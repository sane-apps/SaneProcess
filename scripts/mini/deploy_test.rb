#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

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
      assert(script.include?('operator_brief --nightly-report "$REPORT"'))
      assert(script.include?('OPERATOR_BRIEF_OUTPUT="$OUTPUT_DIR/operator_brief.md"'))
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
