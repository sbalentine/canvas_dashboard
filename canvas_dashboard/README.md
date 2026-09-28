# Canvas School Dashboard

A family-friendly Canvas LMS dashboard for Home Assistant.

The app includes a branded icon and logo for the Home Assistant app store and app details page.

## Configuration

Set `canvas_token` to the student's Canvas API token. Set `token_expires` to the token expiration date in `YYYY-MM-DD` format.

The web interface is exposed on port `4567`. Successful Canvas responses, class-name mappings, and the event journal are retained in the add-on data directory.

## Home Assistant Events

Every detected Canvas change is fired on the Home Assistant event bus as `school_dashboard_activity`. Create an automation with an **Event** trigger using that event type, then access the details under `trigger.event.data` in conditions and actions. No REST sensor or YAML configuration is required.

`GET /api/status` returns current assignment counts and the latest change-event ID. `GET /api/events?after=ID` remains available for external integrations.

See the [project repository](https://github.com/sbalentine/canvas_dashboard) for complete setup, API, and automation examples.