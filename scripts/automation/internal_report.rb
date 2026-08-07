#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tempfile'
require 'time'
require 'uri'

module SaneInternalReport
  TEMPLATE_VERSION = 1
  APP_REVIEW_KIND = 'app_review_transition'
  CWS_REVIEW_KIND = 'chrome_web_store_transition'
  KIND = APP_REVIEW_KIND
  SUPPORTED_KINDS = [APP_REVIEW_KIND, CWS_REVIEW_KIND].freeze
  DELIVERED_EVENTS = %w[delivered opened clicked complained].freeze
  DEFAULT_TRANSPORT_COMMAND = [
    RbConfig.ruby,
    File.expand_path(__FILE__),
    '--transport'
  ].map { |part| Shellwords.escape(part) }.join(' ').freeze

  class DeliveryError < StandardError; end

  module_function

  def render(event)
    validate_event!(event)
    kind = event['kind'].to_s.empty? ? KIND : event.fetch('kind')
    names = event.fetch('changes').map { |change| change.fetch('app_name') }.uniq.sort
    chrome_web_store = kind == CWS_REVIEW_KIND
    subject =
      if chrome_web_store
        names.length == 1 ? "Chrome Web Store changed: #{names.first}" : 'SaneApps Chrome Web Store changed'
      else
        names.length == 1 ? "App Review changed: #{names.first}" : 'SaneApps App Review changed'
      end
    lines = [
      chrome_web_store ? 'Chrome Web Store reported a review-state transition.' :
        'App Store Connect reported a review-state transition.',
      '',
      *event.fetch('changes').sort_by { |change| change.fetch('entity_key') }.map do |change|
        previous = change['previous_state'].to_s.empty? ? 'new' : change['previous_state']
        detail = "#{change.fetch('app_name')}: #{change.fetch('entity_type')} #{previous} -> #{change.fetch('state')}"
        previous_version = change['previous_version'].to_s
        version = change['version'].to_s
        if !version.empty? && !previous_version.empty? && previous_version != version
          detail = "#{detail} (version #{previous_version} -> #{version})"
        elsif !version.empty?
          detail = "#{detail} (version #{version})"
        end
        submission_id = change['submission_id'].to_s
        submission_id.empty? ? detail : "#{detail} (submission #{submission_id})"
      end,
      '',
      "Event: #{event.fetch('id')}",
      "Detected: #{event.fetch('first_seen_at')}"
    ]
    {
      'kind' => kind,
      'template_version' => TEMPLATE_VERSION,
      'event_id' => event.fetch('id'),
      'subject' => subject,
      'body' => lines.join("\n")
    }
  end

  def validate_event!(event)
    raise DeliveryError, 'event must be a JSON object' unless event.is_a?(Hash)
    raise DeliveryError, 'event id is missing' if event['id'].to_s.empty?
    raise DeliveryError, 'event first_seen_at is missing' if event['first_seen_at'].to_s.empty?
    kind = event['kind'].to_s.empty? ? KIND : event['kind'].to_s
    raise DeliveryError, 'event kind is invalid' unless SUPPORTED_KINDS.include?(kind)

    changes = event['changes']
    raise DeliveryError, 'event changes must be a non-empty array' unless changes.is_a?(Array) && !changes.empty?

    changes.each do |change|
      raise DeliveryError, 'event change must be a JSON object' unless change.is_a?(Hash)
      %w[entity_key entity_type app_id app_name state].each do |field|
        raise DeliveryError, "event change #{field} is missing" if change[field].to_s.empty?
      end
    end
  end

  def validate_delivery_receipt!(receipt, event_id)
    raise DeliveryError, 'internal-report receipt must be a JSON object' unless receipt.is_a?(Hash)
    raise DeliveryError, 'internal-report receipt event id mismatch' unless receipt['event_id'].to_s == event_id
    raise DeliveryError, 'internal-report receipt provider id is missing' if receipt['provider_id'].to_s.empty?

    delivery_event = receipt['delivery_event'].to_s.downcase
    return true if DELIVERED_EVENTS.include?(delivery_event)

    value = delivery_event.empty? ? 'missing' : delivery_event
    raise DeliveryError, "internal-report delivery is not verified (event=#{value})"
  end

  class Client
    def initialize(command: ENV.fetch('SANE_INTERNAL_REPORT_TRANSPORT', DEFAULT_TRANSPORT_COMMAND),
                   runner: nil, now: -> { Time.now.utc })
      @command = command.to_s.strip
      @runner = runner || method(:run_command)
      @now = now
    end

    def deliver(event)
      envelope = SaneInternalReport.render(event)
      raise DeliveryError, 'internal-report transport is not configured' if @command.empty?

      stdout, _stderr, status = @runner.call(@command, JSON.generate(envelope))
      unless status.success?
        exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : nil
        detail = exit_status.nil? ? 'unknown status' : "exit #{exit_status}"
        raise DeliveryError, "internal-report transport failed (#{detail})"
      end

      receipt = JSON.parse(stdout)
      SaneInternalReport.validate_delivery_receipt!(receipt, envelope.fetch('event_id'))
      {
        'event_id' => envelope.fetch('event_id'),
        'provider_id' => receipt.fetch('provider_id').to_s,
        'delivery_event' => receipt.fetch('delivery_event').to_s.downcase,
        'delivered_at' => receipt['delivered_at'].to_s.empty? ? @now.call.iso8601 : receipt['delivered_at'].to_s,
        'template_version' => SaneInternalReport::TEMPLATE_VERSION
      }
    rescue JSON::ParserError
      raise DeliveryError, 'internal-report transport returned invalid JSON'
    rescue DeliveryError
      raise
    rescue StandardError => e
      raise DeliveryError, "internal-report transport execution failed: #{e.class}"
    end

    private

    def run_command(command, input)
      argv = Shellwords.split(command)
      raise DeliveryError, 'internal-report transport command is empty' if argv.empty?
      raise DeliveryError, 'internal-report transport must use an absolute executable path' unless argv.first.start_with?('/')
      raise DeliveryError, "internal-report transport is not executable: #{argv.first}" unless File.executable?(argv.first)

      Open3.capture3(*argv, stdin_data: input)
    end

  end

  # Narrow, delivery-verified transport for operator-only App Review alerts.
  # It accepts only the validated internal envelope above, always targets the
  # configured owner, and persists the provider id before polling so a retry
  # cannot send the same transition twice.
  class Transport
    DEFAULT_STATE_PATH = File.expand_path('~/SaneApps/outputs/internal-report-delivery-state.json')
    DEFAULT_ENV_PATH = File.expand_path('~/.config/nv/env')
    DEFAULT_WRANGLER_PATH = File.expand_path(
      '~/SaneApps/infra/sane-email-automation/wrangler.toml'
    )
    EMAIL_API = URI('https://email-api.saneapps.com/api/compose')
    EMAIL_HEALTH_API = URI('https://email-api.saneapps.com/api/stats')
    RESEND_API = 'https://api.resend.com/emails/'
    RESEND_HEALTH_API = URI('https://api.resend.com/emails?limit=1')

    def initialize(state_path: DEFAULT_STATE_PATH, env_path: DEFAULT_ENV_PATH,
                   wrangler_path: DEFAULT_WRANGLER_PATH, sender: nil, poller: nil,
                   health_requester: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, now: -> { Time.now.utc })
      @state_path = File.expand_path(state_path)
      @env_path = File.expand_path(env_path)
      @wrangler_path = File.expand_path(wrangler_path)
      @sender = sender || method(:send_envelope)
      @poller = poller || method(:poll_delivery)
      @health_requester = health_requester || method(:perform_health_request)
      @sleeper = sleeper
      @now = now
    end

    def health
      values = credentials
      verify_health_response!('email_api', @health_requester.call(EMAIL_HEALTH_API, values.fetch(:email_key)))
      verify_health_response!('resend_api', @health_requester.call(RESEND_HEALTH_API, values.fetch(:resend_key)))
      {
        'status' => 'ok',
        'email_api' => 'ok',
        'resend_api' => 'ok',
        'owner' => 'configured',
        'send_performed' => false
      }
    end

    def deliver(envelope)
      validate_envelope!(envelope)
      with_state_lock do
        state = load_state
        record = state.fetch(envelope.fetch('event_id'), {})
        provider_id = record['provider_id'].to_s

        if provider_id.empty?
          provider_id = @sender.call(envelope, credentials).to_s
          raise DeliveryError, 'internal-report provider id is missing' if provider_id.empty?

          state[envelope.fetch('event_id')] = {
            'provider_id' => provider_id,
            'accepted_at' => @now.call.iso8601,
            'delivery_event' => 'accepted'
          }
          save_state(state)
        end

        delivery_event = verified_event(provider_id, credentials)
        state[envelope.fetch('event_id')].merge!(
          'delivery_event' => delivery_event,
          'delivered_at' => @now.call.iso8601
        )
        save_state(state)
        {
          'event_id' => envelope.fetch('event_id'),
          'provider_id' => provider_id,
          'delivery_event' => delivery_event,
          'delivered_at' => state.fetch(envelope.fetch('event_id')).fetch('delivered_at')
        }
      end
    end

    private

    def validate_envelope!(envelope)
      raise DeliveryError, 'internal-report envelope must be a JSON object' unless envelope.is_a?(Hash)
      raise DeliveryError, 'internal-report kind is invalid' unless SUPPORTED_KINDS.include?(envelope['kind'])
      raise DeliveryError, 'internal-report template version is invalid' unless envelope['template_version'].to_i == TEMPLATE_VERSION
      raise DeliveryError, 'internal-report event id is invalid' unless envelope['event_id'].to_s.match?(/\A[0-9a-f]{64}\z/)

      subject = envelope['subject'].to_s
      body = envelope['body'].to_s
      raise DeliveryError, 'internal-report subject is invalid' unless (1..160).cover?(subject.length)
      raise DeliveryError, 'internal-report body is invalid' unless (1..10_000).cover?(body.length)
      raise DeliveryError, 'internal-report body does not identify its event' unless body.include?(envelope.fetch('event_id'))
    end

    def credentials
      @credentials ||= begin
        env = read_env
        email_key = env['SANE_EMAIL_API_KEY'].to_s
        email_key = env['EMAIL_API_KEY'].to_s if email_key.empty?
        resend_key = env['RESEND_API_KEY'].to_s
        raise DeliveryError, 'internal-report email API credential is unavailable' if email_key.empty?
        raise DeliveryError, 'internal-report delivery credential is unavailable' if resend_key.empty?

        {
          email_key: email_key,
          resend_key: resend_key,
          owner_email: read_owner_email
        }
      end
    end

    def read_env
      raise DeliveryError, 'internal-report environment cache is missing' unless File.file?(@env_path)

      File.readlines(@env_path, chomp: true).each_with_object({}) do |line, result|
        match = line.match(/\A\s*(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)\z/)
        next unless match
        next unless %w[SANE_EMAIL_API_KEY EMAIL_API_KEY RESEND_API_KEY].include?(match[1])

        values = Shellwords.split(match[2])
        result[match[1]] = values.first.to_s if values.length == 1
      rescue ArgumentError
        next
      end
    end

    def read_owner_email
      raise DeliveryError, 'internal-report owner configuration is missing' unless File.file?(@wrangler_path)

      line = File.readlines(@wrangler_path, chomp: true).find { |entry| entry.match?(/\A\s*OWNER_EMAIL\s*=/) }
      value = line.to_s[/\A\s*OWNER_EMAIL\s*=\s*"([^"]+)"\s*\z/, 1].to_s
      raise DeliveryError, 'internal-report owner address is invalid' unless value.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

      value
    end

    def send_envelope(envelope, credentials)
      request = Net::HTTP::Post.new(EMAIL_API)
      request['Authorization'] = "Bearer #{credentials.fetch(:email_key)}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(
        'to' => credentials.fetch(:owner_email),
        'subject' => envelope.fetch('subject'),
        'body' => envelope.fetch('body'),
        'lane' => 'admin'
      )
      response = Net::HTTP.start(
        EMAIL_API.host, EMAIL_API.port, use_ssl: true,
        open_timeout: 15, read_timeout: 30
      ) { |http| http.request(request) }
      payload = JSON.parse(response.body.to_s)
      unless response.is_a?(Net::HTTPSuccess) && payload['success']
        raise DeliveryError, "internal-report email API rejected request (HTTP #{response.code})"
      end

      payload['id'].to_s
    rescue JSON::ParserError
      raise DeliveryError, 'internal-report email API returned invalid JSON'
    rescue SocketError, SystemCallError, Timeout::Error => e
      raise DeliveryError, "internal-report email API failed: #{e.class}"
    end

    def perform_health_request(uri, token)
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true,
        open_timeout: 15, read_timeout: 30
      ) { |http| http.request(request) }
      { code: response.code.to_i }
    rescue SocketError, SystemCallError, Timeout::Error => e
      raise DeliveryError, "internal-report health request failed: #{e.class}"
    end

    def verify_health_response!(lane, response)
      code = response.fetch(:code).to_i
      return true if (200..299).cover?(code)

      raise DeliveryError, "internal-report #{lane} health returned HTTP #{code}"
    rescue KeyError
      raise DeliveryError, "internal-report #{lane} health returned no status"
    end

    def poll_delivery(provider_id, credentials)
      uri = URI("#{RESEND_API}#{URI.encode_www_form_component(provider_id)}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{credentials.fetch(:resend_key)}"
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true,
        open_timeout: 15, read_timeout: 30
      ) { |http| http.request(request) }
      return '' unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body.to_s)
      (payload['last_event'] || payload['status']).to_s.downcase
    rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error
      ''
    end

    def verified_event(provider_id, credentials)
      8.times do |attempt|
        event = @poller.call(provider_id, credentials).to_s.downcase
        return event if DELIVERED_EVENTS.include?(event)
        raise DeliveryError, "internal-report delivery failed (event=#{event})" if %w[bounced suppressed].include?(event)

        @sleeper.call(2) if attempt < 7
      end
      raise DeliveryError, 'internal-report delivery is not yet verified'
    end

    def with_state_lock
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.open("#{@state_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        raise DeliveryError, 'another internal-report delivery is active' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def load_state
      return {} unless File.file?(@state_path)

      value = JSON.parse(File.read(@state_path, encoding: Encoding::UTF_8))
      raise DeliveryError, 'internal-report delivery state must be a JSON object' unless value.is_a?(Hash)

      value
    rescue JSON::ParserError
      raise DeliveryError, 'internal-report delivery state is invalid JSON'
    end

    def save_state(state)
      Tempfile.create(['internal-report-delivery-state', '.json'], File.dirname(@state_path)) do |tmp|
        tmp.chmod(0o600)
        tmp.write(JSON.pretty_generate(state))
        tmp.write("\n")
        tmp.flush
        tmp.fsync
        File.rename(tmp.path, @state_path)
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    if ARGV.first == '--transport'
      ARGV.shift
      abort 'Usage: internal_report.rb --transport' unless ARGV.empty?
      envelope = JSON.parse($stdin.read)
      puts JSON.generate(SaneInternalReport::Transport.new.deliver(envelope))
      exit 0
    end
    if ARGV.first == '--health'
      ARGV.shift
      abort 'Usage: internal_report.rb --health' unless ARGV.empty?
      puts JSON.generate(SaneInternalReport::Transport.new.health)
      exit 0
    end

    event_path = ARGV.shift
    abort 'Usage: internal_report.rb EVENT.json' if event_path.to_s.empty?

    event = JSON.parse(File.read(event_path, encoding: Encoding::UTF_8))
    receipt = SaneInternalReport::Client.new.deliver(event)
    puts JSON.generate(receipt)
  rescue SaneInternalReport::DeliveryError, JSON::ParserError, SystemCallError => e
    warn "internal_report: #{e.message}"
    exit 2
  end
end
