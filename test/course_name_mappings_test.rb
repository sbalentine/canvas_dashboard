require_relative "test_helper"

class CourseNameMappingsTest < Minitest::Test
  def setup
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
  end

  def test_missing_file_returns_empty_mapping
    assert_equal({}, load_course_name_mappings)
  end

  def test_mappings_round_trip_in_sorted_order
    save_course_name_mappings("20" => "Art", "10" => "Math")

    assert_equal({ "10" => "Math", "20" => "Art" }, load_course_name_mappings)
    assert_operator File.read(COURSE_NAME_MAPPINGS_FILE).index('"10"'), :<,
      File.read(COURSE_NAME_MAPPINGS_FILE).index('"20"')
  end

  def test_invalid_json_returns_empty_mapping
    FileUtils.mkdir_p(File.dirname(COURSE_NAME_MAPPINGS_FILE))
    File.write(COURSE_NAME_MAPPINGS_FILE, "not json")

    _output, error_output = capture_io do
      assert_equal({}, load_course_name_mappings)
    end

    assert_empty error_output
  end
end