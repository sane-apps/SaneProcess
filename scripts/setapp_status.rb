#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'time'
require 'uri'
require_relative 'setapp_config'

class SetappStatus
  API_BASE = 'https://developer-api.setapp.com/v1'
  DEFAULT_APPS = SetappConfig.apps.freeze
  STATUS_LABELS = {
    2 => 'Needs Revision',
    5 => 'In Review',
    9 => 'Manual Release Required',
    10 => 'Released'
  }.freeze
  NON_ACTION_STATUSES = [5, 10].freeze

  def initialize(argv)
    @options = {
      apps: DEFAULT_APPS.dup,
      json: false,
      soft: false
    }
    parse!(argv)
  end

  def run
    enforce_mini_host! unless @options[:fixture]
    token = @options[:fixture] ? nil : portal_token
    if token.to_s.empty? && !@options[:fixture]
      return unavailable('open developer.setapp.com in Safari on the Mini or set SETAPP_PORTAL_TOKEN')
    end

    rows = @options[:apps].map { |app| row_for(app, token) }
    payload = {
      checked_at: Time.now.utc.iso8601,
      channel: 'setapp',
      apps: rows,
      action_required: rows.any? { |row| row[:action_required] },
      unavailable: rows.any? { |row| row[:unavailable] }
    }

    @options[:json] ? puts(JSON.pretty_generate(payload)) : print_human(payload)
    exit_code_for(payload)
  end

  private

  def parse!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: setapp_status [--json] [--soft] [--app NAME:APP_ID:VERSION_ID]'
      opts.on('--json', 'Print machine-readable status') { @options[:json] = true }
      opts.on('--soft', 'Always exit 0; useful inside broad status reports') { @options[:soft] = true }
      opts.on('--fixture PATH', 'Read version payloads from a fixture JSON file for tests') { |value| @options[:fixture] = value }
      opts.on('--app SPEC', 'Track NAME:APP_ID:VERSION_ID instead of the defaults') do |value|
        @custom_apps ||= []
        @custom_apps << parse_app_spec(value)
      end
      opts.on('-h', '--help', 'Show help') do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    @options[:apps] = @custom_apps if @custom_apps&.any?
  end

  def parse_app_spec(value)
    name, app_id, version_id = value.to_s.split(':', 3)
    abort 'Setapp --app must be NAME:APP_ID:VERSION_ID' if [name, app_id, version_id].any? { |part| part.to_s.empty? }

    { name: name, app_id: app_id, version_id: version_id }
  end

  def enforce_mini_host!
    return if ENV['SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT'] == '1'
    return if running_on_mini_host?

    abort 'Setapp status is Mini-first. Run through ./scripts/SaneMaster.rb setapp_status, or set SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT=1 only for a documented local test.'
  end

  def running_on_mini_host?
    host = `hostname -s 2>/dev/null`.strip.downcase
    user = ENV['USER'].to_s
    host.include?('mini') || user == 'stephansmac'
  end

  def row_for(app, token)
    response = @options[:fixture] ? fixture_response(app.fetch(:version_id)) : fetch_version(token, app.fetch(:version_id))
    data = response.fetch('data', {})
    status_code = data['status'].to_i
    label = status_label(status_code)
    {
      app: app.fetch(:name),
      app_id: app.fetch(:app_id),
      version_id: app.fetch(:version_id),
      version: data['version'],
      ui_version: data['ui_version'],
      archive_url: data['archive_url'],
      status_code: status_code,
      status: label,
      action_required: action_required_status?(status_code),
      vendor_comment_present: !data['vendor_comment'].to_s.strip.empty?,
      reviewer_comment_present: !first_present(data, 'reviewer_comment', 'review_comment', 'decline_reason', 'rejection_reason').to_s.strip.empty?
    }
  rescue StandardError => e
    {
      app: app.fetch(:name),
      app_id: app.fetch(:app_id),
      version_id: app.fetch(:version_id),
      unavailable: true,
      error: e.message,
      action_required: false
    }
  end

  def fetch_version(token, version_id)
    uri = URI("#{API_BASE}/versions/#{version_id}")
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/json'
    request['Authorization'] = "Token #{token}"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end
    body = response.body.to_s
    parsed = body.empty? ? {} : JSON.parse(body)
    return parsed if response.is_a?(Net::HTTPSuccess)

    detail = parsed.dig('errors', 0, 'detail') || parsed.dig('errors', 0, 'title') || body
    raise "HTTP #{response.code}: #{detail}"
  end

  def fixture_response(version_id)
    @fixture_payload ||= JSON.parse(File.read(@options[:fixture]))
    @fixture_payload.fetch(version_id.to_s)
  end

  def portal_token
    env_token = ENV['SETAPP_PORTAL_TOKEN'].to_s
    return env_token unless env_token.empty?

    script = <<~APPLESCRIPT
      tell application "Safari"
        if not running then return "{\\"error\\":\\"Safari is not running\\"}"
        if (count of documents) is 0 then return "{\\"error\\":\\"Safari has no open document\\"}"
        return do JavaScript "JSON.stringify({host: location.hostname, token: decodeURIComponent((document.cookie.split('; ').find(c=>c.startsWith('access_token='))||'=').split('=')[1]||'')})" in front document
      end tell
    APPLESCRIPT
    output, _stderr, status = Open3.capture3('/usr/bin/osascript', stdin_data: script)
    return '' unless status.success?

    data = JSON.parse(output)
    return '' if data['error']
    return '' unless data['host'].to_s == 'developer.setapp.com'

    data['token'].to_s
  rescue JSON::ParserError, Errno::ENOENT
    ''
  end

  def unavailable(reason)
    payload = {
      checked_at: Time.now.utc.iso8601,
      channel: 'setapp',
      unavailable: true,
      action_required: false,
      error: reason,
      apps: @options[:apps].map { |app| app.merge(unavailable: true, action_required: false) }
    }
    @options[:json] ? puts(JSON.pretty_generate(payload)) : print_human(payload)
    @options[:soft] ? 0 : 3
  end

  def print_human(payload)
    puts 'Setapp review status'
    if payload[:unavailable] && payload[:error]
      puts "⚠️  Status unavailable: #{payload[:error]}"
      puts '   Treat Setapp status as incomplete until this is checked.'
      return
    end

    payload[:apps].each do |row|
      if row[:unavailable]
        puts "- #{row[:app]}: unavailable (#{row[:error]})"
        next
      end

      marker = status_marker(row)
      version = [row[:version], row[:ui_version]].compact.join(' / ')
      puts "- #{marker} #{row[:app]}: #{row[:status]} (status #{row[:status_code]}, version #{version}, version_id #{row[:version_id]})"
      puts "  archive: #{row[:archive_url]}" if row[:archive_url]
      puts "  vendor comment: #{row[:vendor_comment_present] ? 'present' : 'missing'}"
      puts '  reviewer note: present (redacted)' if row[:reviewer_comment_present]
    end

    if payload[:unavailable]
      puts 'STATUS INCOMPLETE: at least one Setapp version could not be checked. Fix portal/API availability before deciding review action.'
    end
    if payload[:action_required]
      puts 'ACTION REQUIRED: at least one Setapp version is waiting on us. Complete the portal action (submit for review, fix Needs Revision, or manually release an approved build) and rerun setapp_status.'
    elsif !payload[:unavailable]
      puts 'No Setapp action required.'
    end
  end

  def status_label(code)
    STATUS_LABELS.fetch(code, "Status #{code}")
  end

  def action_required_status?(code)
    !NON_ACTION_STATUSES.include?(code.to_i)
  end

  def status_marker(row)
    return '❌' if row[:action_required]
    return '✅' if row[:status_code].to_i == 10

    '⏳'
  end

  def first_present(hash, *keys)
    keys.each do |key|
      value = hash[key]
      return value unless value.to_s.strip.empty?
    end
    nil
  end

  def compact(value)
    text = value.to_s.gsub(/\s+/, ' ').strip
    text.length > 220 ? "#{text[0, 217]}..." : text
  end

  def exit_code_for(payload)
    return 0 if @options[:soft]
    return 3 if payload[:unavailable]
    return 2 if payload[:action_required]

    0
  end
end

exit(SetappStatus.new(ARGV).run) if __FILE__ == $PROGRAM_NAME
