require "fileutils"
require "json"

GRADE_OVERRIDES_FILE =
  ENV.fetch("GRADE_OVERRIDES_FILE") do
    if File.directory?("/data")
      "/data/grade_overrides.json"
    else
      File.expand_path(
        "../tmp/grade_overrides.json",
        __dir__
      )
    end
  end

def load_grade_overrides
  return {} unless File.exist?(GRADE_OVERRIDES_FILE)

  overrides = JSON.parse(File.read(GRADE_OVERRIDES_FILE))
  return {} unless overrides.is_a?(Hash)

  {
    "canvas" => overrides["canvas"].is_a?(Hash) ? overrides["canvas"] : {},
    "custom" => overrides["custom"].is_a?(Hash) ? overrides["custom"] : {}
  }
rescue JSON::ParserError => e
  puts "Unable to load official grades: #{e.message}"
  {}
end

def save_grade_overrides(overrides)
  FileUtils.mkdir_p(File.dirname(GRADE_OVERRIDES_FILE))

  temporary_file = "#{GRADE_OVERRIDES_FILE}.tmp.#{$$}"
  File.write(
    temporary_file,
    JSON.pretty_generate(
      {
        "canvas" => overrides.fetch("canvas", {}).sort.to_h,
        "custom" => overrides.fetch("custom", {}).sort.to_h
      }
    )
  )
  File.rename(temporary_file, GRADE_OVERRIDES_FILE)
end

def reconcile_canvas_grade_overrides(data)
  overrides = load_grade_overrides
  canvas_overrides = overrides.fetch("canvas", {})
  changed = false
  removed_assignment_ids = []

  submissions_by_assignment = (data["grades"] || []).each_with_object({}) do |submission, index|
    assignment_id =
      submission["assignment_id"] ||
      submission.dig("assignment", "id")

    index[assignment_id.to_s] = submission if assignment_id
  end

  canvas_overrides.delete_if do |assignment_id, override|
    submission = submissions_by_assignment[assignment_id]
    next false unless submission

    current_values = {
      "canvas_score" => submission["score"],
      "canvas_points_possible" =>
        submission.dig("assignment", "points_possible"),
      "canvas_graded_at" => submission["graded_at"]
    }

    baseline_missing = current_values.keys.any? do |key|
      !override.key?(key)
    end

    if baseline_missing
      override.merge!(current_values)
      changed = true
      next false
    end

    canvas_changed = current_values.any? do |key, value|
      override[key] != value
    end

    if canvas_changed
      removed_assignment_ids << assignment_id
      changed = true
    end

    canvas_changed
  end

  save_grade_overrides(overrides) if changed
  removed_assignment_ids
end
