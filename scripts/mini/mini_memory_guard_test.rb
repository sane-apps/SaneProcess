#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

GUARD_PATH = File.expand_path('mini-memory-guard.sh', __dir__)
INSTALLER_PATH = File.expand_path('mini-install-memory-guard.sh', __dir__)

guard_source = File.read(GUARD_PATH)
installer_source = File.read(INSTALLER_PATH)

exit(run_tests('Mini Memory Guard Tests') do
  test_category('Cleanup coverage') do
    test('guards the high-risk accumulation roots') do
      assert_includes(guard_source, '$HOME/.sanemaster/routed-workspaces/')
      assert_includes(guard_source, '$HOME/.codex-sync-backups/')
      assert_includes(guard_source, '$HOME/.Trash/')
      assert_includes(guard_source, '$HOME/SaneApps/outputs/setapp_review/')
      assert_includes(guard_source, '$HOME/SaneApps/tmp/')
      assert_includes(guard_source, '$HOME/tmp/')
      assert_includes(guard_source, '$HOME/Library/Developer/CoreSimulator/Devices/')
      assert_includes(guard_source, '$HOME/SaneApps-automation/apps/')
      assert_includes(guard_source, '$HOME/SaneApps/apps/SaneVideo/outputs')
      true
    end

    test('prunes training artifacts from both human and automation roots') do
      assert_includes(guard_source, 'for sane_root in "$HOME/SaneApps" "$HOME/SaneApps-automation"; do')
      assert_includes(guard_source, '"$sane_root/apps/SaneAI/models/sweeps"')
      assert_includes(guard_source, '"$sane_root/apps/SaneSync/models/sweeps"')
      true
    end

    test('runs the new cleanup passes from main') do
      assert_includes(guard_source, 'cleanup_routed_workspaces')
      assert_includes(guard_source, 'cleanup_sanevideo_outputs')
      assert_includes(guard_source, 'cleanup_codex_sync_backups')
      assert_includes(guard_source, 'cleanup_stale_automation_git_locks')
      assert_includes(guard_source, 'cleanup_setapp_review_outputs')
      assert_includes(guard_source, 'cleanup_tmp_workspaces')
      assert_includes(guard_source, 'cleanup_trash')
      assert_includes(guard_source, 'cleanup_coresimulator_devices')
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

    test('rotates challenger, weekly, and guard logs') do
      assert_includes(guard_source, 'training-challengers.stdout.log')
      assert_includes(guard_source, 'training-weekly.stderr.log')
      assert_includes(guard_source, 'memory-guard.stdout.log')
      assert_includes(guard_source, 'alerts/training/history.log')
      true
    end
  end

  test_category('Installer path') do
    test('points the launch agent at the canonical SaneProcess script path') do
      assert_includes(installer_source, '$HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-memory-guard.sh')
      true
    end
  end
end)
