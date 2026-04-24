#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

require_relative '../hooks/test/test_framework'
require_relative 'gate_review'

class GateReviewHarness
  include SaneMasterModules::GateReview
end

include TestFramework

exit(run_tests('SaneMaster Gate Review Tests') do
  subject = GateReviewHarness.new

  test_category('Matching') do
    test('matches command text when all trigger tokens are present') do
      assert(
        subject.gate_review_match?('force push main', 'git push --force origin main'),
        'expected force/push/main trigger to match force-push command'
      )
      true
    end

    test('does not match when a trigger token is missing') do
      assert(
        !subject.gate_review_match?('force push main', 'git push --force origin develop'),
        'develop branch command should not satisfy a main-branch trigger'
      )
      true
    end
  end

  test_category('Fixture review') do
    test('accepts a candidate with seed proof, block coverage, and clean allow examples') do
      result = subject.review_gate_fixture(
        'rules' => [
          {
            'id' => 'no-force-push-main',
            'trigger' => 'force push main',
            'seed' => 'A release was damaged by force push main',
            'block' => ['git push --force origin main'],
            'allow' => ['git push origin feature-branch', 'git status --short']
          }
        ]
      )
      rule = result[:rules].first

      assert(result[:passed], "expected fixture to pass: #{rule[:issues].inspect}")
      assert_eq(result[:passed_count], 1)
      assert_eq(result[:failed_count], 0)
      assert_eq(rule[:missing_blocks], [])
      assert_eq(rule[:false_positives], [])
      true
    end

    test('rejects a candidate whose seed does not prove the trigger') do
      result = subject.review_gate_fixture(
        'id' => 'no-force-push-main',
        'trigger' => 'force push main',
        'seed' => 'A release failed because tests were skipped',
        'block' => ['git push --force origin main'],
        'allow' => ['git status --short']
      )
      rule = result[:rules].first

      refute_message = rule[:issues].join("\n")
      assert(!result[:passed], 'expected fixture to fail')
      assert_includes(rule[:issues], 'seed does not match trigger', refute_message)
      true
    end

    test('rejects a candidate that misses a must-block example') do
      result = subject.review_gate_fixture(
        'id' => 'no-force-push-main',
        'trigger' => 'force push main',
        'seed' => 'A release was damaged by force push main',
        'block' => ['git push --force origin develop'],
        'allow' => ['git status --short']
      )
      rule = result[:rules].first

      assert(!result[:passed], 'expected fixture to fail')
      assert_match(rule[:issues].join("\n"), /block\[0\] did not match trigger/)
      true
    end

    test('rejects a candidate that catches allowed work') do
      result = subject.review_gate_fixture(
        'id' => 'no-force-push-main',
        'trigger' => 'force push main',
        'seed' => 'A release was damaged by force push main',
        'block' => ['git push --force origin main'],
        'allow' => ['document the force push main incident in SESSION_HANDOFF.md']
      )
      rule = result[:rules].first

      assert(!result[:passed], 'expected fixture to fail')
      assert_match(rule[:issues].join("\n"), /allow\[0\] matched trigger/)
      true
    end

    test('rejects seed-only or block-only fixtures as weak tests') do
      result = subject.review_gate_fixture(
        'id' => 'no-force-push-main',
        'trigger' => 'force push main',
        'seed' => 'A release was damaged by force push main',
        'block' => ['git push --force origin main']
      )
      rule = result[:rules].first

      assert(!result[:passed], 'expected fixture without allow examples to fail')
      assert_includes(rule[:issues], 'at least one allow example is required')
      true
    end

    test('accepts checked-in regression cluster fixtures') do
      fixture_paths = Dir.glob(File.expand_path('../../test/fixtures/gates/*.json', __dir__)).sort
      assert(!fixture_paths.empty?, 'expected checked-in gate fixtures')

      fixture_paths.each do |fixture_path|
        fixture = JSON.parse(File.read(fixture_path))
        result = subject.review_gate_fixture(fixture, fixture_path: fixture_path)
        failing = result[:rules].reject { |rule| rule[:passed] }
        assert(failing.empty?, "#{File.basename(fixture_path)} failed: #{failing.inspect}")
      end
      true
    end
  end
end)
