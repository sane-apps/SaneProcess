#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'app_review_watch'

include TestFramework

class ReceiptStatus
  def initialize(success: true, exitstatus: 0)
    @success = success
    @exitstatus = exitstatus
  end

  attr_reader :exitstatus

  def success?
    @success
  end
end

class WatchSender
  def initialize(receipts = [])
    @receipts = receipts.dup
  end

  def deliver(event)
    value = @receipts.shift
    raise SaneInternalReport::DeliveryError, 'transport missing' if value.nil?
    raise value if value.is_a?(Exception)

    value.merge('event_id' => event.fetch('id'))
  end
end

def watch_entity(state:, key: '1:review_submission:s1', app: 'SaneLot')
  app_id, type, id = key.split(':', 3)
  {
    'entity_key' => key,
    'entity_type' => type,
    'entity_id' => id,
    'app_id' => app_id,
    'app_name' => app,
    'state' => state,
    'submission_id' => type == 'review_submission' ? id : 's1'
  }
end

def delivered_receipt
  {
    'provider_id' => 'provider-1',
    'delivery_event' => 'delivered',
    'delivered_at' => '2026-07-26T12:00:00Z',
    'template_version' => 1
  }
end

exit(run_tests('App Review Watch Tests') do
  test('migrates schema one and queues a transition without advancing delivery') do
    Dir.mktmpdir('app-review-watch') do |dir|
      state_path = File.join(dir, 'state.json')
      File.write(state_path, JSON.generate(
        'schema_version' => 1,
        'last_checked_at' => '2026-07-22T00:00:00Z',
        'apps' => {
          '1' => {
            'name' => 'SaneLot',
            'review_submissions' => { 's1' => { 'state' => 'WAITING_FOR_REVIEW' } }
          }
        }
      ))
      store = SaneAppReviewWatch::StateStore.new(state_path, now: -> { Time.utc(2026, 7, 26, 12) })
      result = SaneAppReviewWatch::Engine.new(
        store: store,
        sender: WatchSender.new,
        now: -> { Time.utc(2026, 7, 26, 12) }
      ).run('1:review_submission:s1' => watch_entity(state: 'UNRESOLVED_ISSUES'))

      state = JSON.parse(File.read(state_path))
      assert_eq(result['pending_count'], 1)
      assert_eq(state['schema_version'], 2)
      assert_eq(state.dig('delivered_entities', '1:review_submission:s1', 'state'), 'WAITING_FOR_REVIEW')
      assert_eq(state.dig('observed_entities', '1:review_submission:s1', 'state'), 'UNRESOLVED_ISSUES')
      true
    end
  end

  test('rerun does not duplicate a pending transition') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      engine = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new)
      snapshot = { '1:review_submission:s1' => watch_entity(state: 'REJECTED') }
      engine.run(snapshot)
      result = engine.run(snapshot)

      assert_eq(result['pending_count'], 1)
      state = store.load
      assert_eq(state['pending_alerts'].length, 1)
      assert_eq(state['pending_alerts'].values.first['attempt_count'], 2)
      true
    end
  end

  test('detects SaneHosts rejected version when linked review submission is complete') do
    Dir.mktmpdir('app-review-watch') do |dir|
      state_path = File.join(dir, 'state.json')
      File.write(state_path, JSON.generate(
        'schema_version' => 1,
        'last_checked_at' => '2026-07-22T00:00:00Z',
        'apps' => {
          '6759330900' => {
            'name' => 'SaneHosts',
            'review_submissions' => {
              '8984d08e-e5f1-4013-b708-d340e3e0b1e3' => { 'state' => 'COMPLETE' }
            }
          }
        }
      ))
      store = SaneAppReviewWatch::StateStore.new(state_path)
      complete_submission = watch_entity(
        state: 'COMPLETE',
        key: '6759330900:review_submission:8984d08e-e5f1-4013-b708-d340e3e0b1e3',
        app: 'SaneHosts'
      )
      rejected_version = watch_entity(
        state: 'REJECTED',
        key: '6759330900:app_store_version:eeaed17c-4f91-4d42-af90-149d9d9f894c',
        app: 'SaneHosts'
      ).merge('version' => '1.1.3', 'platform' => 'MAC_OS')

      result = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
        complete_submission['entity_key'] => complete_submission,
        rejected_version['entity_key'] => rejected_version
      )
      event = store.load.fetch('pending_alerts').values.fetch(0)
      change = event.fetch('changes').find { |item| item['entity_type'] == 'app_store_version' }

      assert_eq(result['pending_count'], 1)
      assert_eq(change['entity_id'], 'eeaed17c-4f91-4d42-af90-149d9d9f894c')
      assert_eq(change['state'], 'REJECTED')
      assert_eq(change['version'], '1.1.3')
      assert_eq(change['platform'], 'MAC_OS')
      true
    end
  end

  test('ASC snapshot is read-only GET and captures version state independently') do
    Dir.mktmpdir('app-review-watch-asc') do |dir|
      script = File.join(dir, 'asc.rb')
      File.write(script, '# fixture')
      calls = []
      runner = lambda do |*argv|
        calls << argv
        path = argv.fetch(3)
        data =
          case path
          when '/v1/apps?fields[apps]=name&limit=200'
            [{ 'id' => '6759330900', 'attributes' => { 'name' => 'SaneHosts' } }]
          when %r{\A/v1/reviewSubmissions\?}
            [{
              'id' => '8984d08e-e5f1-4013-b708-d340e3e0b1e3',
              'attributes' => { 'state' => 'COMPLETE', 'submittedDate' => '2026-03-09T19:50:31.106Z' }
            }]
          when %r{/v1/reviewSubmissions/.+/items}
            []
          when %r{/v1/apps/6759330900/appStoreVersions}
            [{
              'id' => 'eeaed17c-4f91-4d42-af90-149d9d9f894c',
              'attributes' => { 'versionString' => '1.1.3', 'appStoreState' => 'REJECTED', 'platform' => 'MAC_OS' }
            }]
          else
            raise "unexpected ASC path #{path}"
          end
        ["HTTP 200\n#{JSON.generate('data' => data)}\n", '', ReceiptStatus.new]
      end

      snapshot = SaneAppReviewWatch::AscClient.new(script: script, runner: runner).snapshot
      version = snapshot.entities.fetch('6759330900:app_store_version:eeaed17c-4f91-4d42-af90-149d9d9f894c')

      assert(calls.all? { |argv| argv.fetch(2) == 'GET' }, "expected GET-only ASC calls, got #{calls.inspect}")
      assert_eq(version['state'], 'REJECTED')
      assert_eq(version['version'], '1.1.3')
      assert_eq(version['platform'], 'MAC_OS')
      true
    end
  end

  test('ASC discovery falls back to local saneprocess while healthy lanes continue') do
    Dir.mktmpdir('app-review-watch-asc') do |dir|
      script = File.join(dir, 'asc.rb')
      app_dir = File.join(dir, 'apps', 'SaneLot')
      FileUtils.mkdir_p(app_dir)
      File.write(script, '# fixture')
      File.write(File.join(app_dir, '.saneprocess'), "name: SaneLot\nappstore:\n  app_id: '6789208379'\n")
      calls = []
      runner = lambda do |*argv|
        calls << argv
        path = argv.fetch(3)
        return ["HTTP 500\n{\"errors\":[]}\n", '', ReceiptStatus.new] if path == '/v1/apps?fields[apps]=name&limit=200' || path.include?('appStoreVersions')

        data =
          if path.include?('/items')
            [{ 'id' => 'i1', 'attributes' => { 'state' => 'REJECTED' } }]
          else
            [{ 'id' => 's1', 'attributes' => { 'state' => 'UNRESOLVED_ISSUES' } }]
          end
        ["HTTP 200\n#{JSON.generate('data' => data)}\n", '', ReceiptStatus.new]
      end
      client = SaneAppReviewWatch::AscClient.new(
        script: script, runner: runner, app_catalog: SaneAppReviewWatch::AppCatalog.new(apps_root: File.join(dir, 'apps'))
      )
      snapshot = client.snapshot

      assert_eq(snapshot.entities.fetch('6789208379:review_submission:s1')['state'], 'UNRESOLVED_ISSUES')
      assert_eq(snapshot.entities.fetch('6789208379:review_submission_item:i1')['state'], 'REJECTED')
      assert_eq(snapshot.diagnostics.map { |item| item['lane'] }, %w[app_discovery app_store_versions])
      assert(calls.all? { |argv| argv.fetch(2) == 'GET' })
      true
    end
  end

  test('partial lanes preserve observations and retry durable pending delivery') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      sender = WatchSender.new([delivered_receipt, SaneInternalReport::DeliveryError.new('transport missing'), delivered_receipt])
      engine = SaneAppReviewWatch::Engine.new(store: store, sender: sender)
      version = watch_entity(state: 'REJECTED', key: '1:app_store_version:v1')
      submission = watch_entity(state: 'UNRESOLVED_ISSUES')
      engine.run(version['entity_key'] => version)
      partial = SaneAppReviewWatch::Snapshot.new(
        entities: { submission['entity_key'] => submission }, complete_scopes: ['1:review_submission'],
        diagnostics: [{ 'lane' => 'app_store_versions', 'error' => 'HTTP 500' }], app_ids: ['1'], catalog_complete: true
      )
      result = engine.run(partial)
      assert_eq(result['status'], 'partial_pending_alerts')
      assert_eq(store.load.dig('observed_entities', version['entity_key'], 'state'), 'REJECTED')

      unavailable = SaneAppReviewWatch::Snapshot.new(
        entities: {}, complete_scopes: [], diagnostics: [{ 'lane' => 'app_discovery', 'error' => 'HTTP 500' }],
        app_ids: [], catalog_complete: false
      )
      result = engine.run(unavailable)
      assert_eq(result['status'], 'partial')
      assert_eq(store.load['pending_alerts'].length, 0)
      true
    end
  end

  test('delivered adverse state does not re-alert after disappearance and reappearance') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      engine = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new([delivered_receipt]))
      entity = watch_entity(state: 'REJECTED')
      engine.run(entity['entity_key'] => entity)
      engine.run({})
      result = engine.run(entity['entity_key'] => entity)

      assert_eq(result['pending_count'], 0)
      assert_eq(store.load['delivery_receipts'].length, 1)
      true
    end
  end

  test('ASC parser accepts canonical HTTP 200 prefix and JSON body') do
    Dir.mktmpdir('app-review-watch-asc') do |dir|
      script = File.join(dir, 'asc.rb')
      File.write(script, '# fixture')
      runner = lambda do |*_argv|
        ["HTTP 200\n{\"data\":[]}\n", '', ReceiptStatus.new]
      end
      client = SaneAppReviewWatch::AscClient.new(script: script, runner: runner)

      assert_eq(client.send(:get, '/v1/apps'), { 'data' => [] })
      true
    end
  end

  test('ASC parser fails closed on non-2xx HTTP status') do
    Dir.mktmpdir('app-review-watch-asc') do |dir|
      script = File.join(dir, 'asc.rb')
      File.write(script, '# fixture')
      runner = lambda do |*_argv|
        ["HTTP 401\n{\"errors\":[{\"status\":\"401\"}]}\n", '', ReceiptStatus.new]
      end
      client = SaneAppReviewWatch::AscClient.new(script: script, runner: runner)

      begin
        client.send(:get, '/v1/apps')
        assert(false, 'expected non-2xx response to fail closed')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'HTTP 401')
      end
      true
    end
  end

  test('ASC parser fails closed on malformed JSON body') do
    Dir.mktmpdir('app-review-watch-asc') do |dir|
      script = File.join(dir, 'asc.rb')
      File.write(script, '# fixture')
      runner = lambda do |*_argv|
        ["HTTP 200\nnot-json\n", '', ReceiptStatus.new]
      end
      client = SaneAppReviewWatch::AscClient.new(script: script, runner: runner)

      begin
        client.send(:get, '/v1/apps')
        assert(false, 'expected malformed JSON body to fail closed')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'invalid JSON')
      end
      true
    end
  end

  test('verified receipt advances delivery and clears pending') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      sender = WatchSender.new([delivered_receipt])
      result = SaneAppReviewWatch::Engine.new(store: store, sender: sender).run(
        '1:review_submission:s1' => watch_entity(state: 'REJECTED')
      )
      state = store.load

      assert_eq(result['pending_count'], 0)
      assert_eq(result['delivered_count'], 1)
      assert_eq(result.dig('delivered', 0, 'apps'), ['SaneLot'])
      assert_eq(result.dig('delivered', 0, 'changes', 0, 'state'), 'REJECTED')
      assert_eq(state.dig('delivered_entities', '1:review_submission:s1', 'state'), 'REJECTED')
      assert_eq(state['delivery_receipts'].length, 1)

      unchanged = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
        '1:review_submission:s1' => watch_entity(state: 'REJECTED')
      )
      assert_eq(unchanged['delivered_count'], 0)
      true
    end
  end

  test('first-seen benign state establishes a baseline without alerting') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      entity = watch_entity(
        state: 'READY_FOR_SALE',
        key: '1:app_store_version:v1'
      )
      result = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
        entity['entity_key'] => entity
      )
      state = store.load

      assert_eq(result['pending_count'], 0)
      assert_eq(state.dig('observed_entities', entity['entity_key'], 'state'), 'READY_FOR_SALE')
      assert_eq(state.dig('delivered_entities', entity['entity_key'], 'state'), 'READY_FOR_SALE')
      true
    end
  end

  test('first-seen adverse state alerts instead of becoming a delivered baseline') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      entity = watch_entity(state: 'REJECTED', key: '1:app_store_version:v1')
      result = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
        entity['entity_key'] => entity
      )
      state = store.load

      assert_eq(result['pending_count'], 1)
      assert_eq(state['delivered_entities'].length, 0)
      assert_eq(state['pending_alerts'].values.first.dig('changes', 0, 'state'), 'REJECTED')
      true
    end
  end

  test('migration retains an adverse legacy state as undelivered pending work') do
    Dir.mktmpdir('app-review-watch') do |dir|
      state_path = File.join(dir, 'state.json')
      File.write(state_path, JSON.generate(
        'schema_version' => 1,
        'last_checked_at' => '2026-07-22T00:00:00Z',
        'apps' => {
          '1' => {
            'name' => 'SaneLot',
            'app_store_versions' => { 'v1' => { 'version' => '1.1.0', 'state' => 'REJECTED' } }
          }
        }
      ))
      store = SaneAppReviewWatch::StateStore.new(state_path)
      entity = watch_entity(state: 'REJECTED', key: '1:app_store_version:v1')
      result = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
        entity['entity_key'] => entity
      )
      state = store.load

      assert_eq(result['pending_count'], 1)
      assert_eq(state['delivered_entities'].length, 0)
      assert_eq(state['pending_alerts'].values.first.dig('changes', 0, 'state'), 'REJECTED')
      true
    end
  end

  test('non-terminal receipt stays pending and does not advance delivery') do
    Dir.mktmpdir('app-review-watch') do |dir|
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'))
      receipt = delivered_receipt.merge('delivery_event' => 'bounced')
      result = SaneAppReviewWatch::Engine.new(
        store: store,
        sender: WatchSender.new([receipt])
      ).run('1:review_submission:s1' => watch_entity(state: 'REJECTED'))
      state = store.load

      assert_eq(result['pending_count'], 1)
      assert_eq(state['delivered_entities'].length, 0)
      assert_includes(state['pending_alerts'].values.first['last_error'], 'not verified')
      true
    end
  end

  test('two transitions before delivery remain distinct and ordered') do
    Dir.mktmpdir('app-review-watch') do |dir|
      ticks = [
        Time.utc(2026, 7, 26, 12, 0, 0),
        Time.utc(2026, 7, 26, 12, 1, 0),
        Time.utc(2026, 7, 26, 12, 2, 0),
        Time.utc(2026, 7, 26, 12, 3, 0)
      ]
      now = -> { ticks.shift || Time.utc(2026, 7, 26, 12, 4, 0) }
      store = SaneAppReviewWatch::StateStore.new(File.join(dir, 'state.json'), now: now)
      engine = SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new, now: now)
      engine.run('1:review_submission:s1' => watch_entity(state: 'READY_FOR_REVIEW'))
      engine.run('1:review_submission:s1' => watch_entity(state: 'WAITING_FOR_REVIEW'))
      engine.run('1:review_submission:s1' => watch_entity(state: 'REJECTED'))
      state = store.load

      assert_eq(state['pending_alerts'].length, 2)
      transitions = state['pending_alerts'].values.map do |event|
        change = event['changes'].first
        [change['previous_state'], change['state']]
      end
      assert_includes(transitions, ['READY_FOR_REVIEW', 'WAITING_FOR_REVIEW'])
      assert_includes(transitions, ['WAITING_FOR_REVIEW', 'REJECTED'])
      true
    end
  end

  test('corrupt state fails closed and is not overwritten') do
    Dir.mktmpdir('app-review-watch') do |dir|
      path = File.join(dir, 'state.json')
      File.write(path, '{bad json')
      original = File.binread(path)
      store = SaneAppReviewWatch::StateStore.new(path)
      begin
        SaneAppReviewWatch::Engine.new(store: store, sender: WatchSender.new).run(
          '1:review_submission:s1' => watch_entity(state: 'REJECTED')
        )
        assert(false, 'expected corrupt state to fail closed')
      rescue SaneAppReviewWatch::WatchError
        assert_eq(File.binread(path), original)
      end
      true
    end
  end

  test('internal report rejects accepted but unconfirmed delivery') do
    event = {
      'id' => 'event-1',
      'first_seen_at' => '2026-07-26T12:00:00Z',
      'changes' => [watch_entity(state: 'REJECTED')]
    }
    runner = lambda do |_command, input|
      payload = JSON.parse(input)
      stdout = JSON.generate(
        'event_id' => payload.fetch('event_id'),
        'provider_id' => 'provider-1',
        'delivery_event' => 'sent'
      )
      [stdout, '', ReceiptStatus.new]
    end
    client = SaneInternalReport::Client.new(command: '/bin/true', runner: runner)
    begin
      client.deliver(event)
      assert(false, 'expected unconfirmed delivery to fail')
    rescue SaneInternalReport::DeliveryError => e
      assert_includes(e.message, 'not verified')
    end
    true
  end

  test('internal report transport sends a transition once and returns verified delivery') do
    Dir.mktmpdir('internal-report') do |dir|
      env_path = File.join(dir, 'env')
      wrangler_path = File.join(dir, 'wrangler.toml')
      state_path = File.join(dir, 'state.json')
      File.write(env_path, "export SANE_EMAIL_API_KEY='email-test'\nexport RESEND_API_KEY='resend-test'\n")
      File.write(wrangler_path, "OWNER_EMAIL = \"owner@example.com\"\n")
      sends = 0
      transport = SaneInternalReport::Transport.new(
        state_path: state_path,
        env_path: env_path,
        wrangler_path: wrangler_path,
        sender: lambda { |_envelope, _credentials|
          sends += 1
          'provider-1'
        },
        poller: ->(_provider_id, _credentials) { 'delivered' },
        sleeper: ->(_seconds) {},
        now: -> { Time.utc(2026, 7, 26, 12) }
      )
      event_id = 'a' * 64
      envelope = {
        'kind' => SaneInternalReport::KIND,
        'template_version' => SaneInternalReport::TEMPLATE_VERSION,
        'event_id' => event_id,
        'subject' => 'App Review changed: SaneLot',
        'body' => "Transition detected.\nEvent: #{event_id}"
      }

      first = transport.deliver(envelope)
      second = transport.deliver(envelope)

      assert_eq(sends, 1)
      assert_eq(first['delivery_event'], 'delivered')
      assert_eq(second['provider_id'], 'provider-1')
      assert_eq(File.stat(state_path).mode & 0o777, 0o600)
      true
    end
  end

  test('internal report transport preserves an accepted provider id across an unconfirmed retry') do
    Dir.mktmpdir('internal-report') do |dir|
      env_path = File.join(dir, 'env')
      wrangler_path = File.join(dir, 'wrangler.toml')
      state_path = File.join(dir, 'state.json')
      File.write(env_path, "EMAIL_API_KEY=email-test\nRESEND_API_KEY=resend-test\n")
      File.write(wrangler_path, "OWNER_EMAIL = \"owner@example.com\"\n")
      sends = 0
      delivered = false
      transport = SaneInternalReport::Transport.new(
        state_path: state_path,
        env_path: env_path,
        wrangler_path: wrangler_path,
        sender: lambda { |_envelope, _credentials|
          sends += 1
          'provider-accepted'
        },
        poller: ->(_provider_id, _credentials) { delivered ? 'delivered' : 'sent' },
        sleeper: ->(_seconds) {}
      )
      event_id = 'b' * 64
      envelope = {
        'kind' => SaneInternalReport::KIND,
        'template_version' => SaneInternalReport::TEMPLATE_VERSION,
        'event_id' => event_id,
        'subject' => 'SaneApps App Review changed',
        'body' => "Transition detected.\nEvent: #{event_id}"
      }

      begin
        transport.deliver(envelope)
        assert(false, 'expected unconfirmed delivery to remain retryable')
      rescue SaneInternalReport::DeliveryError => e
        assert_includes(e.message, 'not yet verified')
      end
      delivered = true
      receipt = transport.deliver(envelope)

      assert_eq(sends, 1)
      assert_eq(receipt['delivery_event'], 'delivered')
      assert_eq(JSON.parse(File.read(state_path)).dig(event_id, 'provider_id'), 'provider-accepted')
      true
    end
  end
end)
