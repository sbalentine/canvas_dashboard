require "fileutils"
require "json"
require "securerandom"
require "time"

MANUAL_COURSEWORK_FILE =
  ENV.fetch("MANUAL_COURSEWORK_FILE") do
    if File.directory?("/data")
      "/data/manual_coursework.json"
    else
      File.expand_path(
        "../tmp/manual_coursework.json",
        __dir__
      )
    end
  end

def empty_manual_coursework
  { "courses" => {}, "assignments" => {} }
end

def load_manual_coursework
  return empty_manual_coursework unless File.exist?(MANUAL_COURSEWORK_FILE)

  coursework = JSON.parse(File.read(MANUAL_COURSEWORK_FILE))
  return empty_manual_coursework unless coursework.is_a?(Hash)

  {
    "courses" => coursework["courses"].is_a?(Hash) ? coursework["courses"] : {},
    "assignments" =>
      coursework["assignments"].is_a?(Hash) ? coursework["assignments"] : {}
  }
rescue JSON::ParserError => e
  puts "Unable to load manual coursework: #{e.message}"
  empty_manual_coursework
end

def save_manual_coursework(coursework)
  FileUtils.mkdir_p(File.dirname(MANUAL_COURSEWORK_FILE))

  temporary_file = "#{MANUAL_COURSEWORK_FILE}.tmp.#{$$}"
  File.write(
    temporary_file,
    JSON.pretty_generate(
      {
        "courses" => coursework.fetch("courses", {}).sort.to_h,
        "assignments" => coursework.fetch("assignments", {}).sort.to_h
      }
    )
  )
  File.rename(temporary_file, MANUAL_COURSEWORK_FILE)
end

def manual_course_id(id)
  "manual-#{id}"
end

def dashboard_data_with_manual(data = dashboard_data, include_hidden: false)
  return nil unless data

  coursework = load_manual_coursework
  combined = Marshal.load(Marshal.dump(data))
  combined["courses"] ||= []
  combined["course_names"] ||= {}
  combined["upcoming"] ||= []
  combined["missing"] ||= []
  combined["submissions"] ||= {}

  coursework["courses"].each do |id, course|
    course_id = manual_course_id(id)
    combined["courses"] << {
      "id" => course_id,
      "name" => course["name"],
      "_manual" => true
    }
    combined["course_names"][course_id] = course["name"]
  end

  now = Time.now

  coursework["assignments"].each do |id, assignment|
    course_id = manual_course_id(assignment["course_id"])
    next unless combined["course_names"].key?(course_id)

    event = {
      "id" => "manual-#{id}",
      "assignment" => {
        "id" => "manual-#{id}",
        "course_id" => course_id,
        "name" => assignment["name"],
        "due_at" => assignment["due_at"],
        "_manual" => true
      }
    }

    due_at = Time.parse(assignment["due_at"])
    completed = assignment["completed"] == true

    if completed
      combined["submissions"][course_id] ||= {}
      combined["submissions"][course_id]["manual-#{id}"] = {
        "assignment_id" => "manual-#{id}",
        "workflow_state" => "submitted",
        "submitted_at" => assignment["updated_at"],
        "assignment" => event["assignment"]
      }
    elsif due_at < now
      combined["missing"] << event["assignment"]
    else
      combined["upcoming"] << event
    end
  rescue ArgumentError
    next
  end

  include_hidden ? combined : hide_courses_from_dashboard(combined)
end

def manual_course_fields(request)
  name = request.query["name"].to_s.strip

  raise ArgumentError, "Class name is required" if name.empty?
  raise ArgumentError, "Class names must be 80 characters or fewer" if name.length > 80

  { "name" => name, "updated_at" => Time.now.iso8601 }
end

def manual_assignment_fields(request, coursework)
  name = request.query["name"].to_s.strip
  course_id = request.query["course_id"].to_s
  due_at_value = request.query["due_at"].to_s

  raise ArgumentError, "Assignment name is required" if name.empty?
  if name.length > 255
    raise ArgumentError, "Assignment names must be 255 characters or fewer"
  end
  unless coursework["courses"].key?(course_id)
    raise ArgumentError, "Select a valid class"
  end

  due_at = Time.parse(due_at_value)

  {
    "course_id" => course_id,
    "name" => name,
    "due_at" => due_at.iso8601,
    "completed" => request.query["completed"] == "true",
    "updated_at" => Time.now.iso8601
  }
rescue ArgumentError => e
  raise e unless e.message.include?("no time information") ||
    e.message.include?("argument out of range")

  raise ArgumentError, "A valid due date and time are required"
end

def update_manual_coursework(request)
  coursework = load_manual_coursework
  action = request.query["action"].to_s
  id = request.query["id"].to_s

  case action
  when "create_course"
    coursework["courses"][SecureRandom.uuid] = manual_course_fields(request)
  when "update_course"
    raise ArgumentError, "Class not found" unless coursework["courses"].key?(id)

    coursework["courses"][id] = manual_course_fields(request)
  when "delete_course"
    raise ArgumentError, "Class not found" unless coursework["courses"].key?(id)
    if coursework["assignments"].values.any? { |assignment| assignment["course_id"] == id }
      raise ArgumentError, "Remove this class's assignments before removing the class"
    end

    coursework["courses"].delete(id)
  when "create_assignment"
    coursework["assignments"][SecureRandom.uuid] =
      manual_assignment_fields(request, coursework)
  when "update_assignment"
    raise ArgumentError, "Assignment not found" unless coursework["assignments"].key?(id)

    coursework["assignments"][id] =
      manual_assignment_fields(request, coursework)
  when "delete_assignment"
    raise ArgumentError, "Assignment not found" unless coursework["assignments"].key?(id)

    coursework["assignments"].delete(id)
  else
    raise ArgumentError, "Invalid manual coursework action"
  end

  save_manual_coursework(coursework)
end
