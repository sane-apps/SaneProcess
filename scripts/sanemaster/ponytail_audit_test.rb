#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'ponytail_audit'

class PonytailStatus
  def initialize(success, exitstatus)
    @success = success
    @exitstatus = exitstatus
  end

  attr_reader :exitstatus

  def success?
    @success
  end
end

class PonytailAuditHarness
  include SaneMasterModules::PonytailAudit

  attr_reader :metrics

  def initialize(stdout)
    @stdout = stdout
    @metrics = []
  end

  def capture_ponytail_audit(_command, timeout_seconds: nil)
    [@stdout, '', PonytailStatus.new(true, 0)]
  end

  def record_process_metric(type, payload = {})
    @metrics << { type: type }.merge(payload)
  end
end

class PonytailDirectCaptureHarness
  include SaneMasterModules::PonytailAudit
end

include TestFramework

exit(run_tests('SaneMaster Ponytail Audit Tests') do
  test_category('receipt parsing') do
    test('ponytail audit classifies safe cuts separately from proof and security-sensitive cuts') do
      Dir.mktmpdir('ponytail-audit-') do |dir|
        stdout = <<~MD
          - delete: remove unused local design helpers in `Sources/DesignSystem.swift`
          - shrink: replace custom customer proof sweep in `scripts/customer_ui_action_sweep.rb` after XCUITest replacement exists
          - yagni: collapse privileged helper fallback in `Sources/HostsPrivilegedWriter.swift`
          - shrink: extract website CSS from `website/index.html`
        MD
        subject = PonytailAuditHarness.new(stdout)
        result = subject.build_ponytail_audit(target: dir, output: 'outputs/ponytail-audit', model: 'test-model', diff: false)

        assert_eq(result[:schema], 'saneapps.ponytail_audit.v1')
        assert_eq(result[:success], true)
        assert_eq(result[:findings].length, 4)
        assert_eq(result[:summary][:safe_to_cut], 1)
        assert_eq(result[:summary][:needs_replacement_proof], 1)
        assert_eq(result[:summary][:security_sensitive], 1)
        assert_eq(result[:summary][:needs_visual_proof], 1)
        assert(File.exist?(result[:stdout_path]), 'expected stdout receipt')
      end
      true
    end

    test('ponytail_audit writes markdown and json receipts and records a metric') do
      Dir.mktmpdir('ponytail-audit-write-') do |dir|
        subject = PonytailAuditHarness.new("- delete: remove dead alias in `Sources/Alias.swift`\n")
        result = subject.ponytail_audit(['--target', dir, '--output', 'outputs/ponytail-audit', '--model', 'test-model'])

        assert_eq(result, true)
        metric = subject.metrics.last
        assert_eq(metric[:type], 'ponytail_audit')
        assert_eq(metric[:success], true)
        assert_eq(metric[:safe_to_cut], 1)
        markdown_path = metric[:markdown_path]
        json_path = metric[:json_path]
        assert(File.exist?(markdown_path), 'expected markdown receipt')
        assert(File.exist?(json_path), 'expected json receipt')
        assert_includes(File.read(markdown_path), 'Ponytail Audit')
        manifest = JSON.parse(File.read(json_path))
        assert_eq(manifest['summary']['safe_to_cut'], 1)
        assert(!manifest.key?('stdout'), manifest.keys.inspect)
      end
      true
    end

    test('capture times out long-running audits cleanly') do
      subject = PonytailDirectCaptureHarness.new
      stdout, stderr, status = subject.capture_ponytail_audit(
        ['ruby', '-e', 'sleep 5'],
        timeout_seconds: 1
      )

      assert_eq(stdout, '')
      assert_includes(stderr, 'Timed out after 1s')
      assert_eq(status.success?, false)
      assert_eq(status.exitstatus, 124)
      true
    end
  end
end)
