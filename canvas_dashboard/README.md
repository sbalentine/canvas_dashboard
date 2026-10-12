# Canvas School Dashboard

A family-friendly Canvas LMS dashboard for Home Assistant.

The app includes a branded icon and logo for the Home Assistant app store and app details page.

## Configuration

Set `canvas_url` to your school's Canvas URL (for example `https://your-school.instructure.com`). Set `canvas_token` to the student's Canvas API token. Set `token_expires` to the token expiration date in `YYYY-MM-DD` format.

Optionally set `calendar_url` to a public HTTPS iCalendar (`.ics`) subscription URL or a calendar page that advertises one. Pages with embedded structured event data are also supported. The dashboard shows school events for the next seven calendar days, including **Today** and **Tomorrow**, separately from assignments.

Events are cached in `/data/school_calendar.json`. The source is checked at most once per local calendar day, including across restarts and manual Canvas refreshes. A failed check retains cached events and is retried the following day. Changing the URL starts a new cache; clearing it disables the calendar. Use the app's local timezone for day boundaries.

For a page such as `https://www.tvusd.k12.ca.us/view-full-calendar#`, try the page URL first. If the dashboard cannot find a feed, copy the calendar's **Subscribe / iCal** URL instead. JavaScript-only calendars without an advertised feed or embedded event data cannot be imported automatically.

The web interface is exposed on port `4567`. Successful Canvas responses, class-name mappings, and the event journal are retained in the add-on data directory.

## Home Assistant Events

Every detected Canvas change is fired on the Home Assistant event bus as `school_dashboard_activity`. Create an automation with an **Event** trigger using that event type, then access the details under `trigger.event.data` in conditions and actions. No REST sensor or YAML configuration is required.

`GET /api/status` returns current assignment counts and the latest change-event ID. `GET /api/events?after=ID` remains available for external integrations.

See the [project repository](https://github.com/sbalentine/canvas_dashboard) for complete setup, API, and automation examples.