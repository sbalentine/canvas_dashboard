require "webrick"
require "erb"
require "json"

APP_ROOT = File.expand_path(__dir__)

require_relative "lib/canvas"
require_relative "lib/helpers"
require_relative "lib/course_name_mappings"
require_relative "lib/event_journal"
require_relative "lib/home_assistant_events"
require_relative "lib/dashboard_data"

# ============================================================
# Startup
# ============================================================

if $PROGRAM_NAME == __FILE__
  puts "Starting School Dashboard..."

  initialize_dashboard_data
  initialize_event_journal
  start_refresh_thread
end

# ============================================================
# Web Server
# ============================================================

server = WEBrick::HTTPServer.new(
  Port: ENV.fetch("PORT", "4567").to_i,
  BindAddress: "0.0.0.0",
  AccessLog: [],
  Logger: WEBrick::Log.new(
    $stdout,
    WEBrick::Log::INFO
  )
)

DASHBOARD_SERVER = server

# ============================================================
# Dashboard
# ============================================================

server.mount_proc "/" do |_request, response|
  begin
    data = dashboard_data

    unless data
      response.status = 200
      response["Content-Type"] = "text/html; charset=utf-8"
      response["Cache-Control"] = "no-cache"

      response.body = <<~HTML
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">

          <meta
            name="viewport"
            content="width=device-width, initial-scale=1"
          >

          <link
            rel="stylesheet"
            href="/dashboard.css"
          >

          <title>School Dashboard</title>
        </head>

        <body>
          <main class="container">
            <h1>📚 School Dashboard</h1>
            <p>Waiting for Canvas data...</p>
          </main>
        </body>
        </html>
      HTML

      next
    end

    template = ERB.new(
      File.read(
        File.join(APP_ROOT, "views", "dashboard.erb")
      )
    )

    response.status = 200
    response["Content-Type"] = "text/html; charset=utf-8"
    response["Cache-Control"] = "no-cache"

    response.body = template.result(binding)

  rescue => e
    puts(
      "Dashboard error: " \
      "#{e.class}: #{e.message}"
    )

    puts e.backtrace

    response.status = 500
    response["Content-Type"] = "text/plain; charset=utf-8"

    response.body =
      "Unable to load school dashboard." \
      "\n\n#{e.message}"
  end
end

server.mount_proc "/refresh" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  refresh_dashboard

  response.status = 303
  response["Location"] = "/"
  response.body = ""
end

def todo_form_fields(request, data)
  title = request.query["title"].to_s.strip
  details = request.query["details"].to_s.strip
  todo_date = request.query["todo_date"].to_s
  course_id = request.query["course_id"].to_s

  raise ArgumentError, "Title is required" if title.empty?
  raise ArgumentError, "Title is too long" if title.length > 255

  unless todo_date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, "A valid date is required"
  end

  Date.iso8601(todo_date)

  unless course_id.empty? || (data["courses"] || []).any? do |course|
    course["id"].to_s == course_id
  end
    raise ArgumentError, "Invalid course"
  end

  fields = {
    "title" => title,
    "details" => details,
    "todo_date" => todo_date
  }

  fields["course_id"] = course_id unless course_id.empty?
  fields
rescue Date::Error
  raise ArgumentError, "A valid date is required"
end

server.mount_proc "/todo/create" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  begin
    data = dashboard_data || {}
    fields = todo_form_fields(request, data)

    canvas_form_request(
      :post,
      "/api/v1/planner_notes",
      fields
    )

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue ArgumentError => e
    response.status = 422
    response.body = e.message
  rescue => e
    puts(
      "Unable to create Canvas to-do: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response.body = "Unable to create that Canvas to-do."
  end
end

server.mount_proc "/todo/update" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  todo_id = request.query["id"].to_s
  data = dashboard_data || {}

  item = (data["todo"] || []).find do |todo_item|
    todo_item["plannable_type"] == "planner_note" &&
      todo_item["plannable_id"].to_s == todo_id
  end

  unless todo_id.match?(/\A\d+\z/) && item
    response.status = 404
    response.body = "To-do item not found"
    next
  end

  begin
    fields = todo_form_fields(request, data)

    canvas_form_request(
      :put,
      "/api/v1/planner_notes/#{todo_id}",
      fields
    )

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue ArgumentError => e
    response.status = 422
    response.body = e.message
  rescue => e
    puts(
      "Unable to update Canvas to-do: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response.body = "Unable to update that Canvas to-do."
  end
end

server.mount_proc "/todo/complete" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  todo_id = request.query["id"].to_s

  unless todo_id.match?(/\A\d+\z/)
    response.status = 400
    response.body = "Invalid to-do item"
    next
  end

  item = (dashboard_data&.dig("todo") || []).find do |todo_item|
    todo_item["plannable_type"] == "planner_note" &&
      todo_item["plannable_id"].to_s == todo_id
  end

  unless item
    response.status = 404
    response.body = "To-do item not found"
    next
  end

  begin
    override_id = item.dig("planner_override", "id")

    if override_id
      canvas_form_request(
        :put,
        "/api/v1/planner/overrides/#{override_id}",
        "marked_complete" => "true"
      )
    else
      canvas_form_request(
        :post,
        "/api/v1/planner/overrides",
        "plannable_type" => item["plannable_type"],
        "plannable_id" => item["plannable_id"],
        "marked_complete" => "true"
      )
    end

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue => e
    puts(
      "Unable to complete Canvas to-do item: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Unable to complete that Canvas to-do item."
  end
end

# ============================================================
# Class Name Settings
# ============================================================

def class_name_mapping_fields(request, data)
  (data["courses"] || []).each_with_object({}) do |course, mappings|
    course_id = course["id"].to_s
    short_name = request.query["course_#{course_id}"].to_s.strip

    if short_name.length > 80
      raise ArgumentError, "Class names must be 80 characters or fewer"
    end

    mappings[course_id] = short_name unless short_name.empty?
  end
end

server.mount_proc "/class-names" do |request, response|
  data = dashboard_data || {}

  if request.request_method == "POST"
    begin
      mappings = class_name_mapping_fields(request, data)
      save_course_name_mappings(mappings)

      response.status = 303
      response["Location"] = "/"
      response.body = ""
    rescue ArgumentError => e
      response.status = 422
      response["Content-Type"] = "text/plain; charset=utf-8"
      response.body = e.message
    end

    next
  end

  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  mappings = load_course_name_mappings
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "class_names.erb"))
  )

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Class name settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load class name settings."
end

# ============================================================
# Home Assistant API
# ============================================================

server.mount_proc "/api/status" do |request, response|
  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  data = dashboard_data || {}
  now = Time.now
  today = now.getlocal.to_date
  tomorrow = today + 1

  incomplete_upcoming = Array(data["upcoming"]).reject do |assignment|
    submission_complete?(
      submission_for(
        data,
        assignment_course_id(assignment),
        assignment_id(assignment)
      )
    )
  end

  latest_event = dashboard_events.last

  response.status = 200
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = JSON.generate(
    {
      "updated_at" => dashboard_status[:updated_at]&.iso8601,
      "canvas_available" => !data.empty? && dashboard_status[:error].nil?,
      "missing_count" => Array(data["missing"]).length,
      "due_today_count" => incomplete_upcoming.count do |assignment|
        assignment_due_time(assignment)&.getlocal&.to_date == today
      end,
      "due_tomorrow_count" => incomplete_upcoming.count do |assignment|
        assignment_due_time(assignment)&.getlocal&.to_date == tomorrow
      end,
      "latest_event_id" => latest_event&.dig("id") || 0,
      "latest_event" => latest_event
    }
  )
end

server.mount_proc "/api/events" do |request, response|
  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  after_value = request.query["after"].to_s
  limit_value = request.query.fetch("limit", "100").to_s

  unless (after_value.empty? || after_value.match?(/\A\d+\z/)) &&
      limit_value.match?(/\A\d+\z/)
    response.status = 400
    response.body = "Invalid query parameters"
    next
  end

  after_id = after_value.empty? ? nil : after_value.to_i
  limit = [[limit_value.to_i, 1].max, 100].min
  events = dashboard_events(after_id: after_id).last(limit)

  response.status = 200
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = JSON.generate(
    {
      "events" => events,
      "latest_event_id" => dashboard_events.last&.dig("id") || 0
    }
  )
end

# ============================================================
# CSS
# ============================================================

server.mount_proc "/dashboard.css" do |_request, response|
  response.status = 200
  response["Content-Type"] = "text/css; charset=utf-8"
  response["Cache-Control"] = "public, max-age=300"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "dashboard.css")
    )
end

# ============================================================
# App Icon
# ============================================================

server.mount_proc "/school-icon.svg" do |_request, response|
  response.status = 200
  response["Content-Type"] = "image/svg+xml"
  response["Cache-Control"] = "public, max-age=86400"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "school-icon.svg")
    )
end

# ============================================================
# PWA Manifest
# ============================================================

server.mount_proc "/manifest.json" do |_request, response|
  response.status = 200
  response["Content-Type"] = "application/manifest+json"
  response["Cache-Control"] = "no-cache"

  response.body = JSON.generate(
    {
      name: "School Dashboard",
      short_name: "School",
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#f4f6f8",
      theme_color: "#5b67d6",

      icons: [
        {
          src: "/school-icon.svg",
          sizes: "any",
          type: "image/svg+xml",
          purpose: "any"
        }
      ]
    }
  )
end

# ============================================================
# Shutdown
# ============================================================

if $PROGRAM_NAME == __FILE__
  trap("TERM") do
    puts "Stopping School Dashboard..."
    server.shutdown
  end

  trap("INT") do
    puts "Stopping School Dashboard..."
    server.shutdown
  end

  puts(
    "School Dashboard listening on port " \
    "#{server.config[:Port]}"
  )

  server.start
end