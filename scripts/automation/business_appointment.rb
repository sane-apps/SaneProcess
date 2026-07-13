#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'optparse'
require 'digest'
require 'time'
require 'uri'

class BusinessAppointment
  BUSINESS_DOMAIN = 'saneapps.com'
  GOOGLE_EVENTS_BASE = 'https://www.googleapis.com/calendar/v3/calendars'

  def self.run(argv, env: ENV, stdout: $stdout, stderr: $stderr, http_client: nil)
    new(argv, env: env, stdout: stdout, stderr: stderr, http_client: http_client).run
  end

  def initialize(argv, env:, stdout:, stderr:, http_client: nil)
    @argv = argv.dup
    @env = env
    @stdout = stdout
    @stderr = stderr
    @http_client = http_client
    @options = {
      provider: 'google',
      timezone: 'America/New_York',
      duration_minutes: 30,
      reminders_minutes: 15,
      apply: false,
      json: false
    }
  end

  def run
    command = @argv.shift
    return usage(2) unless command == 'add'

    parse!
    validate!
    receipt = build_receipt

    if @options[:apply]
      create_google_event!(receipt)
    else
      receipt[:status] = 'preview'
      receipt[:message] = 'Preview only. Re-run with --apply after reviewing the business account/calendar target.'
    end

    emit(receipt)
    0
  rescue OptionParser::ParseError, ArgumentError => e
    emit_error(e.message)
    2
  rescue StandardError => e
    emit_error(e.message)
    1
  end

  private

  def parse!
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: business_appointment.rb add --title TITLE --start "YYYY-MM-DD HH:MM" --attendee EMAIL [options]'
      opts.on('--title TITLE') { |value| @options[:title] = value }
      opts.on('--start START') { |value| @options[:start] = value }
      opts.on('--duration-minutes N', Integer) { |value| @options[:duration_minutes] = value }
      opts.on('--attendee EMAIL') { |value| (@options[:attendees] ||= []) << value }
      opts.on('--notes TEXT') { |value| @options[:notes] = value }
      opts.on('--url URL') { |value| @options[:url] = value }
      opts.on('--meeting-url URL') { |value| @options[:meeting_url] = value }
      opts.on('--timezone TZ') { |value| @options[:timezone] = value }
      opts.on('--reminders-minutes N', Integer) { |value| @options[:reminders_minutes] = value }
      opts.on('--dedupe-key KEY') { |value| @options[:dedupe_key] = value }
      opts.on('--confirm-send TEXT') { |value| @options[:confirm_send] = value }
      opts.on('--owner-email EMAIL') { |value| @options[:owner_email] = value }
      opts.on('--calendar-id ID') { |value| @options[:calendar_id] = value }
      opts.on('--apply') { @options[:apply] = true }
      opts.on('--json') { @options[:json] = true }
    end
    parser.parse!(@argv)
    raise OptionParser::ParseError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
  end

  def validate!
    required = %i[title start]
    missing = required.select { |key| blank?(@options[key]) }
    raise ArgumentError, "missing required option(s): #{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}" unless missing.empty?

    @options[:attendees] ||= []
    raise ArgumentError, 'at least one --attendee is required' if @options[:attendees].empty?
    raise ArgumentError, '--duration-minutes must be positive' unless @options[:duration_minutes].positive?
    raise ArgumentError, '--reminders-minutes must be non-negative' if @options[:reminders_minutes].negative?
    raise ArgumentError, "unsupported provider #{@options[:provider].inspect}" unless @options[:provider] == 'google'

    owner_email = owner_email!
    unless business_email?(owner_email)
      raise ArgumentError, "blocked non-business appointment owner: #{owner_email.inspect}; use a #{BUSINESS_DOMAIN} account"
    end

    calendar_id = calendar_id!
    if calendar_id.include?('@') && !business_email?(calendar_id)
      raise ArgumentError, "blocked non-business calendar id: #{calendar_id.inspect}; configure SANEAPPS_BUSINESS_CALENDAR_ID"
    end

    @options[:attendees].each do |email|
      raise ArgumentError, "invalid attendee email: #{email.inspect}" unless valid_email?(email)
    end
    %i[url meeting_url].each do |key|
      next if blank?(@options[key])

      raise ArgumentError, "--#{key.to_s.tr('_', '-')} must be an http(s) URL" unless http_url?(@options[key])
    end

    parse_start_time!
    @options[:dedupe_key] ||= default_dedupe_key

    return unless @options[:apply]

    raise ArgumentError, 'live calendar write requires SANEAPPS_BUSINESS_CALENDAR_ID' if blank?(@env['SANEAPPS_BUSINESS_CALENDAR_ID'])
    raise ArgumentError, 'live calendar write requires GOOGLE_CALENDAR_ACCESS_TOKEN' if blank?(@env['GOOGLE_CALENDAR_ACCESS_TOKEN'])
    raise ArgumentError, "live calendar write requires --confirm-send #{confirm_send_phrase.inspect}" unless @options[:confirm_send] == confirm_send_phrase
  end

  def owner_email!
    @options[:owner_email] || @env.fetch('SANEAPPS_APPOINTMENT_OWNER_EMAIL', 'hi@saneapps.com')
  end

  def calendar_id!
    @options[:calendar_id] || @env['SANEAPPS_BUSINESS_CALENDAR_ID'] || owner_email!
  end

  def parse_start_time!
    raw = @options[:start].to_s.strip
    match = raw.match(/\A(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?\z/)
    raise ArgumentError, '--start must look like "2026-07-13 09:00"' unless match

    date, hour, minute, second = match.captures
    @options[:start_iso] = "#{date}T#{hour}:#{minute}:#{second || '00'}"
    @options[:end_iso] = (Time.parse("#{@options[:start_iso]} UTC") + (@options[:duration_minutes] * 60)).utc.strftime('%Y-%m-%dT%H:%M:%S')
  end

  def build_receipt
    {
      provider: @options[:provider],
      owner_email: owner_email!,
      calendar_id: calendar_id!,
      title: @options[:title],
      start: @options[:start_iso],
      end: @options[:end_iso],
      timezone: @options[:timezone],
      attendees: @options[:attendees],
      url: @options[:url],
      meeting_url: @options[:meeting_url],
      notes: @options[:notes],
      send_updates: 'all',
      reminders_minutes: @options[:reminders_minutes],
      apply: @options[:apply],
      dedupe_key: @options[:dedupe_key],
      confirm_send: confirm_send_phrase
    }
  end

  def create_google_event!(receipt)
    if (existing = find_existing_event(receipt))
      receipt[:status] = 'duplicate'
      receipt[:event_id] = existing['id']
      receipt[:html_link] = existing['htmlLink']
      receipt[:organizer_email] = existing.dig('organizer', 'email')
      receipt[:message] = 'Existing business appointment matched dedupe key; no new invite sent.'
      return
    end

    created = insert_event_without_attendees!(receipt)
    organizer_email = created.dig('organizer', 'email').to_s
    unless organizer_email.casecmp?(receipt[:owner_email].to_s)
      delete_google_event!(receipt[:calendar_id], created['id'])
      raise "Google Calendar organizer was not #{receipt[:owner_email]}: #{organizer_email.inspect}; no attendee invites were sent"
    end

    body = add_attendees_and_notify!(receipt, created.fetch('id'))
    receipt[:status] = 'created'
    receipt[:event_id] = body['id']
    receipt[:html_link] = body['htmlLink']
    receipt[:organizer_email] = body.dig('organizer', 'email') || organizer_email
  end

  def insert_event_without_attendees!(receipt)
    uri = collection_uri(receipt[:calendar_id], send_updates: 'none')
    body = google_event_body(receipt, include_attendees: false)
    parse_google_response(http_json_request(uri, Net::HTTP::Post, body), 'Google Calendar create')
  end

  def find_existing_event(receipt)
    uri = collection_uri(receipt[:calendar_id], send_updates: 'none')
    uri.query = URI.encode_www_form(
      maxResults: 1,
      singleEvents: true,
      privateExtendedProperty: "saneappsBusinessAppointmentKey=#{receipt[:dedupe_key]}"
    )
    request = authorized_request(Net::HTTP::Get.new(uri))
    body = parse_google_response(http_request(uri, request), 'Google Calendar dedupe lookup')
    Array(body['items']).first
  end

  def add_attendees_and_notify!(receipt, event_id)
    uri = event_uri(receipt[:calendar_id], event_id, send_updates: receipt[:send_updates])
    body = { attendees: receipt[:attendees].map { |email| { email: email } } }
    parse_google_response(http_json_request(uri, Net::HTTP::Patch, body), 'Google Calendar attendee update')
  rescue StandardError
    delete_google_event!(receipt[:calendar_id], event_id)
    raise
  end

  def delete_google_event!(calendar_id, event_id)
    uri = event_uri(calendar_id, event_id, send_updates: 'none')
    request = authorized_request(Net::HTTP::Delete.new(uri))
    response = http_request(uri, request)
    raise "Google Calendar cleanup failed: HTTP #{response.code} #{response.body.to_s[0, 400]}" unless response.is_a?(Net::HTTPSuccess)
  end

  def google_event_body(receipt, include_attendees: true)
    {
      summary: receipt[:title],
      description: event_description(receipt),
      location: receipt[:meeting_url] || receipt[:url],
      start: { dateTime: receipt[:start], timeZone: receipt[:timezone] },
      end: { dateTime: receipt[:end], timeZone: receipt[:timezone] },
      attendees: include_attendees ? receipt[:attendees].map { |email| { email: email } } : nil,
      extendedProperties: {
        private: { saneappsBusinessAppointmentKey: receipt[:dedupe_key] }
      },
      reminders: {
        useDefault: false,
        overrides: [{ method: 'popup', minutes: receipt[:reminders_minutes] }]
      }
    }.compact
  end

  def event_description(receipt)
    [receipt[:notes], receipt[:url], receipt[:meeting_url]].compact.reject { |value| blank?(value) }.join("\n\n")
  end

  def collection_uri(calendar_id, send_updates:)
    uri = URI("#{GOOGLE_EVENTS_BASE}/#{URI.encode_www_form_component(calendar_id)}/events")
    uri.query = URI.encode_www_form(sendUpdates: send_updates)
    uri
  end

  def event_uri(calendar_id, event_id, send_updates:)
    uri = URI("#{GOOGLE_EVENTS_BASE}/#{URI.encode_www_form_component(calendar_id)}/events/#{URI.encode_www_form_component(event_id)}")
    uri.query = URI.encode_www_form(sendUpdates: send_updates)
    uri
  end

  def default_dedupe_key
    Digest::SHA256.hexdigest([
      calendar_id!,
      @options[:title],
      @options[:start_iso],
      @options[:timezone],
      @options[:attendees].join(',')
    ].join("\0"))[0, 24]
  end

  def confirm_send_phrase
    "send #{owner_email!} invite to #{@options[:attendees].join(',')} at #{@options[:start_iso]} #{@options[:timezone]}"
  end

  def http_json_request(uri, request_class, body)
    request = authorized_request(request_class.new(uri))
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body)
    http_request(uri, request)
  end

  def authorized_request(request)
    request['Authorization'] = "Bearer #{@env.fetch('GOOGLE_CALENDAR_ACCESS_TOKEN')}"
    request
  end

  def http_request(uri, request)
    if @http_client
      return @http_client.request(uri, request)
    end

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
  end

  def parse_google_response(response, action)
    raise "#{action} failed: HTTP #{response.code} #{response.body.to_s[0, 400]}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def emit(receipt)
    if @options[:json]
      @stdout.puts(JSON.pretty_generate(receipt))
    else
      @stdout.puts("#{receipt[:status] || 'ready'}: #{receipt[:title]}")
      @stdout.puts("owner: #{receipt[:owner_email]}")
      @stdout.puts("calendar: #{receipt[:calendar_id]}")
      @stdout.puts("when: #{receipt[:start]} #{receipt[:timezone]}")
      @stdout.puts("attendees: #{receipt[:attendees].join(', ')}")
      @stdout.puts(receipt[:message]) if receipt[:message]
    end
  end

  def emit_error(message)
    payload = { status: 'blocked', error: message }
    if @options[:json]
      @stdout.puts(JSON.pretty_generate(payload))
    else
      @stderr.puts("blocked: #{message}")
    end
  end

  def usage(code)
    @stderr.puts('Usage: business_appointment.rb add --title TITLE --start "YYYY-MM-DD HH:MM" --attendee EMAIL [--apply]')
    code
  end

  def business_email?(email)
    email.to_s.downcase.end_with?("@#{BUSINESS_DOMAIN}")
  end

  def valid_email?(email)
    email.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
  end

  def http_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && !blank?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
end

exit(BusinessAppointment.run(ARGV)) if $PROGRAM_NAME == __FILE__
