require_relative "test_helper"

class HomeAssistantEventsTest < Minitest::Test
  Response = Struct.new(:code)

  def test_publish_sends_authenticated_event_request
    request_details = nil
    replacement = lambda do |uri, request|
      request_details = {
        uri: uri.to_s,
        authorization: request["Authorization"],
        content_type: request["Content-Type"],
        body: JSON.parse(request.body)
      }
      Response.new("200")
    end

    with_supervisor_token("secret") do
      with_replaced_method(self, :home_assistant_http_request, replacement) do
        assert publish_home_assistant_event(
          "id" => 7,
          "type" => "grade_posted"
        )
      end
    end

    assert_equal(
      "http://supervisor/core/api/events/school_dashboard_activity",
      request_details[:uri]
    )
    assert_equal "Bearer secret", request_details[:authorization]
    assert_equal "application/json", request_details[:content_type]
    assert_equal(
      { "id" => 7, "type" => "grade_posted" },
      request_details[:body]
    )
  end

  def test_publish_is_disabled_without_supervisor_token
    with_supervisor_token(nil) do
      refute publish_home_assistant_event("id" => 1)
    end
  end

  def test_publish_failure_is_logged_and_does_not_raise
    replacement = ->(_uri, _request) { Response.new("503") }

    output = with_supervisor_token("secret") do
      with_replaced_method(self, :home_assistant_http_request, replacement) do
        capture_io do
          refute publish_home_assistant_event("id" => 1)
        end.first
      end
    end

    assert_includes output, "HTTP 503"
  end

  private

  def with_supervisor_token(value)
    previous = ENV["SUPERVISOR_TOKEN"]

    if value
      ENV["SUPERVISOR_TOKEN"] = value
    else
      ENV.delete("SUPERVISOR_TOKEN")
    end

    yield
  ensure
    if previous
      ENV["SUPERVISOR_TOKEN"] = previous
    else
      ENV.delete("SUPERVISOR_TOKEN")
    end
  end
end