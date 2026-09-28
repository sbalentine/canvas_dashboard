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
    $dashboard_data = {
      "profile" => { "short_name" => "Avery" },
      "courses" => [],
      "course_names" => {},
      "grades" => [],
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

  def request(path, request_class = Net::HTTP::Get)
    uri = URI("http://127.0.0.1:#{DASHBOARD_TEST_PORT}#{path}")
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request_class.new(uri))
    end
  end

  def test_dashboard_and_static_routes
    dashboard = request("/")
    stylesheet = request("/dashboard.css")
    manifest = request("/manifest.json")
    class_names = request("/class-names")

    assert_equal "200", dashboard.code
    assert_includes dashboard.body, "Good"
    assert_equal "text/css; charset=utf-8", stylesheet["Content-Type"]
    assert_equal "School Dashboard", JSON.parse(manifest.body)["name"]
    assert_equal "200", class_names.code
    assert_includes class_names.body, "Class Names"
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