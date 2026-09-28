require_relative "test_helper"

class AppTest < Minitest::Test
  Request = Struct.new(:query)

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
    refute_includes html, "Quiz <One>"
  end

  def test_todo_form_controls_are_constrained_to_their_grid_columns
    css = File.read(File.join(APP_ROOT, "public", "dashboard.css"))
    controls = css[/\.todo-create-form input,.*?\n\}/m]

    refute_nil controls
    assert_includes controls, "min-width: 0;"
    assert_includes controls, "max-width: 100%;"
  end
end