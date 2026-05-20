#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

TRAIN_PATH = File.expand_path('mini-train.sh', __dir__)

train_source = File.read(TRAIN_PATH)

exit(run_tests('Mini Train Cleanup Tests') do
  test_category('Checkpoint pruning') do
    test('configures checkpoint retention') do
      assert_includes(train_source, 'CHECKPOINT_FILES_TO_KEEP="${CHECKPOINT_FILES_TO_KEEP:-1}"')
      true
    end

    test('implements the checkpoint prune helper') do
      assert_includes(train_source, 'prune_checkpoint_files() {')
      assert_includes(train_source, 'Pruned intermediate checkpoints')
      true
    end

    test('prunes checkpoints after interrupted or successful eval paths') do
      assert_includes(train_source, 'prune_checkpoint_files "$ADAPTER_DIR" "$CHECKPOINT_FILES_TO_KEEP" "$REPORT"')
      true
    end
  end

  test_category('Compiler service cleanup') do
    test('reaps orphaned Apple compiler services after training cleanup') do
      assert_includes(train_source, 'reap_orphaned_compiler_services()')
      assert_includes(train_source, 'ANECompilerService')
      assert_includes(train_source, 'MTLCompilerService')
      assert_includes(train_source, 'ppid=$(ps -o ppid= -p "$pid"')
      assert_includes(train_source, '[ "$ppid" = "1" ] || continue')
      assert_includes(train_source, 'reap_orphaned_compiler_services || true')
      assert_includes(train_source, '.compiler_service_reboot_required')
      assert_includes(train_source, 'COMPILER_SERVICE_REBOOT_RSS_KB')
      assert_includes(train_source, 'Leaving normal-sized $service_name')
      true
    end
  end
end)
