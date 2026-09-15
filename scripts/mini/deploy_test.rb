#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'open3'
require 'tmpdir'

include TestFramework

exit(run_tests('Mini Deploy Tests') do
  test_category('retired training lane') do
    test('deploy cannot reinstall retired training agents') do
      script = File.read(File.join(__dir__, 'deploy.sh'))

      assert(!script.include?('ENABLE_MINI_TRAINING_AGENTS'))
      assert(script.include?('is_retired_training_file'))
      assert(script.include?('launchctl disable "gui/$uid/$label"'))
      assert(script.include?('SaneApps-automation/apps/SaneAI'))
      assert(script.include?('SaneApps-automation/apps/SaneSync'))
      assert(script.include?('Training agents are retired'))
      true
    end

    test('deploy supports local Mini execution without self-SSH') do
      script = File.read(File.join(__dir__, 'deploy.sh'))

      assert(script.include?('Usage: bash scripts/mini/deploy.sh [--local]'))
      assert(script.include?('LOCAL_MODE=0'))
      assert(script.match?(/--local\).*?LOCAL_MODE=1/m))
      assert(script.include?('Deploying Mini services locally (no self-SSH)'))
      assert(script.match?(/mini_ssh\(\).*?if \[ "\$LOCAL_MODE" -eq 1 \].*?\/bin\/bash -lc "\$\*"/m))
      assert(script.include?('security unlock-keychain "$keychain"'))
      assert(script.include?('security set-keychain-settings "$keychain"'))
      true
    end


    test('weekly restart installer prompts only in an interactive terminal') do
      script = File.read(File.join(__dir__, 'mini-install-weekly-restart.sh'))

      assert(script.include?('if [ -t 0 ]; then'))
      assert(script.include?('SUDO=(/usr/bin/sudo)'))
      assert(script.include?('SUDO=(/usr/bin/sudo -n)'))
      assert(script.include?('"${SUDO[@]}" launchctl bootstrap system "$PLIST"'))
      true
    end

    test('automation prep cannot hydrate retired training data') do
      script = File.read(File.join(__dir__, 'mini-prepare-automation-root.sh'))

      assert(!script.include?('hydrate_training_dataset "SaneSync"'))
      assert(!script.include?('hydrate_training_dataset "SaneAI"'))
      assert(!script.include?('hydrate_training_dataset "SaneVideo"'))
      assert(script.match?(/is_retired_repo_name\(\).*?SaneAI\|SaneSync/m))
      assert(script.include?('if is_retired_repo_name "$name"'))
      assert(script.include?('prune_retired_automation_repos'))
      assert(script.include?('target="$AUTOMATION_ROOT/apps/$name"'))
      assert(script.include?('/usr/bin/trash "$target"'))
      assert(script.include?('git clone --quiet --branch "$branch" --single-branch "$source_repo" "$target_repo"'))
      assert(script.include?('git -C "$target_repo" remote set-url origin "$origin_url"'))
      assert(script.include?('Training data hydration retired'))
      true
    end

    test('nightly operator brief remains scheduled and local AI lane is removed') do
      script = File.read(File.join(__dir__, 'mini-nightly.sh'))

      assert(!script.include?('RUN_SANEAI_WORKFLOW_READINESS'))
      assert(!script.include?('SaneAI Workflow Readiness'))
      assert(!script.include?('Active Training Alerts'))
      assert(!script.include?('machine_cleanup --host local --server'))
      assert(script.include?('ruby "$SANEMASTER_SCRIPT" operator_brief'))
      assert(script.include?('--apply --npm-only --latest --role mini'))
      assert(script.include?('OPERATOR_BRIEF_OUTPUT="$OUTPUT_DIR/operator_brief.md"'))
      assert(script.include?('SANEMASTER_SCRIPT="$CANONICAL_SOURCE_ROOT/infra/SaneProcess/scripts/SaneMaster.rb"'))
      assert(!script.include?('MACHINE_CLEANUP_SCRIPT'))
      true
    end

    test('nightly uses a pid-owned lock without recursive deletion') do
      script = File.read(File.join(__dir__, 'mini-nightly.sh'))

      assert(script.include?('LOCK_OWNER_FILE="$LOCK_DIR/owner.pid"'))
      assert(script.include?('kill -0 "$owner"'))
      assert(script.include?('printf \'%s\\n\' "$$" > "$LOCK_OWNER_FILE"'))
      assert(script.include?('rmdir "$LOCK_DIR"'))
      assert(!script.include?('rm -rf'))
      true
    end

    test('nightly delegates each active repo to bounded canonical verify') do
      script = File.read(File.join(__dir__, 'mini-nightly.sh'))

      assert(script.include?('run_bounded_command()'))
      assert(script.include?('pgroup: true'))
      assert(script.include?('Process.kill("TERM", -child_pid)'))
      assert(script.include?('Process.kill("KILL", -child_pid)'))
      assert(script.include?('SANEMASTER_VERIFY_TIMEOUT="$VERIFY_TIMEOUT_SECONDS"'))
      assert(script.include?('"$repo_dir/scripts/SaneMaster.rb" verify --timeout "$VERIFY_TIMEOUT_SECONDS" --no-grant-permissions'))
      assert(!script.match?(/\bxcodebuild\b/))
      assert(!script.match?(/\bswift (?:build|test)\b/))
      true
    end

    test('nightly bounds automation cleanup and operator brief') do
      script = File.read(File.join(__dir__, 'mini-nightly.sh'))

      assert(script.include?('"$CLEANUP_TIMEOUT_SECONDS"'))
      assert(script.include?('/bin/bash "$AUTOMATION_PREP_SCRIPT"'))
      assert(script.include?('"$OPERATOR_BRIEF_TIMEOUT_SECONDS"'))
      assert(script.include?('ruby "$SANEMASTER_SCRIPT" operator_brief'))
      assert(script.include?('--output "$OPERATOR_BRIEF_TEMP"'))
      assert(script.include?('operator_brief_written=1'))
      true
    end

    test('nightly bounded runner terminates an over-deadline process group') do
      script = File.join(__dir__, 'mini-nightly.sh')

      Dir.mktmpdir('mini-nightly-timeout') do |dir|
        log = File.join(dir, 'bounded.log')
        command = <<~'BASH'
          source "$1"
          started=$SECONDS
          run_bounded_command 1 "$2" "$3" /bin/bash -c 'sleep 30'
          status=$?
          printf 'status=%s elapsed=%s\n' "$status" "$((SECONDS - started))"
          exit 0
        BASH
        stdout, stderr, status = Open3.capture3(
          {
            'MINI_NIGHTLY_LIBRARY_ONLY' => '1',
            'SANE_OUTPUT_DIR' => dir
          },
          '/bin/bash', '-c', command, 'nightly-timeout-test', script, dir, log
        )

        assert(status.success?, stderr)
        assert_includes(stdout, 'status=124')
        elapsed = stdout[/elapsed=(\d+)/, 1].to_i
        assert(elapsed.positive? && elapsed < 10, "expected bounded return, got #{stdout.inspect}")
      end
      true
    end

    test('dangerous unowned Mini scripts are retired and removed on deploy') do
      retired = %w[mini-daytime-cleanup.sh mini-license-test.sh mini-codex-keepalive.sh]
      deploy = File.read(File.join(__dir__, 'deploy.sh'))

      retired.each do |name|
        assert(!File.exist?(File.join(__dir__, name)), "expected #{name} to be retired")
        assert(deploy.include?(name))
      end
      assert(deploy.include?('is_retired_unowned_file'))
      assert(deploy.include?('launchctl disable "gui/$uid/com.saneapps.codex-keepalive"'))
      assert(deploy.include?('/usr/bin/trash "$retired_path"'))
      true
    end

    test('retired training suites are not part of canonical verification') do
      registry = File.read(File.expand_path('../test_registry.json', __dir__))

      assert(!registry.include?('mini_train_cleanup_test'))
      assert(!registry.include?('mini_train_process_test'))
      assert(!registry.include?('training_daily_check_test'))
      true
    end
  end
end)
