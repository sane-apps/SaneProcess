#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'stringio'

require_relative '../hooks/test/test_framework'

include TestFramework

SCRIPT = File.expand_path('business_appointment.rb', __dir__)
require_relative 'business_appointment'

def run_appointment(*args, env: {})
  Open3.capture3(
    env,
    'ruby',
    SCRIPT,
    *args
  )
end

class FakeCalendarHttp
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
  end

  def request(uri, request)
    @requests << {
      method: request.method,
      uri: uri.to_s,
      body: request.body && JSON.parse(request.body),
      authorization: request['Authorization']
    }
    response = @responses.shift || ok({})
    response
  end

  def self.ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.body = JSON.generate(body)
    response
  end
end

def live_env
  {
    'SANEAPPS_APPOINTMENT_OWNER_EMAIL' => 'hi@saneapps.com',
    'SANEAPPS_BUSINESS_CALENDAR_ID' => 'hi@saneapps.com',
    'GOOGLE_CALENDAR_ACCESS_TOKEN' => 'test-token'
  }
end

def run_appointment_in_process(*args, http:, env: live_env)
  stdout = StringIO.new
  stderr = StringIO.new
  status = BusinessAppointment.run(args, env: env, stdout: stdout, stderr: stderr, http_client: http)
  [stdout.string, stderr.string, status]
end

exit(run_tests('SaneApps Business Appointment Tests') do
  test_category('business account guard') do
    test('previews a business-owned appointment without external writes') do
      stdout, stderr, status = run_appointment(
        'add',
        '--title', 'SaneCite call with Stelios',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stelios.banel@gmail.com',
        '--notes', 'Discuss SaneCite pilot.',
        '--url', 'https://sanecite.com',
        '--json',
        env: {
          'SANEAPPS_APPOINTMENT_OWNER_EMAIL' => 'hi@saneapps.com',
          'SANEAPPS_BUSINESS_CALENDAR_ID' => 'hi@saneapps.com'
        }
      )

      assert(status.success?, stderr)
      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'preview')
      assert_eq(payload['owner_email'], 'hi@saneapps.com')
      assert_eq(payload['calendar_id'], 'hi@saneapps.com')
      assert_eq(payload['send_updates'], 'all')
      assert_eq(payload['attendees'], ['stelios.banel@gmail.com'])
      true
    end

    test('blocks personal Gmail owner before any live calendar write') do
      stdout, = run_appointment(
        'add',
        '--title', 'Bad route',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stelios.banel@gmail.com',
        '--owner-email', 'stephanjoseph2007@gmail.com',
        '--json'
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], 'blocked non-business appointment owner')
      true
    end

    test('blocks daughter/family calendar id before any live calendar write') do
      stdout, = run_appointment(
        'add',
        '--title', 'Bad calendar',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stelios.banel@gmail.com',
        '--calendar-id', 'sugarplum3345@gmail.com',
        '--json',
        env: { 'SANEAPPS_APPOINTMENT_OWNER_EMAIL' => 'hi@saneapps.com' }
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], 'blocked non-business calendar id')
      true
    end

    test('live writes require explicit business calendar config and token') do
      stdout, = run_appointment(
        'add',
        '--title', 'Needs config',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stelios.banel@gmail.com',
        '--apply',
        '--json',
        env: { 'SANEAPPS_APPOINTMENT_OWNER_EMAIL' => 'hi@saneapps.com' }
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], 'live calendar write requires SANEAPPS_BUSINESS_CALENDAR_ID')
      true
    end

    test('live write verifies business organizer before sending attendee invite') do
      http = FakeCalendarHttp.new([
        FakeCalendarHttp.ok('items' => []),
        FakeCalendarHttp.ok('id' => 'evt_1', 'organizer' => { 'email' => 'hi@saneapps.com' }),
        FakeCalendarHttp.ok('id' => 'evt_1', 'htmlLink' => 'https://calendar.google.com/event?eid=1', 'organizer' => { 'email' => 'hi@saneapps.com' })
      ])

      stdout, stderr, status = run_appointment_in_process(
        'add',
        '--title', 'Live test',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stephanjoseph2007@gmail.com',
        '--meeting-url', 'https://meet.google.com/test-call',
        '--apply',
        '--confirm-send', 'send hi@saneapps.com invite to stephanjoseph2007@gmail.com at 2026-07-13T09:00:00 America/New_York',
        '--json',
        http: http
      )

      assert_eq(status, 0, stderr)
      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'created')
      assert_eq(payload['organizer_email'], 'hi@saneapps.com')
      assert_eq(http.requests.length, 3)
      assert_eq(http.requests[0][:method], 'GET')
      assert_includes(http.requests[0][:uri], 'privateExtendedProperty=saneappsBusinessAppointmentKey')
      assert_eq(http.requests[1][:method], 'POST')
      assert(!http.requests[1][:body].key?('attendees'), 'first live write must not include attendees')
      assert_includes(http.requests[1][:uri], 'sendUpdates=none')
      assert_eq(http.requests[2][:method], 'PATCH')
      assert_eq(http.requests[2][:body]['attendees'], [{ 'email' => 'stephanjoseph2007@gmail.com' }])
      assert_includes(http.requests[2][:uri], 'sendUpdates=all')
      true
    end

    test('live write deletes uninvited event and blocks when organizer is personal') do
      http = FakeCalendarHttp.new([
        FakeCalendarHttp.ok('items' => []),
        FakeCalendarHttp.ok('id' => 'evt_bad', 'organizer' => { 'email' => 'stephanjoseph2007@gmail.com' }),
        FakeCalendarHttp.ok({})
      ])

      stdout, = run_appointment_in_process(
        'add',
        '--title', 'Wrong organizer',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stephanjoseph2007@gmail.com',
        '--apply',
        '--confirm-send', 'send hi@saneapps.com invite to stephanjoseph2007@gmail.com at 2026-07-13T09:00:00 America/New_York',
        '--json',
        http: http
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], 'organizer was not hi@saneapps.com')
      assert_eq(http.requests.length, 3)
      assert_eq(http.requests[1][:method], 'POST')
      assert(!http.requests[1][:body].key?('attendees'), 'wrong-organizer create must not invite attendees')
      assert_eq(http.requests[2][:method], 'DELETE')
      true
    end

    test('live write requires exact send confirmation phrase') do
      stdout, = run_appointment_in_process(
        'add',
        '--title', 'Needs confirmation',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stephanjoseph2007@gmail.com',
        '--apply',
        '--confirm-send', 'send it',
        '--json',
        http: FakeCalendarHttp.new([])
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], 'live calendar write requires --confirm-send')
      true
    end

    test('live write dedupes before creating or sending') do
      http = FakeCalendarHttp.new([
        FakeCalendarHttp.ok('items' => [
          {
            'id' => 'evt_existing',
            'htmlLink' => 'https://calendar.google.com/event?eid=existing',
            'organizer' => { 'email' => 'hi@saneapps.com' }
          }
        ])
      ])

      stdout, stderr, status = run_appointment_in_process(
        'add',
        '--title', 'Duplicate',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stephanjoseph2007@gmail.com',
        '--apply',
        '--confirm-send', 'send hi@saneapps.com invite to stephanjoseph2007@gmail.com at 2026-07-13T09:00:00 America/New_York',
        '--json',
        http: http
      )

      assert_eq(status, 0, stderr)
      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'duplicate')
      assert_eq(payload['event_id'], 'evt_existing')
      assert_eq(http.requests.length, 1)
      assert_eq(http.requests[0][:method], 'GET')
      true
    end

    test('rejects non-http appointment URLs') do
      stdout, = run_appointment(
        'add',
        '--title', 'Bad URL',
        '--start', '2026-07-13 09:00',
        '--attendee', 'stelios.banel@gmail.com',
        '--url', 'javascript:alert(1)',
        '--json',
        env: { 'SANEAPPS_APPOINTMENT_OWNER_EMAIL' => 'hi@saneapps.com' }
      )

      payload = JSON.parse(stdout)
      assert_eq(payload['status'], 'blocked')
      assert_includes(payload['error'], '--url must be an http(s) URL')
      true
    end
  end
end)
