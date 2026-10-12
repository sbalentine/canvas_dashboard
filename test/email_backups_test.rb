require_relative "test_helper"

class EmailBackupsTest < Minitest::Test
  def setup
    FileUtils.rm_f(BACKUP_SETTINGS_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
    $dashboard_data = {
      "profile" => { "short_name" => "Avery" },
      "courses" => [],
      "course_names" => {},
      "grades" => [],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {}
    }
    $event_journal = { "next_id" => 1, "events" => [] }
    $last_daily_backup_attempt_on = nil
  end

  def teardown
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
  end

  def test_backup_settings_round_trip
    settings = {
      "recipient_email" => "parent@example.com",
      "daily_enabled" => true,
      "last_daily_sent_on" => "2026-10-11"
    }

    save_backup_settings(settings)

    assert_equal settings, load_backup_settings
  end

  def test_archive_contains_dashboard_data_without_credentials
    save_manual_coursework(
      "courses" => { "piano" => { "name" => "Piano" } },
      "assignments" => {}
    )
    save_backup_settings(
      "recipient_email" => "parent@example.com",
      "daily_enabled" => true,
      "last_daily_sent_on" => nil
    )

    archive = build_backup_archive(
      now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    )
    entries = {}
    Zip::File.open_buffer(archive) do |zip|
      zip.each { |entry| entries[entry.name] = entry.get_input_stream.read }
    end

    expected_files = %w[
      backup_settings.json
      canvas_cache.json
      course_name_mappings.json
      event_journal.json
      grade_overrides.json
      hidden_courses.json
      manifest.json
      manual_coursework.json
    ]
    assert_equal expected_files, entries.keys.sort
    assert_equal "Piano", JSON.parse(entries["manual_coursework.json"]).dig(
      "courses",
      "piano",
      "name"
    )
    refute_includes archive, "test-token"
    refute entries.key?("options.json")
  end

  def test_email_has_requested_subject_and_only_attachment
    now = Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    message = backup_email_message(
      sender: "sender@gmail.com",
      recipient: "parent@example.com",
      archive: "zip contents",
      filename: "backup.zip",
      now: now
    )

    assert_includes message, "Subject: School Dashboard Backup for October 11, 2026"
    assert_includes message, "Content-Disposition: attachment; filename=\"backup.zip\""
    refute_includes message, "Content-Type: text/plain"
    refute_includes message, "Attached is"
  end

  def test_send_uses_gmail_configuration_and_in_memory_archive
    ENV["GMAIL_SENDER"] = "sender@gmail.com"
    ENV["GMAIL_APP_PASSWORD"] = "abcd efgh ijkl mnop"
    delivered = nil

    with_replaced_method(
      self,
      :deliver_backup_message,
      ->(**arguments) { delivered = arguments }
    ) do
      filename = send_school_dashboard_backup(
        "parent@example.com",
        now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
      )

      assert_equal "school-dashboard-backup-2026-10-11-030000.zip", filename
    end

    assert_equal "sender@gmail.com", delivered[:sender]
    assert_equal "abcdefghijklmnop", delivered[:password]
    assert_equal "parent@example.com", delivered[:recipient]
    assert_includes delivered[:message], "application/zip"
  end

  def test_daily_backup_sends_once_during_three_am_hour
    save_backup_settings(
      "recipient_email" => "parent@example.com",
      "daily_enabled" => true,
      "last_daily_sent_on" => nil
    )
    sends = []
    now = Time.new(2026, 10, 11, 3, 5, 0, "-07:00")

    with_replaced_method(
      self,
      :send_school_dashboard_backup,
      ->(recipient, now:) { sends << [recipient, now] }
    ) do
      assert send_daily_backup_if_due(now)
      refute send_daily_backup_if_due(now + 60)
      refute send_daily_backup_if_due(now + 21 * 60 * 60)
    end

    assert_equal [["parent@example.com", now]], sends
    assert_equal "2026-10-11", load_backup_settings["last_daily_sent_on"]
  end

  def test_failed_daily_backup_is_not_retried_every_minute
    save_backup_settings(
      "recipient_email" => "parent@example.com",
      "daily_enabled" => true,
      "last_daily_sent_on" => nil
    )
    attempts = 0
    now = Time.new(2026, 10, 11, 3, 5, 0, "-07:00")

    with_replaced_method(
      self,
      :send_school_dashboard_backup,
      lambda do |_recipient, now:|
        attempts += 1
        raise "SMTP unavailable"
      end
    ) do
      refute send_daily_backup_if_due(now)
      refute send_daily_backup_if_due(now + 60)
    end

    assert_equal 1, attempts
    assert_nil load_backup_settings["last_daily_sent_on"]
  end
end
