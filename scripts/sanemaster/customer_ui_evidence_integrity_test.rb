#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'customer_ui_contract'
require 'open3'
require 'rbconfig'

include TestFramework
class EvidenceIntegrityHarness
  include SaneMasterModules::CustomerUIContract
end

VIDEO_SWEEP = File.expand_path('../../../../apps/SaneVideo/scripts/customer_ui_action_sweep.rb', __dir__)
require VIDEO_SWEEP

def legacy_payloads
  {
    'Video' => { 'runner' => 'Mac Mini customer UI sweep', 'action_id' => 'open', 'inputs' => [],
                 'steps' => ['Open settings'], 'note' => 'Path-backed Mini workflow evidence.' },
    'Sales' => { 'app' => 'SaneSales', 'host' => 'mini', 'generated_at' => Time.now.utc.iso8601,
                 'actions' => [{ 'id' => 'open', 'surfaces' => ['Settings'], 'inputs' => [], 'expected_outputs' => ['Visible'] }] },
    'Scan' => { 'app' => 'SaneScan', 'host' => 'mini', 'runner' => 'scripts/customer_ui_action_sweep.rb',
                'actions' => [{ 'id' => 'open', 'surfaces' => ['Settings'], 'inputs' => [], 'expected_outputs' => ['Visible'], 'screenshot' => 'old.png' }] }
  }
end

def action_and_receipt(path)
  action = { 'id' => 'open', 'required_proof_level' => 'runtime_visual', 'steps' => ['Open settings'],
             'functional_state' => { 'not_required_reason' => 'Settings needs no fixture' },
             'required_evidence_types' => ['mini_click', 'screenshot'] }
  File.binwrite('view.png', "\x89PNG\r\n\x1A\n".b + ("\0" * 8) + [160, 120].pack('NN') + ("\0" * 16))
  result = { 'status' => 'passed', 'proof_level' => 'runtime_visual',
             'functional_state' => { 'status' => 'not_required', 'detail' => 'No seeded data needed' },
             'workflow' => { 'runner' => 'native AX capture', 'steps_completed' => ['Open settings'],
                             'outcome' => 'Settings became visible', 'artifacts' => [path, 'view.png'] },
             'evidence' => [
               { 'type' => 'source_guard', 'detail' => 'Settings implementation present' },
               { 'type' => 'mini_click', 'detail' => 'Recorded interaction', 'path' => path },
               { 'type' => 'screenshot', 'detail' => 'Settings capture', 'path' => 'view.png' }
             ] }
  [[action], { 'action_results' => { 'open' => result } }]
end

exit(run_tests('Customer UI evidence integrity') do
  harness = EvidenceIntegrityHarness.new
  test_category('Executor coverage') do
    %w[SaneClick SaneHosts].each do |app|
      test("#{app} incomplete executor stops before GUI setup or passed receipts") do
        executor = File.expand_path("../../../../apps/#{app}/scripts/customer_ui_action_executor.rb", __dir__)
        require executor
        subject = Object.const_get("#{app}UIActionExecutor").allocate
        subject.instance_variable_set(:@execute, true)
        subject.define_singleton_method(:require_mini!) { raise 'Unexpected GUI setup reached' }
        message = begin
          subject.run
          'Unexpected successful execution'
        rescue StandardError => e
          e.message
        end
        assert_includes(message, 'Incomplete workflow coverage')
        true
      end
    end
  end

  test_category('Host approval parity') do
    test('accepts only the exact existing owner-approved Air fallback tokens') do
      keys = %w[SANE_APPROVE_LOCAL_UI_ON_AIR SANE_MINI_UNAVAILABLE]
      saved = keys.to_h { |key| [key, ENV[key]] }
      begin
        keys.each { |key| ENV.delete(key) }
        assert(!harness.send(:customer_ui_air_fallback_approved?))
        assert(!harness.send(:customer_ui_receipt_host_allowed?, 'air'))
        ENV['SANE_MINI_UNAVAILABLE'] = '1'
        assert(!harness.send(:customer_ui_air_fallback_approved?))
        ENV['SANE_MINI_UNAVAILABLE'] = 'MR. SANE CONFIRMS MINI UNAVAILABLE'
        assert(harness.send(:customer_ui_air_fallback_approved?))
        assert(harness.send(:customer_ui_receipt_host_allowed?, 'air'))
        assert(!harness.send(:customer_ui_receipt_host_allowed?, 'unknown-remote-host'))
        ENV.delete('SANE_MINI_UNAVAILABLE')
        ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] = 'MR. SANE APPROVES LOCAL UI ON AIR'
        assert(harness.send(:customer_ui_air_fallback_approved?))
      ensure
        saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
      true
    end
  end

  test_category('Release consumer') do
    %w[SaneClick SaneHosts].each do |app|
      test("#{app} old executor receipts cannot regain release clearance") do
        Dir.mktmpdir('ui-legacy-executor-') do |dir|
          Dir.chdir(dir) do
            File.write('capture.json', JSON.generate(
              'events' => [{ 'action' => 'AXPress', 'observed_after' => 'Settings visible' }]
            ))
            actions, receipt = action_and_receipt('capture.json')
            receipt['app'] = app
            receipt['action_results']['open']['workflow']['runner'] = 'scripts/customer_ui_action_executor.rb'
            issues = harness.send(:customer_ui_action_result_issues, actions, receipt)
            assert(issues.any? { |issue| issue.include?('revoked legacy executor') }, issues.inspect)
          end
        end
      end
    end
    legacy_payloads.each do |app, payload|
      test("#{app} declaration-only artifact blocks otherwise complete runtime receipt") do
        Dir.mktmpdir('ui-evidence-') do |dir|
          Dir.chdir(dir) do
            File.write('capture.json', JSON.generate(payload))
            actions, receipt = action_and_receipt('capture.json')
            issues = harness.send(:customer_ui_action_result_issues, actions, receipt)
            assert(issues.any? { |issue| issue.include?('declaration-only artifact') }, issues.inspect)
            %w[file_state log actual_output].each do |type|
              item = { 'type' => type, 'detail' => 'Relabeled evidence', 'path' => 'capture.json' }
              assert(harness.send(:customer_ui_evidence_artifact_issues, 'open', item, 0).any?)
            end
          end
        end
      end
    end
    test('observed native events with source guards retain existing acceptance') do
      Dir.mktmpdir('ui-observed-') do |dir|
        Dir.chdir(dir) do
          File.write('capture.json', JSON.generate(
            'runner' => 'native AX capture', 'pid' => 123,
            'events' => [{ 'action' => 'AXPress', 'target' => 'Settings', 'result' => 'success',
                           'observed_after' => { 'window_title' => 'Settings' } }]
          ))
          actions, receipt = action_and_receipt('capture.json')
          assert_eq(harness.send(:customer_ui_action_result_issues, actions, receipt), [])
        end
      end
    end
    test('explicit source-only proof cannot be relabeled runtime') do
      Dir.mktmpdir('ui-source-') do |dir|
        path = File.join(dir, 'source.json')
        File.write(path, JSON.generate('proof_type' => 'source_guard', 'actions' => {}))
        assert(harness.send(:customer_ui_declared_artifact_issues, path, label: 'runtime').any?)
      end
    end
    test('malformed runtime JSON fails closed') do
      Dir.mktmpdir('ui-invalid-') do |dir|
        path = File.join(dir, 'invalid.json'); File.write(path, '{')
        assert(harness.send(:customer_ui_declared_artifact_issues, path, label: 'runtime').any?)
      end
    end
  end
  test_category('Video producer') do
    test('source sweep exits incomplete and preserves existing runtime receipts') do
      Dir.mktmpdir('video-source-only-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        FileUtils.cp(VIDEO_SWEEP, File.join(dir, 'scripts/customer_ui_action_sweep.rb'))
        guards = SaneVideoCustomerUIActionSweep::SOURCE_GUARDS
        files = Hash.new { |hash, key| hash[key] = [] }
        guards.each_value { |checks| checks.each { |path, needle| files[path] << needle.to_s } }
        files.each do |path, needles|
          target = File.join(dir, path); FileUtils.mkdir_p(File.dirname(target)); File.write(target, needles.uniq.join("\n"))
        end
        File.write(File.join(dir, 'Tests/CustomerUIActions.yml'), YAML.dump('version' => 1, 'app' => 'SaneVideo', 'actions' => guards.keys.map { |id| { 'id' => id } }))
        ['.sane/customer_ui_action_receipt.json', 'outputs/customer_ui_action_receipt.json'].each do |path|
          target = File.join(dir, path); FileUtils.mkdir_p(File.dirname(target)); File.write(target, 'existing real receipt')
        end
        output, status = Open3.capture2e(RbConfig.ruby, File.join(dir, 'scripts/customer_ui_action_sweep.rb'))
        assert(!status.success?, output)
        assert(output.include?('No UI actions were executed'), output)
        assert_eq(Dir.glob(File.join(dir, '**/mini-click.json')), [])
        proofs = Dir.glob(File.join(dir, 'outputs/customer-ui/source-test-proof-*.json'))
        assert_eq(proofs.length, 1)
        proof = JSON.parse(File.read(proofs.first))
        assert_eq(proof['proof_type'], 'source_guard')
        assert(!proof.key?('status'))
        ['.sane/customer_ui_action_receipt.json', 'outputs/customer_ui_action_receipt.json'].each do |path|
          assert_eq(File.read(File.join(dir, path)), 'existing real receipt')
        end
      end
    end
  end
end)
