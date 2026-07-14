#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

GUARD_PATH = File.expand_path('mini-memory-guard.sh', __dir__)
INSTALLER_PATH = File.expand_path('mini-install-memory-guard.sh', __dir__)

guard_source = File.read(GUARD_PATH)
installer_source = File.read(INSTALLER_PATH)

def write_executable(path, body)
  File.write(path, body)
  FileUtils.chmod(0o755, path)
end

def run_guard_fixture(cleanup_sleep: 0, timeout_seconds: 5, child_ignores_term: false)
  Dir.mktmpdir('mini-memory-guard-test') do |home|
    bin = File.join(home, 'bin')
    FileUtils.mkdir_p(bin)
    power_marker = File.join(home, 'power-command-called')
    child_pid_path = File.join(home, 'cleanup-child.pid')

    write_executable(File.join(bin, 'uptime'), <<~SH)
      #!/bin/sh
      echo '10:00 up 12 days, 1 user, load averages: 1.00 1.00 1.00'
    SH
    write_executable(File.join(bin, 'sysctl'), <<~SH)
      #!/bin/sh
      echo 'vm.swapusage: total = 12288.00M  used = 9000.00M  free = 3288.00M'
    SH
    write_executable(File.join(bin, 'memory_pressure'), <<~SH)
      #!/bin/sh
      echo 'System-wide memory free percentage: 50%'
    SH
    write_executable(File.join(bin, 'ps'), <<~SH)
      #!/bin/sh
      exit 0
    SH
    write_executable(File.join(bin, 'pgrep'), <<~SH)
      #!/bin/sh
      exit 1
    SH
    %w[osascript shutdown reboot halt poweroff].each do |command|
      write_executable(File.join(bin, command), <<~SH)
        #!/bin/sh
        echo #{command} >> #{power_marker.inspect}
      SH
    end

    sanemaster = File.join(home, 'SaneApps/infra/SaneProcess/scripts/SaneMaster.rb')
    FileUtils.mkdir_p(File.dirname(sanemaster))
    child_command = if child_ignores_term
                      "Process.spawn('/bin/sh', '-c', 'trap \"\" TERM; exec /bin/sleep #{cleanup_sleep}')"
                    else
                      "Process.spawn('/bin/sleep', #{cleanup_sleep.to_s.inspect})"
                    end
    File.write(sanemaster, <<~RUBY)
      child = #{child_command}
      File.write(#{child_pid_path.inspect}, child.to_s)
      Process.wait(child)
    RUBY

    env = {
      'HOME' => home,
      'PATH' => "#{bin}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      'MACHINE_CLEANUP_TIMEOUT_SECONDS' => timeout_seconds.to_s
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3(env, '/bin/bash', GUARD_PATH, '--dry-run')
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    child_pid = File.exist?(child_pid_path) ? Integer(File.read(child_pid_path)) : nil
    child_alive = if child_pid
                    begin
                      Process.kill(0, child_pid)
                      true
                    rescue Errno::ESRCH
                      false
                    end
                  else
                    false
                  end
    guard_log = File.join(home, 'SaneApps/outputs/mini_memory_guard.log')

    {
      stdout: stdout,
      stderr: stderr,
      status: status,
      elapsed: elapsed,
      power_called: File.exist?(power_marker),
      child_alive: child_alive,
      guard_log: File.exist?(guard_log) ? File.read(guard_log) : ''
    }
  end
end

exit(run_tests('Mini Memory Guard Tests') do
  test_category('Cleanup coverage') do
    test('guards the high-risk accumulation roots') do
      assert_includes(guard_source, '$HOME/.sanemaster/routed-workspaces/')
      assert_includes(guard_source, '$HOME/.codex-sync-backups/')
      assert(!guard_source.include?('$HOME/.Trash/'), 'Trash must not be an automatic permanent-delete root')
      assert_includes(guard_source, 'automatic server hygiene never permanently deletes user Trash')
      assert_includes(guard_source, 'Refusing cleanup through symlinked path component')
      assert_includes(guard_source, '/usr/bin/trash "$path"')
      assert(!guard_source.include?('rm -rf'), 'daily hygiene must not permanently delete allowlisted paths')
      assert_includes(guard_source, '$HOME/SaneApps/outputs/setapp_review/')
      assert_includes(guard_source, '$HOME/SaneApps/tmp/')
      assert_includes(guard_source, '$HOME/tmp/')
      assert_includes(guard_source, '$HOME/Library/Developer/CoreSimulator/Devices/')
      assert_includes(guard_source, 'SaneMaster.rb')
      assert_includes(guard_source, 'machine_cleanup --host local --server')
      assert_includes(guard_source, '$HOME/SaneApps-automation/apps/')
      assert_includes(guard_source, '$HOME/SaneApps/apps/SaneVideo/outputs')
      true
    end

    test('runs the new cleanup passes from main') do
      assert_includes(guard_source, 'cleanup_routed_workspaces')
      assert_includes(guard_source, 'cleanup_orphaned_compiler_services')
      assert_includes(guard_source, 'cleanup_sanevideo_outputs')
      assert_includes(guard_source, 'cleanup_codex_sync_backups')
      assert_includes(guard_source, 'cleanup_stale_automation_git_locks')
      assert_includes(guard_source, 'cleanup_setapp_review_outputs')
      assert_includes(guard_source, 'cleanup_tmp_workspaces')
      assert_includes(guard_source, 'run_sanemaster_server_cleanup')
      assert_includes(guard_source, 'cleanup_trash')
      assert_includes(guard_source, 'cleanup_coresimulator_devices')
      true
    end

    test('protects Swift, SaneMaster, and active DerivedData runtime work') do
      script = File.read(GUARD_PATH)
      assert_includes(script, 'swift (build|test)')
      assert_includes(script, 'SaneMaster.*(verify|launch|release|test_mode)')
      assert_includes(script, '/DerivedData/.*/Sane[^ ]*\\.app/Contents/MacOS/Sane')
      assert(!script.include?('cleanup_stale_deriveddata_apps'), 'daily hygiene must never kill a live test app by pathname')
      assert(!script.include?("pkill -f '/DerivedData/"), 'daily hygiene must not terminate DerivedData app runtimes')
      true
    end

    test('reaps orphaned Apple compiler services only when idle') do
      assert_includes(guard_source, 'cleanup_orphaned_compiler_services()')
      assert_includes(guard_source, 'Compiler service cleanup skipped because a build is active.')
      assert_includes(guard_source, 'ANECompilerService')
      assert_includes(guard_source, 'MTLCompilerService')
      assert_includes(guard_source, '[ "$ppid" = "1" ] || continue')
      assert_includes(guard_source, '.compiler_service_reboot_required')
      assert_includes(guard_source, 'marking Mini restart required')
      assert_includes(guard_source, 'COMPILER_SERVICE_REBOOT_RSS_KB')
      assert_includes(guard_source, 'Leaving normal-sized $service_name')
      true
    end

    test('supports focused compiler-service cleanup without full hygiene pass') do
      assert_includes(guard_source, '--compiler-services-only')
      assert_includes(guard_source, 'COMPILER_SERVICES_ONLY=1')
      assert_includes(guard_source, 'Health after compiler-service cleanup')
      true
    end

    test('recovers stale automation git locks without racing active git') do
      assert_includes(guard_source, 'cleanup_stale_automation_git_locks()')
      assert_includes(guard_source, 'local automation_root="${AUTOMATION_ROOT:-$HOME/SaneApps-automation}"')
      assert_includes(guard_source, 'ps axww -o pid= -o comm= -o command=')
      assert_includes(guard_source, '$2 ~ /(^|\/)git$/')
      assert_includes(guard_source, 'index($0, root)')
      assert_includes(guard_source, 'find "$automation_root" -path "*/.git/index.lock" -mmin +"$stale_after_min"')
      true
    end

    test('logs disk free space before and after cleanup') do
      assert_includes(guard_source, 'disk_free_gb')
      assert_includes(guard_source, 'get_data_disk_free_gb')
      true
    end

    test('treats unreadable size probes as non-fatal') do
      assert_includes(guard_source, 'path_size_mb()')
      assert_includes(guard_source, 'mb="$(du -sm "$1" 2>/dev/null | awk')
      assert_includes(guard_source, '|| mb=0')
      assert_includes(guard_source, 'path_size_mb "$trash_root"')
      assert_includes(guard_source, 'path_size_mb "$devices_root"')
      assert_includes(guard_source, 'path_size_mb "$dd_root"')
      true
    end

    test('rotates active server logs') do
      assert_includes(guard_source, 'nightly.stdout.log')
      assert_includes(guard_source, 'memory-guard.stdout.log')
      true
    end
  end

  test_category('Installer path') do
    test('points the launch agent at the canonical SaneProcess script path') do
      assert_includes(installer_source, '$HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-memory-guard.sh')
      true
    end
  end


  test_category('Always-on runtime behavior') do
    test('does not invoke a power command despite high swap and long uptime') do
      result = run_guard_fixture
      assert(result[:status].success?, result[:stderr])
      assert(!result[:power_called], 'daily guard invoked a shutdown or restart command')
      assert_includes(result[:stdout], 'auto_restart=disabled')
      true
    end

    test('times out deep cleanup, kills its process group, and finishes hygiene') do
      result = run_guard_fixture(cleanup_sleep: 60, timeout_seconds: 1, child_ignores_term: true)
      assert(result[:status].success?, result[:stderr])
      assert(result[:elapsed] < 10, "guard took #{result[:elapsed].round(2)}s")
      assert(!result[:child_alive], 'timed-out cleanup left a child process alive')
      assert_includes(result[:stdout], 'server cleanup timed out after 1s', result[:guard_log])
      assert_includes(result[:stdout], 'mini-memory-guard complete')
      true
    end

    test('timeout always kills the process group after the TERM grace period') do
      script = File.read(GUARD_PATH)
      term_index = script.index('Process.kill("TERM", -wait_thr.pid)')
      kill_index = script.index('Process.kill("KILL", -wait_thr.pid)')
      assert(term_index && kill_index && kill_index > term_index)
      assert(!script.include?('wait_thr.join(5) || (Process.kill("KILL"'))
      true
    end
  end
end)
