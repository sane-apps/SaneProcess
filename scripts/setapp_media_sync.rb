#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require 'time'
require_relative 'setapp_config'

class SetappMediaSync
  CommandStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.to_i.zero?
    end
  end

  API_BASE = 'https://developer-api.setapp.com/v1'
  APP_MEDIA_ENDPOINT = "#{API_BASE}/app_media_file"
  PUBLIC_PAGE_PROOF_MAX_AGE_SECONDS = 7 * 24 * 60 * 60

  def initialize(argv)
    @options = {
      dry_run: false,
      json: false,
      safari_token: true,
      allow_pending_public_page: false
    }
    parse!(argv)
  end

  def run
    apps = selected_apps
    apps.each { |app| SetappConfig.validate_listing_screenshots!(app) }

    return print_dry_run(apps) if @options[:dry_run]

    enforce_mini_host!
    token = portal_token
    abort 'Missing Setapp portal token. Log into developer.setapp.com in Brave on the Mini, or set SETAPP_PORTAL_TOKEN.' if token.empty?

    results = apply_public_page_proof(apps.map { |app| sync_app(app, token) })
    print_results(results)
  end

  private

  def parse!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: setapp_media_sync [--app NAME] [--dry-run] [--json]'
      opts.on('--app NAME', 'Only sync one Setapp app from .saneprocess') { |value| @options[:app_name] = value }
      opts.on('--dry-run', 'Validate and print the planned screenshot upload order without changing Setapp') { @options[:dry_run] = true }
      opts.on('--json', 'Print machine-readable output') { @options[:json] = true }
      opts.on('--no-safari-token', 'Legacy alias: do not read the portal token from Brave cookies') { @options[:safari_token] = false }
      opts.on('--allow-pending-public-page', 'Exit 0 after portal sync even though public setapp.com proof is still pending') { @options[:allow_pending_public_page] = true }
      opts.on('--public-page-proof-file PATH', 'JSON proof that public setapp.com listing screenshots have propagated') { |value| @options[:public_page_proof_file] = value }
    end
    parser.parse!(argv)
  end

  def selected_apps
    return SetappConfig.apps unless @options[:app_name]

    [SetappConfig.app_named(@options[:app_name])]
  end

  def print_dry_run(apps)
    payload = {
      dry_run: true,
      apps: apps.map do |app|
        {
          name: app.fetch(:name),
          app_id: app.fetch(:app_id),
          version_id: app.fetch(:version_id),
          setapp_url: app[:setapp_url],
          public_page_verification_required: true,
          public_page_verified: false,
          screenshots: SetappConfig.listing_screenshot_paths(app).map do |screenshot|
            {
              relative_path: screenshot.fetch(:relative_path),
              path: screenshot.fetch(:path),
              role: screenshot.fetch(:role)
            }
          end
        }
      end
    }
    if @options[:json]
      puts(JSON.pretty_generate(payload))
      return 0
    end

    payload.fetch(:apps).each do |app|
      puts "Setapp listing media dry run: #{app.fetch(:name)}"
      puts "  public page: #{app.fetch(:setapp_url)}" if app[:setapp_url].to_s != ''
      puts '  public-page proof required after sync: confirm setapp.com shows these screenshots'
      app.fetch(:screenshots).each_with_index do |screenshot, index|
        puts "  #{index + 1}. #{screenshot.fetch(:relative_path)} (#{screenshot.fetch(:role)})"
      end
    end
    0
  end

  def sync_app(app, token)
    authorization = "Token #{token}"
    current = fetch_version(app.fetch(:version_id), authorization)
    current_media = media_files_from(current)
    current_status = version_data(current).fetch('status')

    uploaded_screenshots = SetappConfig.listing_screenshot_paths(app).map do |screenshot|
      upload_screenshot(app, screenshot, authorization)
    end
    preserved_media = current_media.reject { |media| media['type'].to_s == 'screenshot' }
    desired_media = uploaded_screenshots + preserved_media

    patch_response = curl_json(
      "#{API_BASE}/versions/#{app.fetch(:version_id)}",
      authorization,
      {
        status: current_status,
        media_files: desired_media
      }
    )
    fail_unless_success!(patch_response, expected: [200])

    verified = fetch_verified_version(app, uploaded_screenshots, preserved_media, authorization)

    {
      name: app.fetch(:name),
      app_id: app.fetch(:app_id),
      version_id: app.fetch(:version_id),
      setapp_url: app[:setapp_url],
      portal_synced: true,
      public_page_verification_required: true,
      public_page_verified: false,
      public_page_status: 'not_checked',
      status: version_data(verified)['status'],
      screenshots: uploaded_screenshots.map { |media| media.slice('id', 'url', 'type') },
      preserved_media: preserved_media.map { |media| media.slice('id', 'url', 'type') },
      preserved_media_count: preserved_media.length
    }
  end

  def upload_screenshot(app, screenshot, authorization)
    path = screenshot.fetch(:path)
    response = curl_form(
      APP_MEDIA_ENDPOINT,
      authorization,
      [
        ['--form', "file=@#{path};type=#{mime_type(path)}"],
        ['--form-string', "application_id=#{app.fetch(:app_id)}"],
        ['--form-string', 'type=screenshot']
      ]
    )
    fail_unless_success!(response, expected: [200, 201])

    data = response.dig(:json, 'data') || {}
    required = %w[id url]
    missing = required.select { |key| data[key].to_s.empty? }
    abort "Setapp screenshot upload response missing #{missing.join(', ')} for #{screenshot.fetch(:relative_path)}" unless missing.empty?

    {
      'id' => data.fetch('id'),
      'url' => data.fetch('url'),
      'type' => data['type'].to_s.empty? ? 'screenshot' : data['type'],
      'additional_attributes' => data['additional_attributes'] || data['additionalAttributes'] || {}
    }
  end

  def fetch_version(version_id, authorization)
    response = curl_get("#{API_BASE}/versions/#{version_id}", authorization)
    fail_unless_success!(response, expected: [200])
    response[:json]
  end

  def version_data(payload)
    data = payload.is_a?(Hash) ? payload['data'] : nil
    abort 'Setapp version response missing data' unless data.is_a?(Hash)

    data
  end

  def media_files_from(payload)
    data = version_data(payload)
    Array(data['media_files'] || data['mediaFiles']).map do |media|
      {
        'id' => media['id'],
        'url' => media['url'],
        'type' => media['type'],
        'additional_attributes' => media['additional_attributes'] || media['additionalAttributes'] || {}
      }
    end
  end

  def fetch_verified_version(app, uploaded_screenshots, preserved_media, authorization)
    last_error = nil
    [0, 1, 2, 4, 8].each_with_index do |delay, index|
      sleep(delay) if delay.positive?
      verified = fetch_version(app.fetch(:version_id), authorization)
      verified_media = media_files_from(verified)
      last_error = media_verification_error(app, uploaded_screenshots, preserved_media, verified_media)
      return verified unless last_error

      next unless index < 4
    end

    abort last_error
  end

  def verify_uploaded_order!(app, uploaded_screenshots, verified_media)
    error = media_verification_error(app, uploaded_screenshots, [], verified_media)
    abort error if error
  end

  def media_verification_error(app, uploaded_screenshots, preserved_media, verified_media)
    actual_ids = verified_media.select { |media| media['type'].to_s == 'screenshot' }.map { |media| media['id'].to_s }
    expected_ids = uploaded_screenshots.map { |media| media['id'].to_s }
    unless actual_ids == expected_ids
      return "Setapp listing media sync did not verify for #{app.fetch(:name)}; expected screenshot ids #{expected_ids.join(', ')}, got #{actual_ids.join(', ')}"
    end

    return nil if preserved_media.empty?

    expected_preserved = media_signature(preserved_media)
    actual_preserved = media_signature(verified_media.reject { |media| media['type'].to_s == 'screenshot' })
    return nil if actual_preserved == expected_preserved

    "Setapp listing media sync did not preserve non-screenshot media for #{app.fetch(:name)}; expected #{expected_preserved}, got #{actual_preserved}"
  end

  def media_signature(media_files)
    media_files.map do |media|
      {
        'id' => media['id'].to_s,
        'type' => media['type'].to_s,
        'url' => media['url'].to_s
      }
    end
  end

  def apply_public_page_proof(results)
    proof_file = @options[:public_page_proof_file].to_s
    return results if proof_file.empty?

    proof_payload = load_public_page_proof(proof_file)
    results.each do |result|
      valid, status = public_page_proof_status(result, proof_payload)
      result[:public_page_verified] = valid
      result[:public_page_status] = status
      result[:public_page_proof_file] = proof_file
    end
    results
  end

  def load_public_page_proof(path)
    expanded = File.expand_path(path)
    abort "Setapp public page proof file not found: #{path}" unless File.file?(expanded)

    JSON.parse(File.read(expanded, encoding: Encoding::UTF_8))
  rescue JSON::ParserError => e
    abort "Setapp public page proof file is not valid JSON: #{e.message}"
  end

  def public_page_proof_status(result, payload)
    proof = public_page_proof_entry(result, payload)
    return [false, 'missing_proof_entry'] unless proof
    return [false, 'not_marked_verified'] unless truthy?(proof['verified'] || proof['public_page_verified'])

    proof_url = proof['setapp_url'].to_s
    return [false, 'setapp_url_mismatch'] if !proof_url.empty? && proof_url != result[:setapp_url].to_s

    expected_count = result.fetch(:screenshots).length
    proof_count = proof['screenshot_count'] || proof['screenshots_count'] || Array(proof['screenshots']).length
    return [false, 'screenshot_count_mismatch'] if proof_count.to_i != expected_count

    checked_at = Time.parse((proof['verified_at'] || proof['checked_at'] || payload['verified_at'] || payload['checked_at']).to_s)
    return [false, 'future_dated_proof'] if checked_at > Time.now.utc + 300
    return [false, 'stale_proof'] if Time.now.utc - checked_at > PUBLIC_PAGE_PROOF_MAX_AGE_SECONDS

    evidence_path = proof['evidence_path'] || proof['screenshot_path'] || proof['receipt_path']
    return [false, 'missing_evidence_path'] if evidence_path.to_s.strip.empty?
    return [false, 'missing_evidence_file'] unless File.file?(File.expand_path(evidence_path.to_s))

    [true, 'verified']
  rescue ArgumentError
    [false, 'invalid_timestamp']
  end

  def public_page_proof_entry(result, payload)
    entries = if payload.is_a?(Hash) && payload['apps'].is_a?(Array)
                payload['apps']
              elsif payload.is_a?(Hash) && payload['proofs'].is_a?(Array)
                payload['proofs']
              elsif payload.is_a?(Hash)
                payload.values.select { |value| value.is_a?(Hash) }
              else
                []
              end
    entries.find do |entry|
      entry['name'].to_s == result[:name].to_s ||
        entry['app'].to_s == result[:name].to_s ||
        entry['setapp_url'].to_s == result[:setapp_url].to_s
    end
  end

  def truthy?(value)
    value == true || %w[1 true yes verified].include?(value.to_s.downcase)
  end

  def mime_type(path)
    case File.extname(path).downcase
    when '.jpg', '.jpeg'
      'image/jpeg'
    else
      'image/png'
    end
  end

  def portal_token
    env_token = ENV['SETAPP_PORTAL_TOKEN'].to_s
    return env_token unless env_token.empty?
    return '' unless @options[:safari_token]

    script = <<~APPLESCRIPT
      tell application "Brave Browser"
        if not running then return "{\\"error\\":\\"Brave is not running\\"}"
        if (count of windows) is 0 then return "{\\"error\\":\\"Brave has no open window\\"}"
        repeat with browserWindow in windows
          repeat with browserTab in tabs of browserWindow
            if (URL of browserTab starts with "https://developer.setapp.com") then
              return execute browserTab javascript "JSON.stringify({host: location.hostname, token: decodeURIComponent((document.cookie.split('; ').find(c=>c.startsWith('access_token='))||'=').split('=')[1]||'')})"
            end if
          end repeat
        end repeat
        return "{\\"error\\":\\"No open developer.setapp.com tab\\"}"
      end tell
    APPLESCRIPT
    output, stderr, status = capture3_with_timeout(10, '/usr/bin/osascript', stdin_data: script)
    unless status.success?
      abort "Could not read Setapp portal token from Brave via AppleScript: #{stderr.strip}"
    end

    data = JSON.parse(output)
    abort 'Brave is not running or has no open Setapp developer page' if data['error']
    abort "Brave Setapp tab returned unexpected host #{data['host']}" unless data['host'].to_s == 'developer.setapp.com'

    token = data['token'].to_s
    abort 'Setapp portal token was empty; sign in to developer.setapp.com in Brave and retry' if token.empty?

    token
  rescue JSON::ParserError => e
    abort "Could not parse Setapp portal token response from Brave: #{e.message}"
  end

  def curl_form(url, authorization, form_args)
    with_curl_config(url, authorization, extra_args: form_args.flatten)
  end

  def curl_json(url, authorization, payload)
    Tempfile.create(['setapp-media-payload', '.json']) do |payload_file|
      payload_file.write(JSON.generate(payload))
      payload_file.flush
      with_curl_config(url, authorization, method: 'PATCH', json: true, extra_args: ['--data-binary', "@#{payload_file.path}"])
    end
  end

  def curl_get(url, authorization)
    with_curl_config(url, authorization, method: 'GET')
  end

  def with_curl_config(url, authorization, method: 'POST', json: false, extra_args: [])
    Tempfile.create('setapp-media-curl') do |config|
      config.chmod(0o600)
      config.puts 'silent'
      config.puts 'show-error'
      config.puts %(request = "#{method}")
      config.puts %(url = "#{curl_config_quote(url)}")
      config.puts %(header = "Authorization: #{curl_config_quote(authorization)}")
      config.puts 'header = "Accept: application/json"'
      config.puts 'header = "Content-Type: application/json"' if json
      config.flush

      headers = Tempfile.new('setapp-media-headers')
      body = Tempfile.new('setapp-media-body')
      _stdout, stderr, status = capture3_with_timeout(
        1_800,
        'curl',
        '--config',
        config.path,
        '-D',
        headers.path,
        '-o',
        body.path,
        *extra_args
      )
      response = {
        ok: status.success?,
        status: parse_http_status(File.read(headers.path)),
        stderr: stderr,
        body: File.read(body.path)
      }
      response[:json] = JSON.parse(response[:body]) unless response[:body].to_s.strip.empty?
      response
    ensure
      headers&.close!
      body&.close!
    end
  end

  def capture3_with_timeout(timeout_seconds, *command, stdin_data: nil)
    stdin_file = nil
    Tempfile.create('setapp-media-stdout') do |stdout_file|
      Tempfile.create('setapp-media-stderr') do |stderr_file|
        spawn_options = { in: File::NULL, out: stdout_file.path, err: stderr_file.path }
        if stdin_data
          stdin_file = Tempfile.new('setapp-media-stdin')
          stdin_file.write(stdin_data)
          stdin_file.flush
          spawn_options[:in] = stdin_file.path
        end

        pid = Process.spawn(*command, spawn_options)
        status = wait_for_pid(pid, timeout_seconds)

        stdout_file.rewind
        stderr_file.rewind
        [stdout_file.read, stderr_file.read, status]
      end
    end
  ensure
    stdin_file&.close!
  end

  def wait_for_pid(pid, timeout_seconds)
    deadline = Time.now + timeout_seconds
    loop do
      waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if waited_pid
      break if Time.now >= deadline

      sleep 0.1
    end

    terminate_child(pid)
    CommandStatus.new(124)
  end

  def terminate_child(pid)
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      return
    end

    20.times do
      waited_pid = waitpid_nohang(pid)
      return if waited_pid

      sleep 0.1
    end
    begin
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      return
    end
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def waitpid_nohang(pid)
    waited_pid, = Process.waitpid2(pid, Process::WNOHANG)
    waited_pid
  rescue Errno::ECHILD
    pid
  end

  def parse_http_status(headers)
    headers.scan(/^HTTP\/\S+\s+(\d{3})/).flatten.last.to_i
  end

  def fail_unless_success!(response, expected:)
    return if response[:ok] && expected.include?(response[:status])

    detail = response.dig(:json, 'errors', 0, 'detail') ||
             response.dig(:json, 'errors', 0, 'title') ||
             response[:body].to_s.strip ||
             response[:stderr].to_s.strip
    abort "Setapp media sync failed (HTTP #{response[:status]}): #{detail}"
  end

  def curl_config_quote(value)
    text = value.to_s
    abort 'Refusing to write control characters into curl config' if text.match?(/[\x00-\x1F\x7F]/)

    text.gsub('\\', '\\\\').gsub('"', '\"')
  end

  def enforce_mini_host!
    return if ENV['SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT'] == '1'
    return if running_on_mini_host?

    abort 'Setapp media sync is Mini-first. Run through ./scripts/SaneMaster.rb setapp_media_sync, or set SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT=1 only for a documented local test.'
  end

  def running_on_mini_host?
    host = `hostname -s 2>/dev/null`.strip.downcase
    user = ENV['USER'].to_s.downcase
    host.include?('mini') || user == 'stephansmac'
  end

  def print_results(results)
    public_page_pending = results.any? do |result|
      result[:public_page_verification_required] && !result[:public_page_verified]
    end
    exit_code = public_page_pending && !@options[:allow_pending_public_page] ? 4 : 0

    if @options[:json]
      puts(JSON.pretty_generate({
        ok: exit_code.zero?,
        public_page_pending: public_page_pending,
        next_action: public_page_pending ? 'Verify the public setapp.com app page after propagation, then record proof before treating listing media as complete.' : nil,
        apps: results
      }))
      return exit_code
    end

    results.each do |result|
      puts "✅ Setapp listing media synced: #{result.fetch(:name)}"
      puts "  app id: #{result.fetch(:app_id)}"
      puts "  version id: #{result.fetch(:version_id)}"
      puts "  public page: #{result.fetch(:setapp_url)}" if result[:setapp_url].to_s != ''
      puts '  public-page proof required: confirm setapp.com shows these exact screenshots after propagation'
      puts "  screenshots: #{result.fetch(:screenshots).length}"
      result.fetch(:screenshots).each_with_index do |screenshot, index|
        puts "    #{index + 1}. id #{screenshot.fetch('id')}: #{screenshot.fetch('url')}"
      end
      puts "  preserved non-screenshot media: #{result.fetch(:preserved_media_count)}"
    end
    if public_page_pending
      puts 'ACTION REQUIRED: public setapp.com page proof is still pending. Verify the public app page after propagation before treating listing media as complete.'
    end
    exit_code
  end
end

class Hash
  def slice(*keys)
    keys.each_with_object({}) { |key, result| result[key] = self[key] if key?(key) }
  end
end unless {}.respond_to?(:slice)

exit(SetappMediaSync.new(ARGV).run) if __FILE__ == $PROGRAM_NAME
