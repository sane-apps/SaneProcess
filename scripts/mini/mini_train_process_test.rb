#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

TRAIN_PATH = File.expand_path('mini-train.sh', __dir__)
TRAIN_ALL_PATH = File.expand_path('mini-train-all.sh', __dir__)
TRAIN_CHALLENGERS_PATH = File.expand_path('mini-train-challengers.sh', __dir__)
EVAL_PATH = File.expand_path('evaluate_model.py', __dir__)

train_source = File.read(TRAIN_PATH)
train_all_source = File.read(TRAIN_ALL_PATH)
train_challengers_source = File.read(TRAIN_CHALLENGERS_PATH)
eval_source = File.read(EVAL_PATH)

exit(run_tests('Mini Train Process Tests') do
  test_category('Sweep scheduling') do
    test('derives default sweep length from the config file') do
      assert_includes(train_source, 'config_iters_from_file')
      assert_includes(train_source, 'build_sweep_iters "$BASE_CONFIG"')
      true
    end

    test('rescales warmup when the overnight sweep length changes') do
      assert_includes(train_source, 'warmup_steps_for_sweep()')
      assert_includes(train_source, 'Sweep schedule: warmup=')
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
  end

  test_category('Unsafe model guard') do
    test('blocks known-unsafe Llama training on the 8 GB Mini unless explicitly overridden') do
      assert_includes(train_source, 'ALLOW_UNSAFE_TRAINING')
      assert_includes(train_source, 'reproducibly OOMs on the 8 GB Mini')
      assert_includes(train_source, 'ALLOW_UNSAFE_TRAINING=true')
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
