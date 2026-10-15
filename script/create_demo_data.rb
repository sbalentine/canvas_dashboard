#!/usr/bin/env ruby

require "fileutils"
require "json"

SOURCE_DIR = File.expand_path(
  ARGV.fetch(0, "../emberguide/tmp"),
  __dir__
)
OUTPUT_DIR = File.expand_path(
  ARGV.fetch(1, "../emberguide/demo"),
  __dir__
)

COURSE_NAMES = [
  "Language Arts",
  "Mathematics",
  "Science",
  "Social Studies",
  "Art",
  "Physical Education"
].freeze

ASSIGNMENT_TOPICS = {
  "Language Arts" => [
    "Reading Response",
    "Vocabulary Check",
    "Narrative Draft",
    "Novel Study",
    "Grammar Practice",
    "Theme Analysis"
  ],
  "Mathematics" => [
    "Expressions Practice",
    "Ratio Review",
    "Geometry Quiz",
    "Problem Set",
    "Data Analysis",
    "Number Sense Check"
  ],
  "Science" => [
    "Lab Reflection",
    "Ecosystems Quiz",
    "Model Diagram",
    "Evidence Notes",
    "Forces Practice",
    "Investigation Report"
  ],
  "Social Studies" => [
    "Map Skills",
    "Primary Source Notes",
    "Civics Reflection",
    "History Quiz",
    "Culture Project",
    "Timeline Review"
  ],
  "Art" => [
    "Color Study",
    "Sketchbook Check",
    "Design Reflection",
    "Composition Project",
    "Artist Notes",
    "Studio Practice"
  ],
  "Physical Education" => [
    "Weekly Activity Log",
    "Wellness Reflection",
    "Fitness Check-In",
    "Teamwork Notes",
    "Movement Skills",
    "Health Quiz"
  ]
}.freeze

COURSE_GRADE_TARGETS = {
  "Language Arts" => 86,
  "Mathematics" => 78,
  "Science" => 84,
  "Social Studies" => 90,
  "Art" => 94,
  "Physical Education" => 92
}.freeze

def read_json(file_name, default)
  path = File.join(SOURCE_DIR, file_name)
  return default unless File.exist?(path)

  JSON.parse(File.read(path))
end

def write_json(file_name, value)
  FileUtils.mkdir_p(OUTPUT_DIR)
  File.write(
    File.join(OUTPUT_DIR, file_name),
    "#{JSON.pretty_generate(value)}\n"
  )
end

class Anonymizer
  def initialize(cache)
    @cache = cache
    @course_ids = {}
    @course_names = {}
    @assignment_ids = {}
    @assignment_names = {}
    @assignment_counts = Hash.new(0)
    index_courses
  end

  attr_reader :course_ids, :course_names, :assignment_ids

  def cache
    result = {
      "profile" => {
        "id" => 1,
        "name" => "Emberlynn",
        "short_name" => "Emberlynn"
      },
      "courses" => @course_ids.map do |source_id, demo_id|
        {
          "id" => demo_id,
          "name" => @course_names.fetch(source_id)
        }
      end,
      "course_names" => @course_ids.to_h do |source_id, demo_id|
        [demo_id.to_s, @course_names.fetch(source_id)]
      end,
      "grades" => Array(@cache["grades"]).filter_map do |submission|
        sanitize_submission(submission)
      end,
      "missing" => Array(@cache["missing"]).filter_map do |assignment|
        sanitize_assignment(assignment)
      end,
      "upcoming" => Array(@cache["upcoming"]).filter_map do |event|
        sanitize_upcoming(event)
      end,
      "todo" => Array(@cache["todo"]).each_with_index.filter_map do |item, index|
        sanitize_todo(item, index)
      end,
      "submissions" => sanitize_submissions,
      "updated_at" => @cache.fetch("updated_at")
    }

    apply_course_grade_targets!(result["grades"])
    result
  end

  def course_name_mappings
    @course_ids.to_h do |source_id, demo_id|
      [demo_id.to_s, @course_names.fetch(source_id)]
    end
  end

  def grade_overrides(source)
    custom = Hash(source.fetch("custom", {})).values.each_with_index.each_with_object({}) do |(grade, index), result|
      course_id = map_course_id(grade["course_id"])
      next unless course_id

      course_name = @course_names.fetch(grade["course_id"].to_s)
      target = COURSE_GRADE_TARGETS.fetch(course_name, 90)
      points_possible = grade["points_possible"].to_f
      result["demo-grade-#{index + 1}"] = {
        "course_id" => course_id,
        "name" => "Progress Check #{index + 1}",
        "score" => (points_possible * target / 100).round(2),
        "points_possible" => points_possible,
        "graded_at" => grade["graded_at"]
      }
    end

    { "canvas" => {}, "custom" => custom }
  end

  def manual_coursework(source)
    courses = {}
    course_ids = {}

    Hash(source.fetch("courses", {})).values.each_with_index do |course, index|
      id = "demo-course-#{index + 1}"
      course_ids[index] = id
      courses[id] = {
        "name" => "Music",
        "updated_at" => course["updated_at"]
      }
    end

    assignments = {}
    source_course_ids = Hash(source.fetch("courses", {})).keys
    Hash(source.fetch("assignments", {})).values.each_with_index do |assignment, index|
      source_index = source_course_ids.index(assignment["course_id"]) || 0
      course_id = course_ids[source_index]
      next unless course_id

      assignments["demo-assignment-#{index + 1}"] = {
        "course_id" => course_id,
        "name" => ["Instrument Practice", "Listening Journal"][index] ||
          "Music Assignment #{index + 1}",
        "due_at" => assignment["due_at"],
        "completed" => assignment["completed"] == true,
        "updated_at" => assignment["updated_at"]
      }
    end

    { "courses" => courses, "assignments" => assignments }
  end

  private

  def index_courses
    Array(@cache["courses"]).each_with_index do |course, index|
      source_id = course["id"].to_s
      @course_ids[source_id] = 101 + index
      @course_names[source_id] =
        COURSE_NAMES[index] || "Elective #{index - COURSE_NAMES.length + 1}"
    end
  end

  def map_course_id(value)
    @course_ids[value.to_s]
  end

  def map_assignment_id(value)
    source_id = value.to_s
    return nil if source_id.empty?

    @assignment_ids[source_id] ||= 1001 + @assignment_ids.length
  end

  def assignment_identity(item)
    item.dig("assignment", "id") ||
      item["assignment_id"] ||
      item["id"]
  end

  def assignment_course_identity(item)
    item.dig("assignment", "course_id") ||
      item["course_id"]
  end

  def assignment_name(source_id, course_source_id)
    @assignment_names[source_id.to_s] ||= begin
      course_name = @course_names.fetch(course_source_id.to_s, "Course")
      topics = ASSIGNMENT_TOPICS.fetch(
        course_name,
        ["Practice", "Reflection", "Project", "Quiz"]
      )
      index = @assignment_counts[course_source_id.to_s]
      @assignment_counts[course_source_id.to_s] += 1
      unit = (index / topics.length) + 1
      "#{topics[index % topics.length]} · Unit #{unit}"
    end
  end

  def sanitize_assignment(item, fallback_course_id = nil, fallback_id = nil)
    source = item["assignment"].is_a?(Hash) ? item["assignment"] : item
    source_course_id = source["course_id"] || fallback_course_id
    source_id = source["id"] || fallback_id || assignment_identity(item)
    course_id = map_course_id(source_course_id)
    assignment_id = map_assignment_id(source_id)
    return nil unless course_id && assignment_id

    {
      "id" => assignment_id,
      "course_id" => course_id,
      "name" => assignment_name(source_id, source_course_id),
      "description" => "",
      "due_at" => source["due_at"],
      "points_possible" => source["points_possible"],
      "html_url" =>
        "https://canvas.example.test/courses/#{course_id}/assignments/#{assignment_id}",
      "omit_from_final_grade" => source["omit_from_final_grade"] == true
    }.compact
  end

  def sanitize_submission(submission, fallback_course_id = nil, fallback_id = nil)
    assignment = sanitize_assignment(
      submission,
      fallback_course_id,
      fallback_id
    )
    return nil unless assignment

    {
      "id" => map_assignment_id(submission["id"] || assignment["id"]),
      "assignment_id" => assignment["id"],
      "score" => submission["score"],
      "grade" => submission["grade"],
      "graded_at" => submission["graded_at"],
      "submitted_at" => submission["submitted_at"],
      "workflow_state" => submission["workflow_state"],
      "missing" => submission["missing"] == true,
      "late" => submission["late"] == true,
      "excused" => submission["excused"] == true,
      "assignment" => assignment,
      "submission_comments" => []
    }.compact
  end

  def sanitize_upcoming(event)
    assignment = sanitize_assignment(event)
    return nil unless assignment

    {
      "id" => assignment["id"],
      "title" => assignment["name"],
      "start_at" => assignment["due_at"],
      "html_url" => assignment["html_url"],
      "assignment" => assignment
    }.compact
  end

  def sanitize_todo(item, index)
    source_course_id =
      item.dig("plannable", "course_id") ||
      item["course_id"]
    course_id = map_course_id(source_course_id)
    return nil unless course_id

    {
      "plannable_type" => "planner_note",
      "plannable" => {
        "id" => 2001 + index,
        "course_id" => course_id,
        "title" => "Study Plan #{index + 1}",
        "details" => "Review today’s notes and prepare for the next class.",
        "todo_date" =>
          item.dig("plannable", "todo_date") ||
          item["plannable_date"]
      }.compact
    }
  end

  def sanitize_submissions
    Hash(@cache["submissions"]).each_with_object({}) do |(course_id, submissions), result|
      demo_course_id = map_course_id(course_id)
      next unless demo_course_id

      sanitized = Hash(submissions).filter_map do |assignment_id, submission|
        value = sanitize_submission(submission, course_id, assignment_id)
        [value["assignment_id"].to_s, value] if value
      end.to_h
      result[demo_course_id.to_s] = sanitized unless sanitized.empty?
    end
  end

  def apply_course_grade_targets!(grades)
    grades.group_by do |submission|
      submission.dig("assignment", "course_id")
    end.each do |course_id, submissions|
      included = submissions.select do |submission|
        !submission["score"].nil? &&
          submission.dig("assignment", "points_possible").to_f.positive? &&
          submission.dig("assignment", "omit_from_final_grade") != true
      end
      possible = included.sum do |submission|
        submission.dig("assignment", "points_possible").to_f
      end
      earned = included.sum { |submission| submission["score"].to_f }
      next if possible.zero? || earned.zero?

      course_name = @course_names.fetch(
        @course_ids.key(course_id),
        "Language Arts"
      )
      target = COURSE_GRADE_TARGETS.fetch(course_name, 90)
      scale = (possible * target / 100.0) / earned
      included.each do |submission|
        submission["score"] = (submission["score"].to_f * scale).round(2)
      end
    end
  end
end

cache = read_json("canvas_cache.json", nil)
abort "No Canvas cache found at #{SOURCE_DIR}" unless cache

anonymizer = Anonymizer.new(cache)
anonymized_cache = anonymizer.cache

write_json("canvas_cache.json", anonymized_cache)
write_json("course_name_mappings.json", anonymizer.course_name_mappings)
write_json(
  "grade_overrides.json",
  anonymizer.grade_overrides(read_json("grade_overrides.json", {}))
)
write_json(
  "manual_coursework.json",
  anonymizer.manual_coursework(
    read_json(
      "manual_coursework.json",
      { "courses" => {}, "assignments" => {} }
    )
  )
)
write_json("hidden_courses.json", [])
write_json(
  "school_calendar_settings.json",
  { "feed_url" => "", "excluded_keywords" => [] }
)

puts "Created anonymized demo data in #{OUTPUT_DIR}"
