require_relative "test_helper"
require_relative "../canvas_dashboard/lib/school_calendar"

class SchoolCalendarTest < Minitest::Test
  TODAY = Date.new(2026, 10, 12)
  NOW = Time.local(2026, 10, 12, 12)
  SOURCE = "https://school.example/calendar.ics"

  def setup
    FileUtils.rm_f(SCHOOL_CALENDAR_FILE)
    @source = SOURCE
    @fetches = []
    @options = Object.instance_method(:options)
    @calendar_test_options = { "calendar_url" => @source }
    configured = @calendar_test_options
    Object.send(:define_method, :options) { configured }
  end

  def teardown
    Object.send(:define_method, :options, @options)
    FileUtils.rm_f(SCHOOL_CALENDAR_FILE)
  end

  def source=(value)
    @calendar_test_options["calendar_url"] = value
  end

  def ics(*events)
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//School//EN\r\n" +
      events.map { |event| "BEGIN:VEVENT\r\n#{event.strip.gsub(/\r?\n/, "\r\n")}\r\nEND:VEVENT\r\n" }.join +
      "END:VCALENDAR\r\n"
  end

  def event(date = "20261012", title = "School closed")
    "UID:#{date}-#{title}\nDTSTART;VALUE=DATE:#{date}\nSUMMARY:#{title}"
  end

  def with_feeds(responses)
    replacement = lambda do |url, **_kwargs|
      @fetches << url
      value = responses.fetch(url)
      raise value if value.is_a?(Exception)

      value.is_a?(Array) ? value : [value, url, "text/calendar"]
    end
    with_replaced_method(SchoolCalendar, :fetch, replacement) { yield }
  end

  def test_direct_feed_and_single_day_all_day_event
    with_feeds(SOURCE => ics(event)) do
      cache = refresh_school_calendar(now: NOW)
      assert_equal 1, cache["events"].length
      school_event = cache["events"].first
      assert_equal "School closed", school_event["title"]
      assert_equal "2026-10-12", school_event["start_at"]
      assert_equal "2026-10-13", school_event["end_at"]
      assert school_event["all_day"]
      assert_equal [school_event], school_calendar_events_on(cache["events"], TODAY)
      assert_empty school_calendar_events_on(cache["events"], TODAY + 1)
      assert_equal NOW.iso8601, cache["updated_at"]
      assert_nil cache["error"]
    end
  end

  def test_html_relative_advertised_feed_uses_final_redirected_url
    page = "https://school.example/calendar#"
    self.source = page
    with_feeds(
      page => ['<a href="../feeds/school.ics?subscription=public">Subscribe</a>',
        "https://school.example/pages/calendar", "text/html"],
      "https://school.example/feeds/school.ics?subscription=public" => ics(event)
    ) do
      assert_equal 1, refresh_school_calendar(now: NOW)["events"].length
      assert_equal [page, "https://school.example/feeds/school.ics?subscription=public"], @fetches
    end
  end

  def test_webcal_feed_and_mime_advertised_feed
    self.source = "https://school.example/calendar"
    with_feeds(
      @calendar_test_options["calendar_url"] => [
        '<link type="text/calendar" href="/subscribe?id=2"><a href="webcal://other.example/calendar">ICS</a>',
        "https://school.example/calendar", "text/html"
      ],
      "https://school.example/subscribe?id=2" => ics(event),
      "https://other.example/calendar" => ics(event("20261013", "Assembly"))
    ) do
      assert_equal 2, refresh_school_calendar(now: NOW)["events"].length
    end
    assert_equal "https://other.example/calendar", SchoolCalendar.source_uri("webcal://other.example/calendar#top").to_s
  end

  def test_missing_feed_is_friendly_and_does_not_guess_endpoints
    with_feeds(SOURCE => ["<h1>Calendar</h1>", SOURCE, "text/html"]) do
      cache = refresh_school_calendar(now: NOW)
      assert_empty cache["events"]
      assert_match(/ICS subscribe URL/, cache["error"])
      assert_equal [SOURCE], @fetches
    end
  end

  def test_subscribe_dialog_advertises_feed_and_ics_data_attributes
    self.source = "https://school.example/calendar"
    with_feeds(
      @calendar_test_options["calendar_url"] => [
        '<button data-feed-url="/feeds/holidays.ics">Holidays</button><button data-ics-url="/feeds/events.ics">Events</button>',
        "https://school.example/calendar", "text/html"
      ],
      "https://school.example/feeds/holidays.ics" => ics(event),
      "https://school.example/feeds/events.ics" => ics(event("20261013", "Assembly"))
    ) do
      cache = refresh_school_calendar(now: NOW)
      assert_nil cache["error"]
      assert_equal ["School closed", "Assembly"], cache["events"].map { |item| item["title"] }
      assert_equal [
        "https://school.example/calendar",
        "https://school.example/feeds/holidays.ics",
        "https://school.example/feeds/events.ics"
      ], @fetches
    end
  end

  def test_malformed_calendar_is_not_a_successful_empty_calendar
    with_feeds(SOURCE => "not a calendar") do
      cache = refresh_school_calendar(now: NOW)
      assert cache["error"]
      assert_nil cache["updated_at"]
    end
    FileUtils.rm_f(SCHOOL_CALENDAR_FILE)
    with_feeds(SOURCE => ics) do
      cache = refresh_school_calendar(now: NOW)
      assert_empty cache["events"]
      assert_nil cache["error"]
      assert_equal NOW.iso8601, cache["updated_at"]
    end
    assert_raises(SchoolCalendar::InvalidSource) do
      SchoolCalendar.parse_ics(ics("SUMMARY:Missing date"), today: TODAY)
    end
  end

  def test_folded_escaped_title_location_and_safe_link
    body = ics("UID:title\nDTSTART;VALUE=DATE:20261012\nSUMMARY:Parent\\, teacher\\; confer\n ence\\nBring forms\nLOCATION:Main\\, hall\nURL:javascript:alert(1)")
    parsed = SchoolCalendar.parse_ics(body, today: TODAY).first
    assert_equal "Parent, teacher; conference\nBring forms", parsed["title"]
    assert_equal "Main, hall", parsed["location"]
    assert_nil parsed["url"]
    assert_equal "https://school.example/events/1", SchoolCalendar.safe_event_url("https://school.example/events/1")
    assert_nil SchoolCalendar.safe_event_url("//school.example/events/1")
  end

  def test_timed_timezone_and_utc_events_use_local_dates_and_exclusive_midnight
    previous_timezone = ENV["TZ"]
    ENV["TZ"] = "America/Los_Angeles"
    events = SchoolCalendar.parse_ics(ics(
      "UID:tz\nDTSTART;TZID=America/Los_Angeles:20261012T190000\nDTEND;TZID=America/Los_Angeles:20261013T000000\nSUMMARY:Evening concert",
      "UID:utc\nDTSTART:20261013T020000Z\nDTEND:20261013T030000Z\nSUMMARY:UTC meeting",
      "UID:floating\nDTSTART:20261012T090000\nSUMMARY:Floating meeting"
    ), today: TODAY)
    assert_equal 3, school_calendar_events_on(events, TODAY).length
    assert_empty school_calendar_events_on(events, TODAY + 1)
    concert = events.find { |item| item["title"] == "Evening concert" }
    assert_equal "2026-10-12T19:00:00-07:00", concert["start_at"]
    assert_equal "2026-10-13", concert["end_date"]
    assert_equal "2026-10-12T09:00:00-07:00", events.find { |item| item["title"] == "Floating meeting" }["start_at"]
  ensure
    ENV["TZ"] = previous_timezone
  end

  def test_multi_day_events_starting_before_today_are_included
    events = SchoolCalendar.parse_ics(ics(
      "UID:break\nDTSTART;VALUE=DATE:20261010\nDTEND;VALUE=DATE:20261015\nSUMMARY:Fall break",
      event("20261018", "This week"),
      event("20261019", "Next week")
    ), today: TODAY)
    assert_equal ["Fall break"], school_calendar_events_on(events, TODAY).map { |item| item["title"] }
    assert_empty school_calendar_events_on(events, TODAY + 3)
    assert_equal ["Fall break", "This week"], weekly_school_calendar_events({ "events" => events }, today: TODAY).map { |item| item["title"] }
  end

  def test_recurrence_exclusions_overrides_and_cancelled_occurrences
    body = ics(
      "UID:repeat\nDTSTART;VALUE=DATE:20261010\nSUMMARY:School\nRRULE:FREQ=DAILY;COUNT=10\nEXDATE;VALUE=DATE:20261013",
      "UID:repeat\nRECURRENCE-ID;VALUE=DATE:20261014\nDTSTART;VALUE=DATE:20261015\nSUMMARY:Rescheduled",
      "UID:repeat\nRECURRENCE-ID;VALUE=DATE:20261016\nSTATUS:CANCELLED",
      "UID:cancelled\nDTSTART;VALUE=DATE:20261012\nSTATUS:CANCELLED\nSUMMARY:Cancelled"
    )
    events = SchoolCalendar.parse_ics(body, today: TODAY)
    assert_empty school_calendar_events_on(events, TODAY + 1)
    assert_empty school_calendar_events_on(events, TODAY + 2)
    assert_equal ["School", "Rescheduled"].sort, school_calendar_events_on(events, TODAY + 3).map { |item| item["title"] }.sort
    assert_empty school_calendar_events_on(events, TODAY + 4)
    assert_equal ["School"], school_calendar_events_on(events, TODAY).map { |item| item["title"] }
  end

  def test_recurrence_stays_at_local_time_across_daylight_saving
    previous_timezone = ENV["TZ"]
    ENV["TZ"] = "America/Los_Angeles"
    events = SchoolCalendar.parse_ics(ics(
      "UID:dst\nDTSTART;TZID=America/Los_Angeles:20261030T090000\nDTEND;TZID=America/Los_Angeles:20261030T100000\nRRULE:FREQ=DAILY;COUNT=5\nSUMMARY:Morning"
    ), today: Date.new(2026, 10, 30))
    assert_equal "2026-10-31T09:00:00-07:00", events[1]["start_at"]
    assert_equal "2026-11-01T09:00:00-08:00", events[2]["start_at"]
  ensure
    ENV["TZ"] = previous_timezone
  end

  def test_timezone_event_can_have_utc_end_and_utc_recurrence_bounds
    previous_timezone = ENV["TZ"]
    ENV["TZ"] = "Pacific/Auckland"
    events = SchoolCalendar.parse_ics(ics(
      "UID:zones\nDTSTART;TZID=Pacific/Auckland:20261012T090000\nDTEND:20261011T210000Z\nRRULE:FREQ=DAILY;UNTIL=20261013T200000Z\nEXDATE:20261012T200000Z\nSUMMARY:Morning"
    ), today: TODAY)
    assert_equal ["2026-10-12", "2026-10-14"], events.map { |item| item["start_date"] }
    assert_equal "2026-10-12T09:00:00+13:00", events.first["start_at"]
    assert_equal "2026-10-12T10:00:00+13:00", events.first["end_at"]
  ensure
    ENV["TZ"] = previous_timezone
  end

  def test_embedded_non_iana_timezone
    body = ics("UID:custom\nDTSTART;TZID=Custom/School:20261012T090000\nDTEND;TZID=Custom/School:20261012T100000\nSUMMARY:Custom timezone")
    timezone = <<~ICAL.gsub("\n", "\r\n")
      BEGIN:VTIMEZONE
      TZID:Custom/School
      BEGIN:STANDARD
      DTSTART:19700101T000000
      TZOFFSETFROM:+0530
      TZOFFSETTO:+0530
      END:STANDARD
      END:VTIMEZONE
    ICAL
    body.sub!("BEGIN:VEVENT", "#{timezone}BEGIN:VEVENT")
    parsed = SchoolCalendar.parse_ics(body, today: TODAY).first
    assert_equal Time.new(2026, 10, 12, 9, 0, 0, "+05:30").getlocal.iso8601, parsed["start_at"]
    assert_equal Time.new(2026, 10, 12, 10, 0, 0, "+05:30").getlocal.iso8601, parsed["end_at"]
  end

  def test_snapshot_and_daily_refresh_survive_restart_and_retry_next_day
    with_feeds(SOURCE => ics(event)) do
      first = refresh_school_calendar(now: NOW)
      assert_equal first, JSON.parse(File.read(SCHOOL_CALENDAR_FILE))
      assert_equal first, school_calendar_data
      assert_equal first, refresh_school_calendar(now: NOW + 3600)
      assert_equal [SOURCE], @fetches
      refresh_school_calendar(now: NOW + 86_400)
      assert_equal [SOURCE, SOURCE], @fetches
    end
  end

  def test_failed_refresh_preserves_events_and_persists_attempt_before_network
    with_feeds(SOURCE => ics(event)) { refresh_school_calendar(now: NOW) }
    replacement = lambda do |_source, **_kwargs|
      assert_equal "2026-10-13", JSON.parse(File.read(SCHOOL_CALENDAR_FILE))["checked_on"]
      raise SocketError, "secret subscription URL"
    end
    output, = capture_io do
      with_replaced_method(SchoolCalendar, :fetch, replacement) do
        failed = refresh_school_calendar(now: NOW + 86_400)
        assert_equal ["School closed"], failed["events"].map { |item| item["title"] }
        assert_equal NOW.iso8601, failed["updated_at"]
        assert_equal failed, refresh_school_calendar(now: NOW + 90_000)
      end
    end
    refute_includes output, "secret subscription URL"
    refute_includes school_calendar_data["error"], SOURCE
  end

  def test_changed_or_disabled_source_never_shows_previous_events
    with_feeds(SOURCE => ics(event)) { refresh_school_calendar(now: NOW) }
    self.source = "https://different.example/calendar.ics"
    assert_empty school_calendar_data["events"]
    with_feeds(@calendar_test_options["calendar_url"] => SocketError.new("failure")) do
      assert_empty refresh_school_calendar(now: NOW)["events"]
    end
    self.source = "  "
    with_feeds({}) do
      assert_empty school_calendar_data["events"]
      assert_empty refresh_school_calendar(now: NOW)["events"]
    end
  end

  def test_failed_initial_attempt_is_not_retried_same_day_but_recovers_next_day
    with_feeds(SOURCE => SocketError.new("down")) do
      refresh_school_calendar(now: NOW)
      refresh_school_calendar(now: NOW + 3600)
      assert_equal [SOURCE], @fetches
    end
    with_feeds(SOURCE => ics(event("20261013"))) do
      cache = refresh_school_calendar(now: NOW + 86_400)
      assert_nil cache["error"]
      assert_equal 1, cache["events"].length
    end
  end

  def test_url_and_address_validation
    %w[http://school.example/ ******school.example/ file:///etc/passwd https://school.example:8443/].each do |url|
      assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.source_uri(url) }
    end
    %w[127.0.0.1 10.0.0.1 172.16.1.1 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0 224.0.0.1 192.0.2.1 ::1 :: ::ffff:127.0.0.1 fc00::1 fe80::1 2001:db8::1 2002:7f00:1::].each do |ip|
      refute SchoolCalendar.public_address?(ip), ip
    end
    %w[8.8.8.8 1.1.1.1 2606:4700:4700::1111 ::ffff:8.8.8.8].each do |ip|
      assert SchoolCalendar.public_address?(ip), ip
    end
    with_replaced_method(SchoolCalendar, :resolve, ->(_host) { ["8.8.8.8", "127.0.0.1"] }) do
      assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.fetch(SOURCE) }
    end
  end

  def test_redirects_revalidate_destination_and_do_not_use_proxies_or_credentials
    http = Object.new
    %i[ipaddr= use_ssl= open_timeout= read_timeout= write_timeout=].each do |name|
      http.define_singleton_method(name) { |_value| }
    end

    http.define_singleton_method(:request) do |request, &block|
      raise "Canvas credentials leaked" if request["Authorization"]
      response = Net::HTTPFound.new("1.1", "302", "Found")
      response["location"] = "https://127.0.0.1/internal"
      block.call(response)
    end
    with_replaced_method(Net::HTTP, :new, lambda { |host, port, proxy|
      assert_equal "school.example", host
      assert_equal 443, port
      assert_nil proxy
      http
    }) do
      with_replaced_method(SchoolCalendar, :resolve, ->(host) { host == "school.example" ? ["8.8.8.8"] : ["127.0.0.1"] }) do
        assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.fetch(SOURCE) }
      end
    end
  end

  def fake_http(response)
    http = Object.new
    %i[ipaddr= use_ssl= open_timeout= read_timeout= write_timeout=].each do |name|
      http.define_singleton_method(name) { |_value| }
    end
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    http
  end

  def test_redirect_count_is_bounded
    response = Net::HTTPFound.new("1.1", "302", "Found")
    response["location"] = "/calendar.ics"
    requests = 0
    with_replaced_method(Net::HTTP, :new, lambda { |*_args|
      requests += 1
      fake_http(response)
    }) do
      with_replaced_method(SchoolCalendar, :resolve, ->(_host) { ["8.8.8.8"] }) do
        assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.fetch(SOURCE) }
      end
    end
    assert_equal 4, requests
  end

  def test_response_size_is_bounded_even_without_content_length
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/calendar"
    response.define_singleton_method(:read_body) do |&block|
      block.call("a" * (SchoolCalendar::MAX_BYTES + 1))
    end
    with_replaced_method(Net::HTTP, :new, ->(*_args) { fake_http(response) }) do
      with_replaced_method(SchoolCalendar, :resolve, ->(_host) { ["8.8.8.8"] }) do
        assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.fetch(SOURCE) }
      end
    end
    response["content-length"] = (SchoolCalendar::MAX_BYTES + 1).to_s
    response.define_singleton_method(:read_body) { raise "Body must not be read" }
    with_replaced_method(Net::HTTP, :new, ->(*_args) { fake_http(response) }) do
      with_replaced_method(SchoolCalendar, :resolve, ->(_host) { ["8.8.8.8"] }) do
        assert_raises(SchoolCalendar::InvalidSource) { SchoolCalendar.fetch(SOURCE) }
      end
    end
  end

  def test_insecure_discovered_feed_is_rejected
    with_feeds(SOURCE => ['<a href="http://school.example/calendar.ics">Subscribe</a>', SOURCE, "text/html"]) do
      cache = refresh_school_calendar(now: NOW)
      assert cache["error"]
      assert_equal [SOURCE], @fetches
    end
  end

  def test_storage_failure_does_not_fetch_or_interrupt_canvas_refresh
    original_error = $last_refresh_error
    canvas_attempted = false
    with_replaced_method(SchoolCalendar, :save, ->(_cache) { raise Errno::EACCES }) do
      with_feeds({}) do
        cache = refresh_school_calendar(now: NOW)
        assert cache["error"]
        assert_empty @fetches
        with_replaced_method(self, :fetch_dashboard_data, lambda {
          canvas_attempted = true
          raise "Canvas attempted"
        }) do
          capture_io { refresh_dashboard }
        end
      end
    end
    assert canvas_attempted
  ensure
    $last_refresh_error = original_error
  end

  def test_final_cache_write_failure_does_not_propagate_or_retry_same_day
    original_save = SchoolCalendar.method(:save)
    writes = 0
    with_replaced_method(SchoolCalendar, :save, lambda { |cache|
      writes += 1
      raise IOError if writes > 1

      original_save.call(cache)
    }) do
      with_feeds(SOURCE => ics(event)) do
        first = refresh_school_calendar(now: NOW)
        assert first["error"]
        assert_equal ["School closed"], first["events"].map { |item| item["title"] }
        refresh_school_calendar(now: NOW + 3600)
        assert_equal [SOURCE], @fetches
      end
    end
  end

  def test_unreadable_cache_does_not_crash_snapshot
    SchoolCalendar.save(SchoolCalendar.empty(SOURCE))
    with_replaced_method(File, :read, ->(*_args) { raise IOError }) do
      assert_empty school_calendar_data["events"]
    end
  end

  def test_dns_resolution_is_inside_its_own_timeout
    intervals = []
    resolved = false
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/calendar"
    body = ics(event)
    response.define_singleton_method(:read_body) { |&block| block.call(body) }
    with_replaced_method(Timeout, :timeout, lambda { |seconds, &block|
      intervals << seconds
      block.call
    }) do
      with_replaced_method(SchoolCalendar, :resolve, lambda { |_host|
        assert_equal [5], intervals
        resolved = true
        ["8.8.8.8"]
      }) do
        with_replaced_method(Net::HTTP, :new, ->(*_args) { fake_http(response) }) do
          assert_equal body, SchoolCalendar.fetch(SOURCE).first
        end
      end
    end
    assert resolved
    assert_equal [5, 20], intervals
  end

  def test_concurrent_refreshes_contact_calendar_once
    calls = 0
    with_replaced_method(SchoolCalendar, :fetch, lambda { |source, **_kwargs|
      calls += 1
      Thread.pass
      [ics(event), source, "text/calendar"]
    }) do
      threads = 5.times.map { Thread.new { refresh_school_calendar(now: NOW) } }
      assert_equal 5, threads.map(&:value).length
      assert_equal 1, calls
    end
  end

  def test_dashboard_refresh_updates_calendar_once_daily_despite_canvas_failure
    original_data = $dashboard_data
    original_error = $last_refresh_error
    cached_canvas = { "profile" => { "short_name" => "Avery" } }
    $dashboard_data = cached_canvas
    canvas_attempts = 0

    with_feeds(SOURCE => ics(event)) do
      with_replaced_method(Time, :now, -> { NOW }) do
        with_replaced_method(self, :fetch_dashboard_data, lambda {
          canvas_attempts += 1
          raise "Canvas unavailable"
        }) do
          capture_io { 3.times { refresh_dashboard } }
        end
      end
    end

    assert_equal 3, canvas_attempts
    assert_equal [SOURCE], @fetches
    assert_equal cached_canvas, dashboard_data
    assert_equal "Canvas unavailable", dashboard_status[:error]
    calendar = school_calendar_data
    assert_nil calendar["error"]
    assert_equal NOW.iso8601, calendar["updated_at"]
    assert_equal ["School closed"], calendar["events"].map { |item| item["title"] }
    assert_equal TODAY.iso8601, calendar["checked_on"]
  ensure
    $dashboard_data = original_data
    $last_refresh_error = original_error
  end

  def test_structured_events_without_a_feed
    document = '<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"Event","name":"Holiday","startDate":"2026-10-12","endDate":"2026-10-13","location":{"name":"Campus"}},{"@type":"Event","name":"Cancelled","startDate":"2026-10-12","eventStatus":"https://schema.org/EventCancelled"}]}</script>'
    with_feeds(SOURCE => [document, SOURCE, "text/html"]) do
      cache = refresh_school_calendar(now: NOW)
      assert_nil cache["error"]
      assert_equal ["Holiday"], cache["events"].map { |item| item["title"] }
      assert_equal "Campus", cache["events"].first["location"]
      assert_equal 1, school_calendar_events_on(cache["events"], TODAY + 1).length
    end
  end
end
