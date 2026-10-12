require_relative "test_helper"

class ManualCourseworkTest < Minitest::Test
  def setup
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def test_hidden_canvas_course_is_filtered_from_all_dashboard_collections
    data = base_data.merge(
      "grades" => [{ "assignment" => { "course_id" => 1 } }],
      "missing" => [{ "course_id" => 1 }],
      "upcoming" => [{ "assignment" => { "course_id" => 1 } }],
      "todo" => [{ "plannable" => { "course_id" => 1 } }],
      "submissions" => { "1" => { "10" => {} } }
    )
    save_hidden_course_ids(["1"])

    $dashboard_data = data
    visible = dashboard_data_with_manual
    settings_data = dashboard_data_with_manual(include_hidden: true)

    assert_empty visible["courses"]
    assert_empty visible["course_names"]
    assert_empty visible["grades"]
    assert_empty visible["missing"]
    assert_empty visible["upcoming"]
    assert_empty visible["todo"]
    assert_empty visible["submissions"]
    assert_equal ["Math"], settings_data["courses"].map { |course| course["name"] }
  end

  def base_data
    {
      "profile" => {},
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {}
    }
  end

  def test_manual_coursework_round_trip
    coursework = {
      "courses" => {
        "course-id" => {
          "name" => "Piano",
          "updated_at" => "2026-10-11T18:00:00-07:00"
        }
      },
      "assignments" => {}
    }

    save_manual_coursework(coursework)

    assert_equal coursework, load_manual_coursework
  end

  def test_dashboard_data_merges_upcoming_and_overdue_assignments
    now = Time.now
    coursework = {
      "courses" => {
        "course-id" => {
          "name" => "Piano",
          "updated_at" => now.iso8601
        }
      },
      "assignments" => {
        "future-id" => {
          "course_id" => "course-id",
          "name" => "Practice scales",
          "due_at" => (now + 86_400).iso8601,
          "completed" => false,
          "updated_at" => now.iso8601
        },
        "past-id" => {
          "course_id" => "course-id",
          "name" => "Theory worksheet",
          "due_at" => (now - 86_400).iso8601,
          "completed" => false,
          "updated_at" => now.iso8601
        }
      }
    }
    save_manual_coursework(coursework)

    $dashboard_data = base_data
    data = dashboard_data_with_manual

    assert_equal "Piano", data.dig("course_names", "manual-course-id")
    assert_equal ["Practice scales"], data["upcoming"].map { |item| assignment_name(item) }
    assert_equal ["Theory worksheet"], data["missing"].map { |item| assignment_name(item) }
  end

  def test_completed_manual_assignment_has_submitted_status
    now = Time.now
    save_manual_coursework(
      "courses" => {
        "course-id" => { "name" => "Piano", "updated_at" => now.iso8601 }
      },
      "assignments" => {
        "assignment-id" => {
          "course_id" => "course-id",
          "name" => "Practice scales",
          "due_at" => (now + 86_400).iso8601,
          "completed" => true,
          "updated_at" => now.iso8601
        }
      }
    )

    $dashboard_data = base_data
    data = dashboard_data_with_manual
    submission = submission_for(
      data,
      "manual-course-id",
      "manual-assignment-id"
    )

    assert submission_complete?(submission)
    assert_empty data["upcoming"]
    assert_empty data["missing"]
  end
end
