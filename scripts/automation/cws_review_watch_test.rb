#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'cws_review_watch'

include TestFramework

class CwsWatchSender
  def initialize(values)
    @values = values.dup
  end

  def deliver(event)
    value = @values.shift
    raise SaneInternalReport::DeliveryError, 'transport missing' if value.nil?
    raise value if value.is_a?(Exception)

    value.merge('event_id' => event.fetch('id'))
  end
end

def cws_receipt
  {
    'provider_id' => 'provider-cws-1',
    'delivery_event' => 'delivered',
    'delivered_at' => '2026-08-03T00:00:00Z',
    'template_version' => 1
  }
end

def cws_payload(state:, version: '1.0.9')
  {
    'itemId' => SaneCwsReviewWatch::DEFAULT_ITEM_ID,
    'submittedItemRevisionStatus' => {
      'state' => state,
      'distributionChannels' => [{ 'deployPercentage' => 100, 'crxVersion' => version }]
    },
    'takenDown' => false,
    'warned' => false
  }
end

exit(run_tests('CWS Review Watch Tests') do
  test('uses only official v2 fetchStatus and normalizes the submitted revision') do
    calls = []
    requester = lambda do |**args|
      calls << args
      { code: 200, body: JSON.generate(cws_payload(state: 'PENDING_REVIEW')) }
    end
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1',
      access_token: 'access-token-fixture',
      requester: requester
    )
    snapshot = client.snapshot
    entity = snapshot.entities.values.fetch(0)

    assert_eq(calls.length, 1)
    assert_eq(calls[0][:method], :get)
    assert_includes(calls[0][:uri].to_s, '/v2/publishers/publisher-1/items/')
    assert(calls[0][:uri].to_s.end_with?(':fetchStatus'))
    assert_eq(entity['state'], 'PENDING_REVIEW')
    assert_eq(entity['version'], '1.0.9')
    assert_eq(entity['platform'], 'CHROME_WEB_STORE')
    true
  end

  test('refreshes OAuth without exposing credentials and then performs GET-only status') do
    calls = []
    requester = lambda do |**args|
      calls << args
      if args[:uri] == SaneCwsReviewWatch::TOKEN_URI
        { code: 200, body: JSON.generate(access_token: 'short-lived-token') }
      else
        { code: 200, body: JSON.generate(cws_payload(state: 'PENDING_REVIEW')) }
      end
    end
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1',
      access_token: '',
      client_id: 'client-fixture',
      client_secret: 'secret-fixture',
      refresh_token: 'refresh-fixture',
      requester: requester
    )
    client.snapshot

    assert_eq(calls.map { |call| call[:method] }, %i[post get])
    assert_eq(calls.last[:headers]['Authorization'], 'Bearer short-lived-token')
    assert(!calls.last[:uri].to_s.include?('short-lived-token'))
    true
  end

  test('fails closed with redacted HTTP diagnostics') do
    requester = lambda do |**_args|
      { code: 403, body: JSON.generate(error: { message: 'secret-bearing-provider-detail' }) }
    end
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1', access_token: 'access-token-fixture', requester: requester
    )

    begin
      client.snapshot
      assert(false, 'expected CWS HTTP failure')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'HTTP 403')
      assert(!e.message.include?('secret-bearing-provider-detail'))
    end
    true
  end

  test('elevates policy warning and takedown flags into alertable states') do
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1', access_token: 'fixture', requester: ->(**) { raise 'unused' }
    )
    warned = cws_payload(state: 'PENDING_REVIEW').merge('warned' => true)
    taken_down = cws_payload(state: 'PUBLISHED').merge('takenDown' => true)

    warned_entity = client.snapshot_from_payload(warned).entities.values.fetch(0)
    taken_down_entity = client.snapshot_from_payload(taken_down).entities.values.fetch(0)

    assert_eq(warned_entity['state'], 'WARNED')
    assert_eq(warned_entity['revision_state'], 'PENDING_REVIEW')
    assert_eq(taken_down_entity['state'], 'TAKEN_DOWN')
    assert_eq(taken_down_entity['revision_state'], 'PUBLISHED')
    true
  end

  test('alerts on the first observed CWS state and retries a rejected transition') do
    Dir.mktmpdir('cws-review-watch') do |dir|
      client = SaneCwsReviewWatch::Client.new(
        publisher_id: 'publisher-1', access_token: 'fixture', requester: ->(**) { raise 'unused' }
      )
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      sender = CwsWatchSender.new([
        cws_receipt,
        SaneInternalReport::DeliveryError.new('transport unavailable'),
        cws_receipt
      ])
      engine = SaneAppReviewWatch::Engine.new(
        store: store,
        sender: sender,
        event_kind: SaneInternalReport::CWS_REVIEW_KIND,
        alert_on_initial: true
      )

      initial = engine.run(client.snapshot_from_payload(cws_payload(state: 'PENDING_REVIEW')))
      rejected_snapshot = client.snapshot_from_payload(cws_payload(state: 'REJECTED'))
      rejected = engine.run(rejected_snapshot)
      retried = engine.run(rejected_snapshot)

      assert_eq(initial['delivered_count'], 1)
      assert_eq(initial.dig('delivered', 0, 'changes', 0, 'state'), 'PENDING_REVIEW')
      assert_eq(rejected['pending_count'], 1)
      assert_eq(retried['pending_count'], 0)
      assert_eq(retried['delivered_count'], 1)
      assert_eq(store.load['delivery_receipts'].length, 2)
      true
    end
  end

  test('renders CWS alerts distinctly from App Store Connect alerts') do
    event = SaneAppReviewWatch.pending_event(
      [{
        'entity_key' => 'item:chrome_web_store_submission:item',
        'entity_type' => 'chrome_web_store_submission',
        'entity_id' => 'item',
        'app_id' => 'item',
        'app_name' => 'SaneLot Auction Pricing',
        'previous_state' => 'PENDING_REVIEW',
        'state' => 'STAGED'
      }],
      at: Time.utc(2026, 8, 3),
      kind: SaneInternalReport::CWS_REVIEW_KIND
    )
    envelope = SaneInternalReport.render(event)

    assert_eq(envelope['kind'], SaneInternalReport::CWS_REVIEW_KIND)
    assert_eq(envelope['subject'], 'Chrome Web Store changed: SaneLot Auction Pricing')
    assert_includes(envelope['body'], 'Chrome Web Store reported a review-state transition.')
    assert(!envelope['body'].include?('App Store Connect reported'))
    true
  end

  test('requires explicit OAuth configuration rather than browser scraping') do
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1',
      access_token: '', client_id: '', client_secret: '', refresh_token: '',
      requester: ->(**) { raise 'request must not run without credentials' }
    )
    begin
      client.snapshot
      assert(false, 'expected missing OAuth configuration to fail closed')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'CWS OAuth credential is unavailable')
      assert_includes(e.message, 'SANE_CWS_REFRESH_TOKEN')
    end
    true
  end
end)
