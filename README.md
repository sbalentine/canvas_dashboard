# 📚 Canvas School Dashboard

A lightweight, family-friendly dashboard for [Canvas LMS](https://www.instructure.com/canvas) built with Ruby.

The dashboard provides a simple view of the school information that matters most day-to-day:

* ⚠️ Missing assignments
* ✅ Canvas to-do list with completion controls
* 📅 Assignments due in the next 7 days
* ✅ Submission status
* 📊 Grades and recent scores
* 🔑 Canvas API token expiration
* 💾 Cached data when Canvas is temporarily unavailable
* 🏠 Home Assistant status and change-event API
* 📱 Mobile and iPad-friendly interface
* 🎓 Branded Home Assistant app-store artwork

It was designed to run continuously as a **Home Assistant add-on on a Raspberry Pi**, but it can also be run locally on macOS or another machine with Ruby.

---

## Screenshot

*Add a screenshot here once the dashboard is set up.*

```text
┌─────────────────────────────────────────────┐
│ 📚 School Dashboard                         │
│ Monday, September 15                        │
│                                             │
│ ⚠️ Missing Assignments                     │
│                                             │
│ 📅 Next 7 Days                             │
│   Math Homework                    5:00 PM   │
│   ✓ Science Assignment          Submitted   │
│                                             │
│ 📊 Grades                                   │
│   Math                              94.2%    │
│   Language Arts                     91.8%    │
└─────────────────────────────────────────────┘
```

---

## Why?

Canvas contains a lot of information, but checking several courses to answer a simple question like:

> "What homework do I still need to do?"

can require a surprising amount of navigation.

This dashboard uses the Canvas API to collect that information and present it on a single page designed to be left open, bookmarked, or added to an iPad Home Screen.

---

## Features

### ⚠️ Missing Assignments

Missing work is displayed prominently at the top of the dashboard so it is difficult to overlook.

### ✅ Canvas To-do List

Shows the student's incomplete Canvas planner notes. To-dos can be created, edited, and marked complete from the dashboard, with each change saved back to Canvas.

### 📅 Upcoming Assignments

Shows assignments due during the next seven days, including:

* Assignment name
* Course
* Due date and time
* Submission status
* Grade, when available

Assignments link back to Canvas when Canvas provides an assignment URL.

### 📊 Grade Summary

Calculates a current grade for each course from graded assignments returned by the Canvas API.

The dashboard also shows recent individual assignment grades.

> **Note:** These percentages are calculated from the assignments available through the API and may not exactly match the official Canvas course grade, particularly when a teacher uses weighted assignment groups, grading periods, dropped assignments, or other gradebook rules.

### 💾 Local Cache

Successful Canvas responses are cached locally.

If Canvas is temporarily unavailable, the dashboard can continue displaying the last successfully retrieved data instead of becoming unusable.

### 🔄 Automatic Refresh

Canvas data is refreshed automatically every 10 minutes.

The browser page also periodically reloads so newly fetched information appears without requiring the user to manually refresh the page.

### 🔑 Token Expiration

The dashboard can display the number of days remaining before the configured Canvas access token expires.

### 📱 iPad / Mobile Support

The interface is responsive and includes PWA/mobile metadata so it can be added to an iPad Home Screen for quick access.

### Course Name Mappings

Use **Edit Class Names** at the bottom of the dashboard to replace long Canvas course names with shorter labels. Aliases are stored by Canvas course ID in `/data/course_name_mappings.json` for the Home Assistant add-on or `tmp/course_name_mappings.json` locally. Both locations are excluded from source control. Blank aliases use the full Canvas course name.

### Home Assistant Events

The dashboard compares consecutive successful Canvas refreshes and keeps the latest 500 changes in `/data/event_journal.json`. The first refresh establishes a baseline and does not create events.

When installed as a Home Assistant app, every change is also fired on Home Assistant's event bus as `school_dashboard_activity`. No REST sensor or YAML configuration is required. In **Settings → Automations & scenes**, create an automation with an **Event** trigger, enter `school_dashboard_activity` as the event type, and add a phone notification action.

Available event types are:

* `assignment_missing`
* `assignment_no_longer_missing`
* `assignment_submitted`
* `grade_posted`
* `grade_changed`
* `due_date_changed`
* `teacher_feedback_added`

Event data is available to automation templates under `trigger.event.data`. For example:

```jinja
{{ trigger.event.data.assignment_name }}
in {{ trigger.event.data.course_name }}
```

To filter an automation to one kind of activity, add this template condition and replace `grade_posted` with the desired event type:

```jinja
{{ trigger.event.data.type == 'grade_posted' }}
```

The REST API remains available for external integrations. `GET /api/status` returns dashboard counts and the latest event. `GET /api/events?after=42&limit=100` returns events after a known event ID.

A REST sensor can use the latest event ID as its state when the dashboard runs outside Home Assistant:

```yaml
rest:
  - resource: http://HOME_ASSISTANT_HOST:4567/api/status
    scan_interval: 60
    sensor:
      - name: School Dashboard Event
        value_template: "{{ value_json.latest_event_id }}"
        json_attributes:
          - latest_event
          - missing_count
          - due_today_count
          - due_tomorrow_count
          - canvas_available
```

Replace `HOME_ASSISTANT_HOST` with the hostname or IP address that exposes the add-on port. `localhost` is only correct when Home Assistant and this process share a network namespace.

Example automation trigger:

```yaml
automation:
  - alias: School grade posted
    triggers:
      - trigger: state
        entity_id: sensor.school_dashboard_event
    conditions:
      - condition: template
        value_template: >-
          {{ trigger.to_state.attributes.get('latest_event', {}).get('type') == 'grade_posted' }}
    actions:
      - action: notify.mobile_app_parent_phone
        data:
          title: New Canvas grade
          message: >-
            {{ trigger.to_state.attributes.latest_event.assignment_name }}:
            {{ trigger.to_state.attributes.latest_event.score }} points
```

---

## Project Structure

```text
canvas-school-dashboard/
├── repository.yaml
├── run-local.sh
├── test/
└── canvas_dashboard/
  ├── app.rb
  ├── Dockerfile
  ├── config.yaml
  ├── run.sh
  ├── lib/
  ├── views/
  ├── public/
  └── tmp/                # Local only; ignored by Git
```

### `canvas_dashboard/app.rb`

Starts the WEBrick web server and defines the dashboard, stylesheet, icon, and PWA manifest routes.

### `canvas_dashboard/lib/canvas.rb`

Handles Canvas configuration, authentication, API requests, and token expiration.

### `canvas_dashboard/lib/dashboard_data.rb`

Retrieves Canvas data, builds the dashboard data model, caches successful responses, and manages the background refresh process.

### `canvas_dashboard/lib/helpers.rb`

Contains presentation and assignment helpers such as date formatting, score formatting, course names, and submission status.

### `canvas_dashboard/views/dashboard.erb`

The HTML/ERB dashboard interface.

### `canvas_dashboard/public/dashboard.css`

Dashboard styling and responsive layout.

---

# Running Locally

## Requirements

You'll need:

* Ruby
* WEBrick
* A Canvas API access token

Check Ruby:

```bash
ruby --version
```

Install WEBrick if necessary:

```bash
gem install webrick
```

---

## Canvas API Token

Generate an access token through your Canvas account.

The exact location depends on how your school configures Canvas, but Canvas normally exposes access tokens through the user's account settings when permitted by the institution.

**Never commit your Canvas token to Git.**

---

## Local Configuration

Create a `.env` file in the project root:

```bash
CANVAS_URL='https://your-school.instructure.com'
CANVAS_TOKEN='your-canvas-token'
TOKEN_EXPIRES='YYYY-MM-DD'
```

For example:

```bash
CANVAS_URL='https://your-school.instructure.com'
CANVAS_TOKEN='your-secret-token-here'
TOKEN_EXPIRES='2026-12-14'
```

`.env` is excluded by `.gitignore`.

---

## Start the Dashboard

Make the local startup script executable:

```bash
chmod +x run-local.sh
```

Then run:

```bash
./run-local.sh
```

Open:

```text
http://localhost:4567
```

### Running Tests

Install the development dependencies and run the test suite:

```bash
bundle install
bundle exec ruby test/run.rb
```

The suite does not contact Canvas. GitHub Actions runs it on the latest Ruby version pinned in `.ruby-version` and builds the ARM64 Home Assistant image for every push and pull request.

The first launch may briefly display a waiting message while the initial Canvas API request completes.

After a successful refresh, local cached data is stored at:

```text
canvas_dashboard/tmp/canvas_cache.json
```

The `tmp` directory is ignored by Git.

---

# Home Assistant Installation

The dashboard can run continuously as a Home Assistant app installed directly from GitHub.

This is particularly useful when Home Assistant OS is running on an always-on Raspberry Pi.

## Add the Repository

1. In Home Assistant, open **Settings → Apps → Install app**.
2. Open the three-dot menu and select **Repositories**.
3. Add this repository URL:

```text
https://github.com/sbalentine/canvas_dashboard
```

4. Refresh the app store and select **School Dashboard**.
5. Install the app and enter the Canvas configuration below.

---

## Home Assistant Configuration

The included `config.yaml` defines the add-on and exposes the dashboard web server.

Example:

```yaml
name: "School Dashboard"
description: "Canvas LMS school dashboard"
version: "0.9.0"
url: "https://github.com/sbalentine/canvas_dashboard"
slug: "canvas_dashboard"
init: false

arch:
  - aarch64

ports:
  4567/tcp: 4567

ports_description:
  4567/tcp: "School Dashboard"

map:
  - addon_config:rw

options:
  canvas_url: ""
  canvas_token: ""
  token_expires: ""

schema:
  canvas_url: str
  canvas_token: password
  token_expires: str
```

Configure the Canvas URL, token, and expiration date through the Home Assistant add-on configuration.

The token is provided to the application through Home Assistant's `/data/options.json` and does **not** need to be stored in the Git repository.

---

## Building the Add-on

After placing or updating the files:

1. Open **Home Assistant**
2. Go to **Settings → Apps**
3. Open the local **School Dashboard** add-on
4. Rebuild/update the add-on
5. Start it
6. Check the add-on logs

A successful startup should look similar to:

```text
Starting School Dashboard...
Loading cached Canvas data...
School Dashboard listening on port 4567
Refreshing Canvas data...
Canvas cache saved.
Canvas refresh successful at ...
```

---

# Configuration

The application supports two configuration environments.

### Home Assistant

Home Assistant stores configuration in:

```text
/data/options.json
```

Expected options:

```json
{
  "canvas_url": "https://your-school.instructure.com",
  "canvas_token": "...",
  "token_expires": "YYYY-MM-DD"
}
```

### Local Development

Local development uses environment variables:

```text
CANVAS_URL
CANVAS_TOKEN
TOKEN_EXPIRES
```

`run-local.sh` loads these values from `.env`.

---

# Canvas API

The dashboard communicates with the Canvas REST API using Bearer-token authentication.

Requests use:

```text
Authorization: Bearer <CANVAS_TOKEN>
```

The application currently retrieves information including:

* Active courses
* Graded submissions
* Missing submissions
* Upcoming events/assignments
* Submission information for upcoming assignments

The Canvas instance URL (for example `https://your-school.instructure.com`) is configured with the `canvas_url` add-on option in Home Assistant, or the `CANVAS_URL` environment variable for local development and tests. The application will not start if it is missing or blank.

---

# Security

The Canvas access token provides access to information available to the associated Canvas account.

Treat it like a password.

Do not:

* Commit it to Git
* Put it in `README.md`
* Include it in screenshots
* Store it directly in source code
* Publish `/data/options.json`
* Publish your local `.env`

The repository's `.gitignore` excludes common secret and runtime files, but always review changes before pushing:

```bash
git status
```

You can also search the repository before publishing:

```bash
grep -RniE 'access_token|canvas_token|Bearer ' . \
  --exclude-dir=.git \
  --exclude='.gitignore'
```

References to variable names such as `canvas_token` or `"Bearer #{TOKEN}"` are expected. An actual token value should never appear.

---

# Development Workflow

Run the dashboard locally:

```bash
./run-local.sh
```

Make changes and test at:

```text
http://localhost:4567
```

Check Ruby syntax:

```bash
ruby -c canvas_dashboard/app.rb
ruby -c canvas_dashboard/lib/canvas.rb
ruby -c canvas_dashboard/lib/helpers.rb
ruby -c canvas_dashboard/lib/dashboard_data.rb
```

Then commit:

```bash
git add .
git commit -m "Describe the change"
git push
```

Once the changes are working locally, increase the version in `canvas_dashboard/config.yaml` and push the changes. Home Assistant will then offer the new version as an update.

---

# Planned Improvements

Some useful next steps for the dashboard include:

* 🏠 Daily "Today" summary
* ⏳ Unsubmitted assignments shown before completed work
* ✅ "All done" indicators for completed days
* 📉 Grade attention indicators
* 🔄 Manual Canvas refresh button
* 💬 Teacher submission comments
* 🔔 Home Assistant notifications for unfinished work
* 🔑 Home Assistant token-expiration notifications
* 📡 Machine-readable dashboard status endpoint

---

# Disclaimer

This is an independent personal project using the Canvas LMS API.

It is not affiliated with, endorsed by, or maintained by Instructure or any school district.

Canvas remains the authoritative source for assignments, submissions, grades, due dates, and teacher feedback. Always verify important academic information directly in Canvas.
