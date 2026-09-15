require "webrick"
require "erb"
require "json"

APP_ROOT = File.expand_path(__dir__)

require_relative "lib/canvas"
require_relative "lib/helpers"
require_relative "lib/dashboard_data"

# ============================================================
# Startup
# ============================================================

puts "Starting School Dashboard..."

initialize_dashboard_data
start_refresh_thread

# ============================================================
# Web Server
# ============================================================

server = WEBrick::HTTPServer.new(
  Port: 4567,
  BindAddress: "0.0.0.0",
  AccessLog: [],
  Logger: WEBrick::Log.new(
    $stdout,
    WEBrick::Log::INFO
  )
)

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

trap("TERM") do
  puts "Stopping School Dashboard..."
  server.shutdown
end

trap("INT") do
  puts "Stopping School Dashboard..."
  server.shutdown
end

puts "School Dashboard listening on port 4567"

server.start