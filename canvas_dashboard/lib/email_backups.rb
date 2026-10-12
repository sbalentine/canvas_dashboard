require "base64"
require "cgi"
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
DIGEST_SEND_HOUR = 6
$email_send_mutex = Mutex.new
$scheduled_email_attempts = {}

class EmailConfigurationError < StandardError; end

def empty_scheduled_email_settings
  {
    "backup_recipients" => [],
    "backup_daily_enabled" => false,
    "last_backup_sent_on" => nil,
    "digest_recipients" => [],
    "digest_daily_enabled" => false,
    "last_digest_sent_on" => nil
  }
end

def normalize_email_recipients(value)
  values =
    if value.is_a?(Array)
      value
    else
      value.to_s.split(/[\s,;]+/)
    end

  values.map { |email| email.to_s.strip.downcase }.reject(&:empty?).uniq
end

def load_scheduled_email_settings
  return empty_scheduled_email_settings unless File.exist?(BACKUP_SETTINGS_FILE)

  stored = JSON.parse(File.read(BACKUP_SETTINGS_FILE))
  return empty_scheduled_email_settings unless stored.is_a?(Hash)

  legacy_recipient = stored["recipient_email"].to_s
  {
    "backup_recipients" => normalize_email_recipients(
      stored["backup_recipients"] || legacy_recipient
    ),
    "backup_daily_enabled" =>
      stored.key?("backup_daily_enabled") ?
        stored["backup_daily_enabled"] == true :
        stored["daily_enabled"] == true,
    "last_backup_sent_on" =>
      stored["last_backup_sent_on"] || stored["last_daily_sent_on"],
    "digest_recipients" =>
      normalize_email_recipients(stored["digest_recipients"]),
    "digest_daily_enabled" => stored["digest_daily_enabled"] == true,
    "last_digest_sent_on" => stored["last_digest_sent_on"]
  }
rescue JSON::ParserError => e
  puts "Unable to load scheduled email settings: #{e.message}"
  empty_scheduled_email_settings
end

def save_scheduled_email_settings(settings)
  FileUtils.mkdir_p(File.dirname(BACKUP_SETTINGS_FILE))

  temporary_file = "#{BACKUP_SETTINGS_FILE}.tmp.#{$$}"
  File.write(temporary_file, JSON.pretty_generate(settings))
  File.rename(temporary_file, BACKUP_SETTINGS_FILE)
end

def valid_scheduled_email?(value)
  value.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
end

def validate_recipient_list(recipients, label:, required:)
  if required && recipients.empty?
    raise ArgumentError, "Enter at least one #{label} email address"
  end

  invalid = recipients.reject { |email| valid_scheduled_email?(email) }
  return if invalid.empty?

  raise ArgumentError, "Invalid email address: #{invalid.first}"
end

def scheduled_email_settings_fields(request)
  backup_recipients = normalize_email_recipients(
    request.query["backup_recipients"]
  )
  digest_recipients = normalize_email_recipients(
    request.query["digest_recipients"]
  )
  backup_daily_enabled = request.query["backup_daily_enabled"] == "true"
  digest_daily_enabled = request.query["digest_daily_enabled"] == "true"

  validate_recipient_list(
    backup_recipients,
    label: "backup recipient",
    required: backup_daily_enabled
  )
  validate_recipient_list(
    digest_recipients,
    label: "digest recipient",
    required: digest_daily_enabled
  )

  existing = load_scheduled_email_settings
  existing.merge(
    "backup_recipients" => backup_recipients,
    "backup_daily_enabled" => backup_daily_enabled,
    "digest_recipients" => digest_recipients,
    "digest_daily_enabled" => digest_daily_enabled
  )
end

def backup_json(value)
  "#{JSON.pretty_generate(value)}\n"
end

def backup_payloads(now: Time.now)
  journal = $event_journal_mutex.synchronize do
    Marshal.load(Marshal.dump($event_journal))
  end
  settings = load_scheduled_email_settings.slice(
    "backup_recipients",
    "backup_daily_enabled",
    "digest_recipients",
    "digest_daily_enabled"
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

def backup_archive_filename(now)
  "school-dashboard-backup-#{now.strftime("%Y-%m-%d-%H%M%S")}.zip"
end

def gmail_email_configuration
  sender = options["gmail_sender"].to_s.strip
  password = options["gmail_app_password"].to_s.gsub(/\s+/, "")

  unless valid_scheduled_email?(sender) && !password.empty?
    raise EmailConfigurationError,
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

def deliver_email_messages(sender:, password:, messages:)
  smtp = Net::SMTP.new("smtp.gmail.com", 587)
  smtp.enable_starttls_auto
  smtp.open_timeout = 10
  smtp.read_timeout = 30

  smtp.start("localhost", sender, password, :plain) do |connection|
    messages.each do |delivery|
      connection.send_message(
        delivery.fetch(:message),
        sender,
        delivery.fetch(:recipient)
      )
    end
  end
end

def send_school_dashboard_backup(recipients, now: Time.now)
  recipients = normalize_email_recipients(recipients)
  validate_recipient_list(recipients, label: "backup recipient", required: true)

  $email_send_mutex.synchronize do
    gmail = gmail_email_configuration
    archive = build_backup_archive(now: now)
    filename = backup_archive_filename(now)
    messages = recipients.map do |recipient|
      {
        recipient: recipient,
        message: backup_email_message(
          sender: gmail[:sender],
          recipient: recipient,
          archive: archive,
          filename: filename,
          now: now
        )
      }
    end

    deliver_email_messages(
      sender: gmail[:sender],
      password: gmail[:password],
      messages: messages
    )

    filename
  end
end

def digest_course_name(data, mappings, course_id)
  mappings.fetch(course_id.to_s, course_name(data, course_id))
end

def digest_grade_snapshot(data, mappings, overrides)
  combined_grade_submissions(data, overrides)
    .group_by { |submission| submission.dig("assignment", "course_id").to_s }
    .filter_map do |course_id, submissions|
      earned = submissions.sum { |submission| submission["score"].to_f }
      possible = submissions.sum do |submission|
        submission.dig("assignment", "points_possible").to_f
      end
      calculated = percentage(earned, possible)
      next unless calculated

      {
        "course_id" => course_id,
        "name" => digest_course_name(data, mappings, course_id),
        "percentage" => calculated.round,
        "letter" => letter_grade(calculated)
      }
    end
    .sort_by { |grade| [-grade["percentage"], grade["name"]] }
end

def digest_assignments_for(data, date)
  assignments = Array(data["upcoming"])
  unique = {}

  assignments.each do |assignment|
    due = assignment_due_time(assignment)
    next unless due&.getlocal&.to_date == date

    course_id = assignment_course_id(assignment)
    assignment_id_value = assignment_id(assignment)
    submission = submission_for(data, course_id, assignment_id_value)
    next if submission_complete?(submission)

    key = "#{course_id}:#{assignment_id_value || assignment_name(assignment)}"
    unique[key] ||= assignment
  end

  unique.values.sort_by do |assignment|
    [assignment_due_time(assignment), assignment_name(assignment)]
  end
end

def digest_recent_grades(data, overrides, now)
  cutoff = now - (7 * 24 * 60 * 60)

  combined_grade_submissions(data, overrides).filter_map do |submission|
    graded_at = parse_canvas_time(submission["graded_at"])
    next unless graded_at && graded_at >= cutoff && graded_at <= now

    submission.merge("_digest_graded_at" => graded_at)
  end.sort_by { |submission| submission["_digest_graded_at"] }.reverse
end

def digest_missing_assignments(data)
  Array(data["missing"]).reject do |assignment|
    submission_complete?(
      submission_for(
        data,
        assignment_course_id(assignment),
        assignment_id(assignment)
      )
    )
  end.sort_by do |assignment|
    [assignment_due_time(assignment) || Time.at(0), assignment_name(assignment)]
  end
end

def digest_data(now: Time.now)
  data = dashboard_data_with_manual || {}
  mappings = load_course_name_mappings
  overrides = load_grade_overrides
  today = now.getlocal.to_date

  {
    "profile_name" => profile_first_name(data),
    "grade_snapshot" => digest_grade_snapshot(data, mappings, overrides),
    "missing" => digest_missing_assignments(data),
    "due_today" => digest_assignments_for(data, today),
    "due_tomorrow" => digest_assignments_for(data, today + 1),
    "important_calendar_dates" => upcoming_school_calendar_events(
      school_calendar_events(now: now),
      today: today
    ),
    "recent_grades" => digest_recent_grades(data, overrides, now),
    "data" => data,
    "mappings" => mappings
  }
end

def digest_assignment_text(assignment, digest)
  due = assignment_due_time(assignment)
  course_id = assignment_course_id(assignment)
  course = digest_course_name(
    digest["data"],
    digest["mappings"],
    course_id
  )
  due_label =
    if due
      "#{date_label(due)} at #{due_time_label(due)}"
    else
      "No due date"
    end
  "#{assignment_name(assignment)} - #{course} - #{due_label}"
end

def digest_text_body(digest, now)
  lines = [
    "Daily Digest for #{digest["profile_name"]} for #{now.strftime("%B %-d, %Y")}",
    "",
    "CURRENT GRADES"
  ]

  if digest["grade_snapshot"].empty?
    lines << "No graded assignments yet."
  else
    digest["grade_snapshot"].each do |grade|
      lines << "#{grade["name"]}: #{grade["percentage"]}% (#{grade["letter"]})"
    end
  end

  lines.concat(["", "MISSING WORK"])
  if digest["missing"].empty?
    lines << "No missing work."
  else
    digest["missing"].each do |assignment|
      lines << digest_assignment_text(assignment, digest)
    end
  end

  [["DUE TODAY", "due_today"], ["DUE TOMORROW", "due_tomorrow"]].each do |title, key|
    lines.concat(["", title])
    assignments = digest[key]
    if assignments.empty?
      lines << "Nothing due."
    else
      assignments.each { |assignment| lines << digest_assignment_text(assignment, digest) }
    end
  end

  lines.concat(["", "IMPORTANT CALENDAR DATES"])
  if digest["important_calendar_dates"].empty?
    lines << "No important dates in the next 30 days."
  else
    digest["important_calendar_dates"].each do |event|
      date_label =
        if event["end_date"] > event["start_date"]
          "#{event["start_date"].strftime("%A, %B %-d")} through " \
            "#{event["end_date"].strftime("%A, %B %-d")}"
        else
          event["start_date"].strftime("%A, %B %-d")
        end
      lines << "#{event["title"]} - #{date_label}"
    end
  end

  lines.concat(["", "GRADES POSTED IN THE LAST 7 DAYS"])
  if digest["recent_grades"].empty?
    lines << "No grades posted."
  else
    digest["recent_grades"].each do |submission|
      assignment = submission["assignment"]
      course = digest_course_name(
        digest["data"],
        digest["mappings"],
        assignment["course_id"]
      )
      lines << "#{assignment["name"]} - #{course}: " \
        "#{format_number(submission["score"])}/" \
        "#{format_number(assignment["points_possible"])} " \
        "(#{submission["_digest_graded_at"].getlocal.strftime("%b %-d")})"
    end
  end

  lines.join("\n")
end

def digest_grade_colors(letter)
  {
    "A" => { foreground: "#027a48", background: "#ecfdf3" },
    "B" => { foreground: "#175cd3", background: "#eff8ff" },
    "C" => { foreground: "#b54708", background: "#fffaeb" },
    "D" => { foreground: "#c4320a", background: "#fff6ed" },
    "F" => { foreground: "#b42318", background: "#fff1f0" }
  }.fetch(
    letter,
    { foreground: "#344054", background: "#f9fafb" }
  )
end

def digest_recent_grade_colors(score, possible)
  calculated = percentage(score, possible)

  if calculated && calculated >= 100
    {
      foreground: "#8a5a00",
      background: "#fff7d6",
      border: "#e8b931"
    }
  elsif calculated && calculated < 70
    {
      foreground: "#b42318",
      background: "#fff1f0",
      border: "#fecdca"
    }
  else
    {
      foreground: "#344054",
      background: "#ffffff",
      border: "#eaecf0"
    }
  end
end

def digest_assignment_html(assignment, digest)
  due = assignment_due_time(assignment)
  course = digest_course_name(
    digest["data"],
    digest["mappings"],
    assignment_course_id(assignment)
  )
  due_label =
    if due
      "#{date_label(due)}<br><span style=\"color:#667085;font-size:12px;\">" \
        "#{due_time_label(due)}</span>"
    else
      "No due date"
    end

  <<~HTML
    <tr>
      <td style="padding:10px 12px;border-bottom:1px solid #eaecf0;">
        <strong>#{CGI.escapeHTML(assignment_name(assignment))}</strong><br>
        <span style="color:#667085;font-size:13px;">#{CGI.escapeHTML(course)}</span>
      </td>
      <td style="padding:10px 12px;border-bottom:1px solid #eaecf0;text-align:right;white-space:nowrap;">
        #{due_label}
      </td>
    </tr>
  HTML
end

def digest_html_body(digest, now)
  grade_cards =
    if digest["grade_snapshot"].empty?
      '<p style="color:#667085;">No graded assignments yet.</p>'
    else
      cards = digest["grade_snapshot"].map do |grade|
        colors = digest_grade_colors(grade["letter"])
        <<~HTML
          <td class="grade-card-cell" style="width:50%;padding:8px;vertical-align:top;">
            <div style="padding:14px;border:1px solid #{colors[:foreground]};border-top:4px solid #{colors[:foreground]};border-radius:12px;text-align:center;background:#{colors[:background]};">
              <div style="font-size:13px;color:#475467;">#{CGI.escapeHTML(grade["name"])}</div>
              <div style="margin-top:5px;font-size:26px;font-weight:800;color:#{colors[:foreground]};">#{grade["percentage"]}%</div>
              <div style="font-size:16px;font-weight:800;color:#{colors[:foreground]};">#{grade["letter"]}</div>
            </div>
          </td>
        HTML
      end

      cards.each_slice(2).map do |row|
        "<tr>#{row.join}#{"<td></td>" if row.length == 1}</tr>"
      end.join
    end

  assignment_section = lambda do |title, assignments|
    section_colors = {
      "Missing Work" => { foreground: "#b42318", background: "#fff1f0", border: "#fecdca" },
      "Due Today" => { foreground: "#5925dc", background: "#f4f3ff", border: "#d9d6fe" },
      "Due Tomorrow" => { foreground: "#175cd3", background: "#eff8ff", border: "#b2ddff" }
    }.fetch(
      title,
      { foreground: "#344054", background: "#f9fafb", border: "#eaecf0" }
    )
    rows =
      if assignments.empty?
        '<tr><td style="padding:12px;color:#667085;">Nothing due.</td></tr>'
      else
        assignments.map { |assignment| digest_assignment_html(assignment, digest) }.join
      end

    <<~HTML
      <h2 style="margin:28px 0 8px;font-size:20px;color:#{section_colors[:foreground]};">#{title}</h2>
      <table role="presentation" style="width:100%;border:1px solid #{section_colors[:border]};border-collapse:collapse;border-radius:12px;background:#{section_colors[:background]};">
        #{rows}
      </table>
    HTML
  end

  recent_rows =
    if digest["recent_grades"].empty?
      '<tr><td style="padding:12px;color:#667085;">No grades posted.</td></tr>'
    else
      digest["recent_grades"].map do |submission|
        assignment = submission["assignment"]
        course = digest_course_name(
          digest["data"],
          digest["mappings"],
          assignment["course_id"]
        )
        colors = digest_recent_grade_colors(
          submission["score"],
          assignment["points_possible"]
        )
        <<~HTML
          <tr style="background:#{colors[:background]};color:#{colors[:foreground]};">
            <td style="padding:10px 12px;border-bottom:1px solid #{colors[:border]};">
              <strong style="color:#{colors[:foreground]};">#{CGI.escapeHTML(assignment["name"].to_s)}</strong><br>
              <span style="color:#667085;font-size:13px;">#{CGI.escapeHTML(course)}</span>
            </td>
            <td style="padding:10px 12px;border-bottom:1px solid #{colors[:border]};text-align:right;white-space:nowrap;">
              <strong style="color:#{colors[:foreground]};">#{format_number(submission["score"])}/#{format_number(assignment["points_possible"])}</strong><br>
              <span style="color:#667085;font-size:12px;">#{submission["_digest_graded_at"].getlocal.strftime("%b %-d")}</span>
            </td>
          </tr>
        HTML
      end.join
    end

  calendar_rows =
    if digest["important_calendar_dates"].empty?
      '<tr><td style="padding:12px;color:#667085;">No important dates in the next 30 days.</td></tr>'
    else
      digest["important_calendar_dates"].map do |event|
        date_label =
          if event["end_date"] > event["start_date"]
            "#{event["start_date"].strftime("%a, %b %-d")} through " \
              "#{event["end_date"].strftime("%a, %b %-d")}"
          else
            event["start_date"].strftime("%A, %b %-d")
          end
        location =
          if event["location"].empty?
            ""
          else
            "<br><span style=\"color:#667085;font-size:12px;\">" \
              "#{CGI.escapeHTML(event["location"])}</span>"
          end

        <<~HTML
          <tr>
            <td style="padding:10px 12px;border-bottom:1px solid #d9d6fe;">
              <strong>#{CGI.escapeHTML(event["title"])}</strong>#{location}
            </td>
            <td style="padding:10px 12px;border-bottom:1px solid #d9d6fe;text-align:right;white-space:nowrap;">
              #{date_label}
            </td>
          </tr>
        HTML
      end.join
    end

  <<~HTML
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          @media only screen and (max-width: 600px) {
            .digest-wrapper {
              padding: 12px !important;
            }

            .digest-header {
              margin-bottom: 16px !important;
              padding: 18px !important;
              border-radius: 12px !important;
            }

            .digest-title {
              font-size: 23px !important;
              line-height: 1.25 !important;
            }

            .grade-snapshot {
              padding: 14px !important;
              border-radius: 12px !important;
            }

            .grade-card-cell {
              display: block !important;
              width: auto !important;
              padding: 6px 0 !important;
            }
          }
        </style>
      </head>
      <body style="margin:0;padding:0;background:#f4f6f8;font-family:Arial,sans-serif;color:#1d2939;">
        <div class="digest-wrapper" style="max-width:720px;margin:0 auto;padding:24px;">
          <div class="digest-header" style="margin-bottom:22px;padding:22px;border-radius:16px;background:#5b67d6;color:#ffffff;">
            <h1 class="digest-title" style="margin:0;font-size:28px;line-height:1.25;color:#ffffff;">Daily Digest for #{CGI.escapeHTML(digest["profile_name"])} for #{now.strftime("%B %-d, %Y")}</h1>
          </div>

          <div class="grade-snapshot" style="padding:20px;border-radius:16px;background:#f4f3ff;border:1px solid #d9d6fe;">
            <h2 style="margin:0 0 12px;font-size:20px;color:#5925dc;">Current Grade Snapshot</h2>
            <table role="presentation" style="width:100%;">#{grade_cards}</table>
          </div>

          #{assignment_section.call("Missing Work", digest["missing"])}
          #{assignment_section.call("Due Today", digest["due_today"])}
          #{assignment_section.call("Due Tomorrow", digest["due_tomorrow"])}

          <h2 style="margin:28px 0 8px;font-size:20px;color:#4753bd;">Important Calendar Dates</h2>
          <table role="presentation" style="width:100%;border:1px solid #d9d6fe;border-collapse:collapse;border-radius:12px;background:#f4f3ff;">
            #{calendar_rows}
          </table>

          <h2 style="margin:28px 0 8px;font-size:20px;color:#344054;">Grades Posted in the Last 7 Days</h2>
          <table role="presentation" style="width:100%;border:1px solid #eaecf0;border-collapse:collapse;border-radius:12px;background:#ffffff;">
            #{recent_rows}
          </table>
        </div>
      </body>
    </html>
  HTML
end

def digest_email_message(sender:, recipient:, digest:, now:)
  boundary = "school-dashboard-digest-#{SecureRandom.hex(16)}"
  text = digest_text_body(digest, now)
  html = digest_html_body(digest, now)

  [
    "From: School Dashboard <#{sender}>",
    "To: #{recipient}",
    "Subject: School Dashboard Daily Digest for #{now.strftime("%B %-d, %Y")}",
    "Date: #{now.rfc2822}",
    "MIME-Version: 1.0",
    "Content-Type: multipart/alternative; boundary=\"#{boundary}\"",
    "",
    "--#{boundary}",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    text,
    "--#{boundary}",
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    html,
    "--#{boundary}--",
    ""
  ].join("\r\n")
end

def send_school_dashboard_digest(recipients, now: Time.now)
  recipients = normalize_email_recipients(recipients)
  validate_recipient_list(recipients, label: "digest recipient", required: true)

  $email_send_mutex.synchronize do
    gmail = gmail_email_configuration
    digest = digest_data(now: now)
    messages = recipients.map do |recipient|
      {
        recipient: recipient,
        message: digest_email_message(
          sender: gmail[:sender],
          recipient: recipient,
          digest: digest,
          now: now
        )
      }
    end

    deliver_email_messages(
      sender: gmail[:sender],
      password: gmail[:password],
      messages: messages
    )

    recipients.length
  end
end

def scheduled_email_due?(settings, type, now)
  prefix = type.to_s
  hour = type == :backup ? BACKUP_SEND_HOUR : DIGEST_SEND_HOUR

  settings["#{prefix}_daily_enabled"] &&
    now.hour == hour &&
    settings["last_#{prefix}_sent_on"] != now.to_date.iso8601 &&
    $scheduled_email_attempts[[type, now.to_date]] != true
end

def send_scheduled_email_if_due(type, now = Time.now)
  settings = load_scheduled_email_settings
  return false unless scheduled_email_due?(settings, type, now)

  $scheduled_email_attempts[[type, now.to_date]] = true
  recipients = settings["#{type}_recipients"]

  if type == :backup
    send_school_dashboard_backup(recipients, now: now)
  else
    send_school_dashboard_digest(recipients, now: now)
  end

  settings["last_#{type}_sent_on"] = now.to_date.iso8601
  save_scheduled_email_settings(settings)
  true
rescue => e
  puts "Unable to send scheduled #{type} email: #{e.class}: #{e.message}"
  false
end

def send_scheduled_emails_if_due(now = Time.now)
  {
    backup: send_scheduled_email_if_due(:backup, now),
    digest: send_scheduled_email_if_due(:digest, now)
  }
end

def start_scheduled_email_thread
  Thread.new do
    loop do
      send_scheduled_emails_if_due
      sleep 60
    end
  end
end
