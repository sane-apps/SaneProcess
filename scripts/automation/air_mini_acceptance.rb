#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'time'

module SaneAppsAirMiniAcceptance
  CommandResult = Struct.new(:stdout, :stderr, :exitstatus, :timed_out, :duration_seconds, keyword_init: true) do
    def success?
      exitstatus.zero? && !timed_out
    end

    def combined
      [stdout, stderr].reject(&:empty?).join("\n")
    end
  end

  class Runner
    def run(command, env: {}, timeout: 45)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout = +''
      stderr = +''
      status = nil
      timed_out = false

      Open3.popen3(env, *command, pgroup: true) do |stdin, out, err, wait_thr|
        stdin.close
        out_reader = Thread.new { out.read }
        err_reader = Thread.new { err.read }
        unless wait_thr.join(timeout)
          timed_out = true
          terminate_group(wait_thr.pid)
          wait_thr.join(5)
        end
        stdout = out_reader.value
        stderr = err_reader.value
        status = wait_thr.value if wait_thr.join(0)
      end

      CommandResult.new(
        stdout: stdout,
        stderr: stderr,
        exitstatus: status&.exitstatus || 124,
        timed_out: timed_out,
        duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      )
    rescue StandardError => e
      CommandResult.new(
        stdout: stdout,
        stderr: "#{stderr}\n#{e.class}: #{e.message}".strip,
        exitstatus: 125,
        timed_out: timed_out,
        duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      )
    end

    private

    def terminate_group(pid)
      Process.kill('TERM', -pid)
      sleep 1
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
      nil
    end
  end

  module Validators
    module_function

    def air_hostname?(text)
      text.downcase.include?('macbook-air')
    end

    def identity?(text, hostname_fragment:, user:)
      normalized = text.downcase
      normalized.include?(hostname_fragment.downcase) && text.lines.map(&:strip).include?(user)
    end

    def dependency_current?(text)
      text.include?('PASS dependency baseline current')
    end

    def versions_current?(text)
      {
        'node=v24.' => 'node=v24.',
        'npm=11.16.' => 'npm=11.16.',
        'ruby=ruby 4.0.' => 'ruby=ruby 4.0.',
        'python=Python 3.14.' => 'python=Python 3.14.',
        'tailscale=1.98.' => 'tailscale=1.98.',
        'codex=codex-cli 0.144.4' => 'codex=codex-cli 0.144.4',
        'claude=2.1.209' => 'claude=2.1.209'
      }.values.all? { |expected| text.include?(expected) }
    end

    def power_current?(text)
      %w[sleep displaysleep disksleep].all? { |key| text.match?(/^\s*#{key}\s+0\s*$/) } &&
        text.match?(/^\s*autorestart\s+1\s*$/)
    end

    def agentmemory_healthy?(text)
      count = text[/Memories:\s*(\d[\d,]*)/, 1]&.delete(',')&.to_i
      text.include?('v0.9.27') && text.match?(/Health:\s+.*healthy/) &&
        text.match?(/Embeddings:\s+.*embeddings/) && count && count >= 1_201
    end

    def agentmemory_service_supervised?(text)
      text.include?('com.saneapps.agentmemory') && text.include?('state = running') &&
        text.include?('sane-agentmemory-supervisor')
    end

    def agentmemory_tunnel_supervised?(text)
      text.include?('com.saneapps.agentmemory-tunnel') && text.include?('state = running') &&
        text.include?('agentmemory-mcp-air.sh') && text.include?('--tunnel')
    end

    def session_guardian_supervised?(text)
      text.include?('com.saneapps.session-guardian') &&
        text.include?('session-guardian.sh') &&
        text.include?('run interval = 600 seconds') &&
        text.include?('last exit code = 0')
    end

    def agentmemory_livez?(text)
      text.lines.any? { |line| line.strip == 'http=200' } &&
        text.lines.reject { |line| line.start_with?('http=') }.join.strip.length.positive?
    end

    def json_http_response(text)
      return nil unless text.lines.any? { |line| line.strip == 'http=200' }

      body = text.lines.reject { |line| line.start_with?('http=') }.join.strip
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def agentmemory_rest_health?(text)
      payload = json_http_response(text)
      payload.is_a?(Hash) && payload['service'] == 'agentmemory' && payload['status'] == 'healthy'
    end

    def agentmemory_search_response?(text)
      payload = json_http_response(text)
      payload.is_a?(Hash) && payload['results'].is_a?(Array) && !payload['results'].empty?
    end

    def credential_consumers_healthy?(text)
      text.include?('github-credential=available') &&
        text.match?(/Summary:\s+PASS=\d+\s+FAIL=0/)
    end

    def mcp_endpoint_healthy?(text)
      text.lines.any? { |line| line.start_with?('http=200') } &&
        (text.include?('jsonrpc') || text.include?('event: message'))
    end

    def repo_parity?(text)
      heads = text.lines.map(&:strip).reject(&:empty?)
      heads.length == 3 && heads.uniq.length == 1 && heads.first.match?(/\A[0-9a-f]{40}\z/)
    end
  end

  class Suite
    include Validators

    attr_reader :checks, :commands

    def initialize(repo_root:, home:, mini_host: 'mini', runner: Runner.new, sync: true)
      @repo_root = File.expand_path(repo_root)
      @home = File.expand_path(home)
      @mini_host = mini_host
      @runner = runner
      @sync = sync
      @checks = []
      @commands = []
    end

    def run
      local_host = execute('air-host', 'Air controller identity', 'air', ['/bin/hostname'], timeout: 10) do |text|
        Validators.air_hostname?(text)
      end
      return checks unless local_host[:passed]

      execute('air-process-access', 'Air process inspection', 'air', ['/bin/ps', '-axo', 'pid,ppid,command'], timeout: 10) do |text|
        text.include?('PID') || text.include?('COMMAND')
      end
      execute('air-dependencies', 'Air dependency baseline', 'air', dependency_command('air'), timeout: 180) do |text|
        Validators.dependency_current?(text)
      end
      execute('air-versions', 'Air client and runtime versions', 'air', version_command, timeout: 30) do |text|
        Validators.versions_current?(text)
      end
      execute('air-tailscale', 'Air Tailscale userspace CLI', 'air', ['tailscale', 'status'], timeout: 20) do |text|
        text.include?('stephans-mac-mini') && text.include?('stephans-macbook-air')
      end
      execute('air-tailscale-agent', 'Air Tailscale restart agent', 'air',
              ['/bin/launchctl', 'print', "gui/#{Process.uid}/com.saneapps.tailscaled-userspace"], timeout: 15) do |text|
        text.include?('state = running') && text.include?('runatload') && text.include?('keepalive')
      end
      execute('air-memory-agent', 'Air memory sync recurrence', 'air',
              ['/bin/launchctl', 'print', "gui/#{Process.uid}/com.saneapps.memory-sync"], timeout: 15) do |text|
        text.include?('com.saneapps.memory-sync')
      end
      execute('air-session-guardian', 'Air session guardian ownership and last run', 'air',
              ['/bin/launchctl', 'print', "gui/#{Process.uid}/com.saneapps.session-guardian"], timeout: 15) do |text|
        Validators.session_guardian_supervised?(text)
      end
      guardian = File.join(@repo_root, 'scripts/hooks/session-guardian.sh')
      execute('air-session-guardian-health', 'Air session guardian read-only health probe', 'air',
              ['/bin/bash', guardian, '--health'], timeout: 15) do |text|
        text.lines.map(&:strip).include?('session-guardian healthy')
      end
      air_agentmemory_checks
      private_route_check
      execute('air-mini-lan', 'Air to Mini normal SSH', 'air->mini', ssh('hostname; /usr/bin/whoami'), timeout: 30) do |text|
        Validators.identity?(text, hostname_fragment: 'mac-mini', user: 'stephansmac')
      end
      execute('air-mini-tailscale', 'Air to Mini forced Tailscale SSH', 'air->mini', ssh('hostname; /usr/bin/whoami'),
              env: { 'SANE_MINI_LAN_HOST' => '127.0.0.2' }, timeout: 30) do |text|
        Validators.identity?(text, hostname_fragment: 'mac-mini', user: 'stephansmac')
      end
      reverse_connectivity_check
      execute('mini-dependencies', 'Mini dependency baseline', 'mini', ssh(remote_dependency_command), timeout: 180) do |text|
        Validators.dependency_current?(text)
      end
      execute('mini-versions', 'Mini client and runtime versions', 'mini', ssh(remote_version_command), timeout: 30) do |text|
        Validators.versions_current?(text)
      end
      execute('mini-filevault', 'Mini FileVault disabled', 'mini', ssh('/usr/bin/fdesetup status'), timeout: 20) do |text|
        text.include?('FileVault is Off')
      end
      execute('mini-autologin', 'Mini automatic login', 'mini',
              ssh('/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser'), timeout: 20) do |text|
        text.lines.map(&:strip).include?('stephansmac')
      end
      execute('mini-power', 'Mini always-on power policy', 'mini', ssh('/usr/bin/pmset -g custom'), timeout: 20) do |text|
        Validators.power_current?(text)
      end
      mini_service_checks
      mini_agentmemory_rest_checks
      execute('mini-agentmemory-health', 'Mini AgentMemory health and corpus', 'mini',
              ssh('/opt/homebrew/bin/agentmemory status'), timeout: 30) do |text|
        Validators.agentmemory_healthy?(text)
      end
      credential_consumer_checks
      mini_mcp_checks
      retired_service_check
      repo_checks
      memory_sync_check if @sync
      focused_contract_checks
      checks
    end

    def pass?
      checks.any? && checks.all? { |check| check[:passed] }
    end

    def plan
      run
      commands.map { |entry| entry.reject { |key, _value| key == :env } }
    end

    private

    def execute(id, description, host, command, env: {}, timeout: 45, &validator)
      commands << { id: id, host: host, command: command, env: env, timeout: timeout }
      if @runner == :plan
        result = { id: id, description: description, host: host, passed: true, planned: true,
                   command: command, evidence: 'planned', duration_seconds: 0.0 }
        checks << result
        return result
      end

      command_result = @runner.run(command, env: env, timeout: timeout)
      evidence = command_result.combined.strip
      passed = command_result.success? && validator.call(evidence)
      result = {
        id: id,
        description: description,
        host: host,
        passed: passed,
        exitstatus: command_result.exitstatus,
        timed_out: command_result.timed_out,
        duration_seconds: command_result.duration_seconds,
        evidence: evidence[0, 1_500]
      }
      checks << result
      result
    end

    def ssh(remote_command)
      ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', @mini_host, remote_command]
    end

    def dependency_command(role)
      ['/opt/homebrew/opt/ruby/bin/ruby', File.join(@repo_root, 'scripts/automation/dependency_baseline.rb'),
       '--check', '--role', role]
    end

    def remote_dependency_command
      'cd "$HOME/SaneApps/infra/SaneProcess" && /opt/homebrew/opt/ruby/bin/ruby scripts/automation/dependency_baseline.rb --check --role mini'
    end

    def version_script
      <<~SH.gsub("\n", '; ')
        printf 'node=%s\n' "$(node --version)"
        printf 'npm=%s\n' "$(npm --version)"
        printf 'ruby=%s\n' "$(ruby --version)"
        printf 'python=%s\n' "$(python3.14 --version)"
        printf 'tailscale=%s\n' "$(tailscale version | /usr/bin/head -1)"
        printf 'codex=%s\n' "$(codex --version)"
        printf 'claude=%s\n' "$(claude --version)"
      SH
    end

    def version_command
      ['/bin/zsh', '-lc', version_script]
    end

    def remote_version_command
      "/bin/zsh -lc #{Shellwords.escape(version_script)}"
    end

    def github_credential_command
      node = '/opt/homebrew/opt/node@24/bin/node'
      bridge = File.join(@repo_root, 'scripts/codex-bin/github-mcp-bridge.mjs')
      [node, bridge, '--credential-status']
    end

    def credential_consumer_checks
      execute('air-github-credential', 'Air GitHub credential consumer', 'air',
              github_credential_command, timeout: 20) do |text|
        text.include?('github-credential=available')
      end
      remote_bridge = '$HOME/SaneApps/infra/SaneProcess/scripts/codex-bin/github-mcp-bridge.mjs'
      bootstrap = '$HOME/SaneApps/infra/SaneProcess/scripts/mini/bootstrap-build-server.sh'
      command = "/opt/homebrew/opt/node@24/bin/node #{remote_bridge} --credential-status && /bin/bash #{bootstrap}"
      execute('mini-credential-consumers', 'Mini signing, App Store, and GitHub credentials usable without export',
              'air->mini', ssh(command), timeout: 120) do |text|
        Validators.credential_consumers_healthy?(text)
      end
    end

    def mini_mcp_checks
      {
        'mini-mcp-apple-docs' => 37_911,
        'mini-mcp-macos-automator' => 37_913,
        'mini-mcp-serena' => 37_917
      }.each do |id, port|
        payload = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sane-acceptance","version":"1"}}}'
        command = "/usr/bin/curl --silent --show-error --max-time 8 -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data #{Shellwords.escape(payload)} -w '\\nhttp=%{http_code}\\n' http://127.0.0.1:#{port}/mcp"
        execute(id, "Mini #{id.delete_prefix('mini-mcp-')} MCP endpoint", 'mini', ssh(command), timeout: 20) do |text|
          Validators.mcp_endpoint_healthy?(text)
        end
      end
    end

    def air_agentmemory_checks
      execute('air-agentmemory-tunnel', 'Air AgentMemory tunnel supervision', 'air',
              ['/bin/launchctl', 'print', "gui/#{Process.uid}/com.saneapps.agentmemory-tunnel"], timeout: 15) do |text|
        Validators.agentmemory_tunnel_supervised?(text)
      end

      health = ['/usr/bin/curl', '--silent', '--show-error', '--max-time', '5',
                '-w', '\nhttp=%{http_code}\n', 'http://127.0.0.1:3111/agentmemory/health']
      execute('air-agentmemory-health', 'Air loopback AgentMemory health', 'air', health, timeout: 10) do |text|
        Validators.agentmemory_rest_health?(text)
      end

      payload = JSON.generate(query: 'SaneApps memory durability', limit: 1, format: 'compact')
      search = ['/usr/bin/curl', '--silent', '--show-error', '--max-time', '8',
                '-H', 'Content-Type: application/json', '--data', payload,
                '-w', '\nhttp=%{http_code}\n', 'http://127.0.0.1:3111/agentmemory/search']
      execute('air-agentmemory-search', 'Air AgentMemory search canary', 'air', search, timeout: 15) do |text|
        Validators.agentmemory_search_response?(text)
      end
    end

    def mini_agentmemory_rest_checks
      livez = "/usr/bin/curl --silent --show-error --max-time 5 -w '\\nhttp=%{http_code}\\n' http://127.0.0.1:3111/agentmemory/livez"
      execute('mini-agentmemory-livez', 'Mini direct AgentMemory livez', 'mini', ssh(livez), timeout: 15) do |text|
        Validators.agentmemory_livez?(text)
      end

      health = "/usr/bin/curl --silent --show-error --max-time 5 -w '\\nhttp=%{http_code}\\n' http://127.0.0.1:3111/agentmemory/health"
      execute('mini-agentmemory-rest-health', 'Mini direct AgentMemory JSON health', 'mini', ssh(health), timeout: 15) do |text|
        Validators.agentmemory_rest_health?(text)
      end

      payload = JSON.generate(query: 'SaneApps memory durability', limit: 1, format: 'compact')
      search = "/usr/bin/curl --silent --show-error --max-time 8 -H 'Content-Type: application/json' --data #{Shellwords.escape(payload)} -w '\\nhttp=%{http_code}\\n' http://127.0.0.1:3111/agentmemory/search"
      execute('mini-agentmemory-search', 'Mini direct AgentMemory search canary', 'mini', ssh(search), timeout: 20) do |text|
        Validators.agentmemory_search_response?(text)
      end
    end

    def private_route_check
      config = File.join(@home, '.ssh/config.d/saneapps-mini.conf')
      proxy = File.join(@home, '.local/bin/saneapps-mini-proxy')
      execute('air-private-routes', 'SSH ladder excludes public tunnels', 'air',
              ['/usr/bin/grep', '-EHi', 'trycloudflare|cloudflared', config, proxy], timeout: 10) do |_text|
        false
      end.tap do |result|
        result[:passed] = result[:exitstatus] == 1 unless result[:planned]
        result[:evidence] = 'No Cloudflare tunnel references' if result[:passed]
      end
    end

    def reverse_connectivity_check
      ip_result = @runner == :plan ? nil : @runner.run(['tailscale', 'ip', '-4'], timeout: 15)
      air_ip = ip_result&.stdout&.lines&.map(&:strip)&.find { |line| line.match?(/\A100\./) }
      remote = if air_ip
                 "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15 sj@#{air_ip} 'hostname; /usr/bin/whoami'"
               else
                 "/usr/bin/false # Air Tailscale IP unavailable"
               end
      execute('mini-air-return', 'Mini to Air return SSH', 'mini->air', ssh(remote), timeout: 35) do |text|
        Validators.identity?(text, hostname_fragment: 'macbook-air', user: 'sj')
      end
    end

    def mini_service_checks
      {
        'mini-always-awake' => ['Mini always-awake service', 'com.saneapps.always-awake', true],
        'mini-memory-guard' => ['Mini daily restart-free hygiene', 'com.saneapps.memory-guard', false],
        'mini-nightly' => ['Mini nightly server workflow', 'com.saneapps.nightly', false],
        'mini-agentmemory-service' => ['Mini AgentMemory restart service', 'com.saneapps.agentmemory', true]
      }.each do |id, (description, label, must_run)|
        command = "uid=$(/usr/bin/id -u); /bin/launchctl print gui/$uid/#{label}"
        execute(id, description, 'mini', ssh(command), timeout: 20) do |text|
          base_state = text.include?(label) && (!must_run || text.include?('state = running'))
          base_state && (label != 'com.saneapps.agentmemory' || Validators.agentmemory_service_supervised?(text))
        end
      end
      execute('mini-weekly-restart', 'Mini guarded weekly restart daemon', 'mini',
              ssh('/bin/launchctl print system/com.saneapps.weekly-restart'), timeout: 20) do |text|
        text.include?('sane-mini-weekly-restart') && %w[10 11 12].all? { |hour| text.include?("\"Hour\" => #{hour}") }
      end
    end

    def retired_service_check
      labels = %w[com.saneapps.training com.saneapps.training-daily-check com.saneapps.training-challengers
                  com.saneapps.training-weekly com.saneapps.saneai-weekend-training-watchdog com.saneapps.nv-benchmark]
      script = "uid=$(/usr/bin/id -u); " + labels.map do |label|
        "/bin/launchctl print gui/$uid/#{label} >/dev/null 2>&1 && { echo active:#{label}; exit 1; }"
      end.join('; ') + '; exit 0'
      execute('mini-retired-training', 'Retired AI training services absent', 'mini', ssh(script), timeout: 20) do |text|
        !text.include?('active:')
      end
    end

    def repo_checks
      {
        'saneprocess-parity' => 'infra/SaneProcess',
        'sanecite-parity' => 'websites/sanecite-saas'
      }.each do |id, relative|
        local = File.join(@home, 'SaneApps', relative)
        command = ['/bin/zsh', '-lc', <<~SH.gsub("\n", '; ')]
          git -C #{Shellwords.escape(local)} rev-parse HEAD
          ssh -o BatchMode=yes #{@mini_host} 'git -C "$HOME/SaneApps/#{relative}" rev-parse HEAD'
          git -C #{Shellwords.escape(local)} ls-remote origin refs/heads/main | awk '{print $1}'
        SH
        execute(id, "#{File.basename(relative)} Air/Mini/origin parity", 'air+mini+github', command, timeout: 40) do |text|
          Validators.repo_parity?(text)
        end
      end
    end

    def memory_sync_check
      script = File.join(@repo_root, 'scripts/automation/sync-memory-mini.sh')
      execute('memory-checksum-parity', 'Claude/Serena/Codex memory parity', 'air<->mini',
              ['/bin/bash', script, @mini_host, '--strict'], timeout: 180) do |text|
        text.include?('Memory sync complete with checksum parity')
      end
    end

    def focused_contract_checks
      tests = %w[
        scripts/mini/mini_weekly_restart_test.rb
        scripts/mini/mini_memory_guard_test.rb
        scripts/mini/mini_access_test.rb
        scripts/mini/mini_agentmemory_test.rb
        scripts/mini/mini_agentmemory_supervisor_test.rb
        scripts/mini/mini_agentmemory_installer_safety_test.rb
        scripts/automation/dependency_baseline_test.rb
        scripts/automation/memory_sync_test.rb
        scripts/automation/session_guardian_test.rb
      ]
      command = ['/bin/zsh', '-lc', tests.map { |path| "ruby #{Shellwords.escape(File.join(@repo_root, path))}" }.join(' && ')]
      execute('acceptance-contracts', 'Server/access/sync regression contracts', 'air', command, timeout: 300) do |text|
        !text.include?('failed (') && !text.include?('❌') &&
          text.scan(/passed \(0 failed\)|PASS \d+\/\d+/).length >= tests.length
      end
    end
  end

  module_function

  def write_receipts(directory, payload)
    FileUtils.mkdir_p(directory)
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    json_path = File.join(directory, "#{stamp}.json")
    markdown_path = File.join(directory, "#{stamp}.md")
    File.write(json_path, JSON.pretty_generate(payload) + "\n")
    lines = ["# Air Mini Restart Acceptance", '', "- Generated: #{payload[:generated_at]}",
             "- Result: #{payload[:passed] ? 'PASS' : 'FAIL'}", '']
    payload[:checks].each do |check|
      lines << "- #{check[:passed] ? 'PASS' : 'FAIL'} `#{check[:id]}` (#{check[:host]}): #{check[:description]}"
      lines << "  - #{check[:evidence].to_s.lines.first.to_s.strip}" unless check[:evidence].to_s.empty?
    end
    File.write(markdown_path, lines.join("\n") + "\n")
    [json_path, markdown_path]
  end

  def main(argv)
    options = { mini: 'mini', sync: true, json: false, plan: false, output: nil }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: air_mini_acceptance.rb [--mini HOST] [--skip-sync] [--json] [--plan] [--output DIR]'
      opts.on('--mini HOST') { |value| options[:mini] = value }
      opts.on('--skip-sync') { options[:sync] = false }
      opts.on('--json') { options[:json] = true }
      opts.on('--plan') { options[:plan] = true }
      opts.on('--output DIR') { |value| options[:output] = value }
    end
    parser.parse!(argv)

    repo_root = File.expand_path('../..', __dir__)
    home = Dir.home
    suite = Suite.new(repo_root: repo_root, home: home, mini_host: options[:mini],
                      runner: options[:plan] ? :plan : Runner.new, sync: options[:sync])
    if options[:plan]
      puts JSON.pretty_generate(suite.plan)
      return 0
    end

    suite.run
    payload = {
      schema_version: 1,
      generated_at: Time.now.utc.iso8601,
      passed: suite.pass?,
      checks: suite.checks
    }
    output = options[:output] || File.join(repo_root, 'outputs/restart-acceptance')
    paths = write_receipts(output, payload)
    if options[:json]
      puts JSON.pretty_generate(payload.merge(receipts: paths))
    else
      suite.checks.each { |check| puts "#{check[:passed] ? 'PASS' : 'FAIL'} #{check[:id]}: #{check[:description]}" }
      puts "Receipt: #{paths.join(', ')}"
    end
    suite.pass? ? 0 : 1
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    2
  end
end

exit SaneAppsAirMiniAcceptance.main(ARGV) if $PROGRAM_NAME == __FILE__
