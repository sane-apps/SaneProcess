#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

exit(run_tests('Mini Deploy Tests') do
  test_category('training agent guard') do
    test('training agent refresh is opt-in') do
      script = File.read(File.join(__dir__, 'deploy.sh'))

      assert(script.include?('ENABLE_MINI_TRAINING_AGENTS="${ENABLE_MINI_TRAINING_AGENTS:-0}"'))
      assert(script.include?('if [ "$ENABLE_MINI_TRAINING_AGENTS" = "1" ]; then'))
      assert(script.include?('Skipped training agent refresh'))
      true
    end
  end
end)
