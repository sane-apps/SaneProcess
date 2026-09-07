#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'test/test_framework'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

include TestFramework

GUARD = File.expand_path('session-guardian.sh', __dir__)
guard_source = File.read(GUARD)

def write_file(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
end

def run_guard(home, extra_env = {}, args: ['--cpu-only', '--json'])
  env = {
    'HOME' => home,
    'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
    'SANE_GUARDIAN_SKIP_REAP' => '1',
    'SANE_GUARDIAN_SKIP_MEMORY' => '1',
    'SANE_GUARDIAN_SKIP_REMOTE' => '1',
    'SANE_GUARDIAN_NOTIFY' => '0',
    'SANE_GUARDIAN_LOG' => File.join(home, 'guardian.log'),
    'SANE_GUARDIAN_STATE_DIR' => File.join(home, 'state'),
    'SANE_GUARDIAN_CPU_JSON' => File.join(home, 'state', 'session-guardian-cpu.json'),
    'SANE_GUARDIAN_NOTIFY_SINK' => File.join(home, 'notify.txt')
  }.merge(extra_env)
  stdout, stderr, status = Open3.capture3(env, '/bin/bash', GUARD, *args)
  json = stdout.lines.reverse.find { |line| line.start_with?('{') }
  report = json ? JSON.parse(json) : nil
  {
    stdout: stdout,
    stderr: stderr,
    status: status,
    report: report,
    notify: File.exist?(env['SANE_GUARDIAN_NOTIFY_SINK']) ? File.read(env['SANE_GUARDIAN_NOTIFY_SINK']) : '',
    log: File.exist?(env['SANE_GUARDIAN_LOG']) ? File.read(env['SANE_GUARDIAN_LOG']) : '',
    json_path: env['SANE_GUARDIAN_CPU_JSON']
  }
end

def unexpected_ps
  <<~PS
    99.0 111 /Users/sj/SaneApps/infra/SaneProcess/scripts/automation/sync-memory-mini.sh
    88.0 222 grep -R . /Users/sj/SaneApps
    1.0 333 /usr/libexec/logd
  PS
end

def expected_ps
  <<~PS
    91.0 111 /usr/bin/xcodebuild -scheme SaneClip
    70.0 222 /Applications/SaneClip.app/Contents/MacOS/SaneClip --sane-skip-app-move
    40.0 333 /usr/bin/caffeinate -dimsu
    21.0 444 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser
  PS
end

exit(run_tests('Session guardian CPU watch tests') do
  test_category('Safety invariants') do
    test('still reaps only ppid 1 disposable family and never live CPU') do
      assert_includes(guard_source, '[ "$ppid" = "1" ] || continue')
      assert_includes(guard_source, 'never auto-killed')
      assert_includes(guard_source, 'ROLE" == "air"')
      assert(!guard_source.match?(/kill .*\$pid.*cpu/i), 'CPU path must not kill by pid')
      true
    end

    test('pages Air after two consecutive unexpected samples and ignores expected work') do
      assert_includes(guard_source, 'SANE_GUARDIAN_CONSECUTIVE')
      assert_includes(guard_source, 'expected_busy')
      assert_includes(guard_source, 'xcodebuild')
      assert_includes(guard_source, 'Brave Browser')
      assert_includes(guard_source, 'Mini CPU watch')
      expected_block = guard_source[/EXPECTED = \[.*?\]/m].to_s
      assert(!expected_block.include?('sync-memory-mini'), 'sync-memory-mini must not be expected work')
      true
    end
  end

  test_category('Classifier') do
    test('low load stays quiet') do
      Dir.mktmpdir('guardian-cpu') do |home|
        ps = File.join(home, 'ps.txt')
        write_file(ps, unexpected_ps)
        result = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'air',
          'SANE_GUARDIAN_NCPU' => '10',
          'SANE_GUARDIAN_LOAD5' => '1.2',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_NOW' => '1000'
        })
        assert(result[:status].success?, result[:stderr])
        assert_eq(result[:report]['status'], 'ok')
        assert_eq(result[:report]['notify'], false)
        assert_eq(result[:notify], '')
        true
      end
    end

    test('high load from xcodebuild and SaneClip is expected_busy') do
      Dir.mktmpdir('guardian-cpu') do |home|
        ps = File.join(home, 'ps.txt')
        write_file(ps, expected_ps)
        result = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'mini',
          'SANE_GUARDIAN_NCPU' => '8',
          'SANE_GUARDIAN_LOAD5' => '7.5',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_NOW' => '1000'
        })
        assert(result[:status].success?, result[:stderr])
        assert_eq(result[:report]['status'], 'expected_busy')
        assert_eq(result[:report]['notify'], false)
        assert_eq(result[:notify], '')
        true
      end
    end

    test('sync-memory-mini and grep are unexpected and not allowlisted') do
      Dir.mktmpdir('guardian-cpu') do |home|
        ps = File.join(home, 'ps.txt')
        write_file(ps, unexpected_ps)
        first = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'air',
          'SANE_GUARDIAN_NCPU' => '10',
          'SANE_GUARDIAN_LOAD5' => '9.5',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_NOW' => '1000'
        })
        assert_eq(first[:report]['status'], 'unexpected', first[:report].inspect)
        assert_eq(first[:report]['consecutive_unexpected'], 1, first[:report].inspect)
        assert_eq(first[:report]['notify'], false)
        assert(first[:report]['signature'].include?('sync-memory-mini.sh'), first[:report]['signature'])
        assert_eq(first[:notify], '')

        second = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'air',
          'SANE_GUARDIAN_NCPU' => '10',
          'SANE_GUARDIAN_LOAD5' => '9.5',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_NOW' => '1600'
        })
        assert_eq(second[:report]['consecutive_unexpected'], 2, second[:report].inspect)
        assert_eq(second[:report]['notify'], true, second[:report].inspect)
        assert(second[:notify].include?('Air CPU watch'), second[:notify])
        assert(second[:notify].include?('sync-memory-mini.sh'), second[:notify])

        third = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'air',
          'SANE_GUARDIAN_NCPU' => '10',
          'SANE_GUARDIAN_LOAD5' => '9.5',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_NOW' => '1700'
        })
        assert_eq(third[:report]['notify'], false, third[:report].inspect)
        assert_eq(third[:notify].lines.length, 1, third[:notify])
        true
      end
    end

    test('Mini records the hit but does not notify locally') do
      Dir.mktmpdir('guardian-cpu') do |home|
        ps = File.join(home, 'ps.txt')
        write_file(ps, unexpected_ps)
        env = {
          'SANE_GUARDIAN_ROLE' => 'mini',
          'SANE_GUARDIAN_NCPU' => '8',
          'SANE_GUARDIAN_LOAD5' => '7.9',
          'SANE_GUARDIAN_PS_FILE' => ps
        }
        run_guard(home, env.merge('SANE_GUARDIAN_NOW' => '1000'))
        second = run_guard(home, env.merge('SANE_GUARDIAN_NOW' => '1600'))
        assert_eq(second[:report]['host_role'], 'mini')
        assert_eq(second[:report]['should_alert'], true)
        assert_eq(second[:report]['notify'], false)
        assert_eq(second[:notify], '')
        true
      end
    end

    test('Air pages Mini heat from Mini JSON without killing anything') do
      Dir.mktmpdir('guardian-cpu') do |home|
        ps = File.join(home, 'ps.txt')
        write_file(ps, "1.0 1 /usr/libexec/logd\n")
        mini = File.join(home, 'mini.json')
        write_file(mini, JSON.pretty_generate({
          'status' => 'unexpected',
          'consecutive_unexpected' => 2,
          'sampled_at' => 1000,
          'load5' => 7.9,
          'ncpu' => 8,
          'signature' => 'sync-memory-mini.sh',
          'offenders' => [{
            'cpu' => 99.0,
            'pid' => 111,
            'command' => '/Users/stephansmac/SaneApps/infra/SaneProcess/scripts/automation/sync-memory-mini.sh'
          }]
        }))
        result = run_guard(home, {
          'SANE_GUARDIAN_ROLE' => 'air',
          'SANE_GUARDIAN_NCPU' => '10',
          'SANE_GUARDIAN_LOAD5' => '1.1',
          'SANE_GUARDIAN_PS_FILE' => ps,
          'SANE_GUARDIAN_MINI_JSON' => mini,
          'SANE_GUARDIAN_NOW' => '1100'
        })
        assert_eq(result[:report]['status'], 'ok')
        assert_eq(result[:report]['notify'], true)
        assert(result[:notify].start_with?('Mini CPU watch'))
        assert(result[:notify].include?('sync-memory-mini.sh'))
        true
      end
    end
  end

  test_category('Installer') do
    test('writes the same LaunchAgent on both hosts without launchctl') do
      Dir.mktmpdir('guardian-install') do |home|
        env = {
          'HOME' => home,
          'SANE_GUARDIAN_SKIP_LAUNCHCTL' => '1',
          'SANE_GUARDIAN_OUT_LOG' => File.join(home, 'out.log'),
          'SANE_GUARDIAN_ERR_LOG' => File.join(home, 'err.log')
        }
        stdout, stderr, status = Open3.capture3(env, '/bin/bash', GUARD, '--install')
        assert(status.success?, stderr)
        plist = File.join(home, 'Library/LaunchAgents/com.saneapps.session-guardian.plist')
        assert(File.exist?(plist), stdout)
        body = File.read(plist)
        assert_includes(body, 'session-guardian.sh')
        assert_includes(body, '<integer>600</integer>')
        assert_includes(body, '<integer>10</integer>')
        true
      end
    end
  end
end)
