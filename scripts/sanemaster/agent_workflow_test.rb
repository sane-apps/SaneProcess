#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'agent_workflow'

class AgentWorkflowHarness
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::AgentWorkflow

  def initialize(metrics_path)
    @metrics_path = metrics_path
  end

  def process_metrics_path
    @metrics_path
  end
end

include TestFramework

exit(run_tests('SaneMaster Agent Workflow Tests') do
  test_category('agent eval') do
    test('default fixture catches prompt-to-workflow routing') do
      subject = AgentWorkflowHarness.new('/tmp/saneprocess-agent-workflow-test.jsonl')
      result = subject.run_agent_eval_fixture(File.expand_path('../agent_eval_fixtures.json', __dir__))

      assert(result[:passed], result[:cases].reject { |entry| entry[:passed] }.inspect)
      assert_eq(result[:case_count], 11)
      true
    end

    test('classification requires tool discovery before workaround workflows') do
      subject = AgentWorkflowHarness.new('/tmp/saneprocess-agent-workflow-test.jsonl')
      actual = subject.classify_agent_prompt('We need a missing tool check before another workaround.')

      assert_includes(actual[:commands], 'tool_discovery')
      assert_includes(actual[:skills], 'evolve')
      true
    end
  end

  test_category('skill lint') do
    test('skill linter accepts routed skill descriptions with trigger guidance') do
      Dir.mktmpdir('skill-lint-pass-') do |dir|
        skill_dir = File.join(dir, 'example')
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, 'SKILL.md'), <<~MD)
          ---
          name: example
          description: Use when a user asks to review an example workflow and produce a short, structured summary.
          ---

          # Example Skill

          ## When to use

          Trigger when the user asks for an example workflow review.
        MD

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([skill_dir])

        assert(result[:passed], result.inspect)
        assert_eq(result[:skill_count], 1)
      end
      true
    end

    test('skill linter flags missing SKILL.md directories') do
      Dir.mktmpdir('skill-lint-fail-') do |dir|
        skill_dir = File.join(dir, 'broken')
        FileUtils.mkdir_p(skill_dir)

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([skill_dir])

        assert(!result[:passed], 'expected skill_lint to fail for missing SKILL.md')
        assert_includes(result[:skills].first[:issues], 'skill directory is missing SKILL.md')
      end
      true
    end

    test('skill linter distinguishes TODO topic text from unresolved placeholders') do
      Dir.mktmpdir('skill-lint-todo-') do |dir|
        skill_dir = File.join(dir, 'techdebt')
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, 'SKILL.md'), <<~MD)
          ---
          name: techdebt
          description: Use when a user asks to find technical debt such as stale TODOs and maintenance hazards.
          ---

          # Tech Debt

          ## When to use

          Trigger when the user asks to find TODOs, duplicate code, or dead code.
        MD

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([skill_dir])

        assert(result[:passed], result.inspect)
      end
      true
    end

    test('skill linter accepts YAML block descriptions') do
      Dir.mktmpdir('skill-lint-yaml-') do |dir|
        skill_dir = File.join(dir, 'block-description')
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, 'SKILL.md'), <<~MD)
          ---
          name: block-description
          description: >
            Use when a user asks to review a multi-line skill description
            and verify routing metadata remains parseable.
          ---

          # Block Description

          ## When to use

          Trigger when testing frontmatter parsing.
        MD

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([skill_dir])

        assert(result[:passed], result.inspect)
      end
      true
    end

    test('skill linter flags legacy NVIDIA default guidance') do
      Dir.mktmpdir('skill-lint-nvidia-') do |dir|
        skill_dir = File.join(dir, 'legacy')
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, 'SKILL.md'), <<~MD)
          ---
          name: legacy
          description: Use when a user asks to review legacy model routing and identify unsafe default execution paths.
          ---

          # Legacy

          ## When to use

          Trigger when testing unsafe defaults.

          Fire 21 parallel nv calls by default.
        MD

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([skill_dir])

        assert(!result[:passed], 'expected legacy NVIDIA guidance to fail skill_lint')
        assert_includes(result[:skills].first[:issues], 'contains legacy NVIDIA/nv default guidance')
      end
      true
    end

    test('skill linter reports duplicate skill names with divergent content') do
      Dir.mktmpdir('skill-lint-duplicate-') do |dir|
        first = File.join(dir, 'root-a', 'deploy')
        second = File.join(dir, 'root-b', 'deploy')
        FileUtils.mkdir_p(first)
        FileUtils.mkdir_p(second)
        File.write(File.join(first, 'SKILL.md'), <<~MD)
          ---
          name: deploy
          description: Use when a user asks to deploy an application through the stable production release path.
          ---

          # Deploy

          ## When to use

          Trigger when testing duplicate skill drift.
        MD
        File.write(File.join(second, 'SKILL.md'), <<~MD)
          ---
          name: deploy
          description: Use when a user asks to deploy an application through an experimental staging-only path.
          ---

          # Deploy

          ## When to use

          Trigger when testing divergent duplicate skills.
        MD

        subject = AgentWorkflowHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.lint_skill_paths([first, second])

        assert(result[:passed], result.inspect)
        assert_eq(result[:duplicate_drift].length, 1)
        assert_eq(result[:duplicate_drift].first[:name], 'deploy')
      end
      true
    end
  end

  test_category('environment review') do
    test('environment review turns metrics and research cache into actions') do
      Dir.mktmpdir('agent-env-review-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(type: 'verify', success: true, project: 'SaneProcess') + "\n")
        FileUtils.mkdir_p(File.join(dir, '.claude'))
        File.write(File.join(dir, '.claude', 'research.md'), "# Research\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = AgentWorkflowHarness.new(metrics_path)
          subject.define_singleton_method(:default_skill_lint_paths) { [File.join(dir, 'skills')] }
          FileUtils.mkdir_p(File.join(dir, 'skills', 'example'))
          File.write(File.join(dir, 'skills', 'example', 'SKILL.md'), <<~MD)
            ---
            name: example
            description: Use when a user asks to review agent setup drift and return a concise environment summary.
            ---

            # Example

            ## When to use

            Trigger when testing agent environment review.
          MD
          result = subject.build_agent_env_review

          assert_eq(result.dig(:metrics, :total_events), 1)
          assert_includes(result[:warnings], 'process metrics have fewer than 30 verify attempts; trend confidence is low')
          assert(result[:recommended_actions].any? { |action| action.include?('agent_eval') })
          assert(result[:recommended_actions].any? { |action| action.include?('process_eval') })
          assert_eq(result[:skill_lint][:failed_count], 0)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end
  end
end)
