require_relative "test_helper"

class HelpersTest < Minitest::Test
  def test_number_formatting
    assert_equal 25.0, percentage(1, 4)
    assert_nil percentage(nil, 4)
    assert_nil percentage(1, 0)
    assert_equal "-", format_number(nil)
    assert_equal 5, format_number(5.0)
    assert_equal 5.3, format_number(5.34)
  end

  def test_course_and_assignment_values_support_canvas_shapes
    data = { "course_names" => { "12" => "Science" } }
    nested = {
      "plannable" => {
        "title" => "Lab",
        "course_id" => 12,
        "todo_date" => "2026-09-28T17:00:00Z"
      },
      "assignment" => { "id" => 44, "html_url" => "/courses/12/assignments/44" }
    }

    assert_equal "Science", course_name(data, 12)
    assert_equal "Unknown Course", course_name(data, nil)
    assert_equal "Lab", assignment_name(nested)
    assert_equal 12, assignment_course_id(nested)
    assert_equal 44, assignment_id(nested)
    assert_equal "https://temecula.instructure.com/courses/12/assignments/44", assignment_url(nested)
    assert_equal Time.parse("2026-09-28T17:00:00Z"), assignment_due_time(nested)
  end

  def test_date_and_profile_labels
    now = Time.now

    assert_equal "Today", date_label(now)
    assert_equal "Tomorrow", date_label(now + 86_400)
    assert_equal "No due date", date_label(nil)
    assert_equal "Good morning", greeting_for(Time.local(2026, 1, 1, 9))
    assert_equal "Good afternoon", greeting_for(Time.local(2026, 1, 1, 14))
    assert_equal "Good evening", greeting_for(Time.local(2026, 1, 1, 20))
    assert_equal "Avery", profile_first_name("profile" => { "short_name" => "Avery Student" })
    assert_equal "there", profile_first_name({})
  end

  def test_submission_statuses
    assert_equal "not-submitted", submission_status(nil)[:css]
    assert_equal "missing-status", submission_status("missing" => true)[:css]
    assert_equal "late-status", submission_status("late" => true, "workflow_state" => "submitted")[:css]
    assert_equal "submitted", submission_status("workflow_state" => "submitted")[:css]

    graded = {
      "score" => 9,
      "assignment" => { "points_possible" => 10 }
    }
    assert_equal "Graded · 9/10", submission_status(graded)[:label]
    assert submission_complete?(graded)
    refute submission_complete?(nil)
  end

  def test_latest_nonempty_submission_comment
    submission = {
      "submission_comments" => [
        { "id" => 1, "comment" => "Earlier", "created_at" => "2026-09-20T10:00:00Z" },
        { "id" => 2, "comment" => "", "created_at" => "2026-09-22T10:00:00Z" },
        { "id" => 3, "comment" => "Latest", "created_at" => "2026-09-21T10:00:00Z" }
      ]
    }

    assert_equal 3, latest_submission_comment(submission)["id"]
    assert_nil latest_submission_comment(nil)
  end
end