#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require 'tmpdir'

class SetappUpload
  CommandStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.to_i.zero?
    end
  end

  API_BASE = 'https://developer-api.setapp.com/v1'
  CI_ENDPOINT = "#{API_BASE}/ci/version"
  PORTAL_UPLOAD_ENDPOINT = "#{API_BASE}/versions/upload_archive"

  def initialize(argv)
    @options = {
      status: 'review',
      beta: false,
      release_on_approval: false,
      allow_overwrite: true,
      portal_fallback: false,
      safari_token: true,
      json: false,
      dry_run: false
    }
    parse!(argv)
  end

  def run
    validate!
    return dry_run if @options[:dry_run]

    if @options[:portal_fallback]
      run_portal_fallback
    else
      run_ci_upload
    end
  end

  private

  def parse!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: setapp_upload --zip ZIP --release-notes TEXT [--portal-fallback --app-id ID --version-id ID]'
      opts.on('--zip PATH', 'Setapp ZIP archive to upload') { |value| @options[:zip] = value }
      opts.on('--release-notes TEXT', 'Release notes text') { |value| @options[:release_notes] = value }
      opts.on('--release-notes-file PATH', 'Read release notes from a file') do |value|
        @options[:release_notes] = File.read(value)
      end
      opts.on('--app-id ID', 'Setapp application id; required for portal fallback') { |value| @options[:app_id] = value }
      opts.on('--version-id ID', 'Existing Setapp version id to patch; required for portal fallback') { |value| @options[:version_id] = value }
      opts.on('--status STATUS', 'CI upload status: draft or review') { |value| @options[:status] = value }
      opts.on('--release-on-approval BOOL', 'Publish automatically after approval') do |value|
        @options[:release_on_approval] = parse_bool(value)
      end
      opts.on('--beta BOOL', 'Upload as beta build') { |value| @options[:beta] = parse_bool(value) }
      opts.on('--allow-overwrite BOOL', 'Allow CI overwrite of a waiting review build') do |value|
        @options[:allow_overwrite] = parse_bool(value)
      end
      opts.on('--portal-fallback', 'Use logged-in portal upload + patch path') { @options[:portal_fallback] = true }
      opts.on('--no-safari-token', 'Do not read the portal token from Safari cookies') { @options[:safari_token] = false }
      opts.on('--json', 'Print machine-readable response') { @options[:json] = true }
      opts.on('--dry-run', 'Validate inputs and print the planned upload path') { @options[:dry_run] = true }
      opts.on('-h', '--help', 'Show help') do
        puts opts
        exit 0
      end
    end

    parser.parse!(argv)
  rescue Errno::ENOENT => e
    abort "Release notes file not found: #{e.message}"
  end

  def validate!
    abort 'Missing --zip PATH' if @options[:zip].to_s.empty?
    abort "ZIP not found: #{@options[:zip]}" unless File.file?(@options[:zip])
    abort 'Missing --release-notes or --release-notes-file' if @options[:release_notes].to_s.strip.empty?
    abort 'Setapp status must be draft or review' unless %w[draft review].include?(@options[:status])
    validate_archive_icon! unless @options[:dry_run]

    return unless @options[:portal_fallback]

    abort 'Portal fallback requires --app-id' if @options[:app_id].to_s.empty?
    abort 'Portal fallback requires --version-id' if @options[:version_id].to_s.empty?
  end

  def validate_archive_icon!
    Dir.mktmpdir('setapp-upload-archive') do |tmpdir|
      _stdout, stderr, status = capture3_with_timeout(
        120,
        '/usr/bin/unzip',
        '-q',
        File.expand_path(@options[:zip]),
        '-d',
        tmpdir
      )
      abort "Setapp archive could not be expanded: #{stderr.strip}" unless status.success?

      icon_path = Dir.glob(File.join(tmpdir, '*.app', 'Contents', 'Resources', 'AppIcon.icns')).first
      abort 'Setapp archive is missing Contents/Resources/AppIcon.icns' unless icon_path

      output, icon_stderr, icon_status = capture3_with_timeout(
        30,
        '/usr/bin/sips',
        '-g',
        'pixelWidth',
        '-g',
        'pixelHeight',
        icon_path
      )
      abort "Setapp archive AppIcon.icns could not be inspected: #{icon_stderr.strip}" unless icon_status.success?

      width = output[/pixelWidth:\s*(\d+)/, 1].to_i
      height = output[/pixelHeight:\s*(\d+)/, 1].to_i
      return if width >= 512 && height >= 512

      abort "Setapp archive AppIcon.icns is #{width}x#{height}; Setapp requires at least 512x512"
    end
  end

  def dry_run
    payload = {
      mode: @options[:portal_fallback] ? 'portal_fallback' : 'ci',
      zip: File.expand_path(@options[:zip]),
      endpoint: @options[:portal_fallback] ? PORTAL_UPLOAD_ENDPOINT : CI_ENDPOINT,
      app_id: @options[:app_id],
      version_id: @options[:version_id],
      status: @options[:status],
      beta: @options[:beta],
      release_on_approval: @options[:release_on_approval],
      allow_overwrite: @options[:allow_overwrite]
    }

    return puts(JSON.pretty_generate(payload)) if @options[:json]

    puts 'Setapp upload dry run'
    payload.each { |key, value| puts "  #{key}: #{value}" unless value.nil? || value.to_s.empty? }
  end

  def run_ci_upload
    token = ENV['SETAPP_AUTOMATION_TOKEN'].to_s
    abort 'Missing SETAPP_AUTOMATION_TOKEN for official Setapp CI upload' if token.empty?

    response = curl_form(
      CI_ENDPOINT,
      "Bearer #{token}",
      [
        ['--form', "archive=@#{File.expand_path(@options[:zip])};type=application/zip"],
        ['--form-string', "release_notes=#{@options[:release_notes]}"],
        ['--form-string', "status=#{@options[:status]}"],
        ['--form-string', "beta=#{@options[:beta]}"],
        ['--form-string', "release_on_approval=#{@options[:release_on_approval]}"],
        ['--form-string', "allow_overwrite=#{@options[:allow_overwrite]}"]
      ]
    )
    fail_unless_success!(response, expected: [200, 202, 204])
    print_result('Setapp CI upload accepted', response[:json])
  end

  def run_portal_fallback
    token = portal_token
    abort 'Missing Setapp portal token. Log into developer.setapp.com in Safari on this machine, or set SETAPP_PORTAL_TOKEN.' if token.empty?

    upload_response = curl_form(
      PORTAL_UPLOAD_ENDPOINT,
      "Token #{token}",
      [
        ['--form-string', "application_id=#{@options[:app_id]}"],
        ['--form', "archive=@#{File.expand_path(@options[:zip])};type=application/zip"]
      ]
    )
    fail_unless_success!(upload_response, expected: [200])

    data = upload_response.dig(:json, 'data') || {}
    required = %w[archive_tmp_name icon_url version ui_version]
    missing = required.select { |key| data[key].to_s.empty? }
    abort "Setapp upload response missing: #{missing.join(', ')}" unless missing.empty?

    patch_payload = {
      archive_tmp_name: data.fetch('archive_tmp_name'),
      icon_url: data.fetch('icon_url'),
      version: data.fetch('version'),
      ui_version: data.fetch('ui_version'),
      release_notes: @options[:release_notes]
    }
    patch_response = curl_json(
      "#{API_BASE}/versions/#{@options[:version_id]}",
      "Token #{token}",
      patch_payload
    )
    fail_unless_success!(patch_response, expected: [200])
    print_result('Setapp portal fallback attached archive', patch_response[:json])
  end

  def portal_token
    env_token = ENV['SETAPP_PORTAL_TOKEN'].to_s
    return env_token unless env_token.empty?
    return '' unless @options[:safari_token]

    script = <<~APPLESCRIPT
      tell application "Safari"
        if not running then return "{\\"error\\":\\"Safari is not running\\"}"
        if (count of documents) is 0 then return "{\\"error\\":\\"Safari has no open document\\"}"
        return do JavaScript "JSON.stringify({host: location.hostname, token: decodeURIComponent((document.cookie.split('; ').find(c=>c.startsWith('access_token='))||'=').split('=')[1]||'')})" in front document
      end tell
    APPLESCRIPT
    output, _stderr, status = capture3_with_timeout(10, '/usr/bin/osascript', stdin_data: script)
    return '' unless status.success?

    data = JSON.parse(output)
    abort 'Safari is not running or has no open Setapp developer page' if data['error']
    unless data['host'].to_s == 'developer.setapp.com'
      abort "Safari front tab must be developer.setapp.com for portal fallback; current host is #{data['host']}"
    end

    token = data['token'].to_s
    abort 'Setapp portal token was empty; refresh developer.setapp.com in Safari and retry' if token.empty?

    token
  rescue JSON::ParserError
    ''
  end

  def curl_form(url, authorization, form_args)
    with_curl_config(url, authorization, extra_args: form_args.flatten)
  end

  def curl_json(url, authorization, payload)
    Tempfile.create(['setapp-upload-payload', '.json']) do |payload_file|
      payload_file.write(JSON.generate(payload))
      payload_file.flush
      with_curl_config(url, authorization, method: 'PATCH', json: true, extra_args: ['--data-binary', "@#{payload_file.path}"])
    end
  end

  def with_curl_config(url, authorization, method: 'POST', json: false, extra_args: [])
    Tempfile.create('setapp-upload-curl') do |config|
      config.chmod(0o600)
      config.puts 'silent'
      config.puts 'show-error'
      config.puts %(request = "#{method}")
      config.puts %(url = "#{curl_config_quote(url)}")
      config.puts %(header = "Authorization: #{curl_config_quote(authorization)}")
      config.puts 'header = "Accept: application/json"'
      config.puts 'header = "Content-Type: application/json"' if json
      config.flush

      headers = Tempfile.new('setapp-upload-headers')
      body = Tempfile.new('setapp-upload-body')
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
    Tempfile.create('setapp-upload-stdout') do |stdout_file|
      Tempfile.create('setapp-upload-stderr') do |stderr_file|
        spawn_options = { in: File::NULL, out: stdout_file.path, err: stderr_file.path }
        if stdin_data
          stdin_file = Tempfile.new('setapp-upload-stdin')
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
    abort "Setapp upload failed (HTTP #{response[:status]}): #{detail}"
  end

  def print_result(label, payload)
    return puts(JSON.pretty_generate(payload || {})) if @options[:json]

    data = payload.is_a?(Hash) ? payload['data'] : nil
    puts "✅ #{label}"
    return unless data.is_a?(Hash)

    puts "  app version: #{data['version']}" if data['version']
    puts "  display version: #{data['ui_version']}" if data['ui_version']
    puts "  status: #{data['status']}" if data['status']
    puts "  archive: #{data['archive_url']}" if data['archive_url']
  end

  def parse_bool(value)
    case value.to_s.downcase
    when '1', 'true', 'yes' then true
    when '0', 'false', 'no' then false
    else
      abort "Invalid boolean: #{value}"
    end
  end

  def curl_config_quote(value)
    text = value.to_s
    abort 'Refusing to write control characters into curl config' if text.match?(/[\x00-\x1F\x7F]/)

    text.gsub('\\', '\\\\').gsub('"', '\"')
  end
end

SetappUpload.new(ARGV).run if __FILE__ == $PROGRAM_NAME
