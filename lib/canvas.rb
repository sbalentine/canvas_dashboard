require "net/http"
require "json"
require "uri"
require "date"

BASE_URL = "https://temecula.instructure.com"

# ============================================================
# Configuration
# ============================================================

def options
  if File.exist?("/data/options.json")
    JSON.parse(
      File.read("/data/options.json")
    )
  else
    {
      "canvas_token" => ENV["CANVAS_TOKEN"],
      "token_expires" => ENV["TOKEN_EXPIRES"]
    }
  end
end

def load_token
  token = options["canvas_token"]

  if token.nil? || token.strip.empty?
    raise(
      "Canvas token is not configured. " \
      "Set CANVAS_TOKEN locally or configure " \
      "canvas_token in Home Assistant."
    )
  end

  token
end

def token_expiration
  value = options["token_expires"]

  return nil if value.nil? || value.strip.empty?

  Date.parse(value)
rescue ArgumentError
  nil
end

def token_days_remaining
  expiration = token_expiration

  return nil unless expiration

  (expiration - Date.today).to_i
end

TOKEN = load_token

# ============================================================
# Canvas API
# ============================================================

def canvas_get(path)
  uri = URI("#{BASE_URL}#{path}")

  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{TOKEN}"

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: true,
    open_timeout: 10,
    read_timeout: 30
  ) do |http|
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    raise(
      "Canvas API error: " \
      "#{response.code} #{response.message}"
    )
  end

  JSON.parse(response.body)
end