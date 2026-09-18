require "fileutils"
require "json"

COURSE_NAME_MAPPINGS_FILE =
  ENV.fetch("COURSE_NAME_MAPPINGS_FILE") do
    if File.directory?("/data")
      "/data/course_name_mappings.json"
    else
      File.expand_path(
        "../tmp/course_name_mappings.json",
        __dir__
      )
    end
  end

def load_course_name_mappings
  return {} unless File.exist?(COURSE_NAME_MAPPINGS_FILE)

  JSON.parse(File.read(COURSE_NAME_MAPPINGS_FILE))
rescue JSON::ParserError => e
  puts "Unable to load class names: #{e.message}"
  {}
end

def save_course_name_mappings(mappings)
  FileUtils.mkdir_p(File.dirname(COURSE_NAME_MAPPINGS_FILE))

  temporary_file = "#{COURSE_NAME_MAPPINGS_FILE}.tmp.#{$$}"
  File.write(temporary_file, JSON.pretty_generate(mappings.sort.to_h))
  File.rename(temporary_file, COURSE_NAME_MAPPINGS_FILE)
end