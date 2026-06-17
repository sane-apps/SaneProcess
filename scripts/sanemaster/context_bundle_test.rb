#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'agent_context'

class ContextBundleHarness
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::AgentContext

  def initialize(metrics_path)
    @metrics_path = metrics_path
  end

  def process_metrics_path
    @metrics_path
  end

  def record_process_metric(type, payload = {})
    FileUtils.mkdir_p(File.dirname(@metrics_path))
    File.open(@metrics_path, 'a') do |file|
      file.puts(JSON.generate({ type: type }.merge(payload)))
    end
  end
end

include TestFramework

def assert_raises_message(pattern)
  raised = false
  begin
    yield
  rescue StandardError => e
    raised = true
    assert_match(e.message, pattern)
  end
  assert(raised, "expected exception matching #{pattern.inspect}")
end

exit(run_tests('SaneMaster Context Bundle Tests') do
  test_category('bundle manifest') do
    test('context bundle indexes existing docs, research cards, and Serena memories') do
      Dir.mktmpdir('context-bundle-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n\nUse SaneMaster.\n")
        File.write(File.join(dir, 'SESSION_HANDOFF.md'), "# Handoff\n\nActive state.\n")
        FileUtils.mkdir_p(File.join(dir, '.claude'))
        File.write(File.join(dir, '.claude', 'research.md'), <<~MD)
          # Research

          ## Active Bug Family | Updated: 2026-06-17 | Status: active | TTL: 14d
          - Current issue.

          ## Old Verified Tooling | Updated: 2020-01-01 | Status: verified | TTL: 30d
          - Durable finding.

          ## Unstructured Memory
          - Missing metadata.
        MD
        FileUtils.mkdir_p(File.join(dir, '.serena', 'memories', 'SaneProcess'))
        File.write(File.join(dir, '.serena', 'memories', 'SaneProcess', 'release.md'), "# Release Memory\n\nFact.\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ContextBundleHarness.new(File.join(dir, 'metrics.jsonl'))
          result = subject.build_context_bundle(task: 'review context', output: File.join(dir, 'bundle.md'), max_research: 10, max_memory: 10)

          assert_eq(result[:schema], 'saneapps.context_bundle.v1')
          assert_eq(result[:task], 'review context')
          assert(result[:sources].any? { |entry| entry[:path] == 'AGENTS.md' }, result[:sources].inspect)
          assert_eq(result.dig(:research, :card_count), 3)
          assert_eq(result.dig(:research, :stale_count), 1)
          assert_eq(result.dig(:research, :active_count), 1)
          assert_eq(result.dig(:research, :unstructured_count), 1)
          assert_eq(result.dig(:research, :invalid_count), 0)
          active = result.dig(:research, :cards).find { |card| card[:title] == 'Active Bug Family' }
          assert_eq(active[:promotion_target], 'SESSION_HANDOFF.md')
          assert_eq(result.dig(:serena_memories, :card_count), 1)
          assert(result[:warnings].any? { |warning| warning.include?('stale') }, result[:warnings].inspect)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context_bundle writes markdown with OKF-style frontmatter and records a metric') do
      Dir.mktmpdir('context-bundle-write-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        File.write(File.join(dir, 'SESSION_HANDOFF.md'), "# Handoff\n")
        FileUtils.mkdir_p(File.join(dir, '.claude'))
        File.write(File.join(dir, '.claude', 'research.md'), "## Tooling | Updated: 2026-06-17 | Status: verified | TTL: 30d\n- Finding.\n")
        output_path = File.join(dir, 'outputs', 'context-bundles', 'bundle.md')
        metrics_path = File.join(dir, 'metrics.jsonl')

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ContextBundleHarness.new(metrics_path)
          result = subject.context_bundle(['--task', 'subagent review', '--output', output_path])

          assert_eq(result[:output_path], output_path)
          assert(File.exist?(output_path), 'expected context bundle file')
          assert(File.exist?(output_path.sub(/\.md\z/, '.json')), 'expected context bundle manifest sidecar')
          body = File.read(output_path)
          assert_includes(body, 'schema: saneapps.context_bundle.v1')
          assert_includes(body, '# Context Bundle:')
          assert_includes(body, '## Research Knowledge Cards')
          assert_includes(body, 'Do not share outside SaneApps without redaction')
          manifest = JSON.parse(File.read(output_path.sub(/\.md\z/, '.json')))
          assert_eq(manifest['output_path'], output_path)
          assert(!manifest.fetch('sources').any? { |source| source.key?('excerpt') }, manifest.inspect)
          metric = JSON.parse(File.readlines(metrics_path).last)
          assert_eq(metric['type'], 'context_bundle')
          assert_eq(metric['success'], true)
          assert_eq(metric['artifact_written'], true)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context bundle roots source discovery at git root when invoked from a subdirectory') do
      Dir.mktmpdir('context-bundle-root-') do |dir|
        system('git', '-C', dir, 'init', out: File::NULL, err: File::NULL)
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        File.write(File.join(dir, 'SESSION_HANDOFF.md'), "# Handoff\n")
        nested = File.join(dir, 'scripts', 'nested')
        FileUtils.mkdir_p(nested)

        old_pwd = Dir.pwd
        Dir.chdir(nested)
        begin
          subject = ContextBundleHarness.new(File.join(dir, 'metrics.jsonl'))
          result = subject.build_context_bundle(task: 'nested review', max_research: 10, max_memory: 10)

          assert_eq(result[:source_root], dir)
          assert(result[:output_path].start_with?(File.join(dir, 'outputs', 'context-bundles')), result[:output_path])
          assert(result[:sources].any? { |entry| entry[:path] == 'AGENTS.md' }, result[:sources].inspect)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context bundle rejects unsafe output paths and invalid card limits') do
      Dir.mktmpdir('context-bundle-validation-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        subject = ContextBundleHarness.new(File.join(dir, 'metrics.jsonl'))

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          assert_raises_message(/inside the repo root/) do
            subject.context_bundle(['--task', 'bad output', '--output', File.join(Dir.tmpdir, 'outside.md')])
          end
          assert_raises_message(/end with \.md/) do
            subject.context_bundle(['--task', 'bad extension', '--output', 'outputs/context-bundles/bundle.json'])
          end
          assert_raises_message(/positive integer/) do
            subject.context_bundle(['--task', 'bad max', '--max-research', 'bogus', '--dry-run'])
          end
          existing = File.join(dir, 'outputs', 'context-bundles', 'existing.md')
          FileUtils.mkdir_p(File.dirname(existing))
          File.write(existing, 'existing')
          assert_raises_message(/already exists/) do
            subject.context_bundle(['--task', 'existing output', '--output', existing])
          end
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context bundle dry-run does not write artifacts and records dry-run metric') do
      Dir.mktmpdir('context-bundle-dry-run-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        output_path = File.join(dir, 'outputs', 'context-bundles', 'dry.md')
        metrics_path = File.join(dir, 'metrics.jsonl')

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ContextBundleHarness.new(metrics_path)
          result = subject.context_bundle(['--task', 'preview', '--output', output_path, '--dry-run'])

          assert_eq(result[:output_path], output_path)
          assert(!File.exist?(output_path), 'dry-run should not write markdown')
          assert(!File.exist?(output_path.sub(/\.md\z/, '.json')), 'dry-run should not write manifest')
          metric = JSON.parse(File.readlines(metrics_path).last)
          assert_eq(metric['dry_run'], true)
          assert_eq(metric['artifact_written'], false)
          assert(!metric.key?('output_path'), metric.inspect)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context bundle default paths are unique and recent receipts include markdown and json sidecars') do
      Dir.mktmpdir('context-bundle-receipts-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        receipts_dir = File.join(dir, 'outputs', 'context-bundles')
        FileUtils.mkdir_p(receipts_dir)
        File.write(File.join(receipts_dir, 'old.md'), 'markdown')
        File.write(File.join(receipts_dir, 'old.json'), '{}')

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ContextBundleHarness.new(File.join(dir, 'metrics.jsonl'))
          time = Time.utc(2026, 6, 17, 12, 0, 0)
          first = subject.send(:default_context_bundle_path, time, dir)
          second = subject.send(:default_context_bundle_path, time, dir)
          assert(first != second, "#{first} should differ from #{second}")
          receipts = subject.send(:recent_context_receipts, dir).map { |entry| entry[:path] }
          assert_includes(receipts, 'outputs/context-bundles/old.md')
          assert_includes(receipts, 'outputs/context-bundles/old.json')
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('context bundle flags invalid research freshness metadata') do
      Dir.mktmpdir('context-bundle-invalid-research-') do |dir|
        File.write(File.join(dir, 'AGENTS.md'), "# Agents\n")
        FileUtils.mkdir_p(File.join(dir, '.claude'))
        File.write(File.join(dir, '.claude', 'research.md'), <<~MD)
          ## Bad TTL | Updated: 2026-06-17 | Status: verified | TTL: forever
          - Invalid TTL.

          ## Future Update | Updated: 2099-01-01 | Status: verified | TTL: 30d
          - Invalid date.
        MD

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ContextBundleHarness.new(File.join(dir, 'metrics.jsonl'))
          result = subject.build_context_bundle(task: 'invalid metadata', max_research: 10, max_memory: 10)

          assert_eq(result.dig(:research, :invalid_count), 2)
          assert(result[:warnings].any? { |warning| warning.include?('invalid freshness metadata') }, result[:warnings].inspect)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end
  end
end)
