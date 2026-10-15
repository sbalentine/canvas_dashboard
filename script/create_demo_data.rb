#!/usr/bin/env ruby

require "fileutils"
require "json"
require "time"

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
  "Physical Education" => 91
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
      "upcoming" => demo_upcoming,
      "todo" => demo_todos,
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

    [
      ["Rhythm and Meter Quiz", 18, 20, -24],
      ["Listening Analysis", 42, 50, -17],
      ["Scale Check-In", 17, 20, -10],
      ["Composition Reflection", 28, 30, -3],
      ["Note Reading Check", 17, 20, -31],
      ["Instrument Families Quiz", 18, 20, -27],
      ["Melody Exercise", 16, 20, -14],
      ["Performance Reflection", 19, 20, -7]
    ].each_with_index do |(name, score, points_possible, day_offset), index|
      custom["demo-music-grade-#{index + 1}"] = {
        "course_id" => "manual-demo-course-1",
        "name" => name,
        "score" => score,
        "points_possible" => points_possible,
        "graded_at" => demo_time(day_offset, 12, 0).split("T").first
      }
    end

    science_course_id = map_course_id(@course_names.key("Science"))
    [
      ["Ecosystem Vocabulary", 20, 25, -35],
      ["Food Web Diagram", 22, 25, -30],
      ["Energy Flow Notes", 21, 25, -25],
      ["Habitat Investigation", 23, 25, -20],
      ["Population Graph", 19, 25, -15],
      ["Lab Safety Check", 21.5, 25, -9],
      ["Evidence Reflection", 20.5, 25, -4]
    ].each_with_index do |(name, score, points_possible, day_offset), index|
      custom["demo-science-grade-#{index + 1}"] = {
        "course_id" => science_course_id,
        "name" => name,
        "score" => score,
        "points_possible" => points_possible,
        "graded_at" => demo_time(day_offset, 12, 0).split("T").first
      }
    end

    { "canvas" => {}, "custom" => custom }
  end

  def manual_coursework(_source)
    course_id = "demo-course-1"

    {
      "courses" => {
        course_id => {
        "name" => "Music",
          "updated_at" => @cache.fetch("updated_at")
        }
      },
      "assignments" => {
        "demo-assignment-1" => {
          "course_id" => course_id,
          "name" => "Listening Journal · Film Score",
          "due_at" => demo_time(-2, 18, 0),
          "completed" => true,
          "updated_at" => @cache.fetch("updated_at")
        },
        "demo-assignment-2" => {
          "course_id" => course_id,
          "name" => "Practice C Major Scale",
          "due_at" => demo_time(6, 17, 0),
          "completed" => false,
          "updated_at" => @cache.fetch("updated_at")
        }
      }
    }
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

  def demo_upcoming
    [
      ["Mathematics", "Problem Set · Unit 4", 1, 8, 0],
      ["Science", "Lab Reflection · Unit 2", 3, 15, 15],
      ["Social Studies", "Primary Source Notes · Unit 3", 5, 8, 0]
    ].filter_map do |course_name, name, day_offset, hour, minute|
      demo_assignment_event(
        course_name,
        name,
        day_offset,
        hour,
        minute
      )
    end
  end

  def demo_todos
    [
      ["Art", "Pack sketchbook and colored pencils", 1, 7, 30],
      ["Science", "Review lab vocabulary", 2, 16, 0],
      ["Language Arts", "Read twenty minutes", 4, 18, 0]
    ].each_with_index.filter_map do |(course_name, title, day_offset, hour, minute), index|
      source_course_id = @course_names.key(course_name)
      course_id = map_course_id(source_course_id)
      next unless course_id

      {
        "plannable_type" => "planner_note",
        "plannable" => {
          "id" => 2001 + index,
          "course_id" => course_id,
          "title" => title,
          "details" => "",
          "todo_date" => demo_time(day_offset, hour, minute)
        }
      }
    end
  end

  def demo_assignment_event(course_name, name, day_offset, hour, minute)
    source_course_id = @course_names.key(course_name)
    course_id = map_course_id(source_course_id)
    return nil unless course_id

    source_id = "demo-upcoming-#{course_name.downcase.gsub(/\W+/, "-")}"
    assignment_id = map_assignment_id(source_id)
    due_at = demo_time(day_offset, hour, minute)
    assignment = {
      "id" => assignment_id,
      "course_id" => course_id,
      "name" => name,
      "description" => "",
      "due_at" => due_at,
      "html_url" =>
        "https://canvas.example.test/courses/#{course_id}/assignments/#{assignment_id}",
      "omit_from_final_grade" => false
    }

    {
      "id" => assignment_id,
      "title" => name,
      "start_at" => due_at,
      "html_url" => assignment["html_url"],
      "assignment" => assignment
    }
  end

  def demo_time(day_offset, hour, minute)
    anchor = Time.iso8601(@cache.fetch("updated_at"))
    date = anchor.to_date + day_offset
    Time.new(
      date.year,
      date.month,
      date.day,
      hour,
      minute,
      0,
      anchor.utc_offset
    ).iso8601
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
        points = submission.dig("assignment", "points_possible").to_f
        submission["score"] = [
          [submission["score"].to_f * scale, 0].max,
          points
        ].min
      end

      adjusted_earned = included.sum { |submission| submission["score"] }
      difference = (possible * target / 100.0) - adjusted_earned
      capacities = included.map do |submission|
        points = submission.dig("assignment", "points_possible").to_f
        if difference.positive?
          points - submission["score"]
        else
          submission["score"]
        end
      end
      total_capacity = capacities.sum

      if total_capacity.positive?
        included.zip(capacities).each do |submission, capacity|
          adjustment = difference * capacity / total_capacity
          points = submission.dig("assignment", "points_possible").to_f
          submission["score"] = [
            [submission["score"] + adjustment, 0].max,
            points
          ].min.round(2)
        end
      end
    end

    grades.each do |submission|
      points = submission.dig("assignment", "points_possible")
      next if submission["score"].nil? || points.nil?

      submission["score"] = [
        [submission["score"].to_f, 0].max,
        points.to_f
      ].min.round(2)
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
