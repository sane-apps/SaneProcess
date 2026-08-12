#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'stringio'
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
  test('stores one allowlisted stdin value atomically without printing it') do
    Dir.mktmpdir('cws-env-store') do |dir|
      path = File.join(dir, 'env')
      File.write(path, "export UNRELATED=value\nexport SANE_CWS_CLIENT_SECRET=old\n")
      FileUtils.chmod(0o600, path)
      result = SaneCwsReviewWatch.store_env_value_from_stdin(
        'SANE_CWS_CLIENT_SECRET', input: StringIO.new("new-secret\n"), env_path: path
      )
      stored = File.read(path)

      assert_eq(result, { 'status' => 'stored', 'name' => 'SANE_CWS_CLIENT_SECRET', 'value' => 'redacted' })
      assert_includes(stored, 'export UNRELATED=value')
      assert_includes(stored, 'export SANE_CWS_CLIENT_SECRET=new-secret')
      assert(!stored.include?('old'))
      assert_eq(File.stat(path).mode & 0o777, 0o600)
      assert(!JSON.generate(result).include?('new-secret'))
      true
    end
  end

  test('credential stdin storage rejects non-allowlisted names and multiline values') do
    Dir.mktmpdir('cws-env-store-invalid') do |dir|
      path = File.join(dir, 'env')
      errors = []
      begin
        SaneCwsReviewWatch.store_env_value_from_stdin(
          'UNRELATED_SECRET', input: StringIO.new('secret'), env_path: path
        )
      rescue SaneAppReviewWatch::WatchError => e
        errors << e.message
      end
      begin
        SaneCwsReviewWatch.store_env_value_from_stdin(
          'SANE_CWS_CLIENT_SECRET', input: StringIO.new("one\ntwo\n"), env_path: path
        )
      rescue SaneAppReviewWatch::WatchError => e
        errors << e.message
      end

      assert_eq(errors.length, 2)
      assert_includes(errors.first, 'not allowlisted')
      assert_includes(errors.last, 'input is invalid')
      assert(!File.exist?(path))
      true
    end
  end

  test('loads only allowlisted private cache values without overriding process ENV') do
    Dir.mktmpdir('cws-env-cache') do |dir|
      path = File.join(dir, 'env')
      File.write(path, <<~ENV)
        export SANE_CWS_PUBLISHER_ID='cached-publisher'
        SANE_CWS_CLIENT_ID='cached-client'
        SANE_CWS_CLIENT_SECRET='cached-secret'
        SANE_CWS_REFRESH_TOKEN='cached-refresh'
        UNRELATED_SECRET='must-not-load'
      ENV
      FileUtils.chmod(0o600, path)
      configuration = SaneCwsReviewWatch.credential_configuration(
        process_env: { 'SANE_CWS_CLIENT_ID' => 'process-client' }, env_path: path
      )

      assert_eq(configuration['SANE_CWS_PUBLISHER_ID'], 'cached-publisher')
      assert_eq(configuration['SANE_CWS_CLIENT_ID'], 'process-client')
      assert_eq(configuration['SANE_CWS_CLIENT_SECRET'], 'cached-secret')
      assert(!configuration.key?('UNRELATED_SECRET'))
      true
    end
  end

  test('empty process values do not mask a complete private cache') do
    Dir.mktmpdir('cws-env-cache-empty-process') do |dir|
      path = File.join(dir, 'env')
      File.write(path, <<~ENV)
        SANE_CWS_PUBLISHER_ID='cached-publisher'
        SANE_CWS_ACCESS_TOKEN='cached-access'
      ENV
      FileUtils.chmod(0o600, path)
      details = SaneCwsReviewWatch.credential_configuration_with_sources(
        process_env: {
          'SANE_CWS_PUBLISHER_ID' => '',
          'SANE_CWS_ACCESS_TOKEN' => ''
        },
        env_path: path
      )

      assert_eq(details.dig(:configuration, 'SANE_CWS_PUBLISHER_ID'), 'cached-publisher')
      assert_eq(details.dig(:configuration, 'SANE_CWS_ACCESS_TOKEN'), 'cached-access')
      assert_eq(details.dig(:sources, 'SANE_CWS_PUBLISHER_ID'), 'private_cache')
      assert_eq(details.dig(:sources, 'SANE_CWS_ACCESS_TOKEN'), 'private_cache')
      true
    end
  end

  test('configuration diagnostic distinguishes publisher and OAuth blockers') do
    missing_publisher = SaneCwsReviewWatch.configuration_diagnostic({})
    missing_oauth = SaneCwsReviewWatch.configuration_diagnostic(
      'SANE_CWS_PUBLISHER_ID' => 'publisher-1'
    )
    ready = SaneCwsReviewWatch.configuration_diagnostic(
      'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
      'SANE_CWS_ACCESS_TOKEN' => 'access-fixture'
    )
    blocked_without_secret = SaneCwsReviewWatch.configuration_diagnostic(
      'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
      'SANE_CWS_CLIENT_ID' => 'client-fixture',
      'SANE_CWS_REFRESH_TOKEN' => 'refresh-fixture'
    )

    assert_eq(missing_publisher['error_code'], 'publisher_id_missing')
    assert_eq(missing_oauth['error_code'], 'oauth_missing')
    assert_includes(missing_oauth['missing_configuration'], 'SANE_CWS_REFRESH_TOKEN')
    assert_includes(missing_oauth['missing_configuration'], 'SANE_CWS_CLIENT_SECRET')
    assert_eq(ready['status'], 'ready')
    assert_eq(ready['credential_mode'], 'access_token')
    assert_eq(blocked_without_secret['status'], 'blocked')
    assert_eq(blocked_without_secret['credential_mode'], 'unavailable')
    assert_eq(blocked_without_secret['missing_configuration'], ['SANE_CWS_CLIENT_SECRET'])
    true
  end

  test('credential stdin storage rejects empty input without crashing') do
    Dir.mktmpdir('cws-empty-credential') do |dir|
      begin
        SaneCwsReviewWatch.store_env_value_from_stdin(
          'SANE_CWS_CLIENT_SECRET', input: StringIO.new(''), env_path: File.join(dir, 'env')
        )
        assert(false, 'empty credential input must fail closed')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'input is empty')
      end
    end
    true
  end

  test('writes a private redacted configuration receipt and rejects receipt symlinks') do
    Dir.mktmpdir('cws-receipt') do |dir|
      path = File.join(dir, 'receipt.json')
      configuration = {
        'SANE_CWS_PUBLISHER_ID' => 'publisher-secret-fixture',
        'SANE_CWS_ACCESS_TOKEN' => 'access-secret-fixture'
      }
      sources = SaneCwsReviewWatch::ENV_NAMES.to_h { |name| [name, 'missing'] }
      sources['SANE_CWS_PUBLISHER_ID'] = 'private_cache'
      sources['SANE_CWS_ACCESS_TOKEN'] = 'private_cache'
      receipt = SaneCwsReviewWatch.configuration_receipt(
        configuration: configuration,
        sources: sources,
        official_get: 'skipped',
        now: Time.utc(2026, 8, 10, 12, 0, 0)
      )
      SaneCwsReviewWatch.write_receipt(path, receipt)
      serialized = File.read(path)

      assert_eq(File.stat(path).mode & 0o777, 0o600)
      assert_eq(JSON.parse(serialized)['status'], 'ready')
      assert(!serialized.include?('publisher-secret-fixture'))
      assert(!serialized.include?('access-secret-fixture'))

      File.delete(path)
      File.symlink(File.join(dir, 'target'), path)
      begin
        SaneCwsReviewWatch.write_receipt(path, receipt)
        assert(false, 'receipt symlink must fail closed')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'must not be a symlink')
      end
      true
    end
  end

  test('rejects a group-readable credential cache') do
    Dir.mktmpdir('cws-env-cache-mode') do |dir|
      path = File.join(dir, 'env')
      File.write(path, "SANE_CWS_PUBLISHER_ID=publisher-1\n")
      FileUtils.chmod(0o640, path)
      begin
        SaneCwsReviewWatch.credential_configuration(process_env: {}, env_path: path)
        assert(false, 'expected unsafe credential cache mode to fail')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'permissions must be private')
      end
      true
    end
  end

  test('local health is redacted and never creates state or sends an alert') do
    Dir.mktmpdir('cws-health') do |dir|
      state = File.join(dir, 'state.json')
      env = {
        'HOME' => dir,
        'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
        'SANE_CWS_ACCESS_TOKEN' => 'access-token-fixture'
      }
      receipt = File.join(dir, 'receipt.json')
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, File.expand_path('cws_review_watch.rb', __dir__),
        '--health', '--state', state, '--receipt', receipt
      )

      assert(status.success?, stderr)
      result = JSON.parse(stdout)
      assert_eq(result['status'], 'ok')
      assert_eq(result['official_get'], 'skipped')
      assert_eq(result['credential_mode'], 'access_token')
      assert(!stdout.include?('publisher-1'))
      assert(!stdout.include?('access-token-fixture'))
      assert(!File.exist?(state), 'health mode created watcher state')
      persisted = JSON.parse(File.read(receipt))
      assert_eq(persisted['status'], 'ok')
      assert_eq(persisted['official_get'], 'skipped')
      true
    end
  end

  test('local health blocks refresh credentials without the required client secret') do
    Dir.mktmpdir('cws-health-desktop-pkce') do |dir|
      state = File.join(dir, 'state.json')
      receipt = File.join(dir, 'receipt.json')
      env = SaneCwsReviewWatch::ENV_NAMES.to_h { |name| [name, ''] }.merge(
        'HOME' => dir,
        'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
        'SANE_CWS_CLIENT_ID' => 'client-fixture',
        'SANE_CWS_REFRESH_TOKEN' => 'refresh-fixture'
      )
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, File.expand_path('cws_review_watch.rb', __dir__),
        '--health', '--state', state, '--receipt', receipt
      )

      assert(!status.success?, 'health unexpectedly accepted refresh credentials without a client secret')
      persisted = JSON.parse(File.read(receipt))
      assert_includes(stderr, 'oauth_missing')
      assert_eq(stdout, '')
      assert_eq(persisted['credential_mode'], 'unavailable')
      assert_eq(persisted['official_get'], 'skipped')
      assert_eq(persisted['missing_configuration'], ['SANE_CWS_CLIENT_SECRET'])
      assert_eq(persisted.dig('configuration_sources', 'SANE_CWS_CLIENT_SECRET'), 'missing')
      assert(!File.exist?(state), 'health mode created watcher state')
      true
    end
  end

  test('missing configuration exits blocked with a durable exact redacted receipt') do
    Dir.mktmpdir('cws-health-blocked') do |dir|
      state = File.join(dir, 'state.json')
      receipt = File.join(dir, 'receipt.json')
      env = SaneCwsReviewWatch::ENV_NAMES.to_h { |name| [name, ''] }.merge('HOME' => dir)
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, File.expand_path('cws_review_watch.rb', __dir__),
        '--health', '--state', state, '--receipt', receipt
      )

      assert_eq(status.exitstatus, 2)
      assert_eq(stdout, '')
      assert_includes(stderr, 'publisher_id_missing')
      persisted = JSON.parse(File.read(receipt))
      assert_eq(persisted['status'], 'blocked')
      assert_eq(persisted['stage'], 'configuration')
      assert_eq(persisted['error_code'], 'publisher_id_missing')
      assert_eq(persisted['publisher_id'], 'missing')
      assert(!File.exist?(state), 'blocked health created watcher state')
      true
    end
  end

  test('authorized health performs only official status retrieval and remains redacted') do
    calls = []
    requester = lambda do |**args|
      calls << args
      { code: 200, body: JSON.generate(cws_payload(state: 'PENDING_REVIEW')) }
    end
    configuration = {
      'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
      'SANE_CWS_ACCESS_TOKEN' => 'access-token-fixture'
    }
    result = SaneCwsReviewWatch.health(
      configuration: configuration, official_get: true, requester: requester
    )
    serialized = JSON.generate(result)

    assert_eq(calls.length, 1)
    assert_eq(calls.first[:method], :get)
    assert(calls.first[:uri].to_s.end_with?(':fetchStatus'))
    assert_eq(result['official_get'], 'ok')
    assert_eq(result['revision_state'], 'PENDING_REVIEW')
    assert(!serialized.include?('publisher-1'))
    assert(!serialized.include?('access-token-fixture'))
    true
  end

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

  test('refreshes canonical desktop OAuth with client secret and then performs GET-only status') do
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
    refresh_fields = URI.decode_www_form(calls.first[:body]).to_h
    assert_eq(refresh_fields['client_id'], 'client-fixture')
    assert_eq(refresh_fields['refresh_token'], 'refresh-fixture')
    assert_eq(refresh_fields['client_secret'], 'secret-fixture')
    assert_eq(calls.last[:headers]['Authorization'], 'Bearer short-lived-token')
    assert(!calls.last[:uri].to_s.include?('short-lived-token'))
    true
  end

  test('complete refresh credentials take precedence over a stale direct access token') do
    calls = []
    requester = lambda do |**args|
      calls << args
      if args[:uri] == SaneCwsReviewWatch::TOKEN_URI
        { code: 200, body: JSON.generate(access_token: 'fresh-access-token') }
      else
        { code: 200, body: JSON.generate(cws_payload(state: 'PENDING_REVIEW')) }
      end
    end
    configuration = {
      'SANE_CWS_PUBLISHER_ID' => 'publisher-1',
      'SANE_CWS_ACCESS_TOKEN' => 'expired-direct-token',
      'SANE_CWS_CLIENT_ID' => 'client-fixture',
      'SANE_CWS_CLIENT_SECRET' => 'secret-fixture',
      'SANE_CWS_REFRESH_TOKEN' => 'refresh-fixture'
    }
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: configuration.fetch('SANE_CWS_PUBLISHER_ID'),
      access_token: configuration.fetch('SANE_CWS_ACCESS_TOKEN'),
      client_id: configuration.fetch('SANE_CWS_CLIENT_ID'),
      client_secret: configuration.fetch('SANE_CWS_CLIENT_SECRET'),
      refresh_token: configuration.fetch('SANE_CWS_REFRESH_TOKEN'),
      requester: requester
    )

    client.snapshot

    assert_eq(SaneCwsReviewWatch.credential_mode(configuration), 'refresh_token')
    assert_eq(calls.map { |call| call[:method] }, %i[post get])
    refresh_fields = URI.decode_www_form(calls.first[:body]).to_h
    assert_eq(refresh_fields['client_secret'], 'secret-fixture')
    assert_eq(calls.last[:headers]['Authorization'], 'Bearer fresh-access-token')
    assert(!JSON.generate(calls.last).include?('expired-direct-token'))
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

  test('fetchStatus malformed JSON diagnostic never includes the provider body') do
    provider_body = 'fetch-status-secret-body{not-json'
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1',
      access_token: 'access-token-fixture',
      requester: ->(**_args) { { code: 200, body: provider_body } }
    )

    begin
      client.snapshot
      assert(false, 'malformed fetchStatus JSON must fail closed')
    rescue SaneAppReviewWatch::WatchError => e
      assert_eq(e.message, 'CWS fetchStatus returned invalid JSON')
      assert(!e.message.include?(provider_body))
      assert_eq(e.cause, nil)
      assert(!e.full_message.include?(provider_body))
    end
    true
  end

  test('OAuth refresh malformed JSON diagnostic never includes the provider body') do
    provider_body = 'oauth-refresh-secret-body{not-json'
    client = SaneCwsReviewWatch::Client.new(
      publisher_id: 'publisher-1',
      access_token: '',
      client_id: 'client-fixture',
      client_secret: 'secret-fixture',
      refresh_token: 'refresh-fixture',
      requester: ->(**_args) { { code: 200, body: provider_body } }
    )

    begin
      client.snapshot
      assert(false, 'malformed OAuth refresh JSON must fail closed')
    rescue SaneAppReviewWatch::WatchError => e
      assert_eq(e.message, 'CWS OAuth refresh returned invalid JSON')
      assert(!e.message.include?(provider_body))
      assert_eq(e.cause, nil)
      assert(!e.full_message.include?(provider_body))
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

  test('same-state CWS package version change is delivered as a new observation') do
    Dir.mktmpdir('cws-version-observation') do |dir|
      client = SaneCwsReviewWatch::Client.new(
        publisher_id: 'publisher-1', access_token: 'fixture', requester: ->(**) { raise 'unused' }
      )
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      engine = SaneAppReviewWatch::Engine.new(
        store: store,
        sender: CwsWatchSender.new([cws_receipt, cws_receipt]),
        event_kind: SaneInternalReport::CWS_REVIEW_KIND,
        alert_on_initial: true
      )

      first = engine.run(client.snapshot_from_payload(cws_payload(state: 'PENDING_REVIEW', version: '1.0.9')))
      second = engine.run(client.snapshot_from_payload(cws_payload(state: 'PENDING_REVIEW', version: '1.0.10')))

      assert_eq(first['delivered_count'], 1)
      assert_eq(second['delivered_count'], 1)
      assert_eq(second.dig('delivered', 0, 'changes', 0, 'previous_state'), 'PENDING_REVIEW')
      assert_eq(second.dig('delivered', 0, 'changes', 0, 'version'), '1.0.10')
      delivered_id = second.dig('delivered', 0, 'id')
      receipt_event = store.load.fetch('delivery_receipts').fetch(delivered_id)
      assert_eq(receipt_event['event_id'], delivered_id)
      assert_eq(store.load.dig('delivered_entities',
                               "#{SaneCwsReviewWatch::DEFAULT_ITEM_ID}:chrome_web_store_submission:#{SaneCwsReviewWatch::DEFAULT_ITEM_ID}",
                               'version'), '1.0.10')
      assert_eq(store.load['delivery_receipts'].length, 2)
      true
    end
  end

  test('Mini host gate accepts only canonical exact hostnames') do
    assert(SaneCwsReviewWatch.mini_host?('Stephans-Mac-mini.local'))
    assert(SaneCwsReviewWatch.mini_host?('mini'))
    assert(!SaneCwsReviewWatch.mini_host?('attacker-mini.example'))
    assert(!SaneCwsReviewWatch.mini_host?('MacBook-Air'))
    true
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
        'state' => 'PENDING_REVIEW',
        'previous_version' => '1.0.9',
        'version' => '1.0.10'
      }],
      at: Time.utc(2026, 8, 3),
      kind: SaneInternalReport::CWS_REVIEW_KIND
    )
    envelope = SaneInternalReport.render(event)

    assert_eq(envelope['kind'], SaneInternalReport::CWS_REVIEW_KIND)
    assert_eq(envelope['subject'], 'Chrome Web Store changed: SaneLot Auction Pricing')
    assert_includes(envelope['body'], 'Chrome Web Store reported a review-state transition.')
    assert_includes(envelope['body'], 'version 1.0.9 -> 1.0.10')
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
      assert_includes(e.message, 'SANE_CWS_CLIENT_SECRET')
    end
    true
  end
end)
