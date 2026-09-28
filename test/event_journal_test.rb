require_relative "test_helper"

class EventJournalTest < Minitest::Test
  def setup
    FileUtils.rm_f(EVENT_JOURNAL_FILE)
    $event_journal = { "next_id" => 1, "events" => [] }

    @base = {
      "course_names" => { "1" => "Math" },
      "missing" => [],
      "grades" => [],
      "upcoming" => [],
      "submissions" => {}
    }
  end

  def assignment(overrides = {})
    {
      "id" => 10,
      "course_id" => 1,
      "name" => "Practice"
    }.merge(overrides)
  end

  def submission(overrides = {})
    {
      "assignment_id" => 10,
      "workflow_state" => "unsubmitted",
      "assignment" => assignment,
      "submission_comments" => []
    }.merge(overrides)
  end

  def changed_data
    Marshal.load(Marshal.dump(@base))
  end

  def test_identical_snapshots_do_not_emit_events
    assert_empty detect_dashboard_events(@base, @base)
  end

  def test_missing_assignment_transitions_emit_events
    current = changed_data
    current["missing"] = [assignment]

    added = detect_dashboard_events(@base, current)
    resolved = detect_dashboard_events(current, @base)

    assert_equal ["assignment_missing"], added.map { |event| event["type"] }
    assert_equal ["assignment_no_longer_missing"], resolved.map { |event| event["type"] }
  end

  def test_new_and_changed_grades_emit_events
    posted = changed_data
    posted["grades"] = [submission("score" => 8)]
    changed = changed_data
    changed["grades"] = [submission("score" => 9)]

    assert_equal "grade_posted", detect_dashboard_events(@base, posted).first["type"]

    event = detect_dashboard_events(posted, changed).first
    assert_equal "grade_changed", event["type"]
    assert_equal 8, event["previous_score"]
    assert_equal 9, event["score"]
  end

  def test_submission_and_feedback_transitions_emit_events
    previous = changed_data
    previous["submissions"] = { "1" => { "10" => submission } }
    current = changed_data
    current["submissions"] = {
      "1" => {
        "10" => submission(
          "workflow_state" => "submitted",
          "submitted_at" => "2026-09-27T10:00:00Z",
          "submission_comments" => [
            { "id" => 7, "comment" => "Nice work", "author_name" => "Teacher" }
          ]
        )
      }
    }

    assert_equal(
      ["assignment_submitted", "teacher_feedback_added"],
      detect_dashboard_events(previous, current).map { |event| event["type"] }
    )
  end

  def test_due_date_change_emits_event
    previous = changed_data
    previous["upcoming"] = [assignment("due_at" => "2026-09-28T10:00:00Z")]
    current = changed_data
    current["upcoming"] = [assignment("due_at" => "2026-09-29T10:00:00Z")]

    event = detect_dashboard_events(previous, current).first

    assert_equal "due_date_changed", event["type"]
    assert_equal "2026-09-28T10:00:00Z", event["previous_due_at"]
    assert_equal "2026-09-29T10:00:00Z", event["due_at"]
  end

  def test_journal_persists_ids_and_supports_cursor_reads
    append_dashboard_events([
      { "type" => "grade_posted" },
      { "type" => "assignment_submitted" }
    ])

    assert_equal [1, 2], dashboard_events.map { |event| event["id"] }
    assert_equal [2], dashboard_events(after_id: 1).map { |event| event["id"] }

    $event_journal = { "next_id" => 1, "events" => [] }
    initialize_event_journal

    assert_equal 3, $event_journal["next_id"]
    assert_equal 2, dashboard_events.length
  end
end