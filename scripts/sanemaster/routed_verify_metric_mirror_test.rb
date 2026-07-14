#!/usr/bin/env ruby
# frozen_string_literal: true

# Behavioral tests for routed verify metric mirroring (regression 2026-07-14):
# Mini-first routing records type=verify evidence on the Mini, while the local
# TaskCompleted/Stop gates read the LOCAL metrics file. Without mirroring, the
# Air's metrics file never contains a verify event, so a dirty tree could
# never satisfy the completion gate even after a green canonical verify.

require 'json'
require 'fileutils'
require 'open3'
require 'time'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'

include TestFramework

class MirrorHarness
  include SaneMasterModules::ProcessMetrics

  def safe_metric_project_name
    'MirrorFixture'
  end
end

def verify_event(timestamp:, fingerprint: 'f' * 64, success: true, tests_run: 12, host: 'Stephans-Mac-mini.local')
  {
    'timestamp' => timestamp,
    'project' => 'SaneProcess',
    'cwd' => '/Users/stephansmac/.sanemaster/verify-workspaces/abc/SaneApps/infra/SaneProcess',
    'type' => 'verify',
    'success' => success,
    'tests_run' => tests_run,
    'evidence_strength' => 'tested',
    'host' => host,
    'source_fingerprint' => fingerprint
  }
end

def with_fake_remote_metrics(lines)
  Dir.mktmpdir('mirror-fixture-') do |dir|
    remote_file = File.join(dir, 'remote_metrics.jsonl')
    File.write(remote_file, lines.join("\n") + "\n")
    bin_dir = File.join(dir, 'bin')
    FileUtils.mkdir_p(bin_dir)
    fake_ssh = File.join(bin_dir, 'ssh')
    File.write(fake_ssh, <<~SH)
      #!/bin/bash
      # Fixture ssh: ignore host/command, emit the fixture remote metrics tail.
      cat #{remote_file}
    SH
    FileUtils.chmod(0o755, fake_ssh)

    local_metrics = File.join(dir, 'local_metrics.jsonl')
    old_path = ENV['PATH']
    old_metrics = ENV['SANEMASTER_PROCESS_METRICS_PATH']
    ENV['PATH'] = "#{bin_dir}:#{old_path}"
    ENV['SANEMASTER_PROCESS_METRICS_PATH'] = local_metrics
    begin
      yield local_metrics
    ensure
      ENV['PATH'] = old_path
      if old_metrics
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics
      else
        ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
      end
    end
  end
end

def read_events(path)
  return [] unless File.exist?(path)

  File.readlines(path).map { |line| JSON.parse(line) }
end

exit(run_tests('Routed Verify Metric Mirror Tests') do
  test_category('Window and filter policy') do
    test('keeps only parseable in-window verify events not already present') do
      harness = MirrorHarness.new
      now = Time.now.utc
      fresh = verify_event(timestamp: now.iso8601)
      stale = verify_event(timestamp: (now - 3600).iso8601, fingerprint: 'a' * 64)
      future = verify_event(timestamp: (now + 3600).iso8601, fingerprint: 'b' * 64)
      duplicate = verify_event(timestamp: now.iso8601, fingerprint: 'c' * 64)
      other_type = fresh.merge('type' => 'workflow_receipt')

      lines = [
        JSON.generate(fresh),
        JSON.generate(stale),
        JSON.generate(future),
        JSON.generate(duplicate),
        JSON.generate(other_type),
        'not json at all'
      ]
      selected = harness.select_routed_verify_mirror_events(
        lines,
        window_start: now - 120,
        window_end: now + 120,
        existing_keys: [harness.verify_mirror_event_key(duplicate)].to_set
      )

      assert_eq(selected.length, 1)
      assert_eq(selected.first['source_fingerprint'], 'f' * 64)
      true
    end
  end

  test_category('Mirroring behavior') do
    test('mirrors a fresh routed verify event verbatim into the local metrics file') do
      harness = MirrorHarness.new
      now = Time.now.utc
      fresh = verify_event(timestamp: now.iso8601)
      stale = verify_event(timestamp: (now - 3600).iso8601, fingerprint: 'a' * 64)

      with_fake_remote_metrics([JSON.generate(fresh), JSON.generate(stale)]) do |local_metrics|
        mirrored = harness.mirror_routed_verify_metrics!('mini', now - 30)

        assert_eq(mirrored, 1)
        events = read_events(local_metrics)
        assert_eq(events.length, 1)
        event = events.first
        assert_eq(event['type'], 'verify')
        assert_eq(event['timestamp'], fresh['timestamp'])
        assert_eq(event['host'], fresh['host'])
        assert_eq(event['source_fingerprint'], fresh['source_fingerprint'])
        assert_eq(event['tests_run'], fresh['tests_run'])
        assert_eq(event['cwd'], fresh['cwd'])
        assert_eq(event['mirrored_from'], 'mini')
        assert(!event['mirrored_at'].to_s.empty?, 'mirrored_at must be stamped')
        true
      end
    end

    test('does not duplicate an event that was already mirrored') do
      harness = MirrorHarness.new
      now = Time.now.utc
      fresh = verify_event(timestamp: now.iso8601)

      with_fake_remote_metrics([JSON.generate(fresh)]) do |local_metrics|
        first = harness.mirror_routed_verify_metrics!('mini', now - 30)
        second = harness.mirror_routed_verify_metrics!('mini', now - 30)

        assert_eq(first, 1)
        assert_eq(second, 0)
        assert_eq(read_events(local_metrics).length, 1)
        true
      end
    end

    test('a stale remote receipt alone mirrors nothing') do
      harness = MirrorHarness.new
      now = Time.now.utc
      stale = verify_event(timestamp: (now - 3600).iso8601)

      with_fake_remote_metrics([JSON.generate(stale)]) do |local_metrics|
        mirrored = harness.mirror_routed_verify_metrics!('mini', now - 30)

        assert_eq(mirrored, 0)
        assert_eq(read_events(local_metrics).length, 0)
        true
      end
    end
  end
end)
