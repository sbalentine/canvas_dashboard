require "fileutils"
require "json"

HIDDEN_COURSES_FILE =
  ENV.fetch("HIDDEN_COURSES_FILE") do
    if File.directory?("/data")
      "/data/hidden_courses.json"
    else
      File.expand_path(
        "../tmp/hidden_courses.json",
        __dir__
      )
    end
  end

def load_hidden_course_ids
  return [] unless File.exist?(HIDDEN_COURSES_FILE)

  ids = JSON.parse(File.read(HIDDEN_COURSES_FILE))
  ids.is_a?(Array) ? ids.map(&:to_s).uniq : []
rescue JSON::ParserError => e
  puts "Unable to load hidden classes: #{e.message}"
  []
end

def save_hidden_course_ids(course_ids)
  FileUtils.mkdir_p(File.dirname(HIDDEN_COURSES_FILE))

  temporary_file = "#{HIDDEN_COURSES_FILE}.tmp.#{$$}"
  File.write(
    temporary_file,
    JSON.pretty_generate(course_ids.map(&:to_s).uniq.sort)
  )
  File.rename(temporary_file, HIDDEN_COURSES_FILE)
end

def hide_courses_from_dashboard(data)
  hidden_ids = load_hidden_course_ids
  return data if hidden_ids.empty?

  hidden = hidden_ids.to_h { |course_id| [course_id, true] }
  visible = Marshal.load(Marshal.dump(data))

  visible["courses"] = Array(visible["courses"]).reject do |course|
    hidden.key?(course["id"].to_s)
  end
  visible["course_names"] = visible.fetch("course_names", {}).reject do |course_id, _name|
    hidden.key?(course_id.to_s)
  end

  %w[grades missing upcoming todo].each do |collection|
    visible[collection] = Array(visible[collection]).reject do |item|
      hidden.key?(assignment_course_id(item).to_s)
    end
  end

  visible["submissions"] = visible.fetch("submissions", {}).reject do |course_id, _submissions|
    hidden.key?(course_id.to_s)
  end

  visible
end
