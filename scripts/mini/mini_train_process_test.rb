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
