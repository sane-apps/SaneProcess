#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'net/http'
require 'optparse'
require 'shellwords'
require 'socket'
require 'tempfile'
require 'time'
require 'uri'

require_relative 'app_review_watch'

module SaneCwsReviewWatch
  DEFAULT_STATE_PATH = File.expand_path('~/SaneApps/outputs/cws-review-watch-state.json')
  DEFAULT_RECEIPT_PATH = File.expand_path('~/SaneApps/outputs/cws-review-watch-receipt.json')
  DEFAULT_ITEM_ID = 'ihhnhedfjfjplodfhacompiahlnjbpeb'
  DEFAULT_ITEM_NAME = 'SaneLot Auction Pricing'
  DEFAULT_ENV_PATH = File.expand_path('~/.config/nv/env')
  ENV_NAMES = %w[
    SANE_CWS_PUBLISHER_ID
    SANE_CWS_ACCESS_TOKEN
    SANE_CWS_CLIENT_ID
    SANE_CWS_CLIENT_SECRET
    SANE_CWS_REFRESH_TOKEN
  ].freeze
  TOKEN_URI = URI('https://oauth2.googleapis.com/token')
  API_ORIGIN = 'https://chromewebstore.googleapis.com'

  class Client
    def initialize(publisher_id:, item_id: DEFAULT_ITEM_ID, item_name: DEFAULT_ITEM_NAME,
                   access_token: ENV['SANE_CWS_ACCESS_TOKEN'],
                   client_id: ENV['SANE_CWS_CLIENT_ID'], client_secret: ENV['SANE_CWS_CLIENT_SECRET'],
                   refresh_token: ENV['SANE_CWS_REFRESH_TOKEN'], requester: nil)
      @publisher_id = publisher_id.to_s.strip
      @item_id = item_id.to_s.strip
      @item_name = item_name.to_s.strip
      @direct_access_token = access_token.to_s.strip
      @client_id = client_id.to_s.strip
      @client_secret = client_secret.to_s.strip
      @refresh_token = refresh_token.to_s.strip
      @requester = requester || method(:perform_request)
      validate_identifiers!
    end

    def snapshot
      uri = URI("#{API_ORIGIN}/v2/publishers/#{@publisher_id}/items/#{@item_id}:fetchStatus")
      response = @requester.call(
        method: :get,
        uri: uri,
        headers: { 'Authorization' => "Bearer #{access_token}" },
        body: nil
      )
      payload = parse_response(response, lane: 'fetchStatus')
      snapshot_from_payload(payload)
    end

    def snapshot_from_payload(payload)
      raise SaneAppReviewWatch::WatchError, 'CWS status response must be a JSON object' unless payload.is_a?(Hash)
      raise SaneAppReviewWatch::WatchError, 'CWS status item id mismatch' unless payload['itemId'].to_s == @item_id

      submitted = payload['submittedItemRevisionStatus']
      published = payload['publishedItemRevisionStatus']
      revision = submitted.is_a?(Hash) ? submitted : published
      raise SaneAppReviewWatch::WatchError, 'CWS status response has no submitted or published revision' unless revision.is_a?(Hash)

      revision_state = revision['state'].to_s
      raise SaneAppReviewWatch::WatchError, 'CWS status response has no item state' if revision_state.empty?
      state =
        if payload['takenDown'] == true
          'TAKEN_DOWN'
        elsif payload['warned'] == true
          'WARNED'
        else
          revision_state
        end

      versions = Array(revision['distributionChannels']).filter_map do |channel|
        channel['crxVersion'].to_s.strip if channel.is_a?(Hash)
      end.reject(&:empty?).uniq.sort
      key = SaneAppReviewWatch.entity_key(@item_id, 'chrome_web_store_submission', @item_id)
      entity = {
        'entity_key' => key,
        'entity_type' => 'chrome_web_store_submission',
        'entity_id' => @item_id,
        'app_id' => @item_id,
        'app_name' => @item_name,
        'state' => state,
        'revision_state' => revision_state,
        'version' => versions.join(','),
        'platform' => 'CHROME_WEB_STORE',
        'taken_down' => payload['takenDown'] == true,
        'warned' => payload['warned'] == true,
        'upload_state' => payload['lastAsyncUploadState'].to_s
      }
      SaneAppReviewWatch::Snapshot.new(
        entities: { key => entity },
        complete_scopes: [SaneAppReviewWatch.entity_scope(entity)],
        diagnostics: [],
        app_ids: [@item_id],
        catalog_complete: true
      )
    end

    private

    def validate_identifiers!
      unless @publisher_id.match?(/\A[a-zA-Z0-9._-]+\z/)
        raise SaneAppReviewWatch::WatchError, 'CWS publisher id is missing or invalid'
      end
      unless @item_id.match?(/\A[a-z]{32}\z/)
        raise SaneAppReviewWatch::WatchError, 'CWS item id is missing or invalid'
      end
      raise SaneAppReviewWatch::WatchError, 'CWS item name is missing' if @item_name.empty?
    end

    def access_token
      refresh_values = {
        'SANE_CWS_CLIENT_ID' => @client_id,
        'SANE_CWS_REFRESH_TOKEN' => @refresh_token
      }
      missing = refresh_values.select { |_name, value| value.empty? }.keys
      return refresh_access_token if missing.empty?
      return @direct_access_token unless @direct_access_token.empty?

      unless missing.empty?
        raise SaneAppReviewWatch::WatchError,
              "CWS OAuth credential is unavailable (missing #{missing.join(', ')})"
      end
    end

    def refresh_access_token
      fields = {
        client_id: @client_id,
        refresh_token: @refresh_token,
        grant_type: 'refresh_token'
      }
      fields[:client_secret] = @client_secret unless @client_secret.empty?
      response = @requester.call(
        method: :post,
        uri: TOKEN_URI,
        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
        body: URI.encode_www_form(fields)
      )
      payload = parse_response(response, lane: 'OAuth refresh')
      token = payload['access_token'].to_s
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth refresh returned no access token' if token.empty?

      token
    end

    def parse_response(response, lane:)
      code = response.fetch(:code).to_i
      unless (200..299).cover?(code)
        raise SaneAppReviewWatch::WatchError, "CWS #{lane} returned HTTP #{code}"
      end
      body = response.fetch(:body).to_s
      raise SaneAppReviewWatch::WatchError, "CWS #{lane} returned an empty body" if body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      raise SaneAppReviewWatch::WatchError, "CWS #{lane} returned invalid JSON", cause: nil
    end

    def perform_request(method:, uri:, headers:, body:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20
      request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body
      response = http.request(request)
      { code: response.code.to_i, body: response.body.to_s }
    rescue SocketError, SystemCallError, Timeout::Error => e
      raise SaneAppReviewWatch::WatchError, "CWS request failed: #{e.class}"
    end
  end

  module_function

  def credential_configuration(process_env: ENV, env_path: DEFAULT_ENV_PATH)
    credential_configuration_with_sources(process_env: process_env, env_path: env_path).fetch(:configuration)
  end

  def credential_configuration_with_sources(process_env: ENV, env_path: DEFAULT_ENV_PATH)
    cached = read_env_cache(env_path)
    configuration = {}
    sources = {}
    ENV_NAMES.each do |name|
      process_value = process_env[name].to_s
      cached_value = cached[name].to_s
      if !process_value.empty?
        configuration[name] = process_value
        sources[name] = 'process_env'
      elsif !cached_value.empty?
        configuration[name] = cached_value
        sources[name] = 'private_cache'
      else
        configuration[name] = ''
        sources[name] = 'missing'
      end
    end
    { configuration: configuration, sources: sources }
  end

  def read_env_cache(path)
    expanded = File.expand_path(path)
    return {} unless File.file?(expanded)
    raise SaneAppReviewWatch::WatchError, 'CWS environment cache must not be a symlink' if File.symlink?(expanded)
    if (File.stat(expanded).mode & 0o077).positive?
      raise SaneAppReviewWatch::WatchError, 'CWS environment cache permissions must be private'
    end

    File.foreach(expanded, chomp: true).each_with_object({}) do |line, result|
      match = line.match(/\A\s*(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)\z/)
      next unless match && ENV_NAMES.include?(match[1])

      values = Shellwords.split(match[2])
      result[match[1]] = values.first.to_s if values.length == 1
    rescue ArgumentError
      next
    end
  rescue SystemCallError => e
    raise SaneAppReviewWatch::WatchError, "CWS environment cache is unavailable: #{e.class}"
  end

  def credential_mode(configuration)
    refresh_names = %w[SANE_CWS_CLIENT_ID SANE_CWS_REFRESH_TOKEN]
    missing = refresh_names.select { |name| configuration[name].to_s.empty? }
    return 'refresh_token' if missing.empty?
    return 'access_token' unless configuration['SANE_CWS_ACCESS_TOKEN'].to_s.empty?

    unless missing.empty?
      raise SaneAppReviewWatch::WatchError,
            "CWS OAuth credential is unavailable (missing #{missing.join(', ')})"
    end
  end

  def configuration_diagnostic(configuration)
    publisher_id = configuration['SANE_CWS_PUBLISHER_ID'].to_s.strip
    unless publisher_id.match?(/\A[a-zA-Z0-9._-]+\z/)
      code = publisher_id.empty? ? 'publisher_id_missing' : 'publisher_id_invalid'
      return {
        'status' => 'blocked',
        'stage' => 'configuration',
        'error_code' => code,
        'publisher_id' => publisher_id.empty? ? 'missing' : 'invalid',
        'credential_mode' => 'unavailable',
        'missing_configuration' => ['SANE_CWS_PUBLISHER_ID']
      }
    end

    refresh_names = %w[SANE_CWS_CLIENT_ID SANE_CWS_REFRESH_TOKEN]
    missing = refresh_names.select { |name| configuration[name].to_s.empty? }
    mode = if missing.empty?
             'refresh_token'
           elsif !configuration['SANE_CWS_ACCESS_TOKEN'].to_s.empty?
             'access_token'
           else
             'unavailable'
           end
    return {
      'status' => 'blocked',
      'stage' => 'configuration',
      'error_code' => 'oauth_missing',
      'publisher_id' => 'configured',
      'credential_mode' => mode,
      'missing_configuration' => missing
    } if mode == 'unavailable'

    {
      'status' => 'ready',
      'stage' => 'configuration',
      'error_code' => nil,
      'publisher_id' => 'configured',
      'credential_mode' => mode,
      'missing_configuration' => []
    }
  end

  def configuration_receipt(configuration:, sources:, official_get:, now: Time.now.utc)
    diagnostic = configuration_diagnostic(configuration)
    {
      'schema_version' => 1,
      'checked_at' => now.iso8601,
      'status' => diagnostic.fetch('status'),
      'stage' => diagnostic.fetch('stage'),
      'error_code' => diagnostic['error_code'],
      'publisher_id' => diagnostic.fetch('publisher_id'),
      'credential_mode' => diagnostic.fetch('credential_mode'),
      'official_get' => official_get,
      'missing_configuration' => diagnostic.fetch('missing_configuration'),
      'configuration_sources' => ENV_NAMES.to_h { |name| [name, sources.fetch(name, 'missing')] }
    }
  end

  def write_receipt(path, receipt)
    expanded = File.expand_path(path)
    raise SaneAppReviewWatch::WatchError, 'CWS watcher receipt path must not be a symlink' if File.symlink?(expanded)

    directory = File.dirname(expanded)
    FileUtils.mkdir_p(directory, mode: 0o700)
    Tempfile.create(['cws-review-watch-receipt', '.json'], directory) do |temporary|
      temporary.chmod(0o600)
      temporary.write(JSON.pretty_generate(receipt))
      temporary.write("\n")
      temporary.flush
      temporary.fsync
      File.rename(temporary.path, expanded)
    end
    File.chmod(0o600, expanded)
    expanded
  rescue SystemCallError => e
    raise SaneAppReviewWatch::WatchError, "CWS watcher receipt is unavailable: #{e.class}"
  end

  def failure_classification(error)
    message = error.message.to_s
    return ['configuration', 'configuration_blocked'] if message.include?('configuration is blocked')
    return ['oauth', 'oauth_failed'] if message.include?('OAuth')
    return ['status_get', 'status_get_failed'] if message.include?('fetchStatus') || message.include?('request failed')
    return ['alert_delivery', 'alert_delivery_pending'] if message.include?('delivery')

    ['watcher', 'watcher_failed']
  end

  def store_env_value_from_stdin(name, input: $stdin, env_path: DEFAULT_ENV_PATH)
    raise SaneAppReviewWatch::WatchError, 'CWS credential name is not allowlisted' unless ENV_NAMES.include?(name)

    value = input.read(16_385)
    if value.bytesize > 16_384 || value.include?("\0") || value.lines.length > 1
      raise SaneAppReviewWatch::WatchError, 'CWS credential input is invalid'
    end
    value = value.strip
    raise SaneAppReviewWatch::WatchError, 'CWS credential input is empty' if value.empty?

    path = File.expand_path(env_path)
    if File.exist?(path)
      raise SaneAppReviewWatch::WatchError, 'CWS environment cache must not be a symlink' if File.symlink?(path)
      raise SaneAppReviewWatch::WatchError, 'CWS environment cache must be a regular file' unless File.file?(path)
      if (File.stat(path).mode & 0o077).positive?
        raise SaneAppReviewWatch::WatchError, 'CWS environment cache permissions must be private'
      end
    end

    directory = File.dirname(path)
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    lines = File.exist?(path) ? File.readlines(path, chomp: true, encoding: Encoding::UTF_8) : []
    assignment = /\A\s*(?:export\s+)?#{Regexp.escape(name)}=/
    lines.reject! { |line| line.match?(assignment) }
    lines << "export #{name}=#{Shellwords.escape(value)}"

    temporary = File.join(directory, ".#{File.basename(path)}.cws-#{Process.pid}-#{rand(1_000_000)}")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(lines.join("\n") + "\n")
      file.flush
      file.fsync
    end
    File.chmod(0o600, temporary)
    File.rename(temporary, path)
    { 'status' => 'stored', 'name' => name, 'value' => 'redacted' }
  rescue SystemCallError => e
    raise SaneAppReviewWatch::WatchError, "CWS environment cache update failed: #{e.class}"
  ensure
    File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def health(configuration:, item_id: DEFAULT_ITEM_ID, item_name: DEFAULT_ITEM_NAME,
             official_get: false, requester: nil)
    client = Client.new(
      publisher_id: configuration['SANE_CWS_PUBLISHER_ID'],
      item_id: item_id,
      item_name: item_name,
      access_token: configuration['SANE_CWS_ACCESS_TOKEN'],
      client_id: configuration['SANE_CWS_CLIENT_ID'],
      client_secret: configuration['SANE_CWS_CLIENT_SECRET'],
      refresh_token: configuration['SANE_CWS_REFRESH_TOKEN'],
      requester: requester
    )
    result = {
      'status' => 'ok',
      'publisher_id' => 'configured',
      'credential_mode' => credential_mode(configuration),
      'official_get' => official_get ? 'pending' : 'skipped'
    }
    return result unless official_get

    entity = client.snapshot.entities.values.fetch(0)
    result.merge(
      'official_get' => 'ok',
      'revision_state' => entity['revision_state'],
      'version' => entity['version']
    )
  end

  def mini_host?(hostname = Socket.gethostname)
    SaneAppReviewWatch.mini_host?(hostname)
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    configuration_details = SaneCwsReviewWatch.credential_configuration_with_sources
    configuration = configuration_details.fetch(:configuration)
    configuration_sources = configuration_details.fetch(:sources)
    options = {
      state: SaneCwsReviewWatch::DEFAULT_STATE_PATH,
      receipt: SaneCwsReviewWatch::DEFAULT_RECEIPT_PATH,
      publisher_id: configuration['SANE_CWS_PUBLISHER_ID'],
      item_id: SaneCwsReviewWatch::DEFAULT_ITEM_ID,
      item_name: SaneCwsReviewWatch::DEFAULT_ITEM_NAME,
      health: false,
      health_get: false,
      store_stdin: nil,
      publisher_id_overridden: false
    }
    OptionParser.new do |opts|
      opts.banner = 'Usage: cws_review_watch.rb --publisher-id ID [--item-id ID] [--item-name NAME] [--state PATH]'
      opts.on('--publisher-id ID', 'Chrome Web Store publisher ID') do |value|
        options[:publisher_id] = value
        options[:publisher_id_overridden] = true
      end
      opts.on('--item-id ID', 'Chrome Web Store item ID') { |value| options[:item_id] = value }
      opts.on('--item-name NAME', 'Human-readable item name') { |value| options[:item_name] = value }
      opts.on('--state PATH', 'Durable state path') { |value| options[:state] = value }
      opts.on('--receipt PATH', 'Redacted durable configuration/status receipt') { |value| options[:receipt] = value }
      opts.on('--health', 'Validate redacted local configuration without GET, state, or alert delivery') do
        options[:health] = true
      end
      opts.on('--health-get', 'Validate configuration and perform the official read-only status GET') do
        options[:health] = true
        options[:health_get] = true
      end
      opts.on('--store-stdin NAME', SaneCwsReviewWatch::ENV_NAMES,
              'Store one allowlisted CWS value from stdin in the private env cache') do |value|
        options[:store_stdin] = value
      end
    end.parse!

    unless SaneCwsReviewWatch.mini_host?
      raise SaneAppReviewWatch::WatchError, 'CWS review watch is Mini-only'
    end

    configuration['SANE_CWS_PUBLISHER_ID'] = options[:publisher_id].to_s
    if options[:publisher_id_overridden]
      configuration_sources['SANE_CWS_PUBLISHER_ID'] = 'command_line'
    end
    if options[:store_stdin]
      puts JSON.generate(SaneCwsReviewWatch.store_env_value_from_stdin(options[:store_stdin]))
      exit 0
    end
    configuration_receipt = SaneCwsReviewWatch.configuration_receipt(
      configuration: configuration,
      sources: configuration_sources,
      official_get: (options[:health_get] || !options[:health]) ? 'pending' : 'skipped'
    )
    SaneCwsReviewWatch.write_receipt(options[:receipt], configuration_receipt)
    if configuration_receipt['status'] == 'blocked'
      raise SaneAppReviewWatch::WatchError,
            "CWS watcher configuration is blocked (#{configuration_receipt.fetch('error_code')})"
    end
    if options[:health]
      result = SaneCwsReviewWatch.health(
        configuration: configuration,
        item_id: options[:item_id],
        item_name: options[:item_name],
        official_get: options[:health_get]
      )
      configuration_receipt['status'] = 'ok'
      configuration_receipt['stage'] = options[:health_get] ? 'status_get' : 'configuration'
      configuration_receipt['official_get'] = result.fetch('official_get')
      configuration_receipt['revision_state'] = result['revision_state'] if result['revision_state']
      configuration_receipt['version'] = result['version'] if result['version']
      configuration_receipt['error_code'] = nil
      SaneCwsReviewWatch.write_receipt(options[:receipt], configuration_receipt)
      puts JSON.pretty_generate(result)
      exit 0
    end

    snapshot = SaneCwsReviewWatch::Client.new(
      publisher_id: options[:publisher_id], item_id: options[:item_id], item_name: options[:item_name],
      access_token: configuration['SANE_CWS_ACCESS_TOKEN'],
      client_id: configuration['SANE_CWS_CLIENT_ID'],
      client_secret: configuration['SANE_CWS_CLIENT_SECRET'],
      refresh_token: configuration['SANE_CWS_REFRESH_TOKEN']
    ).snapshot
    store = SaneAppReviewWatch::StateStore.new(options[:state])
    sender = SaneInternalReport::Client.new
    result = SaneAppReviewWatch::Engine.new(
      store: store,
      sender: sender,
      event_kind: SaneInternalReport::CWS_REVIEW_KIND,
      alert_on_initial: true
    ).run(snapshot)
    configuration_receipt['status'] = result['pending_count'].positive? || result['diagnostics'].any? ? 'blocked' : 'ok'
    configuration_receipt['stage'] = 'watcher'
    configuration_receipt['official_get'] = 'ok'
    configuration_receipt['error_code'] = if result['pending_count'].positive?
                                              'alert_delivery_pending'
                                            elsif result['diagnostics'].any?
                                              'watcher_diagnostics'
                                            end
    SaneCwsReviewWatch.write_receipt(options[:receipt], configuration_receipt)
    puts JSON.pretty_generate(result)
    exit(result['pending_count'].positive? || result['diagnostics'].any? ? 2 : 0)
  rescue SaneAppReviewWatch::WatchError, JSON::ParserError, KeyError, SystemCallError => e
    if defined?(configuration_receipt) && configuration_receipt && defined?(options) && options
      stage, error_code = SaneCwsReviewWatch.failure_classification(e)
      if stage == 'configuration' && configuration_receipt['error_code']
        error_code = configuration_receipt['error_code']
      end
      failed_receipt = configuration_receipt.merge(
        'checked_at' => Time.now.utc.iso8601,
        'status' => 'blocked',
        'stage' => stage,
        'error_code' => error_code,
        'official_get' => stage == 'configuration' ? configuration_receipt['official_get'] : 'failed'
      )
      begin
        SaneCwsReviewWatch.write_receipt(options[:receipt], failed_receipt)
      rescue SaneAppReviewWatch::WatchError => receipt_error
        warn "cws_review_watch: unable to persist redacted receipt (#{receipt_error.class})"
      end
    end
    warn "cws_review_watch: #{e.message}"
    exit 2
  end
end
