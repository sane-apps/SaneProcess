#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'optparse'
require 'socket'
require 'time'
require 'uri'

require_relative 'app_review_watch'

module SaneCwsReviewWatch
  DEFAULT_STATE_PATH = File.expand_path('~/SaneApps/outputs/cws-review-watch-state.json')
  DEFAULT_ITEM_ID = 'ihhnhedfjfjplodfhacompiahlnjbpeb'
  DEFAULT_ITEM_NAME = 'SaneLot Auction Pricing'
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
      end.reject(&:empty?).uniq
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
      return @direct_access_token unless @direct_access_token.empty?

      missing = {
        'SANE_CWS_CLIENT_ID' => @client_id,
        'SANE_CWS_CLIENT_SECRET' => @client_secret,
        'SANE_CWS_REFRESH_TOKEN' => @refresh_token
      }.select { |_name, value| value.empty? }.keys
      unless missing.empty?
        raise SaneAppReviewWatch::WatchError,
              "CWS OAuth credential is unavailable (missing #{missing.join(', ')})"
      end

      response = @requester.call(
        method: :post,
        uri: TOKEN_URI,
        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
        body: URI.encode_www_form(
          client_id: @client_id,
          client_secret: @client_secret,
          refresh_token: @refresh_token,
          grant_type: 'refresh_token'
        )
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
    rescue JSON::ParserError => e
      raise SaneAppReviewWatch::WatchError, "CWS #{lane} returned invalid JSON: #{e.message}"
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

  def mini_host?(hostname = Socket.gethostname)
    hostname.to_s.downcase.include?('mini')
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    options = {
      state: SaneCwsReviewWatch::DEFAULT_STATE_PATH,
      publisher_id: ENV['SANE_CWS_PUBLISHER_ID'],
      item_id: SaneCwsReviewWatch::DEFAULT_ITEM_ID,
      item_name: SaneCwsReviewWatch::DEFAULT_ITEM_NAME,
      allow_non_mini: false
    }
    OptionParser.new do |opts|
      opts.banner = 'Usage: cws_review_watch.rb --publisher-id ID [--item-id ID] [--item-name NAME] [--state PATH]'
      opts.on('--publisher-id ID', 'Chrome Web Store publisher ID') { |value| options[:publisher_id] = value }
      opts.on('--item-id ID', 'Chrome Web Store item ID') { |value| options[:item_id] = value }
      opts.on('--item-name NAME', 'Human-readable item name') { |value| options[:item_name] = value }
      opts.on('--state PATH', 'Durable state path') { |value| options[:state] = value }
      opts.on('--allow-non-mini', 'Tests only: allow a non-Mini host') { options[:allow_non_mini] = true }
    end.parse!

    unless options[:allow_non_mini] || SaneCwsReviewWatch.mini_host?
      raise SaneAppReviewWatch::WatchError, 'CWS review watch is Mini-only'
    end

    snapshot = SaneCwsReviewWatch::Client.new(
      publisher_id: options[:publisher_id], item_id: options[:item_id], item_name: options[:item_name]
    ).snapshot
    store = SaneAppReviewWatch::StateStore.new(options[:state])
    sender = SaneInternalReport::Client.new
    result = SaneAppReviewWatch::Engine.new(
      store: store,
      sender: sender,
      event_kind: SaneInternalReport::CWS_REVIEW_KIND,
      alert_on_initial: true
    ).run(snapshot)
    puts JSON.pretty_generate(result)
    exit(result['pending_count'].positive? || result['diagnostics'].any? ? 2 : 0)
  rescue SaneAppReviewWatch::WatchError, JSON::ParserError, KeyError, SystemCallError => e
    warn "cws_review_watch: #{e.message}"
    exit 2
  end
end
