#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'socket'
require 'tempfile'
require 'time'
require 'yaml'

require_relative 'internal_report'

module SaneAppReviewWatch
  SCHEMA_VERSION = 2
  DEFAULT_STATE_PATH = File.expand_path('~/SaneApps/outputs/app-review-watch-state.json')
  DEFAULT_ASC_SCRIPT = File.expand_path('~/SaneApps/apps/SaneLot/scripts/asc.rb')
  DEFAULT_APPS_ROOT = File.expand_path('~/SaneApps/apps')
  ADVERSE_STATES = %w[REJECTED UNRESOLVED_ISSUES].freeze

  class WatchError < StandardError; end

  module_function
  def mini_host?(hostname = Socket.gethostname)
    hostname.to_s.downcase.include?('mini')
  end

  def entity_key(app_id, type, id)
    [app_id, type, id].join(':')
  end

  def adverse_state?(state)
    ADVERSE_STATES.include?(state.to_s)
  end

  def pending_event(changes, at:)
    fingerprint = changes.sort_by { |change| change.fetch('entity_key') }.map do |change|
      [change.fetch('entity_key'), change['previous_state'], change.fetch('state')]
    end
    id = Digest::SHA256.hexdigest(JSON.generate(fingerprint))
    {
      'id' => id,
      'kind' => SaneInternalReport::KIND,
      'template_version' => SaneInternalReport::TEMPLATE_VERSION,
      'first_seen_at' => at.iso8601,
      'last_attempt_at' => nil,
      'attempt_count' => 0,
      'last_error' => nil,
      'changes' => changes
    }
  end

  class Snapshot
    attr_reader :entities, :complete_scopes, :diagnostics, :app_ids

    def initialize(entities:, complete_scopes:, diagnostics:, app_ids:, catalog_complete:)
      @entities = entities
      @complete_scopes = complete_scopes
      @diagnostics = diagnostics
      @app_ids = app_ids.map(&:to_s)
      @catalog_complete = catalog_complete
    end

    def catalog_complete?
      @catalog_complete
    end

    def complete_scope?(entity)
      @complete_scopes.include?(SaneAppReviewWatch.entity_scope(entity))
    end
  end

  def entity_scope(entity)
    [entity.fetch('app_id').to_s, entity.fetch('entity_type').to_s].join(':')
  end

  class AppCatalog
    def initialize(apps_root: DEFAULT_APPS_ROOT)
      @apps_root = File.expand_path(apps_root)
    end

    def apps
      Dir.glob(File.join(@apps_root, '*', '.saneprocess')).sort.each_with_object({}) do |path, result|
        config = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8), aliases: true)
        next unless config.is_a?(Hash)

        app_id = (config.dig('appstore', 'app_id') || config.dig('app_store', 'app_id')).to_s.strip
        next unless app_id.match?(/\A\d+\z/)

        name = config['name'].to_s.strip
        name = File.basename(File.dirname(path)) if name.empty?
        result[app_id] ||= name
      rescue Psych::Exception, SystemCallError
        next
      end
    end
  end

  def flatten_legacy_apps(apps)
    entities = {}
    Hash(apps).each do |app_id, app|
      app_name = app['name'].to_s
      Hash(app['review_submissions']).each do |id, attrs|
        key = entity_key(app_id, 'review_submission', id)
        entities[key] = {
          'entity_key' => key, 'entity_type' => 'review_submission', 'entity_id' => id,
          'app_id' => app_id, 'app_name' => app_name, 'state' => attrs['state'].to_s,
          'submitted_date' => attrs['submitted_date']
        }
      end
      Hash(app['app_store_versions']).each do |id, attrs|
        key = entity_key(app_id, 'app_store_version', id)
        entities[key] = {
          'entity_key' => key, 'entity_type' => 'app_store_version', 'entity_id' => id,
          'app_id' => app_id, 'app_name' => app_name, 'state' => attrs['state'].to_s,
          'version' => attrs['version']
        }
      end
    end
    entities
  end

  class StateStore
    def initialize(path, now: -> { Time.now.utc })
      @path = File.expand_path(path)
      @now = now
    end

    attr_reader :path

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        raise WatchError, "another App Review watch owns #{@path}.lock" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def load
      return empty_state unless File.exist?(@path)

      raw = JSON.parse(File.read(@path, encoding: Encoding::UTF_8))
      return validate_v2!(raw) if raw['schema_version'].to_i == SCHEMA_VERSION
      return migrate_v1(raw) if raw['schema_version'].to_i == 1

      raise WatchError, "unsupported App Review state schema #{raw['schema_version'].inspect}"
    rescue JSON::ParserError => e
      raise WatchError, "App Review state is invalid JSON: #{e.message}"
    end

    def save(state)
      validate_v2!(state)
      FileUtils.mkdir_p(File.dirname(@path))
      Tempfile.create(['app-review-watch-state', '.json'], File.dirname(@path)) do |tmp|
        tmp.chmod(0o600)
        tmp.write(JSON.pretty_generate(state))
        tmp.write("\n")
        tmp.flush
        tmp.fsync
        File.rename(tmp.path, @path)
      end
    end

    private

    def empty_state
      {
        'schema_version' => SCHEMA_VERSION,
        'last_checked_at' => nil,
        'observed_entities' => {},
        'delivered_entities' => {},
        'pending_alerts' => {},
        'delivery_receipts' => {}
      }
    end

    def migrate_v1(raw)
      entities = SaneAppReviewWatch.flatten_legacy_apps(raw['apps'])
      delivered = entities.reject { |_key, entity| SaneAppReviewWatch.adverse_state?(entity['state']) }
      state = empty_state.merge(
        'last_checked_at' => raw['last_checked_at'],
        'observed_entities' => entities,
        'delivered_entities' => Marshal.load(Marshal.dump(delivered))
      )
      adverse = entities.values.select { |entity| SaneAppReviewWatch.adverse_state?(entity['state']) }
      unless adverse.empty?
        event = SaneAppReviewWatch.pending_event(
          adverse.map { |entity| entity.merge('previous_state' => nil) },
          at: @now.call
        )
        state.fetch('pending_alerts')[event.fetch('id')] = event
      end
      state
    end

    def validate_v2!(state)
      raise WatchError, 'App Review state must be a JSON object' unless state.is_a?(Hash)
      raise WatchError, "App Review state schema must be #{SCHEMA_VERSION}" unless state['schema_version'].to_i == SCHEMA_VERSION
      %w[observed_entities delivered_entities pending_alerts delivery_receipts].each do |field|
        raise WatchError, "App Review state #{field} must be an object" unless state[field].is_a?(Hash)
      end
      state
    end
  end

  class AscClient
    def initialize(script: DEFAULT_ASC_SCRIPT, runner: nil, app_catalog: AppCatalog.new)
      @script = File.expand_path(script)
      @runner = runner || Open3.method(:capture3)
      @app_catalog = app_catalog
    end

    def snapshot
      raise WatchError, "ASC helper is missing: #{@script}" unless File.file?(@script)

      entities = {}
      complete_scopes = []
      diagnostics = []
      apps, catalog_complete = discover_apps(diagnostics)
      apps.each do |app_id, app_name|
        items_complete = true
        begin
          submissions = get("/v1/reviewSubmissions?filter[app]=#{app_id}&limit=3&fields[reviewSubmissions]=state,submittedDate")
          Array(submissions['data']).each do |submission|
            attrs = submission['attributes'] || {}
            add_entity(entities, app_id, app_name, 'review_submission', submission.fetch('id'), attrs['state'],
                       'submitted_date' => attrs['submittedDate'], 'submission_id' => submission.fetch('id'))
            begin
              items = get("/v1/reviewSubmissions/#{submission.fetch('id')}/items?limit=200&fields[reviewSubmissionItems]=state")
              Array(items['data']).each do |item|
                add_entity(entities, app_id, app_name, 'review_submission_item', item.fetch('id'),
                           item.dig('attributes', 'state'), 'submission_id' => submission.fetch('id'))
              end
            rescue WatchError => e
              items_complete = false
              diagnostics << lane_diagnostic('review_submission_items', e, app_id, app_name,
                                             'submission_id' => submission.fetch('id').to_s)
            end
          end
          complete_scopes << "#{app_id}:review_submission"
          complete_scopes << "#{app_id}:review_submission_item" if items_complete
        rescue WatchError => e
          diagnostics << lane_diagnostic('review_submissions', e, app_id, app_name)
        end

        begin
          versions = get("/v1/apps/#{app_id}/appStoreVersions?limit=20&fields[appStoreVersions]=versionString,appStoreState,platform")
          Array(versions['data']).each do |version|
            attrs = version['attributes'] || {}
            add_entity(entities, app_id, app_name, 'app_store_version', version.fetch('id'), attrs['appStoreState'],
                       'version' => attrs['versionString'], 'platform' => attrs['platform'])
          end
          complete_scopes << "#{app_id}:app_store_version"
        rescue WatchError => e
          diagnostics << lane_diagnostic('app_store_versions', e, app_id, app_name)
        end
      end
      Snapshot.new(
        entities: entities,
        complete_scopes: complete_scopes,
        diagnostics: diagnostics,
        app_ids: apps.keys,
        catalog_complete: catalog_complete
      )
    end

    private

    def discover_apps(diagnostics)
      remote = get('/v1/apps?fields[apps]=name&limit=200').fetch('data').each_with_object({}) do |app, result|
        result[app.fetch('id').to_s] = app.dig('attributes', 'name').to_s
      end
      [remote, true]
    rescue WatchError => e
      local = @app_catalog.apps
      diagnostics << {
        'lane' => 'app_discovery',
        'scope' => 'all_apps',
        'error' => e.message.to_s[0, 500],
        'fallback' => 'local_saneprocess',
        'fallback_app_count' => local.length
      }
      [local, false]
    end

    def lane_diagnostic(lane, error, app_id, app_name, extra = {})
      {
        'lane' => lane,
        'app_id' => app_id.to_s,
        'app_name' => app_name.to_s,
        'error' => error.message.to_s[0, 500]
      }.merge(extra)
    end

    def get(path)
      stdout, stderr, status = @runner.call(RbConfig.ruby, @script, 'GET', path)
      raise WatchError, "ASC GET failed for #{path}: #{stderr.to_s.strip}" unless status.success?

      status_line, body = stdout.to_s.split(/\r?\n/, 2)
      match = status_line.to_s.match(/\AHTTP (\d{3})\z/)
      raise WatchError, "ASC GET returned a malformed HTTP status for #{path}" unless match

      http_status = match[1].to_i
      raise WatchError, "ASC GET returned HTTP #{http_status} for #{path}" unless (200..299).cover?(http_status)
      raise WatchError, "ASC GET returned an empty body for #{path}" if body.to_s.strip.empty?

      parsed = JSON.parse(body)
      raise WatchError, "ASC GET returned no data for #{path}" unless parsed.is_a?(Hash) && parsed['data'].is_a?(Array)

      parsed
    rescue JSON::ParserError => e
      raise WatchError, "ASC GET returned invalid JSON for #{path}: #{e.message}"
    end

    def add_entity(entities, app_id, app_name, type, id, state, extra = {})
      return if state.to_s.empty?

      key = SaneAppReviewWatch.entity_key(app_id, type, id)
      entities[key] = {
        'entity_key' => key, 'entity_type' => type, 'entity_id' => id.to_s,
        'app_id' => app_id, 'app_name' => app_name, 'state' => state.to_s
      }.merge(extra)
    end
  end

  class Engine
    def initialize(store:, sender:, now: -> { Time.now.utc })
      @store = store
      @sender = sender
      @now = now
    end

    def run(snapshot)
      @store.with_lock do
        state = @store.load
        current, diagnostics = current_entities(state, snapshot)
        changes = detect_changes(state, current)
        enqueue(state, changes) unless changes.empty?
        state['observed_entities'] = current
        state['last_checked_at'] = @now.call.iso8601
        @store.save(state)
        delivered = deliver_pending(state)
        @store.save(state)
        result(state, diagnostics, delivered)
      end
    end

    private

    def current_entities(state, snapshot)
      return [normalize_entities(snapshot), []] unless snapshot.is_a?(Snapshot)
      current = normalize_entities(snapshot.entities)
      state.fetch('observed_entities').each do |key, entity|
        app_still_in_scope = snapshot.app_ids.include?(entity['app_id'].to_s) || !snapshot.catalog_complete?
        next unless app_still_in_scope
        next if snapshot.complete_scope?(entity)

        current[key] ||= entity
      end
      [current, snapshot.diagnostics]
    end

    def normalize_entities(entities)
      raise WatchError, 'current App Review entities must be an object' unless entities.is_a?(Hash)

      entities.each_with_object({}) do |(key, entity), memo|
        raise WatchError, "App Review entity #{key} must be an object" unless entity.is_a?(Hash)
        raise WatchError, "App Review entity #{key} has no state" if entity['state'].to_s.empty?
        raise WatchError, "App Review entity key mismatch for #{key}" unless entity['entity_key'].to_s == key
        memo[key] = entity
      end
    end

    def detect_changes(state, current)
      observed = state.fetch('observed_entities')
      delivered = state.fetch('delivered_entities')
      current.each_with_object([]) do |(key, entity), changes|
        previous = observed[key]
        unless previous
          next if delivered.dig(key, 'state').to_s == entity['state'].to_s
          next if pending_state?(state, key, entity['state'])

          if SaneAppReviewWatch.adverse_state?(entity['state'])
            changes << entity.merge('previous_state' => nil)
          else
            delivered[key] = entity
          end
          next
        end
        next if previous && previous['state'].to_s == entity['state'].to_s
        next if delivered[key] && delivered[key]['state'].to_s == entity['state'].to_s
        next if pending_state?(state, key, entity['state'])

        changes << entity.merge('previous_state' => previous&.dig('state'))
      end
    end

    def pending_state?(state, entity_key, entity_state)
      state.fetch('pending_alerts').values.any? do |event|
        event.fetch('changes').any? do |change|
          change['entity_key'].to_s == entity_key.to_s && change['state'].to_s == entity_state.to_s
        end
      end
    end

    def enqueue(state, changes)
      event = SaneAppReviewWatch.pending_event(changes, at: @now.call)
      state.fetch('pending_alerts')[event.fetch('id')] ||= event
    end

    def deliver_pending(state)
      delivered = []
      state.fetch('pending_alerts').values.sort_by { |event| event.fetch('first_seen_at') }.each do |event|
        event['attempt_count'] = event['attempt_count'].to_i + 1
        event['last_attempt_at'] = @now.call.iso8601
        begin
          receipt = @sender.deliver(event)
          SaneInternalReport.validate_delivery_receipt!(receipt, event.fetch('id'))
          event.fetch('changes').each do |change|
            state.fetch('delivered_entities')[change.fetch('entity_key')] = change.reject { |key, _| key == 'previous_state' }
          end
          state.fetch('delivery_receipts')[event.fetch('id')] = receipt
          delivered << {
            'id' => event.fetch('id'),
            'delivered_at' => receipt.fetch('delivered_at'),
            'apps' => event.fetch('changes').map { |change| change.fetch('app_name') }.uniq.sort,
            'changes' => event.fetch('changes').map do |change|
              change.slice('app_name', 'entity_type', 'previous_state', 'state', 'version', 'platform')
            end
          }
          state.fetch('pending_alerts').delete(event.fetch('id'))
          @store.save(state)
        rescue SaneInternalReport::DeliveryError, StandardError => e
          event['last_error'] = e.message.to_s[0, 500]
          @store.save(state)
        end
      end
      delivered
    end

    def result(state, diagnostics, delivered)
      pending = state.fetch('pending_alerts').values
      status =
        if diagnostics.any? && pending.any?
          'partial_pending_alerts'
        elsif diagnostics.any?
          'partial'
        elsif pending.any?
          'pending_alerts'
        else
          'ok'
        end
      {
        'status' => status,
        'last_checked_at' => state['last_checked_at'],
        'delivered_count' => delivered.length,
        'delivered' => delivered,
        'pending_count' => pending.length,
        'diagnostics' => diagnostics,
        'pending' => pending.map do |event|
          {
            'id' => event['id'],
            'first_seen_at' => event['first_seen_at'],
            'attempt_count' => event['attempt_count'],
            'last_error' => event['last_error'],
            'apps' => event.fetch('changes').map { |change| change['app_name'] }.uniq.sort
          }
        end
      }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    options = {
      state: SaneAppReviewWatch::DEFAULT_STATE_PATH,
      snapshot: nil,
      allow_non_mini: false
    }
    OptionParser.new do |opts|
      opts.banner = 'Usage: app_review_watch.rb [--state PATH] [--snapshot PATH]'
      opts.on('--state PATH', 'Durable state path') { |value| options[:state] = value }
      opts.on('--snapshot PATH', 'Read-only fixture snapshot (tests/dry runs)') { |value| options[:snapshot] = value }
      opts.on('--allow-non-mini', 'Tests only: allow a non-Mini host') { options[:allow_non_mini] = true }
    end.parse!

    unless options[:allow_non_mini] || SaneAppReviewWatch.mini_host?
      raise SaneAppReviewWatch::WatchError, 'App Review watch is Mini-only'
    end

    entities =
      if options[:snapshot]
        payload = JSON.parse(File.read(options[:snapshot], encoding: Encoding::UTF_8))
        payload.fetch('entities')
      else
        SaneAppReviewWatch::AscClient.new.snapshot
      end
    store = SaneAppReviewWatch::StateStore.new(options[:state])
    sender = SaneInternalReport::Client.new
    result = SaneAppReviewWatch::Engine.new(store: store, sender: sender).run(entities)
    puts JSON.pretty_generate(result)
    exit(result['pending_count'].positive? || result['diagnostics'].any? ? 2 : 0)
  rescue SaneAppReviewWatch::WatchError, JSON::ParserError, KeyError, SystemCallError => e
    warn "app_review_watch: #{e.message}"
    exit 2
  end
end
