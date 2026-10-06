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

    assert_equal "200", dashboard.code
    assert_includes dashboard.body, "Good"
    assert_equal "text/css; charset=utf-8", stylesheet["Content-Type"]
    assert_equal "School Dashboard", JSON.parse(manifest.body)["name"]
    assert_equal "200", class_names.code
    assert_includes class_names.body, "Class Names"
    assert_equal "200", grades.code
    assert_includes grades.body, "Edit Assignment Grades"
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

  def test_status_route_exposes_home_assistant_contract
    response = request("/api/status")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["canvas_available"]
    assert_equal 0, body["latest_event_id"]
    assert_equal 0, body["missing_count"]
    assert_equal "no-cache", response["Cache-Control"]
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