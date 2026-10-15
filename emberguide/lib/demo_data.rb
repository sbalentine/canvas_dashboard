require "date"
require "fileutils"
require "json"
require "time"

module DemoData
  FILE_NAMES = %w[
    canvas_cache.json
    course_name_mappings.json
    grade_overrides.json
    hidden_courses.json
    manual_coursework.json
    school_calendar_settings.json
  ].freeze

  module_function

  def prepare_runtime!(app_root, now: Time.now)
    source_dir = File.join(app_root, "demo")
    runtime_dir = File.join(app_root, "tmp", "demo")
    cache = read_json(File.join(source_dir, "canvas_cache.json"))
    anchor = Time.parse(cache.fetch("updated_at"))
    offset_seconds = now - anchor
    offset_days = (now.to_date - anchor.to_date).to_i

    FileUtils.mkdir_p(runtime_dir)

    FILE_NAMES.each do |file_name|
      source_path = File.join(source_dir, file_name)
      next unless File.exist?(source_path)

      value = read_json(source_path)
      shifted = shift_dates(value, offset_seconds, offset_days)
      File.write(
        File.join(runtime_dir, file_name),
        JSON.pretty_generate(shifted)
      )
    end

    {
      "CACHE_FILE" => File.join(runtime_dir, "canvas_cache.json"),
      "COURSE_NAME_MAPPINGS_FILE" =>
        File.join(runtime_dir, "course_name_mappings.json"),
      "GRADE_OVERRIDES_FILE" =>
        File.join(runtime_dir, "grade_overrides.json"),
      "HIDDEN_COURSES_FILE" =>
        File.join(runtime_dir, "hidden_courses.json"),
      "MANUAL_COURSEWORK_FILE" =>
        File.join(runtime_dir, "manual_coursework.json"),
      "SCHOOL_CALENDAR_SETTINGS_FILE" =>
        File.join(runtime_dir, "school_calendar_settings.json"),
      "EVENT_JOURNAL_FILE" => File.join(runtime_dir, "event_journal.json"),
      "BACKUP_SETTINGS_FILE" => File.join(runtime_dir, "backup_settings.json")
    }
  end

  def read_json(path)
    JSON.parse(File.read(path))
  end

  def shift_dates(value, offset_seconds, offset_days)
    case value
    when Hash
      value.transform_values do |child|
        shift_dates(child, offset_seconds, offset_days)
      end
    when Array
      value.map do |child|
        shift_dates(child, offset_seconds, offset_days)
      end
    when String
      shift_date_string(value, offset_seconds, offset_days)
    else
      value
    end
  end

  def shift_date_string(value, offset_seconds, offset_days)
    if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      (Date.iso8601(value) + offset_days).iso8601
    elsif value.match?(/\A\d{4}-\d{2}-\d{2}T/)
      (Time.iso8601(value) + offset_seconds).iso8601
    else
      value
    end
  rescue Date::Error, ArgumentError
    value
  end
end
