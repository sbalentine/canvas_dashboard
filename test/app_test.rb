require_relative "test_helper"

class AppTest < Minitest::Test
  Request = Struct.new(:query)

  def setup
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
  end

  def test_todo_form_fields_normalize_valid_input
    request = Request.new({
      "title" => "  Read chapter  ",
      "details" => "Pages 1-10",
      "todo_date" => "2026-09-28",
      "course_id" => "12"
    })
    data = { "courses" => [{ "id" => 12 }] }

    assert_equal(
      {
        "title" => "Read chapter",
        "details" => "Pages 1-10",
        "todo_date" => "2026-09-28",
        "course_id" => "12"
      },
      todo_form_fields(request, data)
    )
  end

  def test_todo_form_fields_validate_input
    data = { "courses" => [{ "id" => 12 }] }

    assert_raises(ArgumentError) do
      todo_form_fields(Request.new({ "title" => "", "todo_date" => "2026-09-28" }), data)
    end
    assert_raises(ArgumentError) do
      todo_form_fields(Request.new({ "title" => "Read", "todo_date" => "bad" }), data)
    end
    assert_raises(ArgumentError) do
      todo_form_fields(
        Request.new({ "title" => "Read", "todo_date" => "2026-09-28", "course_id" => "99" }),
        data
      )
    end
  end

  def test_class_name_mapping_fields_remove_blanks
    request = Request.new({ "course_1" => " Math ", "course_2" => " " })
    data = { "courses" => [{ "id" => 1 }, { "id" => 2 }] }

    assert_equal({ "1" => "Math" }, class_name_mapping_fields(request, data))
  end

  def test_class_name_mapping_fields_reject_long_names
    request = Request.new({ "course_1" => "a" * 81 })
    data = { "courses" => [{ "id" => 1 }] }

    assert_raises(ArgumentError) { class_name_mapping_fields(request, data) }
  end

  def test_grade_override_fields_normalize_canvas_values_and_remove_blanks
    request = Request.new({
      "canvas_10_score" => " 9.25 ",
      "canvas_10_points" => "",
      "canvas_11_score" => "",
      "canvas_11_points" => "",
      "new_name" => ""
    })
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [
        { "assignment_id" => 10 },
        { "assignment_id" => 11 }
      ]
    }

    overrides = grade_override_fields(
      request,
      data,
      { "canvas" => {}, "custom" => {} }
    )

    assert_equal 9.25, overrides.dig("canvas", "10", "score")
    assert_nil overrides.dig("canvas", "10", "points_possible")
    assert_nil overrides.dig("canvas", "10", "canvas_score")
    assert_nil overrides.dig("canvas", "10", "canvas_points_possible")
    assert overrides.dig("canvas", "10", "updated_at")
    refute overrides["canvas"].key?("11")
  end

  def test_grade_override_fields_validate_values
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [{ "assignment_id" => 10 }]
    }

    assert_raises(ArgumentError) do
      grade_override_fields(
        Request.new({
          "canvas_10_score" => "invalid",
          "canvas_10_points" => "",
          "new_name" => ""
        }),
        data,
        { "canvas" => {}, "custom" => {} }
      )
    end
  end

  def test_dashboard_template_renders_and_escapes_canvas_content
    data = {
      "profile" => { "short_name" => "<Avery> Student" },
      "courses" => [{ "id" => 1, "name" => "Math & Logic" }],
      "course_names" => { "1" => "Math & Logic" },
      "missing" => [
        { "id" => 10, "course_id" => 1, "name" => "Quiz <One>", "due_at" => Time.now.iso8601 }
      ],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {}
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = template.result(binding)

    assert_includes html, "&lt;Avery&gt;"
    assert_includes html, "Quiz &lt;One&gt;"
    assert_includes html, "No graded Canvas assignments"
    assert_includes html, "1 missing"
    refute_includes html, "0 assignments"
    refute_includes html, "0 due tomorrow"
    refute_includes html, "Quiz <One>"
  end

  def test_up_next_shows_all_clear_instead_of_zero_counts
    data = {
      "profile" => { "short_name" => "Emberlynn" },
      "courses" => [],
      "course_names" => {},
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {}
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = template.result(binding)

    assert_includes html, "All clear"
    refute_includes html, "0 assignments"
    refute_includes html, "0 due tomorrow"
    refute_includes html, "No missing work"
  end

  def calendar_dashboard_data(events, overrides = {})
    {
      "profile" => { "short_name" => "Avery" },
      "courses" => [],
      "course_names" => {},
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {},
      "school_calendar" => {
        "events" => events,
        "updated_at" => Time.now.iso8601
      }.merge(overrides)
    }
  end

  def calendar_event(title, date, overrides = {})
    {
      "title" => title,
      "start_at" => date.iso8601,
      "end_at" => (date + 1).iso8601,
      "start_date" => date.iso8601,
      "end_date" => (date + 1).iso8601,
      "all_day" => true,
      "location" => ""
    }.merge(overrides)
  end

  def render_calendar_dashboard(data, url: "https://school.example/calendar.ics")
    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    with_replaced_method(self, :school_calendar_url, -> { url }) do
      template.result(binding)
    end
  end

  def test_calendar_shows_today_tomorrow_and_week_without_assignment_counts
    today = Date.today
    data = calendar_dashboard_data([
      calendar_event("School <Holiday>", today, "location" => "Hall & Gym"),
      calendar_event("Assembly", today + 1, "url" => "https://school.example/events/assembly"),
      calendar_event("Spirit day", today + 6),
      calendar_event("Outside this week", today + 7)
    ])

    html = render_calendar_dashboard(data)

    assert_includes html, "School Calendar"
    assert_includes html, "Today"
    assert_includes html, "Tomorrow"
    assert_includes html, "School &lt;Holiday&gt;"
    assert_includes html, "Hall &amp; Gym"
    assert_includes html, "Assembly"
    assert_includes html, "Spirit day"
    assert_includes html, "All day"
    assert_includes html, "1 calendar event today"
    assert_includes html, "1 calendar event tomorrow"
    assert_includes html, 'rel="noopener noreferrer"'
    refute_includes html, "Outside this week"
    refute_includes html, "All clear"
    refute_includes html, "left today"
    refute_includes html, "due tomorrow"
    refute_includes html, "School <Holiday>"
  end

  def test_calendar_includes_earlier_today_and_multiday_events
    today = Date.today
    early = Time.local(today.year, today.month, today.day, 0, 1)
    data = calendar_dashboard_data([
      calendar_event("Early meeting", today, {
        "start_at" => early.iso8601,
        "end_at" => (early + 3600).iso8601,
        "all_day" => false
      }),
      calendar_event("School break", today - 1, {
        "end_at" => (today + 2).iso8601,
        "end_date" => (today + 2).iso8601
      })
    ])

    html = render_calendar_dashboard(data)

    assert_includes html, "Early meeting"
    assert_includes html, "12:01 AM"
    assert_equal 2, html.scan("School break").length
    assert_includes html, "2 calendar events today"
    assert_includes html, "1 calendar event tomorrow"
  end

  def test_calendar_reports_cached_failure_and_empty_days
    data = calendar_dashboard_data([], "error" => "Calendar <unavailable>.")
    html = render_calendar_dashboard(data)

    assert_includes html, "Calendar &lt;unavailable&gt;."
    assert_includes html, "Showing cached events"
    assert_equal 2, html.scan("No calendar events.").length
    assert_includes html, "All clear"

    data["school_calendar"].delete("updated_at")
    html = render_calendar_dashboard(data)
    assert_equal 2, html.scan("Calendar events unavailable.").length
    refute_includes html, "No calendar events."
  end

  def test_blank_calendar_configuration_hides_cached_events
    data = calendar_dashboard_data([calendar_event("Old calendar", Date.today)])
    html = render_calendar_dashboard(data, url: "")

    refute_includes html, "School Calendar"
    refute_includes html, "Old calendar"
    assert_includes html, "All clear"
  end

  def test_grade_editor_sorts_canvas_assignments_newest_first
    data = {
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [
        {
          "assignment_id" => 10,
          "score" => 8,
          "graded_at" => "2026-09-01T12:00:00Z",
          "assignment" => {
            "id" => 10,
            "course_id" => 1,
            "name" => "Older Quiz",
            "points_possible" => 10
          }
        },
        {
          "assignment_id" => 11,
          "score" => 9,
          "graded_at" => "2026-10-01T12:00:00Z",
          "assignment" => {
            "id" => 11,
            "course_id" => 1,
            "name" => "Recent Quiz",
            "points_possible" => 10
          }
        }
      ]
    }
    overrides = { "canvas" => {}, "custom" => {} }
    mappings = {}

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "grades.erb")))
    html = template.result(binding)

    assert_operator html.index("Recent Quiz"), :<, html.index("Older Quiz")
  end

  def test_dashboard_renders_grade_snapshot_with_whole_percentage_and_letter
    data = {
      "profile" => { "short_name" => "Emberlynn" },
      "courses" => [{ "id" => 1, "name" => "6th Grade Science" }],
      "course_names" => { "1" => "6th Grade Science" },
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {},
      "grades" => [{
        "assignment_id" => 10,
        "score" => 10,
        "assignment" => {
          "id" => 10,
          "course_id" => 1,
          "name" => "Lab",
          "points_possible" => 10
        }
      }]
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = template.result(binding)

    assert_includes html, "Overall grade snapshot"
    assert_includes html, "🧪"
    assert_includes html, "grade-snapshot-item grade-a perfect-grade"
    assert_includes html, "<strong>100%</strong>"
    assert_includes html, "grade-snapshot-letter\">A"
    assert_includes html, 'href="#grade-course-1"'
    assert_includes html, 'id="grade-course-1"'
  end
end