require "base64"
require "digest"
require "fileutils"
require "json"
require "net/smtp"
require "securerandom"
require "time"
require "zip"

BACKUP_SETTINGS_FILE =
  ENV.fetch("BACKUP_SETTINGS_FILE") do
    if File.directory?("/data")
      "/data/backup_settings.json"
    else
      File.expand_path(
        "../tmp/backup_settings.json",
        __dir__
      )
    end
  end

BACKUP_SEND_HOUR = 3
$backup_mutex = Mutex.new
$last_daily_backup_attempt_on = nil

class BackupConfigurationError < StandardError; end

def empty_backup_settings
  {
    "recipient_email" => "",
    "daily_enabled" => false,
    "last_daily_sent_on" => nil
  }
end

def load_backup_settings
  return empty_backup_settings unless File.exist?(BACKUP_SETTINGS_FILE)

  settings = JSON.parse(File.read(BACKUP_SETTINGS_FILE))
  return empty_backup_settings unless settings.is_a?(Hash)

  {
    "recipient_email" => settings["recipient_email"].to_s,
    "daily_enabled" => settings["daily_enabled"] == true,
    "last_daily_sent_on" => settings["last_daily_sent_on"]
  }
rescue JSON::ParserError => e
  puts "Unable to load backup settings: #{e.message}"
  empty_backup_settings
end

def save_backup_settings(settings)
  FileUtils.mkdir_p(File.dirname(BACKUP_SETTINGS_FILE))

  temporary_file = "#{BACKUP_SETTINGS_FILE}.tmp.#{$$}"
  File.write(temporary_file, JSON.pretty_generate(settings))
  File.rename(temporary_file, BACKUP_SETTINGS_FILE)
end

def valid_backup_email?(value)
  value.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
end

def backup_settings_fields(request)
  recipient = request.query["recipient_email"].to_s.strip
  daily_enabled = request.query["daily_enabled"] == "true"

  if !recipient.empty? && !valid_backup_email?(recipient)
    raise ArgumentError, "Enter a valid backup email address"
  end
  if daily_enabled && recipient.empty?
    raise ArgumentError, "An email address is required for daily backups"
  end

  existing = load_backup_settings
  existing.merge(
    "recipient_email" => recipient,
    "daily_enabled" => daily_enabled
  )
end

def backup_json(value)
  "#{JSON.pretty_generate(value)}\n"
end

def backup_payloads(now: Time.now)
  journal = $event_journal_mutex.synchronize do
    Marshal.load(Marshal.dump($event_journal))
  end
  settings = load_backup_settings.slice(
    "recipient_email",
    "daily_enabled"
  )

  payloads = {
    "canvas_cache.json" => backup_json(dashboard_data || {}),
    "manual_coursework.json" => backup_json(load_manual_coursework),
    "grade_overrides.json" => backup_json(load_grade_overrides),
    "course_name_mappings.json" => backup_json(load_course_name_mappings),
    "hidden_courses.json" => backup_json(load_hidden_course_ids),
    "event_journal.json" => backup_json(journal),
    "backup_settings.json" => backup_json(settings)
  }

  manifest = {
    "schema_version" => 1,
    "created_at" => now.iso8601,
    "files" => payloads.transform_values do |content|
      {
        "bytes" => content.bytesize,
        "sha256" => Digest::SHA256.hexdigest(content)
      }
    end
  }
  payloads["manifest.json"] = backup_json(manifest)
  payloads
end

def build_backup_archive(now: Time.now)
  buffer = Zip::OutputStream.write_buffer do |archive|
    backup_payloads(now: now).each do |filename, content|
      archive.put_next_entry(filename)
      archive.write(content)
    end
  end

  buffer.string
end

def gmail_backup_configuration
  sender = options["gmail_sender"].to_s.strip
  password = options["gmail_app_password"].to_s.gsub(/\s+/, "")

  unless valid_backup_email?(sender) && !password.empty?
    raise BackupConfigurationError,
      "Configure the Gmail sender and app password in the Home Assistant add-on settings."
  end

  { sender: sender, password: password }
end

def backup_email_message(sender:, recipient:, archive:, filename:, now:)
  boundary = "school-dashboard-#{SecureRandom.hex(16)}"
  encoded_archive = Base64.strict_encode64(archive).scan(/.{1,76}/).join("\r\n")

  [
    "From: School Dashboard <#{sender}>",
    "To: #{recipient}",
    "Subject: School Dashboard Backup for #{now.strftime("%B %-d, %Y")}",
    "Date: #{now.rfc2822}",
    "MIME-Version: 1.0",
    "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
    "",
    "--#{boundary}",
    "Content-Type: application/zip; name=\"#{filename}\"",
    "Content-Disposition: attachment; filename=\"#{filename}\"",
    "Content-Transfer-Encoding: base64",
    "",
    encoded_archive,
    "--#{boundary}--",
    ""
  ].join("\r\n")
end

def deliver_backup_message(sender:, password:, recipient:, message:)
  smtp = Net::SMTP.new("smtp.gmail.com", 587)
  smtp.enable_starttls_auto
  smtp.open_timeout = 10
  smtp.read_timeout = 30

  smtp.start("localhost", sender, password, :plain) do |connection|
    connection.send_message(message, sender, recipient)
  end
end

def send_school_dashboard_backup(recipient, now: Time.now)
  raise ArgumentError, "Enter a valid backup email address" unless valid_backup_email?(recipient)

  $backup_mutex.synchronize do
    gmail = gmail_backup_configuration
    archive = build_backup_archive(now: now)
    filename = "school-dashboard-backup-#{now.strftime("%Y-%m-%d-%H%M%S")}.zip"
    message = backup_email_message(
      sender: gmail[:sender],
      recipient: recipient,
      archive: archive,
      filename: filename,
      now: now
    )

    deliver_backup_message(
      sender: gmail[:sender],
      password: gmail[:password],
      recipient: recipient,
      message: message
    )

    filename
  end
end

def send_daily_backup_if_due(now = Time.now)
  settings = load_backup_settings
  return false unless settings["daily_enabled"]
  return false unless now.hour == BACKUP_SEND_HOUR
  return false if settings["last_daily_sent_on"] == now.to_date.iso8601
  return false if $last_daily_backup_attempt_on == now.to_date

  $last_daily_backup_attempt_on = now.to_date

  send_school_dashboard_backup(settings["recipient_email"], now: now)
  settings["last_daily_sent_on"] = now.to_date.iso8601
  save_backup_settings(settings)
  true
rescue => e
  puts "Unable to send daily backup: #{e.class}: #{e.message}"
  false
end

def start_backup_thread
  Thread.new do
    loop do
      send_daily_backup_if_due
      sleep 60
    end
  end
end
