require "time"
require "cgi"

# ============================================================
# HTML / Number Formatting
# ============================================================

def h(value)
  CGI.escapeHTML(value.to_s)
end

def percentage(score, possible)
  return nil if score.nil? || possible.nil?
  return nil if possible.to_f <= 0

  ((score.to_f / possible.to_f) * 100).round(1)
end

def format_number(number)
  return "-" if number.nil?

  number.to_f % 1 == 0 ? number.to_i : number.round(1)
end

# ============================================================
# Course / Assignment Helpers
# ============================================================

def course_name(data, course_id)
  return "Unknown Course" if course_id.nil?

  data["course_names"][course_id.to_s] ||
    "Course #{course_id}"
end

def parse_canvas_time(value)
  return nil if value.nil?

  Time.parse(value)
rescue ArgumentError
  nil
end

def assignment_due_time(item)
  parse_canvas_time(
    item.dig("assignment", "due_at") ||
    item["due_at"] ||
    item["start_at"]
  )
end

def assignment_name(item)
  item.dig("assignment", "name") ||
    item["name"] ||
    item["title"] ||
    "Untitled Assignment"
end

def assignment_course_id(item)
  item.dig("assignment", "course_id") ||
    item["course_id"]
end

def assignment_id(item)
  item.dig("assignment", "id") ||
    item["assignment_id"] ||
    item["id"]
end

def assignment_url(item)
  item.dig("assignment", "html_url") ||
    item["html_url"]
end

# ============================================================
# Date Formatting
# ============================================================

def date_label(time)
  return "No due date" unless time

  today = Date.today
  date = time.getlocal.to_date

  case date
  when today
    "Today"
  when today + 1
    "Tomorrow"
  else
    time.getlocal.strftime("%A, %B %-d")
  end
end

def due_time_label(time)
  return "" unless time

  time.getlocal.strftime("%-I:%M %p")
end

def grade_date(value)
  time = parse_canvas_time(value)
  return "No date" unless time

  time.getlocal.strftime("%b %-d")
end

def greeting_for(time = Time.now)
  case time.hour
  when 0...12
    "Good morning"
  when 12...17
    "Good afternoon"
  else
    "Good evening"
  end
end

def profile_first_name(data)
  name = data.dig("profile", "short_name") ||
    data.dig("profile", "name")

  name.to_s.strip.split.first || "there"
end

# ============================================================
# Submission Helpers
# ============================================================

def submission_for(data, course_id, assignment_id)
  return nil unless course_id && assignment_id

  data.dig(
    "submissions",
    course_id.to_s,
    assignment_id.to_s
  )
end

def submission_status(submission)
  unless submission
    return {
      label: "Not submitted",
      css: "not-submitted",
      icon: "○"
    }
  end

  if submission["missing"] == true
    return {
      label: "Missing",
      css: "missing-status",
      icon: "!"
    }
  end

  score = submission["score"]
  assignment = submission["assignment"] || {}
  points = assignment["points_possible"]

  unless score.nil?
    score_text =
      if points && points.to_f > 0
        "#{format_number(score)}/#{format_number(points)}"
      else
        format_number(score)
      end

    return {
      label: "Graded · #{score_text}",
      css: "graded",
      icon: "✓"
    }
  end

  if submission["late"] == true &&
      submission["workflow_state"] == "submitted"

    return {
      label: "Submitted late",
      css: "late-status",
      icon: "✓"
    }
  end

  if submission["workflow_state"] == "submitted" ||
      submission["submitted_at"]

    return {
      label: "Submitted",
      css: "submitted",
      icon: "✓"
    }
  end

  {
    label: "Not submitted",
    css: "not-submitted",
    icon: "○"
  }
end

def submission_complete?(submission)
  status = submission_status(submission)

  !%w[not-submitted missing-status].include?(status[:css])
end

def latest_submission_comment(submission)
  comments = submission && submission["submission_comments"]
  return nil unless comments.is_a?(Array)

  comments.reject do |comment|
    comment["comment"].to_s.strip.empty?
  end.max_by do |comment|
    parse_canvas_time(comment["created_at"]) || Time.at(0)
  end
end
