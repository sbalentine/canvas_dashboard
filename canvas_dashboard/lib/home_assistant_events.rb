require "json"
require "net/http"
require "uri"

HOME_ASSISTANT_API_URL = ENV.fetch(
  "HOME_ASSISTANT_API_URL",
  "http://supervisor/core/api"
)
HOME_ASSISTANT_EVENT_TYPE = "school_dashboard_activity"

def home_assistant_http_request(uri, request)
  Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: 5,
    read_timeout: 5
  ) do |http|
    http.request(request)
  end
end

def publish_home_assistant_event(event)
  token = ENV["SUPERVISOR_TOKEN"].to_s
  return false if token.empty?

  uri = URI(
    "#{HOME_ASSISTANT_API_URL}/events/#{HOME_ASSISTANT_EVENT_TYPE}"
  )
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(event)

  response = home_assistant_http_request(uri, request)
  raise "HTTP #{response.code}" unless response.code.to_i.between?(200, 299)

  true
rescue => e
  puts(
    "Unable to publish Home Assistant event: " \
    "#{e.class}: #{e.message}"
  )
  false
end

def publish_home_assistant_events(events)
  Array(events).map do |event|
    publish_home_assistant_event(event)
  end
end