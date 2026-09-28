require_relative "test_helper"

class CanvasTest < Minitest::Test
  def http_response(response_class, body, code, message)
    response = response_class.new("1.1", code, message)
    response.instance_variable_set(:@read, true)
    response.body = body
    response
  end

  def test_options_and_token_expiration_use_environment
    ENV["CANVAS_TOKEN"] = "environment-token"
    ENV["TOKEN_EXPIRES"] = (Date.today + 5).iso8601

    assert_equal "environment-token", options["canvas_token"]
    assert_equal Date.today + 5, token_expiration
    assert_equal 5, token_days_remaining
  ensure
    ENV["CANVAS_TOKEN"] = "test-token"
    ENV.delete("TOKEN_EXPIRES")
  end

  def test_invalid_or_missing_token_values
    ENV["CANVAS_TOKEN"] = " "
    error = assert_raises(RuntimeError) { load_token }
    assert_match(/not configured/, error.message)

    ENV["TOKEN_EXPIRES"] = "not-a-date"
    assert_nil token_expiration
  ensure
    ENV["CANVAS_TOKEN"] = "test-token"
    ENV.delete("TOKEN_EXPIRES")
  end

  def test_canvas_get_sends_bearer_token_and_parses_json
    response = http_response(Net::HTTPOK, '{"id":123}', "200", "OK")
    request_seen = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      request_seen = request
      response
    end

    start = lambda do |host, port, **options, &block|
      assert_equal "temecula.instructure.com", host
      assert_equal 443, port
      assert_equal true, options[:use_ssl]
      block.call(fake_http)
    end

    result = with_replaced_method(Net::HTTP, :start, start) do
      canvas_get("/api/v1/users/self/profile")
    end

    assert_equal({ "id" => 123 }, result)
    assert_equal "Bearer test-token", request_seen["Authorization"]
  end

  def test_canvas_form_request_encodes_fields_and_rejects_unknown_method
    response = http_response(Net::HTTPOK, '{"id":7}', "200", "OK")
    request_seen = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      request_seen = request
      response
    end

    result = with_replaced_method(Net::HTTP, :start, ->(*, **, &block) { block.call(fake_http) }) do
      canvas_form_request(:post, "/api/v1/planner_notes", "title" => "Read chapter")
    end

    assert_equal({ "id" => 7 }, result)
    assert_instance_of Net::HTTP::Post, request_seen
    assert_equal "title=Read+chapter", request_seen.body
    assert_raises(ArgumentError) { canvas_form_request(:delete, "/anything", {}) }
  end

  def test_canvas_errors_include_http_status
    response = http_response(Net::HTTPUnauthorized, "no", "401", "Unauthorized")
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_request| response }

    error = with_replaced_method(Net::HTTP, :start, ->(*, **, &block) { block.call(fake_http) }) do
      assert_raises(RuntimeError) { canvas_get("/api/v1/users/self/profile") }
    end

    assert_match(/401 Unauthorized/, error.message)
  end
end