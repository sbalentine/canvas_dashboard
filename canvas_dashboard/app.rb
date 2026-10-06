require "webrick"
require "erb"
require "json"
require "securerandom"

APP_ROOT = File.expand_path(__dir__)

require_relative "lib/canvas"
require_relative "lib/helpers"
require_relative "lib/course_name_mappings"
require_relative "lib/grade_overrides"
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
# Official Grade Settings
# ============================================================

def grade_number(value, field_name)
  number = Float(value)

  unless number.finite? && number.between?(0, 99_999)
    raise ArgumentError, "#{field_name} must be between 0 and 99,999"
  end

  number.round(2)
rescue ArgumentError, TypeError
  raise ArgumentError, "#{field_name} must be a valid number"
end

def grade_override_fields(request, data, existing)
  canvas = {}

  (data["grades"] || []).each do |submission|
    assignment_id =
      submission["assignment_id"] ||
      submission.dig("assignment", "id")

    next unless assignment_id

    score_value =
      request.query["canvas_#{assignment_id}_score"].to_s.strip
    points_value =
      request.query["canvas_#{assignment_id}_points"].to_s.strip

    next if score_value.empty? && points_value.empty?

    canvas[assignment_id.to_s] = {
      "score" => score_value.empty? ? nil : grade_number(score_value, "Earned points"),
      "points_possible" => points_value.empty? ? nil : grade_number(points_value, "Possible points"),
      "canvas_score" => submission["score"],
      "canvas_points_possible" =>
        submission.dig("assignment", "points_possible"),
      "canvas_graded_at" => submission["graded_at"],
      "updated_at" => Time.now.iso8601
    }
  end

  valid_course_ids = (data["courses"] || []).map { |course| course["id"].to_s }
  custom = {}

  existing.fetch("custom", {}).each_key do |grade_id|
    name = request.query["custom_#{grade_id}_name"].to_s.strip
    next if name.empty?

    custom[grade_id] = custom_grade_fields(
      request,
      "custom_#{grade_id}",
      valid_course_ids,
      name
    )
  end

  new_grade_indices = request.query.keys.filter_map do |key|
    key[/\Anew_(\d+)_name\z/, 1]
  end.uniq.sort_by(&:to_i)

  new_grade_indices.each do |index|
    prefix = "new_#{index}"
    name = request.query["#{prefix}_name"].to_s.strip
    next if name.empty?

    custom[SecureRandom.uuid] = custom_grade_fields(
      request,
      prefix,
      valid_course_ids,
      name
    )
  end

  { "canvas" => canvas, "custom" => custom }
end

def custom_grade_fields(request, prefix, valid_course_ids, name)
  raise ArgumentError, "Assignment names must be 255 characters or fewer" if name.length > 255

  course_id = request.query["#{prefix}_course_id"].to_s
  raise ArgumentError, "Select a valid course" unless valid_course_ids.include?(course_id)

  score_value = request.query["#{prefix}_score"].to_s.strip
  points_value = request.query["#{prefix}_points"].to_s.strip
  grade_date = request.query["#{prefix}_date"].to_s

  raise ArgumentError, "Earned points are required" if score_value.empty?
  raise ArgumentError, "Possible points are required" if points_value.empty?

  unless grade_date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, "A valid grade date is required"
  end

  Date.iso8601(grade_date)

  {
    "course_id" => course_id,
    "name" => name,
    "score" => grade_number(score_value, "Earned points"),
    "points_possible" => grade_number(points_value, "Possible points"),
    "graded_at" => grade_date,
    "updated_at" => Time.now.iso8601
  }
rescue Date::Error
  raise ArgumentError, "A valid grade date is required"
end

server.mount_proc "/grades" do |request, response|
  data = dashboard_data || {}

  if request.request_method == "POST"
    begin
      existing = load_grade_overrides
      overrides = grade_override_fields(request, data, existing)
      save_grade_overrides(overrides)

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

  overrides = load_grade_overrides
  mappings = load_course_name_mappings
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "grades.erb"))
  )

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Grade settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load grade settings."
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