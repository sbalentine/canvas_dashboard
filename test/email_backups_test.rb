require_relative "test_helper"

class EmailBackupsTest < Minitest::Test
  def setup
    FileUtils.rm_f(BACKUP_SETTINGS_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
    $dashboard_data = base_data
    $event_journal = { "next_id" => 1, "events" => [] }
    $scheduled_email_attempts = {}
    $school_calendar_cache = nil
  end

  def teardown
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    $school_calendar_cache = nil
  end

  def base_data
    {
      "profile" => { "short_name" => "Avery" },
      "courses" => [
        { "id" => 1, "name" => "Math" },
        { "id" => 2, "name" => "Science" }
      ],
      "course_names" => { "1" => "Math", "2" => "Science" },
      "grades" => [],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {}
    }
  end

  def scheduled_settings(overrides = {})
    empty_scheduled_email_settings.merge(overrides)
  end

  def test_scheduled_email_settings_round_trip
    settings = scheduled_settings(
      "backup_recipients" => ["backup@example.com"],
      "backup_daily_enabled" => true,
      "digest_recipients" => ["one@example.com", "two@example.com"],
      "digest_daily_enabled" => true
    )

    save_scheduled_email_settings(settings)

    assert_equal settings, load_scheduled_email_settings
  end

  def test_legacy_backup_settings_are_migrated
    File.write(
      BACKUP_SETTINGS_FILE,
      JSON.generate(
        "recipient_email" => "parent@example.com",
        "daily_enabled" => true,
        "last_daily_sent_on" => "2026-10-11"
      )
    )

    settings = load_scheduled_email_settings

    assert_equal ["parent@example.com"], settings["backup_recipients"]
    assert settings["backup_daily_enabled"]
    assert_equal "2026-10-11", settings["last_backup_sent_on"]
    assert_empty settings["digest_recipients"]
  end

  def test_recipient_lists_accept_newlines_commas_and_remove_duplicates
    assert_equal(
      ["one@example.com", "two@example.com"],
      normalize_email_recipients(
        "One@example.com\n two@example.com,one@example.com"
      )
    )
  end

  def test_archive_contains_dashboard_data_without_credentials
    save_manual_coursework(
      "courses" => { "piano" => { "name" => "Piano" } },
      "assignments" => {}
    )
    save_scheduled_email_settings(
      scheduled_settings(
        "backup_recipients" => ["backup@example.com"],
        "digest_recipients" => ["digest@example.com"]
      )
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

  def test_backup_email_has_requested_subject_and_only_attachment
    now = Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    message = backup_email_message(
      sender: "sender@gmail.com",
      recipient: "parent@example.com",
      archive: "zip contents",
      filename: "backup.zip",
      now: now
    )

    assert_includes message, "Subject: EmberGuide Backup for October 11, 2026"
    assert_includes message, "Content-Disposition: attachment; filename=\"backup.zip\""
    refute_includes message, "Content-Type: text/plain"
  end

  def test_backup_archive_filename_uses_timestamp
    now = Time.new(2026, 10, 11, 20, 8, 9, "-07:00")

    assert_equal(
      "emberguide-backup-2026-10-11-200809.zip",
      backup_archive_filename(now)
    )
  end

  def test_backup_sends_separate_messages_to_multiple_recipients
    configure_gmail
    delivery = nil

    with_replaced_method(
      self,
      :deliver_email_messages,
      ->(**arguments) { delivery = arguments }
    ) do
      send_school_dashboard_backup(
        ["one@example.com", "two@example.com"],
        now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
      )
    end

    assert_equal %w[one@example.com two@example.com],
      delivery[:messages].map { |message| message[:recipient] }
    delivery[:messages].each do |message|
      refute_includes message[:message], "two@example.com" if
        message[:recipient] == "one@example.com"
    end
  end

  def test_digest_contains_snapshot_missing_due_work_and_recent_grades
    now = Time.new(2026, 10, 11, 6, 0, 0, "-07:00")
    $dashboard_data["grades"] = [
      graded_submission(10, 1, "Quiz", 9, 10, "2026-10-08T12:00:00-07:00"),
      graded_submission(20, 2, "Lab", 10, 10, "2026-10-10T12:00:00-07:00"),
      graded_submission(21, 2, "Old Lab", 10, 10, "2026-10-01T12:00:00-07:00")
    ]
    $dashboard_data["missing"] = [
      assignment(30, 1, "Missing Worksheet", "2026-10-09T15:00:00-07:00")
    ]
    $dashboard_data["upcoming"] = [
      assignment(31, 1, "Today Homework", "2026-10-11T15:00:00-07:00"),
      assignment(32, 2, "Tomorrow Project", "2026-10-12T16:00:00-07:00")
    ]
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url, "Elementary")
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: now,
      events: [
        {
          "title" => "Middle School Modified Day",
          "description" => "",
          "location" => "Middle schools",
          "start_date" => Date.new(2026, 10, 15),
          "end_date" => Date.new(2026, 10, 15)
        },
        {
          "title" => "Elementary Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => Date.new(2026, 10, 16),
          "end_date" => Date.new(2026, 10, 16)
        }
      ]
    }

    digest = digest_data(now: now)
    html = digest_html_body(digest, now)
    text = digest_text_body(digest, now)

    assert_equal %w[Science Math], digest["grade_snapshot"].map { |grade| grade["name"] }
    assert_includes html, "Daily Digest"
    assert_includes html, "Avery &middot; October 11, 2026"
    assert_includes html, ">EmberGuide</td>"
    assert_includes text, "Daily Digest for Avery for October 11, 2026"
    assert_includes html, "Current Grade Snapshot"
    assert_includes html, '<meta name="viewport" content="width=device-width, initial-scale=1">'
    assert_includes html, "@media only screen and (max-width: 600px)"
    assert_includes html, 'class="grade-card-cell"'
    assert_includes html, "background:#080711"
    assert_includes html, "background:#11221f"
    assert_includes html, "background:#4fd6a0"
    assert_includes html, "Missing Worksheet"
    assert_includes html,
      'href="https://temecula.instructure.com/courses/1/assignments/30"'
    assert_includes html, "Friday, October 9"
    assert_includes html, "Today Homework"
    assert_includes html, "Tomorrow Project"
    assert_includes html, "Upcoming Schedule Changes"
    assert_includes html, "Middle School Modified Day"
    assert_includes html, "Middle schools"
    refute_includes html, "Elementary Modified Day"
    assert_operator html.index("Lab"), :<, html.index("Quiz")
    assert_includes html,
      'href="https://temecula.instructure.com/courses/2/assignments/20"'
    refute_includes html, "Old Lab"
    assert_includes text, "MISSING WORK"
    assert_includes text,
      "https://temecula.instructure.com/courses/1/assignments/30"
    assert_includes text, "UPCOMING SCHEDULE CHANGES"
    assert_includes text, "Middle School Modified Day - Thursday, October 15"
    assert_includes text,
      "https://temecula.instructure.com/courses/2/assignments/20"
    refute_includes text, "Elementary Modified Day"
    assert_includes text, "GRADES POSTED IN THE LAST 7 DAYS"
  end

  def test_digest_excludes_hidden_assignments_and_their_points
    now = Time.local(2026, 10, 14, 9)
    hidden_assignment = {
      "id" => 10, "course_id" => 1, "name" => "Premature Grade",
      "points_possible" => 100,
      "due_at" => Time.local(2026, 10, 14, 12).iso8601
    }
    $dashboard_data["grades"] = [
      { "assignment_id" => 10, "score" => 0,
        "graded_at" => now.iso8601, "assignment" => hidden_assignment },
      { "assignment_id" => 11, "score" => 9,
        "graded_at" => now.iso8601,
        "assignment" => { "id" => 11, "course_id" => 1,
                          "name" => "Real Grade", "points_possible" => 10 } }
    ]
    $dashboard_data["missing"] = [hidden_assignment]
    $dashboard_data["upcoming"] = [{ "assignment" => hidden_assignment }]
    original = deep_copy($dashboard_data)
    save_grade_overrides("canvas" => { "10" => { "hidden" => true } })

    digest = digest_data(now: now)

    assert_equal [90], digest["grade_snapshot"].map { |grade| grade["percentage"] }
    assert_equal [11], digest["recent_grades"].map { |grade| grade["assignment_id"] }
    assert_empty digest["missing"]
    assert_empty digest["due_today"]
    assert_empty digest["due_tomorrow"]
    refute_includes digest_html_body(digest, now), "Premature Grade"
    refute_includes digest_text_body(digest, now), "Premature Grade"
    assert_equal original, dashboard_data
  end

  def test_digest_grade_colors_match_dashboard_grade_palette
    assert_equal(
      { foreground: "#4fd6a0", background: "#11221f", border: "#285746" },
      digest_grade_colors("A")
    )
    assert_equal(
      { foreground: "#58a6ff", background: "#101d2d", border: "#284f78" },
      digest_grade_colors("B")
    )
    assert_equal(
      { foreground: "#ff7085", background: "#251319", border: "#6d2f3a" },
      digest_grade_colors("F")
    )
  end

  def test_recent_grade_colors_highlight_low_and_perfect_scores
    assert_equal(
      {
        foreground: "#ff7085",
        background: "#251319",
        border: "#6d2f3a"
      },
      digest_recent_grade_colors(6, 10)
    )
    assert_equal(
      {
        foreground: "#ffc96b",
        background: "#211c14",
        border: "#64502b"
      },
      digest_recent_grade_colors(10, 10)
    )
    assert_equal(
      {
        foreground: "#f4f2ff",
        background: "#121020",
        border: "#29263d"
      },
      digest_recent_grade_colors(9, 10)
    )
  end

  def test_digest_sends_separate_html_messages_to_all_recipients
    configure_gmail
    delivery = nil

    with_replaced_method(
      self,
      :deliver_email_messages,
      ->(**arguments) { delivery = arguments }
    ) do
      count = send_school_dashboard_digest(
        ["one@example.com", "two@example.com"],
        now: Time.new(2026, 10, 11, 6, 0, 0, "-07:00")
      )
      assert_equal 2, count
    end

    assert_equal %w[one@example.com two@example.com],
      delivery[:messages].map { |message| message[:recipient] }
    assert_includes delivery[:messages].first[:message], "multipart/alternative"
    assert_includes delivery[:messages].first[:message], "multipart/related"
    assert_includes delivery[:messages].first[:message],
      "Content-ID: <emberguide-logo>"
    assert_includes delivery[:messages].first[:message],
      "Subject: Avery's EmberGuide Daily Digest"
  end

  def test_backup_and_digest_run_once_at_their_scheduled_hours
    settings = scheduled_settings(
      "backup_recipients" => ["backup@example.com"],
      "backup_daily_enabled" => true,
      "digest_recipients" => ["digest@example.com"],
      "digest_daily_enabled" => true
    )
    save_scheduled_email_settings(settings)
    sends = []

    with_replaced_method(
      self,
      :send_school_dashboard_backup,
      ->(recipients, now:) { sends << [:backup, recipients, now.hour] }
    ) do
      with_replaced_method(
        self,
        :send_school_dashboard_digest,
        ->(recipients, now:) { sends << [:digest, recipients, now.hour] }
      ) do
        at_three = Time.new(2026, 10, 11, 3, 5, 0, "-07:00")
        at_six = Time.new(2026, 10, 11, 6, 5, 0, "-07:00")

        assert send_scheduled_email_if_due(:backup, at_three)
        refute send_scheduled_email_if_due(:backup, at_three + 60)
        assert send_scheduled_email_if_due(:digest, at_six)
        refute send_scheduled_email_if_due(:digest, at_six + 60)
      end
    end

    assert_equal [
      [:backup, ["backup@example.com"], 3],
      [:digest, ["digest@example.com"], 6]
    ], sends
  end

  def test_failed_schedule_is_not_retried_every_minute
    save_scheduled_email_settings(
      scheduled_settings(
        "digest_recipients" => ["digest@example.com"],
        "digest_daily_enabled" => true
      )
    )
    attempts = 0
    now = Time.new(2026, 10, 11, 6, 5, 0, "-07:00")

    with_replaced_method(
      self,
      :send_school_dashboard_digest,
      lambda do |_recipients, now:|
        attempts += 1
        raise "SMTP unavailable"
      end
    ) do
      capture_io do
        refute send_scheduled_email_if_due(:digest, now)
        refute send_scheduled_email_if_due(:digest, now + 60)
      end
    end

    assert_equal 1, attempts
    assert_nil load_scheduled_email_settings["last_digest_sent_on"]
  end

  private

  def configure_gmail
    ENV["GMAIL_SENDER"] = "sender@gmail.com"
    ENV["GMAIL_APP_PASSWORD"] = "abcd efgh ijkl mnop"
  end

  def graded_submission(id, course_id, name, score, possible, graded_at)
    {
      "assignment_id" => id,
      "score" => score,
      "graded_at" => graded_at,
      "assignment" => {
        "id" => id,
        "course_id" => course_id,
        "name" => name,
        "html_url" => "/courses/#{course_id}/assignments/#{id}",
        "points_possible" => possible
      }
    }
  end

  def assignment(id, course_id, name, due_at)
    {
      "assignment" => {
        "id" => id,
        "course_id" => course_id,
        "name" => name,
        "html_url" => "/courses/#{course_id}/assignments/#{id}",
        "due_at" => due_at
      }
    }
  end
end
