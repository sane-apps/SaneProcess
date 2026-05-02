#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative '../hooks/test/test_framework'

include TestFramework

TRAIN_PATH = File.expand_path('mini-train.sh', __dir__)
TRAIN_ALL_PATH = File.expand_path('mini-train-all.sh', __dir__)
TRAIN_CHALLENGERS_PATH = File.expand_path('mini-train-challengers.sh', __dir__)
TRAIN_INSTALLER_PATH = File.expand_path('mini-install-training-agents.sh', __dir__)
EVAL_PATH = File.expand_path('evaluate_model.py', __dir__)

train_source = File.read(TRAIN_PATH)
train_all_source = File.read(TRAIN_ALL_PATH)
train_challengers_source = File.read(TRAIN_CHALLENGERS_PATH)
eval_source = File.read(EVAL_PATH)
training_mode_source = File.read(File.expand_path('mini-training-mode.sh', __dir__))

exit(run_tests('Mini Train Process Tests') do
  test_category('Sweep scheduling') do
    test('derives default sweep length from the config file') do
      assert_includes(train_source, 'config_iters_from_file')
      assert_includes(train_source, 'build_sweep_iters "$BASE_CONFIG"')
      true
    end

    test('does not treat incomplete adapter dirs as completed sweeps') do
      assert_includes(train_source, '[ -f "$ADAPTER_DIR/adapter_config.json" ] && [ -s "$ADAPTER_DIR/adapters.safetensors" ]')
      true
    end

    test('challenger sweep dirs include config fingerprint') do
      assert_includes(train_source, 'config_fingerprint()')
      assert_includes(train_source, 'shasum -a 256')
      assert_includes(train_source, 'cannot fingerprint config safely')
      assert_includes(train_source, 'SWEEP_NAME="challenger_${MODEL_SHORT}_${ITERS}_${CONFIG_FINGERPRINT}_${DATE}"')
      true
    end

    test('rescales warmup when the overnight sweep length changes') do
      assert_includes(train_source, 'warmup_steps_for_sweep()')
      assert_includes(train_source, 'Sweep schedule: warmup=')
      true
    end

    test('mini training disables inline valid.jsonl pressure and relies on post-train eval by default') do
      assert_includes(train_source, 'TRAIN_DISABLE_INLINE_VALIDATION="${TRAIN_DISABLE_INLINE_VALIDATION:-true}"')
      assert_includes(train_source, 'prepare_training_data_dir()')
      assert_includes(train_source, 'Inline validation: disabled on Mini training run')
      true
    end

    test('hard stop is epoch based so late-night runs can target the next morning') do
      assert_includes(train_source, 'compute_hard_stop_epoch()')
      assert_includes(train_source, 'date -j -v+1d -f "%Y-%m-%d %H:%M" "$run_date $TRAIN_HARD_STOP_TIME"')
      assert_includes(train_source, 'if [ "$target_epoch" -le "$START_EPOCH" ]; then')
      assert_includes(train_source, 'now=$(date +%s)')
      assert_includes(train_challengers_source, 'compute_hard_stop_epoch()')
      assert_includes(train_challengers_source, 'if [ "$target_epoch" -le "$CHALLENGER_START" ]; then')
      true
    end
  end

  test_category('Automation root hygiene') do
    test('weekly training refreshes the automation root before merge + train') do
      assert_includes(train_all_source, 'mini-prepare-automation-root.sh')
      assert_includes(train_all_source, 'prepare_automation_root_if_needed')
      true
    end

    test('challenger training refreshes the automation root before merge + train') do
      assert_includes(train_challengers_source, 'mini-prepare-automation-root.sh')
      assert_includes(train_challengers_source, 'prepare_automation_root_if_needed')
      true
    end

    test('automation root refresh is serialized and heals stale git locks') do
      prepare_source = File.read(File.expand_path('mini-prepare-automation-root.sh', __dir__))
      assert_includes(prepare_source, 'PREPARE_LOCK="$AUTOMATION_ROOT/.prepare.lock"')
      assert_includes(prepare_source, 'acquire_prepare_lock')
      assert_includes(prepare_source, 'cleanup_stale_git_index_locks')
      assert_includes(prepare_source, 'find "$AUTOMATION_ROOT" -path "*/.git/index.lock"')
      true
    end

    test('source training data prefers synced app repos over stale top-level fallbacks') do
      prepare_source = File.read(File.expand_path('mini-prepare-automation-root.sh', __dir__))
      assert_includes(prepare_source, 'Order matters: the first existing path wins.')
      assert_includes(prepare_source, 'stale top-level compatibility checkouts cannot overwrite fresh data')
      assert_includes(prepare_source, '"$SOURCE_ROOT/apps/$app_name/training_data"')
      assert_includes(prepare_source, '"$SOURCE_ROOT/$app_name/training_data"')
      apps_index = prepare_source.index('"$SOURCE_ROOT/apps/$app_name/training_data"')
      top_level_index = prepare_source.index('"$SOURCE_ROOT/$app_name/training_data"')
      assert(apps_index < top_level_index, 'Expected apps/ training data to be preferred over top-level fallback')
      true
    end

    test('git-managed challenger config dirs are not overwritten by stale source checkouts') do
      prepare_source = File.read(File.expand_path('mini-prepare-automation-root.sh', __dir__))
      assert_includes(prepare_source, 'if target_repo_tracks_training_prefix "$app_name" "$rel_dir"; then')
      assert_includes(prepare_source, 'KEEP  apps/$app_name/training_data/$rel_dir [git-managed]')
      assert_includes(prepare_source, 'Tracked config dirs are kept above; new candidates must be committed.')
      assert_includes(prepare_source, 'if [ "$rel_dir" = "challenger_configs" ]; then')
      assert_includes(prepare_source, 'rsync -a "$source_dir"/ "$target_dir"/')
      assert_includes(prepare_source, 'SYNC  apps/$app_name/training_data/$rel_dir [merged]')
      true
    end

    test('challenger lane defaults to one rotated config unless multi-run is explicitly allowed') do
      assert_includes(train_challengers_source, 'CHALLENGER_SELECTION_MODE="${CHALLENGER_SELECTION_MODE:-alternate}"')
      assert_includes(train_challengers_source, 'ALLOW_MULTI_CHALLENGER_RUNS="${ALLOW_MULTI_CHALLENGER_RUNS:-false}"')
      assert_includes(train_challengers_source, 'Refusing to run ${CONFIG_COUNT} challenger configs in one lane.')
      true
    end

    test('training agent installer validates challenger rotation order') do
      installer_source = File.read(TRAIN_INSTALLER_PATH)
      assert_includes(installer_source, 'Invalid CHALLENGER_ROTATION_ORDER')
      assert_includes(installer_source, '^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$')
      _stdout, stderr, status = Open3.capture3(
        { 'CHALLENGER_ROTATION_ORDER' => 'qwen3-0.6b,,smollm3-3b' },
        'bash',
        TRAIN_INSTALLER_PATH
      )
      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'Invalid CHALLENGER_ROTATION_ORDER')
      true
    end
  end

  test_category('Model selection + process hygiene') do
    test('production training reads the model from the resolved base config') do
      assert_includes(train_source, 'config_model_from_file()')
      assert_includes(train_source, 'MODEL_FROM_BASE_CONFIG=$(config_model_from_file "$BASE_CONFIG")')
      assert_includes(train_all_source, '--config lora_config_mini.yaml')
      true
    end

    test('challenger reports stay separate even when the run is selected by config only') do
      assert_includes(train_source, 'report_model_short_from_value()')
      assert_includes(train_source, 'elif [ -n "$CONFIG_OVERRIDE" ]; then')
      assert_includes(train_source, 'REPORT="$OUTPUT_DIR/challenger_report_${APP_NAME}_${MODEL_SHORT}.md"')
      assert_includes(train_source, "sed 's/\\.yaml$//'")
      assert_includes(train_source, "sed 's/\\.yml$//'")
      true
    end

    test('all Mini training modes share one MLX lock and drain stale processes before launch') do
      assert_includes(train_source, 'LOCKFILE="$OUTPUT_DIR/.training_mlx.lock"')
      assert_includes(train_source, 'wait_for_clean_training_processes()')
      assert_includes(train_source, 'list_lingering_training_processes()')
      assert_includes(train_source, 'purge 2>/dev/null || true')
      true
    end

    test('standalone SaneVideo runs default to workflow-only eval suites') do
      assert_includes(train_source, 'if [ "$APP_NAME" = "SaneVideo" ]; then')
      assert_includes(train_source, 'DEFAULT_EVAL_SUITE_WEIGHTS="commentary_workflow=4,workflow_packs=2,workflow_guardrails=2"')
      assert_includes(train_source, 'DEFAULT_EVAL_SUITES="commentary_workflow,workflow_packs,workflow_guardrails"')
      assert_includes(train_source, 'EVAL_MAX_TOKENS_CAP=256')
      true
    end

    test('training mode isolates user apps and launch agents before training starts') do
      assert_includes(train_source, 'TRAINING_MODE_ENABLED="${TRAINING_MODE_ENABLED:-true}"')
      assert_includes(train_source, 'enter_training_mode_if_needed()')
      assert_includes(train_source, 'exit_training_mode_if_needed')
      assert_includes(training_mode_source, 'TRAINING_MODE_AGENT_SUSPEND_LIST')
      assert_includes(training_mode_source, 'TRAINING_MODE_APP_QUIT_LIST')
      assert_includes(training_mode_source, 'TRAINING_MODE_PROCESS_KILL_PATTERNS')
      assert_includes(training_mode_source, 'kill_matching_patterns()')
      assert_includes(training_mode_source, 'launchctl bootout')
      true
    end

    test('production promotion clears stale adapter contents before copying the new winner') do
      assert_includes(train_source, 'rm -rf "$PROD_DIR"')
      assert_includes(train_source, 'cp -r "$BEST_ADAPTER_DIR/"* "$PROD_DIR/"')
      true
    end

    test('nightly readiness derives the base model from production adapter metadata') do
      nightly_source = File.read(File.expand_path('mini-nightly.sh', __dir__))
      assert_includes(nightly_source, 'adapter_config.json')
      assert_includes(nightly_source, 'payload.get("model", "")')
      assert_includes(nightly_source, 'if [ -z "$SANEAI_MODEL" ]; then')
      true
    end
  end

  test_category('Eval contract') do
    test('evaluate_model.py accepts the max token cap used by mini-train.sh') do
      assert_includes(eval_source, '--max-tokens-cap')
      assert_includes(eval_source, 'args.max_tokens_cap')
      true
    end
  end
end)
