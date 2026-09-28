require "json"
require "fileutils"
require "time"

EVENT_JOURNAL_LIMIT = 500

EVENT_JOURNAL_FILE = ENV.fetch("EVENT_JOURNAL_FILE") do
  if File.directory?("/data")
    "/data/event_journal.json"
  else
    File.expand_path(
      "../tmp/event_journal.json",
      __dir__
    )
  end
end

$event_journal = {
  "next_id" => 1,
  "events" => []
}
$event_journal_mutex = Mutex.new

def dashboard_assignment_key(item)
  course_id = assignment_course_id(item)
  assignment_id = assignment_id(item)

  return nil unless course_id && assignment_id

  "#{course_id}:#{assignment_id}"
end

def dashboard_assignment_index(items)
  Array(items).each_with_object({}) do |item, index|
    key = dashboard_assignment_key(item)
    index[key] = item if key
  end
end

def dashboard_submission_index(data)
  (data["submissions"] || {}).each_with_object({}) do |(course_id, submissions), index|
    submissions.each do |assignment_id, submission|
      index["#{course_id}:#{assignment_id}"] = submission
    end
  end
end

def event_details(type, item, data, changes = {})
  course_id = assignment_course_id(item)

  {
    "type" => type,
    "occurred_at" => Time.now.iso8601,
    "course_id" => course_id,
    "course_name" => data.dig("course_names", course_id.to_s),
    "assignment_id" => assignment_id(item),
    "assignment_name" => assignment_name(item)
  }.merge(changes).compact
end

def detect_dashboard_events(previous, current)
  return [] unless previous

  events = []
  previous_missing = dashboard_assignment_index(previous["missing"])
  current_missing = dashboard_assignment_index(current["missing"])

  current_missing.each do |key, assignment|
    next if previous_missing.key?(key)

    events << event_details("assignment_missing", assignment, current)
  end

  previous_missing.each do |key, assignment|
    next if current_missing.key?(key)

    events << event_details("assignment_no_longer_missing", assignment, current)
  end

  previous_grades = dashboard_assignment_index(previous["grades"])

  dashboard_assignment_index(current["grades"]).each do |key, submission|
    score = submission["score"]
    next if score.nil?

    old_submission = previous_grades[key]

    if old_submission.nil? || old_submission["score"].nil?
      events << event_details(
        "grade_posted",
        submission,
        current,
        "score" => score,
        "points_possible" => submission.dig("assignment", "points_possible")
      )
    elsif old_submission["score"] != score
      events << event_details(
        "grade_changed",
        submission,
        current,
        "previous_score" => old_submission["score"],
        "score" => score,
        "points_possible" => submission.dig("assignment", "points_possible")
      )
    end
  end

  previous_upcoming = dashboard_assignment_index(previous["upcoming"])

  dashboard_assignment_index(current["upcoming"]).each do |key, assignment|
    old_assignment = previous_upcoming[key]
    next unless old_assignment

    old_due_at = assignment_due_time(old_assignment)&.iso8601
    due_at = assignment_due_time(assignment)&.iso8601
    next if old_due_at == due_at

    events << event_details(
      "due_date_changed",
      assignment,
      current,
      "previous_due_at" => old_due_at,
      "due_at" => due_at
    )
  end

  previous_submissions = dashboard_submission_index(previous)

  dashboard_submission_index(current).each do |key, submission|
    old_submission = previous_submissions[key]
    next unless old_submission

    assignment = submission["assignment"] || submission

    if submission_complete?(submission) && !submission_complete?(old_submission)
      events << event_details("assignment_submitted", assignment, current)
    end

    old_comment_ids = Array(old_submission["submission_comments"]).map do |comment|
      comment["id"].to_s
    end

    Array(submission["submission_comments"]).each do |comment|
      next if old_comment_ids.include?(comment["id"].to_s)

      events << event_details(
        "teacher_feedback_added",
        assignment,
        current,
        "comment_id" => comment["id"],
        "comment" => comment["comment"],
        "author_name" => comment["author_name"]
      )
    end
  end

  events
end

def save_event_journal
  FileUtils.mkdir_p(File.dirname(EVENT_JOURNAL_FILE))
  temporary_file = "#{EVENT_JOURNAL_FILE}.tmp"

  File.write(temporary_file, JSON.pretty_generate($event_journal))
  File.rename(temporary_file, EVENT_JOURNAL_FILE)
end

def initialize_event_journal
  return unless File.exist?(EVENT_JOURNAL_FILE)

  journal = JSON.parse(File.read(EVENT_JOURNAL_FILE))
  return unless journal["events"].is_a?(Array)

  $event_journal_mutex.synchronize do
    $event_journal = journal
    $event_journal["next_id"] ||= ($event_journal["events"].last&.dig("id") || 0) + 1
  end
rescue => e
  puts "Unable to load event journal: #{e.class}: #{e.message}"
end

def append_dashboard_events(events)
  return if events.empty?

  $event_journal_mutex.synchronize do
    events.each do |event|
      event["id"] = $event_journal["next_id"]
      $event_journal["next_id"] += 1
      $event_journal["events"] << event
    end

    $event_journal["events"] = $event_journal["events"].last(EVENT_JOURNAL_LIMIT)
    save_event_journal
  end
end

def dashboard_events(after_id: nil)
  $event_journal_mutex.synchronize do
    events = $event_journal["events"]
    events = events.select { |event| event["id"] > after_id } if after_id
    Marshal.load(Marshal.dump(events))
  end
end