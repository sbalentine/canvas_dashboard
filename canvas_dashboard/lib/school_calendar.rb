require "date"
require "fileutils"
require "icalendar/recurrence"
require "ipaddr"
require "json"
require "net/http"
require "nokogiri"
require "resolv"
require "time"
require "timeout"
require "uri"

SCHOOL_CALENDAR_FILE = ENV.fetch("SCHOOL_CALENDAR_FILE") do
  File.directory?("/data") ? "/data/school_calendar.json" :
    File.expand_path("../tmp/school_calendar.json", __dir__)
end
SCHOOL_CALENDAR_MUTEX = Mutex.new

module SchoolCalendar
  extend self

  MAX_BYTES = 5 * 1024 * 1024
  MAX_EVENTS = 5_000
  PRIVATE_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
    169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
    192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
    203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    2001::/23 2001:db8::/32 2002::/16 3fff::/20
  ].map { |network| IPAddr.new(network) }.freeze

  class NoFeed < StandardError; end
  class InvalidSource < StandardError; end

  class EmbeddedTimezone
    def initialize(timezone)
      @timezone = timezone
    end

    def local_to_utc(civil, _dst = true)
      Time.new(civil.year, civil.month, civil.day, civil.hour, civil.min, civil.sec,
        @timezone.offset_for_local(civil).to_s).utc
    end

    def utc_to_local(utc)
      local = utc.getlocal(@timezone.offset_for_local(utc).to_s)
      utc.getlocal(@timezone.offset_for_local(local).to_s)
    end
  end

  def empty(source = "")
    { "source_url" => source, "events" => [] }
  end

  def load
    return empty unless File.file?(SCHOOL_CALENDAR_FILE)

    data = JSON.parse(File.read(SCHOOL_CALENDAR_FILE))
    return empty unless data.is_a?(Hash) && data["events"].is_a?(Array)

    data
  rescue JSON::ParserError, SystemCallError, IOError
    empty
  end

  def save(data)
    FileUtils.mkdir_p(File.dirname(SCHOOL_CALENDAR_FILE))
    path = "#{SCHOOL_CALENDAR_FILE}.tmp.#{$$}"
    File.write(path, JSON.generate(data))
    File.rename(path, SCHOOL_CALENDAR_FILE)
  ensure
    FileUtils.rm_f(path) if path
  end

  def source_uri(value)
    uri = URI.parse(value.to_s.strip.sub(/\Awebcal:/i, "https:"))
    unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? &&
        uri.userinfo.nil? && uri.port == 443
      raise InvalidSource
    end
    uri.fragment = nil
    uri
  rescue URI::InvalidURIError
    raise InvalidSource
  end

  def public_address?(value)
    address = IPAddr.new(value)
    address = address.native if address.ipv4_mapped?
    return false if PRIVATE_NETWORKS.any? { |network| network.include?(address) }
    return IPAddr.new("2000::/3").include?(address) if address.ipv6?

    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def resolve(host)
    Resolv.getaddresses(host)
  end

  def fetch(value, redirects: 3)
    uri = source_uri(value)
    addresses = Timeout.timeout(5) { resolve(uri.hostname) }
    raise InvalidSource if addresses.empty? || !addresses.all? { |ip| public_address?(ip) }

    # Disable environment proxies and pin DNS so the checked address is the one contacted.
    http = Net::HTTP.new(uri.hostname, uri.port, nil)
    http.ipaddr = addresses.first
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    http.write_timeout = 5
    body = +""
    redirect = nil
    content_type = nil
    Timeout.timeout(20) do
      http.request(Net::HTTP::Get.new(uri.request_uri, "Accept" => "text/calendar, text/html")) do |response|
        raise InvalidSource if response["content-length"].to_i > MAX_BYTES

        if response.is_a?(Net::HTTPRedirection)
          raise InvalidSource if redirects.zero? || response["location"].to_s.empty?

          redirect = URI.join(uri.to_s, response["location"]).to_s
        else
          raise InvalidSource unless response.is_a?(Net::HTTPSuccess)

          content_type = response["content-type"].to_s
        end
        bytes = 0
        response.read_body do |chunk|
          bytes += chunk.bytesize
          raise InvalidSource if bytes > MAX_BYTES

          body << chunk unless redirect
        end
      end
    end
    return fetch(redirect, redirects: redirects - 1) if redirect

    [body, uri.to_s, content_type]
  end

  def calendar_body?(body, content_type)
    content_type.downcase.include?("text/calendar") ||
      body.lstrip.start_with?("BEGIN:VCALENDAR")
  end

  def retrieve(source, today:)
    body, final_url, content_type = fetch(source)
    return parse_ics(body, today: today) if calendar_body?(body, content_type)

    document = Nokogiri::HTML(body)
    feeds = document.css("[href], [data-url], [data-ical-url], [data-feed-url], [data-ics-url], [src]").flat_map do |node|
      %w[href data-url data-ical-url data-feed-url data-ics-url src].filter_map do |attribute|
        target = node[attribute]
        next if target.to_s.empty?
        next unless node["type"].to_s.downcase == "text/calendar" ||
          target.match?(%r{\Awebcal:|\.ics(?:[?#]|\z)|(?:[/?=&_-])ical(?:endar)?(?:[/?=&_.-]|\z)}i)

        source_uri(URI.join(final_url, target).to_s).to_s
      end
    end.uniq.first(10)
    unless feeds.empty?
      events = feeds.flat_map do |feed|
        feed_body, _, feed_type = fetch(feed)
        raise InvalidSource unless calendar_body?(feed_body, feed_type)

        parse_ics(feed_body, today: today)
      end
      return sort_events(events)
    end

    events = structured_events(document, today: today)
    return events unless events.nil?

    raise NoFeed
  end

  def civil_time(value)
    Time.utc(value.year, value.month, value.day,
      value.respond_to?(:hour) ? value.hour : 0,
      value.respond_to?(:min) ? value.min : 0,
      value.respond_to?(:sec) ? value.sec : 0)
  end

  def event_timezone(event)
    value_timezone(event.dtstart)
  end

  def value_timezone(value)
    id = Array(value.ical_params["tzid"]).first
    return nil unless id

    TZInfo::Timezone.get(id.to_s.delete('"'))
  rescue TZInfo::InvalidTimezoneIdentifier
    embedded = value.timezone_store&.retrieve(id)
    raise InvalidSource unless embedded

    EmbeddedTimezone.new(embedded)
  end

  def actual_time(civil, event)
    timezone = event_timezone(event)
    return timezone.local_to_utc(civil, true).getlocal if timezone
    return civil.getlocal if event.dtstart.value_ical.end_with?("Z")

    Time.local(civil.year, civil.month, civil.day, civil.hour, civil.min, civil.sec)
  end

  def recurrence_civil(value, event)
    return civil_time(value) if value.is_a?(Icalendar::Values::Date)

    timezone = event_timezone(event)
    source_timezone = value_timezone(value)
    utc = if source_timezone
      source_timezone.local_to_utc(civil_time(value), true)
    elsif value.value_ical.end_with?("Z")
      civil_time(value)
    end
    if utc
      local = if timezone
        timezone.utc_to_local(utc)
      elsif event.dtstart.value_ical.end_with?("Z")
        utc
      else
        utc.getlocal
      end
      return civil_time(local)
    end

    civil_time(value)
  end

  def event_duration(event)
    return recurrence_civil(event.dtend, event) - civil_time(event.dtstart) if event.dtend
    if event.duration
      return event.duration.weeks * 604_800 + event.duration.days * 86_400 +
        event.duration.hours * 3600 + event.duration.minutes * 60 + event.duration.seconds
    end
    event.dtstart.is_a?(Icalendar::Values::Date) ? 86_400 : 0
  end

  def safe_event_url(value)
    uri = URI.parse(value.to_s)
    uri.to_s if %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end

  def normalize(event, start_civil, end_civil)
    all_day = event.dtstart.is_a?(Icalendar::Values::Date)
    start_at = all_day ? start_civil.to_date : actual_time(start_civil, event)
    end_at = all_day ? end_civil.to_date : actual_time(end_civil, event)
    start_date = start_at.to_date
    end_date = end_at.to_date
    end_date += 1 unless all_day || (end_at.hour.zero? && end_at.min.zero? && end_at.sec.zero?)
    end_date = start_date + 1 if end_date <= start_date
    {
      "title" => event.summary.to_s.empty? ? "School event" : event.summary.to_s,
      "start_at" => start_at.iso8601, "end_at" => end_at.iso8601,
      "start_date" => start_date.iso8601, "end_date" => end_date.iso8601,
      "all_day" => all_day, "location" => event.location.to_s,
      "url" => safe_event_url(event.url)
    }
  end

  def parse_ics(body, today:)
    unless body.match?(/^\s*BEGIN:VCALENDAR\s*$/) && body.match?(/^\s*END:VCALENDAR\s*$/)
      raise InvalidSource
    end
    raise InvalidSource unless body.scan(/^BEGIN:VEVENT\s*$/).length == body.scan(/^END:VEVENT\s*$/).length

    Timeout.timeout(10) do
      calendars = Icalendar::Calendar.parse(body)
      raise InvalidSource if calendars.empty?

      normalized = calendars.flat_map do |calendar|
        raise InvalidSource if calendar.events.length > MAX_EVENTS

        overrides = calendar.events.select(&:recurrence_id).group_by { |event| event.uid.to_s }
        calendar.events.reject(&:recurrence_id).flat_map do |event|
          next [] if event.status.to_s.upcase == "CANCELLED"
          raise InvalidSource unless event.dtstart

          duration = event_duration(event)
          raise InvalidSource if duration.negative?

          schedule = IceCube::Schedule.new(civil_time(event.dtstart), duration: duration)
          event.rrule.each do |rule|
            recurrence = IceCube::Rule.from_ical(rule.value_ical)
            until_value = rule.value_ical[/UNTIL=(\d{8}T\d{6}Z)/, 1]
            if until_value
              recurrence.until(recurrence_civil(Icalendar::Values::DateTime.new(until_value), event))
            end
            schedule.add_recurrence_rule(recurrence)
          end
          event.rdate.each do |dates|
            Array(dates).each { |date| schedule.add_recurrence_time(recurrence_civil(date, event)) }
          end
          event.exdate.each do |dates|
            Array(dates).each { |date| schedule.add_exception_time(recurrence_civil(date, event)) }
          end
          changes = overrides.fetch(event.uid.to_s, [])
          changes.each { |change| schedule.add_exception_time(recurrence_civil(change.recurrence_id, event)) }
          # Civil-time recurrence keeps local school times stable across daylight saving changes.
          first = Time.utc(today.year, today.month, today.day) - [duration, 86_400].max - 86_400
          last_date = today + 31
          last = Time.utc(last_date.year, last_date.month, last_date.day)
          occurrences = []
          schedule.remaining_occurrences_enumerator(first).each do |occurrence|
            break if occurrence.start_time > last
            raise InvalidSource if occurrences.length >= MAX_EVENTS

            occurrences << normalize(event, occurrence.start_time, occurrence.end_time)
          end
          occurrences.concat(changes.filter_map do |change|
            next if change.status.to_s.upcase == "CANCELLED"
            raise InvalidSource unless change.dtstart

            start = civil_time(change.dtstart)
            normalize(change, start, start + event_duration(change))
          end)
        end
      end
      raise InvalidSource if normalized.length > MAX_EVENTS

      sort_events(normalized.select { |event| overlaps?(event, today, today + 30) })
    end
  end

  def structured_events(document, today:)
    found = false
    events = []
    walk = lambda do |value|
      case value
      when Array
        value.each { |item| walk.call(item) }
      when Hash
        if Array(value["@type"]).any? { |type| type.to_s.split("/").last == "Event" }
          found = true
          unless value["eventStatus"].to_s.end_with?("EventCancelled")
            start_value = value["startDate"].to_s
            raise InvalidSource if start_value.empty?

            all_day = start_value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            start_at = all_day ? Date.iso8601(start_value) : Time.iso8601(start_value).getlocal
            end_value = value["endDate"].to_s
            end_at = if end_value.empty?
              all_day ? start_at + 1 : start_at
            else
              all_day ? Date.iso8601(end_value) + 1 : Time.iso8601(end_value).getlocal
            end
            end_date = end_at.to_date
            end_date += 1 unless all_day || (end_at.hour.zero? && end_at.min.zero? && end_at.sec.zero?)
            end_date = start_at.to_date + 1 if end_date <= start_at.to_date
            location = value["location"]
            events << {
              "title" => value["name"].to_s, "start_at" => start_at.iso8601,
              "end_at" => end_at.iso8601, "start_date" => start_at.to_date.iso8601,
              "end_date" => end_date.iso8601, "all_day" => all_day,
              "location" => location.is_a?(Hash) ? location["name"].to_s : location.to_s,
              "url" => safe_event_url(value["url"])
            }
          end
        end
        value.each_value { |item| walk.call(item) if item.is_a?(Hash) || item.is_a?(Array) }
      end
      raise InvalidSource if events.length > MAX_EVENTS
    end
    document.css('script[type="application/ld+json"]').each do |script|
      walk.call(JSON.parse(script.text))
    end
    found ? sort_events(events.select { |event| overlaps?(event, today, today + 30) }) : nil
  rescue JSON::ParserError
    nil
  end

  def overlaps?(event, first, last)
    event.is_a?(Hash) && Date.iso8601(event["start_date"].to_s) < last &&
      Date.iso8601(event["end_date"].to_s) > first
  rescue ArgumentError
    false
  end

  def sort_events(events)
    events.uniq.sort_by { |event| [event["start_at"], event["title"]] }
  end
end

def school_calendar_url
  options["calendar_url"].to_s.strip
end

def school_calendar_data
  source = school_calendar_url
  return SchoolCalendar.empty if source.empty?

  data = SchoolCalendar.load
  data["source_url"] == source ? data : SchoolCalendar.empty(source)
end

def refresh_school_calendar(now: Time.now)
  cache = nil
  source = nil
  SCHOOL_CALENDAR_MUTEX.synchronize do
    source = school_calendar_url
    return SchoolCalendar.empty if source.empty?

    cache = SchoolCalendar.load
    cache = SchoolCalendar.empty(source) unless cache["source_url"] == source
    today = now.getlocal.to_date
    return cache if cache["checked_on"] == today.iso8601

    cache["checked_on"] = today.iso8601
    SchoolCalendar.save(cache)
    begin
      cache["events"] = Timeout.timeout(60) { SchoolCalendar.retrieve(source, today: today) }
      cache["updated_at"] = now.iso8601
      cache.delete("error")
    rescue StandardError => error
      cache["error"] = if error.is_a?(SchoolCalendar::NoFeed)
        "No calendar feed found. Please use the calendar's ICS subscribe URL."
      else
        "Unable to update the school calendar. Please check its public HTTPS or ICS URL."
      end
      puts "School calendar refresh failed (#{error.class})."
    end
    SchoolCalendar.save(cache)
    cache
  end
rescue StandardError => error
  puts "School calendar refresh failed (#{error.class})."
  cache ||= SchoolCalendar.empty(source.to_s)
  cache["error"] = "Unable to save the school calendar cache."
  cache
end

def weekly_school_calendar_events(calendar, today: Date.today)
  Array(calendar["events"]).select { |event| SchoolCalendar.overlaps?(event, today, today + 7) }
end

def school_calendar_events_on(events, date)
  Array(events).select { |event| SchoolCalendar.overlaps?(event, date, date + 1) }
end
