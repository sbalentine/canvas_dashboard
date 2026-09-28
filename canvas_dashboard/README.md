# Canvas School Dashboard

A family-friendly Canvas LMS dashboard for Home Assistant.

The app includes a branded icon and logo for the Home Assistant app store and app details page.

## Configuration

Set `canvas_token` to the student's Canvas API token. Set `token_expires` to the token expiration date in `YYYY-MM-DD` format.

The web interface is exposed on port `4567`. Successful Canvas responses, class-name mappings, and the event journal are retained in the add-on data directory.

## Home Assistant Events

`GET /api/status` returns current assignment counts and the latest change-event ID. `GET /api/events?after=ID` returns journal entries after a known ID for Home Assistant automations.

See the [project repository](https://github.com/sbalentine/canvas_dashboard) for complete setup, API, and automation examples.