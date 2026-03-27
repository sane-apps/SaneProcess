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
      assert_includes(guard_source, '$HOME/SaneApps/apps/SaneVideo/outputs')
      true
    end

    test('runs the new cleanup passes from main') do
      assert_includes(guard_source, 'cleanup_routed_workspaces')
      assert_includes(guard_source, 'cleanup_sanevideo_outputs')
      assert_includes(guard_source, 'cleanup_codex_sync_backups')
      assert_includes(guard_source, 'cleanup_trash')
      true
    end

    test('logs disk free space before and after cleanup') do
      assert_includes(guard_source, 'disk_free_gb')
      assert_includes(guard_source, 'get_data_disk_free_gb')
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
