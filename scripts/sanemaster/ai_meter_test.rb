#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

require_relative '../hooks/test/test_framework'
require_relative 'ai_meter'

class AIMeterHarness
  include SaneMasterModules::AIMeter

  attr_accessor :response_status, :response_body, :captured_sql

  def initialize
    @response_status = 200
    @response_body = '{"data":[]}'
  end

  def ai_meter_http_post(_uri, _token, sql)
    @captured_sql = sql
    [response_status, response_body]
  end
end

include TestFramework

FIXTURE = File.expand_path('../../test/fixtures/ai_meter_rows.json', __dir__)

exit(run_tests('SaneMaster AI Meter Tests') do
  test('SaneMaster registers the read-only ai_meter command as Mini-first') do
    source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
    mini_first = source[/MINI_FIRST_COMMANDS = Set\.new\(%w\[(.*?)\]\)\.freeze/m, 1]

    assert_includes(source, "require_relative 'sanemaster/ai_meter'")
    assert_includes(source, "'ai_meter' =>")
    assert_includes(source, "when 'ai_meter'")
    assert(mini_first, 'expected Mini-first command registry')
    assert_includes(mini_first, 'ai_meter')
    true
  end

  test('queries the exact shared schema with sample weighting') do
    subject = AIMeterHarness.new
    subject.query_ai_meter(days: 7, token: 'token', account_id: 'account')

    assert_includes(subject.captured_sql, 'FROM sane_ai_meter')
    assert_includes(subject.captured_sql, 'index1 AS indexed_product')
    (1..9).each { |index| assert_includes(subject.captured_sql, "blob#{index}") }
    (1..8).each { |index| assert_includes(subject.captured_sql, "double#{index}") }
    assert_includes(subject.captured_sql, '_sample_interval')
    assert_includes(subject.captured_sql, "blob1 = 'inference_attempt'")
    assert_includes(subject.captured_sql, "blob2 = 'v1'")
    assert_includes(subject.captured_sql, 'sumIf(_sample_interval, double1 > 1) AS retries')
    assert_includes(subject.captured_sql, "sumIf(_sample_interval, blob8 = 'fallback_success') AS fallbacks")
    true
  end

  test('reports weighted attempts, latency, retries, fallbacks, coverage, and dated cost') do
    rows = JSON.parse(File.read(FIXTURE)).fetch('data')
    subject = AIMeterHarness.new
    report = subject.build_ai_meter_report(rows, days: 7, now: Date.new(2026, 7, 20))
    totals = report[:totals]

    assert_eq(report[:state], 'ready')
    assert_eq(report[:data_through], '2026-07-20T12:02:00Z')
    assert_eq(totals[:calls], 4)
    assert_eq(totals[:successes], 2)
    assert_eq(totals[:errors], 2)
    assert_eq(totals[:retries], 2)
    assert_eq(totals[:fallbacks], 1)
    assert_eq(totals[:weighted_average_latency_ms], 2000.0)
    assert_eq(totals[:measured_token_coverage_pct], 25.0)
    assert_eq(totals[:cost_state], 'partial_usage')
    assert_eq(totals[:gross_post_credit_estimated_usd], 0.000412)
    assert_eq(report[:pricing][:verified_on], '2026-07-08')

    offsetless = subject.build_ai_meter_report(
      [rows.first.merge('data_through' => '2026-07-20 04:20:28')],
      days: 7,
      now: Date.new(2026, 7, 20)
    )
    assert_eq(offsetless[:data_through], '2026-07-20T04:20:28Z')

    explicit_offset = subject.build_ai_meter_report(
      [rows.first.merge('data_through' => '2026-07-20 04:20:28-04:00')],
      days: 7,
      now: Date.new(2026, 7, 20)
    )
    assert_eq(explicit_offset[:data_through], '2026-07-20T08:20:28Z')
    true
  end

  test('distinguishes unavailable, delayed, query-error, and invalid schema states') do
    subject = AIMeterHarness.new
    unavailable = subject.query_ai_meter(days: 7, token: nil, account_id: nil)
    assert_eq(unavailable[:state], 'unavailable')

    delayed = subject.build_ai_meter_report([], days: 7, now: Date.new(2026, 7, 20))
    assert_eq(delayed[:state], 'delayed')

    subject.response_status = 503
    error = subject.query_ai_meter(days: 7, token: 'token', account_id: 'account')
    assert_eq(error[:state], 'query_error')

    invalid = JSON.parse(File.read(FIXTURE)).fetch('data').first.merge('indexed_product' => 'other')
    mismatch = subject.build_ai_meter_report([invalid], days: 7, now: Date.new(2026, 7, 20))
    assert_eq(mismatch[:state], 'query_error')
    true
  end

  test('keeps inference quality unknown and separate from canaries') do
    subject = AIMeterHarness.new
    rows = JSON.parse(File.read(FIXTURE)).fetch('data')
    report = subject.build_ai_meter_report(rows, days: 7, now: Date.new(2026, 7, 20))

    assert_eq(report[:quality][:state], 'unknown')
    assert_includes(report[:quality][:note], 'were not run')
    invalid = rows.first.merge('quality_code' => 0)
    rejected = subject.build_ai_meter_report([invalid], days: 7, now: Date.new(2026, 7, 20))
    assert_eq(rejected[:state], 'query_error')
    true
  end

  test('rejects invalid producer enums and missing required aggregates') do
    subject = AIMeterHarness.new
    row = JSON.parse(File.read(FIXTURE)).fetch('data').first

    %w[event_type task context route outcome usage_state].each do |field|
      invalid = row.merge(field => 'not_a_producer_value')
      report = subject.build_ai_meter_report([invalid], days: 7, now: Date.new(2026, 7, 20))
      assert_eq(report[:state], 'query_error', "expected invalid #{field} to be rejected")
    end

    missing = row.reject { |key, _| key == 'calls' }
    report = subject.build_ai_meter_report([missing], days: 7, now: Date.new(2026, 7, 20))
    assert_eq(report[:state], 'query_error')
    true
  end

  test('rejects stale rates and unpriced usage instead of understating cost') do
    subject = AIMeterHarness.new
    rows = JSON.parse(File.read(FIXTURE)).fetch('data')

    stale = subject.build_ai_meter_report(rows, days: 7, now: Date.new(2026, 9, 1))
    assert_eq(stale[:totals][:cost_state], 'stale_rates')
    assert_eq(stale[:totals][:gross_post_credit_estimated_usd], nil)

    unknown = rows.first.merge('model' => '@cf/example/unpriced')
    unpriced = subject.build_ai_meter_report([unknown], days: 7, now: Date.new(2026, 7, 20))
    assert_eq(unpriced[:totals][:cost_state], 'unpriced_usage')
    assert_eq(unpriced[:totals][:gross_post_credit_estimated_usd], nil)
    assert_includes(unpriced[:warnings].join(' '), '@cf/example/unpriced')
    true
  end

  test('renders a concise morning-report section without invoice claims') do
    rows = JSON.parse(File.read(FIXTURE)).fetch('data')
    report = AIMeterHarness.new.build_ai_meter_report(rows, days: 7, now: Date.new(2026, 7, 20))
    markdown = AIMeterHarness.new.render_ai_meter_markdown(report)

    assert_includes(markdown, '## AI Usage & Cost (7-day)')
    assert_includes(markdown, '| sanelot |')
    assert_includes(markdown, '| sanecite |')
    assert_includes(markdown, 'were not run by this report')
    assert_includes(markdown, 'not invoice or credit truth')
    assert(!markdown.include?('p95'), 'must not claim an unweighted p95')
    true
  end

  test('never includes credentials in query errors') do
    subject = AIMeterHarness.new
    subject.response_status = 401
    report = subject.query_ai_meter(days: 7, token: 'SECRET_TOKEN', account_id: 'account')
    serialized = JSON.generate(report)

    assert_eq(report[:state], 'query_error')
    assert(!serialized.include?('SECRET_TOKEN'), 'query error must not expose credentials')
    true
  end
end)
