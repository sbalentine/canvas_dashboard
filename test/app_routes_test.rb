require "net/http"
require "timeout"
require_relative "test_helper"

DASHBOARD_TEST_SERVER_THREAD = Thread.new do
  DASHBOARD_SERVER.start
end

Timeout.timeout(5) do
  Thread.pass until DASHBOARD_SERVER.status == :Running
end

DASHBOARD_TEST_PORT = DASHBOARD_SERVER.listeners.first.addr[1]

Minitest.after_run do
  DASHBOARD_SERVER.shutdown
  DASHBOARD_TEST_SERVER_THREAD.join
end

class AppRoutesTest < Minitest::Test
  def setup
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    FileUtils.rm_f(BACKUP_SETTINGS_FILE)
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    $school_calendar_cache = nil
    $dashboard_data = {
      "profile" => { "short_name" => "Avery" },
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [{
        "assignment_id" => 10,
        "score" => 8,
        "assignment" => {
          "id" => 10,
          "course_id" => 1,
          "name" => "Quiz",
          "points_possible" => 10
        }
      }],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {},
      "updated_at" => "2026-09-27T12:00:00Z"
    }
    $last_successful_update = Time.parse("2026-09-27T12:00:00Z")
    $last_refresh_error = nil
    $event_journal = { "next_id" => 1, "events" => [] }
  end

  def request(path, request_class = Net::HTTP::Get, fields = nil)
    uri = URI("http://127.0.0.1:#{DASHBOARD_TEST_PORT}#{path}")
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      request = request_class.new(uri)
      request.set_form_data(fields) if fields
      http.request(request)
    end
  end

  def test_dashboard_and_static_routes
    dashboard = request("/")
    stylesheet = request("/dashboard.css")
    manifest = request("/manifest.json")
    class_names = request("/class-names")
    grades = request("/grades")
    scheduled_emails = request("/scheduled-emails")
    settings = request("/settings")
    calendar = request("/calendar")
    digest_preview = request("/scheduled-emails/digest-preview")
    backup_download = request("/scheduled-emails/backup-download")

    assert_equal "200", dashboard.code
    assert_includes dashboard.body, "Good"
    assert_equal "text/css; charset=utf-8", stylesheet["Content-Type"]
    assert_equal "School Dashboard", JSON.parse(manifest.body)["name"]
    assert_equal "200", class_names.code
    assert_includes class_names.body, "Class Names"
    assert_equal "200", grades.code
    assert_includes grades.body, "Edit Assignment Grades"
    assert_equal "200", scheduled_emails.code
    assert_includes scheduled_emails.body, "Scheduled Emails"
    assert_includes scheduled_emails.body, "Preview Daily Digest"
    assert_includes scheduled_emails.body, "Download Backup"
    assert_equal "200", settings.code
    assert_includes settings.body, "District Calendar"
    assert_includes settings.body, "Scheduled Emails"
    assert_equal "200", calendar.code
    assert_includes calendar.body, "School Calendar"
    assert_equal "200", digest_preview.code
    assert_equal "text/html; charset=utf-8", digest_preview["Content-Type"]
    assert_equal "no-store", digest_preview["Cache-Control"]
    assert_includes digest_preview.body, "Daily Digest for Avery"
    assert_includes digest_preview.body, "Current Grade Snapshot"
    assert_equal "200", backup_download.code
    assert_equal "application/zip", backup_download["Content-Type"]
    assert_match(
      /\Aattachment; filename="school-dashboard-backup-\d{4}-\d{2}-\d{2}-\d{6}\.zip"\z/,
      backup_download["Content-Disposition"]
    )
    assert_equal "no-store", backup_download["Cache-Control"]
    assert_equal backup_download.body.bytesize.to_s, backup_download["Content-Length"]
  end

  def test_settings_route_saves_calendar_feed_without_exposing_it_on_dashboard
    feed_url = "https://calendar.example.test/private.ics?token=secret"
    saved = request(
      "/settings",
      Net::HTTP::Post,
      "calendar_feed_url" => feed_url,
      "calendar_excluded_keywords" => "Elementary\nHigh School"
    )

    assert_equal "303", saved.code
    assert_equal "/settings?saved=calendar", URI(saved["Location"]).request_uri
    assert_equal feed_url, load_school_calendar_settings["feed_url"]
    assert_equal(
      ["Elementary", "High School"],
      load_school_calendar_settings["excluded_keywords"]
    )

    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: []
    }
    body = request("/").body

    assert_includes body, "Up Next"
    assert_includes body, 'href="/settings"'
    refute_includes body, feed_url
    refute_includes body, "Edit Class Names"
  end

  def test_up_next_shows_only_the_nearest_calendar_change
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url)
    today = Date.today
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: [
        {
          "title" => "First Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => today + 2,
          "end_date" => today + 2
        },
        {
          "title" => "Second Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => today + 3,
          "end_date" => today + 3
        }
      ]
    }

    body = request("/").body
    up_next = body[/<section class="today-summary">.*?<\/section>/m]

    assert_includes up_next, "First Modified Day"
    refute_includes up_next, "Second Modified Day"
    assert_includes body, "Second Modified Day"
  end

  def test_scheduled_email_route_saves_separate_recipients_and_preferences
    response = request(
      "/scheduled-emails",
      Net::HTTP::Post,
      "action" => "save",
      "backup_recipients" => "backup@example.com",
      "backup_daily_enabled" => "true",
      "digest_recipients" => "one@example.com\ntwo@example.com",
      "digest_daily_enabled" => "true"
    )

    assert_equal "303", response.code
    assert_equal "/scheduled-emails?saved=1", URI(response["Location"]).request_uri
    assert_equal(
      {
        "backup_recipients" => ["backup@example.com"],
        "backup_daily_enabled" => true,
        "last_backup_sent_on" => nil,
        "digest_recipients" => ["one@example.com", "two@example.com"],
        "digest_daily_enabled" => true,
        "last_digest_sent_on" => nil
      },
      load_scheduled_email_settings
    )
  end

  def test_scheduled_email_route_reports_missing_gmail_configuration
    response = request(
      "/scheduled-emails",
      Net::HTTP::Post,
      "action" => "send_digest",
      "digest_recipients" => "parent@example.com"
    )

    assert_equal "422", response.code
    assert_includes response.body, "Gmail is not configured"
    assert_includes response.body, "Configure the Gmail sender and app password"
  end

  def test_legacy_backup_route_redirects_to_scheduled_emails
    response = request("/backups")

    assert_equal "303", response.code
    assert_equal "/scheduled-emails", URI(response["Location"]).request_uri
  end

  def test_grade_snapshot_is_sorted_highest_to_lowest
    $dashboard_data["courses"] << { "id" => 2, "name" => "Science" }
    $dashboard_data["course_names"]["2"] = "Science"
    $dashboard_data["grades"] << {
      "assignment_id" => 20,
      "score" => 10,
      "assignment" => {
        "id" => 20,
        "course_id" => 2,
        "name" => "Lab",
        "points_possible" => 10
      }
    }

    body = request("/").body

    assert_operator body.index("Science:"), :<, body.index("Math:")
  end

  def test_grade_route_saves_and_clears_official_grades
    saved = request(
      "/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "9.2",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "303", saved.code
    assert_equal 9.2, load_grade_overrides.dig("canvas", "10", "score")

    editor = request("/grades")
    assert_includes editor.body, "assignment-grade-row is-edited"
    assert_includes editor.body, ">Edited<"

    cleared = request(
      "/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "303", cleared.code
    assert_equal(
      { "canvas" => {}, "custom" => {} },
      load_grade_overrides
    )
  end

  def test_grade_route_rejects_invalid_percentages
    response = request(
      "/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "invalid",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "422", response.code
    assert_includes response.body, "valid number"
  end

  def test_grade_route_adds_infinite_campus_only_assignment
    response = request(
      "/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "",
      "canvas_10_points" => "",
      "new_0_name" => "Unit Test",
      "new_0_course_id" => "1",
      "new_0_score" => "18",
      "new_0_points" => "20",
      "new_0_date" => "2026-10-06",
      "new_1_name" => "Lab Report",
      "new_1_course_id" => "1",
      "new_1_score" => "24",
      "new_1_points" => "25",
      "new_1_date" => "2026-10-05"
    )

    assert_equal "303", response.code

    grades = load_grade_overrides.fetch("custom").values.sort_by { |grade| grade["name"] }
    assert_equal 2, grades.length
    assert_equal ["Lab Report", "Unit Test"], grades.map { |grade| grade["name"] }
    assert_equal [24.0, 18.0], grades.map { |grade| grade["score"] }
    assert_equal [25.0, 20.0], grades.map { |grade| grade["points_possible"] }
  end

  def test_grade_editor_filters_one_class_and_preserves_other_overrides
    $dashboard_data["courses"] << { "id" => 2, "name" => "Science" }
    $dashboard_data["course_names"]["2"] = "Science"
    $dashboard_data["grades"] << {
      "assignment_id" => 20,
      "score" => 7,
      "assignment" => {
        "id" => 20,
        "course_id" => 2,
        "name" => "Lab",
        "points_possible" => 10
      }
    }
    save_grade_overrides(
      "canvas" => {
        "10" => { "score" => 9, "points_possible" => nil },
        "20" => { "score" => 8, "points_possible" => nil }
      },
      "custom" => {
        "math-grade" => {
          "course_id" => "1",
          "name" => "Math Test",
          "score" => 18,
          "points_possible" => 20,
          "graded_at" => "2026-10-01"
        },
        "science-grade" => {
          "course_id" => "2",
          "name" => "Science Test",
          "score" => 19,
          "points_possible" => 20,
          "graded_at" => "2026-10-02"
        }
      }
    )

    editor = request("/grades?course_id=1")

    assert_equal "200", editor.code
    assert_includes editor.body, "Edit Math Grades"
    assert_includes editor.body, "Quiz"
    assert_includes editor.body, "Math Test"
    refute_includes editor.body, "Lab"
    refute_includes editor.body, "Science Test"

    saved = request(
      "/grades",
      Net::HTTP::Post,
      "course_id" => "1",
      "canvas_10_score" => "9.5",
      "canvas_10_points" => "",
      "custom_math-grade_name" => "Math Test",
      "custom_math-grade_course_id" => "1",
      "custom_math-grade_score" => "18",
      "custom_math-grade_points" => "20",
      "custom_math-grade_date" => "2026-10-01"
    )

    assert_equal "303", saved.code
    overrides = load_grade_overrides
    assert_equal 9.5, overrides.dig("canvas", "10", "score")
    assert_equal 8, overrides.dig("canvas", "20", "score")
    assert overrides.fetch("custom").key?("science-grade")
  end

  def test_dashboard_links_each_grade_card_to_its_editor
    dashboard = request("/")

    assert_includes dashboard.body, "/grades?course_id=1"
    assert_includes dashboard.body, "Edit this class"
  end

  def test_grade_editor_rejects_unknown_class
    response = request("/grades?course_id=missing")

    assert_equal "404", response.code
    assert_equal "Class not found", response.body
  end

  def test_status_route_exposes_home_assistant_contract
    response = request("/api/status")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["canvas_available"]
    assert_equal 0, body["latest_event_id"]
    assert_equal 0, body["missing_count"]
    assert_equal "no-cache", response["Cache-Control"]
  end

  def test_manual_coursework_routes_add_class_and_assignment
    course_response = request(
      "/coursework",
      Net::HTTP::Post,
      "action" => "create_course",
      "name" => "Piano"
    )

    assert_equal "303", course_response.code
    course_id = load_manual_coursework.fetch("courses").keys.first

    assignment_response = request(
      "/coursework",
      Net::HTTP::Post,
      "action" => "create_assignment",
      "course_id" => course_id,
      "name" => "Practice scales",
      "due_at" => (Time.now + 86_400).strftime("%Y-%m-%dT%H:%M")
    )

    assert_equal "303", assignment_response.code

    editor = request("/coursework")
    dashboard = request("/")

    assert_includes editor.body, "Piano"
    assert_includes editor.body, "Practice scales"
    assert_includes dashboard.body, "Practice scales"
    assert_includes dashboard.body, "Piano"
  end

  def test_manual_coursework_route_validates_assignment_course
    response = request(
      "/coursework",
      Net::HTTP::Post,
      "action" => "create_assignment",
      "course_id" => "missing",
      "name" => "Practice scales",
      "due_at" => (Time.now + 86_400).strftime("%Y-%m-%dT%H:%M")
    )

    assert_equal "422", response.code
    assert_includes response.body, "valid class"
  end

  def test_class_settings_hide_and_restore_canvas_course
    $dashboard_data["upcoming"] = [{
      "assignment" => {
        "id" => 11,
        "course_id" => 1,
        "name" => "Homework",
        "due_at" => (Time.now + 86_400).iso8601
      }
    }]

    hidden = request(
      "/class-names",
      Net::HTTP::Post,
      "course_1" => "",
      "hidden_course_1" => "true"
    )

    assert_equal "303", hidden.code
    assert_equal ["1"], load_hidden_course_ids
    refute_includes request("/").body, "Homework"
    refute_includes request("/grades").body, "Quiz"

    settings = request("/class-names")
    assert_includes settings.body, "Math"
    assert_match(/hidden_course_1[^>]+checked/, settings.body)

    restored = request(
      "/class-names",
      Net::HTTP::Post,
      "course_1" => ""
    )

    assert_equal "303", restored.code
    assert_empty load_hidden_course_ids
    assert_includes request("/").body, "Homework"
  end

  def test_events_route_filters_by_cursor_and_limit
    append_dashboard_events([
      { "type" => "grade_posted" },
      { "type" => "assignment_submitted" },
      { "type" => "assignment_missing" }
    ])

    response = request("/api/events?after=1&limit=1")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal [3], body["events"].map { |event| event["id"] }
    assert_equal 3, body["latest_event_id"]
  end

  def test_api_routes_validate_methods_and_parameters
    assert_equal "405", request("/api/status", Net::HTTP::Post).code
    assert_equal "400", request("/api/events?after=bad").code
    assert_equal "400", request("/api/events?limit=bad").code
  end
end