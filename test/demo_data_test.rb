require_relative "test_helper"
require_relative "../emberguide/lib/demo_data"

class DemoDataTest < Minitest::Test
  DEMO_DIR = File.expand_path("../emberguide/demo", __dir__)

  def demo_cache
    JSON.parse(File.read(File.join(DEMO_DIR, "canvas_cache.json")))
  end

  def test_committed_demo_data_is_synthetic_and_complete
    cache = demo_cache
    serialized = JSON.generate(cache)

    assert_equal "Emberlynn", cache.dig("profile", "name")
    assert_equal "Emberlynn", cache.dig("profile", "short_name")
    assert_operator cache.fetch("courses").length, :>=, 5
    assert_operator cache.fetch("grades").length, :>=, 20
    assert_operator cache.fetch("upcoming").length, :>=, 1
    assert_equal(
      cache.fetch("courses").length,
      cache.fetch("course_names").length
    )

    refute_match(/primary_email|login_id|avatar_url|lti_user_id/, serialized)
    refute_match(/@|instructure\.com/i, serialized)

    urls = serialized.scan(%r{https://[^"\\]+})
    refute_empty urls
    assert urls.all? { |url| URI(url).host == "canvas.example.test" }

    overrides = JSON.parse(
      File.read(File.join(DEMO_DIR, "grade_overrides.json"))
    )
    custom_grades = overrides.fetch("custom").values.map do |grade|
      {
        "score" => grade["score"],
        "assignment" => {
          "course_id" => grade["course_id"],
          "points_possible" => grade["points_possible"],
          "omit_from_final_grade" => false
        }
      }
    end
    percentages = (cache.fetch("grades") + custom_grades).group_by do |submission|
      submission.dig("assignment", "course_id")
    end.to_h do |course_id, submissions|
      included = submissions.reject do |submission|
        submission["score"].nil? ||
          submission.dig("assignment", "points_possible").to_f.zero? ||
          submission.dig("assignment", "omit_from_final_grade") == true
      end
      earned = included.sum { |submission| submission["score"].to_f }
      possible = included.sum do |submission|
        submission.dig("assignment", "points_possible").to_f
      end

      [course_id.to_s, earned / possible * 100]
    end

    grade_order = cache.fetch("courses").filter_map do |course|
      percentage = percentages[course.fetch("id").to_s]
      next unless percentage

      letter =
        if percentage >= 90
          "A"
        elsif percentage >= 80
          "B"
        else
          "C"
        end
      [course.fetch("name"), letter]
    end.sort.map(&:last)

    assert_equal %w[A B C A B], grade_order

    anchor = Time.iso8601(cache.fetch("updated_at"))
    upcoming = cache.fetch("upcoming")
    due_times = upcoming.map do |event|
      Time.iso8601(event.dig("assignment", "due_at"))
    end

    assert_equal [1, 3, 5], due_times.map { |due| (due.to_date - anchor.to_date).to_i }
    assert_equal [[8, 0], [15, 15], [8, 0]], due_times.map { |due| [due.hour, due.min] }
    assert_equal 3, upcoming.map { |event| event.dig("assignment", "course_id") }.uniq.length
    assert_equal 3, cache.fetch("todo").length

    manual_coursework = JSON.parse(
      File.read(File.join(DEMO_DIR, "manual_coursework.json"))
    )
    assert_equal ["Music"],
      manual_coursework.fetch("courses").values.map { |course| course["name"] }
    assert_equal 2, manual_coursework.fetch("assignments").length
    assert_equal [false, true],
      manual_coursework.fetch("assignments").values
        .map { |assignment| assignment["completed"] }
        .sort_by(&:to_s)

    music_grades = overrides.fetch("custom").values.select do |grade|
      grade["course_id"] == "manual-demo-course-1"
    end
    assert_equal 4, music_grades.length
    assert_in_delta 87.5,
      music_grades.sum { |grade| grade["score"].to_f } /
        music_grades.sum { |grade| grade["points_possible"].to_f } * 100,
      0.01
  end

  def test_prepare_runtime_shifts_dates_and_isolates_writable_files
    anchor = Time.iso8601(demo_cache.fetch("updated_at"))
    now = anchor + (45 * 86_400)
    paths = DemoData.prepare_runtime!(
      File.expand_path("../emberguide", __dir__),
      now: now
    )
    runtime_cache = JSON.parse(File.read(paths.fetch("CACHE_FILE")))
    runtime_updated_at = Time.iso8601(runtime_cache.fetch("updated_at"))
    source_due_at = Time.iso8601(
      demo_cache.dig("upcoming", 0, "assignment", "due_at")
    )
    runtime_due_at = Time.iso8601(
      runtime_cache.dig("upcoming", 0, "assignment", "due_at")
    )

    assert_in_delta now.to_f, runtime_updated_at.to_f, 1
    assert_equal [source_due_at.hour, source_due_at.min],
      [runtime_due_at.hour, runtime_due_at.min]
    assert paths.values.all? do |path|
      path.start_with?(File.expand_path("../emberguide/tmp/demo", __dir__))
    end
    assert_equal(
      demo_cache.dig("grades", 0, "score"),
      runtime_cache.dig("grades", 0, "score")
    )
  end
end
