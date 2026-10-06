require_relative "test_helper"

class GradeOverridesTest < Minitest::Test
  def setup
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
  end

  def test_missing_file_returns_empty_overrides
    assert_equal({}, load_grade_overrides)
  end

  def test_overrides_round_trip_in_sorted_order
    save_grade_overrides(
      "canvas" => {
        "20" => { "score" => 9, "points_possible" => nil },
        "10" => { "score" => 8, "points_possible" => 10 }
      },
      "custom" => {}
    )

    assert_equal(
      {
        "canvas" => {
          "10" => { "score" => 8, "points_possible" => 10 },
          "20" => { "score" => 9, "points_possible" => nil }
        },
        "custom" => {}
      },
      load_grade_overrides
    )
    assert_operator File.read(GRADE_OVERRIDES_FILE).index('"10"'), :<,
      File.read(GRADE_OVERRIDES_FILE).index('"20"')
  end

  def test_invalid_json_returns_empty_overrides
    FileUtils.mkdir_p(File.dirname(GRADE_OVERRIDES_FILE))
    File.write(GRADE_OVERRIDES_FILE, "not json")

    _output, error_output = capture_io do
      assert_equal({}, load_grade_overrides)
    end

    assert_empty error_output
  end

  def test_reconcile_removes_changed_canvas_override_and_keeps_custom_grades
    save_grade_overrides(
      "canvas" => {
        "10" => {
          "score" => 9,
          "points_possible" => nil,
          "canvas_score" => 8,
          "canvas_points_possible" => 10,
          "canvas_graded_at" => "2026-10-01T12:00:00Z"
        },
        "11" => {
          "score" => 7,
          "points_possible" => nil,
          "canvas_score" => 6,
          "canvas_points_possible" => 10,
          "canvas_graded_at" => "2026-10-01T12:00:00Z"
        }
      },
      "custom" => {
        "manual-1" => {
          "name" => "Infinite Campus Quiz",
          "score" => 10,
          "points_possible" => 10
        }
      }
    )

    removed = reconcile_canvas_grade_overrides(
      "grades" => [
        {
          "assignment_id" => 10,
          "score" => 8.5,
          "graded_at" => "2026-10-06T12:00:00Z",
          "assignment" => { "points_possible" => 10 }
        },
        {
          "assignment_id" => 11,
          "score" => 6,
          "graded_at" => "2026-10-01T12:00:00Z",
          "assignment" => { "points_possible" => 10 }
        }
      ]
    )

    assert_equal ["10"], removed
    assert_equal ["11"], load_grade_overrides.fetch("canvas").keys
    assert_equal ["manual-1"], load_grade_overrides.fetch("custom").keys
  end

  def test_reconcile_adds_baseline_to_legacy_override
    save_grade_overrides(
      "canvas" => {
        "10" => { "score" => 9, "points_possible" => nil }
      },
      "custom" => {}
    )

    removed = reconcile_canvas_grade_overrides(
      "grades" => [{
        "assignment_id" => 10,
        "score" => 8,
        "graded_at" => "2026-10-01T12:00:00Z",
        "assignment" => { "points_possible" => 10 }
      }]
    )

    assert_empty removed
    override = load_grade_overrides.dig("canvas", "10")
    assert_equal 8, override["canvas_score"]
    assert_equal 10, override["canvas_points_possible"]
    assert_equal "2026-10-01T12:00:00Z", override["canvas_graded_at"]
  end
end
