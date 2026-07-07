#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require 'zlib'

require_relative '../hooks/test/test_framework'
require_relative 'customer_ui_contract'
require_relative 'gate_review'
require_relative 'release'

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

def capture_stderr
  original_stderr = $stderr
  buffer = StringIO.new
  $stderr = buffer
  yield
  buffer.string
ensure
  $stderr = original_stderr
end

def with_env(overrides)
  previous = {}
  overrides.each_key { |key| previous[key] = ENV.key?(key) ? ENV[key] : :__missing__ }
  overrides.each do |key, value|
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
  yield
ensure
  previous.each do |key, value|
    value == :__missing__ ? ENV.delete(key) : ENV[key] = value
  end
end

def write_test_png(path, width: 160, height: 120)
  File.binwrite(path, "\x89PNG\r\n\x1A\n".b + ("\0" * 8) + [width, height].pack('NN') + ("\0" * 16))
end

def write_test_png_with_text(path, text:, source: 'outputs/shared-source.png', width: 160, height: 120)
  chunk = lambda do |type, payload|
    [payload.bytesize].pack('N') + type + payload + [Zlib.crc32(type + payload)].pack('N')
  end
  row = "\0".b + ("\xFF\x55\x00".b * width)
  raw = row * height
  ihdr = [width, height, 8, 2, 0, 0, 0].pack('NNC5')
  File.binwrite(
    path,
    "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR', ihdr) +
      chunk.call('tEXt', "SaneSource\0#{source}") +
      chunk.call('tEXt', "SaneAction\0#{text}") +
      chunk.call('IDAT', Zlib::Deflate.deflate(raw)) +
      chunk.call('IEND', ''.b)
  )
end

def write_resource_soak_pair(dir, version:, build:, include_log: true, keyword_candidate: false)
  now = Time.now.utc
  evidence_dir = File.join(dir, 'outputs', 'customer-ui', 'resource-soak-proof')
  FileUtils.mkdir_p(evidence_dir)
  artifact_path = File.join(evidence_dir, 'resource-soak-sanebar_runtime_resource_soak.json')
  log_path = File.join(evidence_dir, 'resource-soak-sanebar_runtime_resource_soak.log')
  if include_log
    candidate_line = if keyword_candidate
                       "candidate={pid: 123, app_path: \"/Applications/SaneExample.app\", app_version: \"#{version}\", app_build: \"#{build}\", process_path: \"/Applications/SaneExample.app/Contents/MacOS/SaneExample\"}"
                     else
                       "candidate={:app_path=>\"/Applications/SaneExample.app\", :app_version=>\"#{version}\", :app_build=>\"#{build}\", :process_path=>\"/Applications/SaneExample.app/Contents/MacOS/SaneExample\"}"
                     end
    File.write(
      log_path,
      [
        "resource_soak_started_at=#{(now - 300).iso8601}",
        candidate_line,
        'sample=1 elapsed=0.0s cpu=0.2 rss=80.0MB physical=60.0MB',
        'sample=2 elapsed=300.0s cpu=0.1 rss=82.0MB physical=61.0MB',
        "resource_soak_finished_at=#{now.iso8601}",
        'status=pass'
      ].join("\n")
    )
  end
  File.write(
    artifact_path,
    JSON.pretty_generate(
      status: 'pass',
      started_at: (now - 300).iso8601,
      finished_at: now.iso8601,
      duration_seconds: 300.0,
      adaptive: true,
      adaptive_status: 'early_pass',
      sample_count: 2,
      physical_sample_count: 2,
      physical_missing_sample_count: 0,
      evidence_types: %w[mini_runtime log state_receipt],
      evidence_paths: [log_path],
      completed_scenarios: [
        'adaptive Mini resource check passed for this release build',
        'average CPU remains within idle budget',
        'RSS and physical footprint do not grow beyond the short-soak release budget'
      ],
      samples: [
        {
          sampled_at: (now - 300).iso8601,
          elapsed_seconds: 0.0,
          cpu: 0.2,
          rss_mb: 80.0,
          physical_footprint_mb: 60.0
        },
        {
          sampled_at: now.iso8601,
          elapsed_seconds: 300.0,
          cpu: 0.1,
          rss_mb: 82.0,
          physical_footprint_mb: 61.0
        }
      ],
      candidate: {
        app_path: '/Applications/SaneExample.app',
        app_version: version,
        app_build: build
      }
    )
  )
  [artifact_path, log_path]
end

class ReleaseGuardrailHarness
  include SaneMasterModules::CustomerUIContract
  include SaneMasterModules::GateReview
  include SaneMasterModules::Release

  def initialize
    @stubbed_url_statuses = {}
    @stubbed_asc_paths = {}
    @stubbed_asc_status_paths = {}
    @stubbed_jxa_result = nil
    @last_jxa_script = nil
    @saneprocess_repo_root = File.expand_path('../..', __dir__)
    @customer_ui_commands = []
  end

  attr_writer :saneprocess_repo_root
  attr_reader :customer_ui_commands

  def saneprocess_repo_root
    @saneprocess_repo_root
  end

  def stub_url_status(url, code:, location: '', error: nil)
    @stubbed_url_statuses[url] = { code: code, location: location, error: error }
  end

  def appstore_fetch_url_status(url)
    @stubbed_url_statuses.fetch(url) do
      { code: 0, location: '', error: "missing stub for #{url}" }
    end
  end

  def stub_asc_json(path, payload)
    @stubbed_asc_paths[path] = payload
  end

  def stub_asc_json_with_status(path, code, payload, base: 'https://api.appstoreconnect.apple.com/v1')
    @stubbed_asc_status_paths[[base, path]] = [code, payload]
  end

  def appstore_connect_token
    'stub-token'
  end

  def ensure_research_gate_clear!(_command_name)
    true
  end

  def asc_get_json(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
    _ = token
    _ = base
    @stubbed_asc_paths[path]
  end

  def asc_get_json_with_status(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
    _ = token
    @stubbed_asc_status_paths.fetch([base, path]) do
      payload = @stubbed_asc_paths[path]
      payload ? [200, payload] : [0, nil]
    end
  end

  def stub_osascript_jxa(output, success:)
    @stubbed_jxa_result = [output, success]
  end

  def run_osascript_jxa(_script)
    @last_jxa_script = _script
    output, success = @stubbed_jxa_result || ['', true]
    status = Struct.new(:success?).new(success)
    [output, status]
  end

  def customer_ui_mini_host?
    true
  end

  def customer_ui_run_command(*command)
    @customer_ui_commands << command
    status = Struct.new(:success?).new(true)
    ['{"ok":true}', status]
  end

  attr_reader :last_jxa_script
end

include TestFramework

exit(run_tests('SaneMaster App Store Guardrail Tests') do
  subject = ReleaseGuardrailHarness.new

  test_category('Release preflight plist discovery') do
    test('ignores dependency Info.plist fixtures when checking app release metadata') do
      Dir.mktmpdir('project-plist-paths-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'SourcePackages', 'checkouts', 'Sparkle', 'Tests', 'Resources', 'Fixture.bundle', 'Contents'))
        FileUtils.mkdir_p(File.join(dir, 'Carthage', 'Checkouts', 'Sparkle', 'Fixture.bundle', 'Contents'))
        File.write(File.join(dir, 'SaneExample', 'Info.plist'), '<plist/>')
        File.write(File.join(dir, 'SourcePackages', 'checkouts', 'Sparkle', 'Tests', 'Resources', 'Fixture.bundle', 'Contents', 'Info.plist'), '<plist/>')
        File.write(File.join(dir, 'Carthage', 'Checkouts', 'Sparkle', 'Fixture.bundle', 'Contents', 'Info.plist'), '<plist/>')

        paths = nil
        Dir.chdir(dir) do
          paths = subject.project_info_plist_paths
        end

        assert(paths.sort == ['SaneExample/Info.plist'], "expected only app Info.plist, got #{paths.inspect}")
      end
      true
    end
  end

  test_category('Customer UI action release contract') do
    test('blocks release when customer UI contract is missing') do
      Dir.mktmpdir('missing-customer-ui-contract-') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected missing customer UI contract to block')
        assert_includes(report[:issues].join("\n"), 'Missing customer UI action contract')
      end
      true
    end

    test('requires receipt to match manifest and current source fingerprint') do
      Dir.mktmpdir('customer-ui-contract-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        manifest_path = File.join(dir, 'Tests', 'CustomerUIActions.yml')
        File.write(
          manifest_path,
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'Clicked primary toggle on the Mini and observed state change',
                      path: 'outputs/saneexample-main-clicks.json'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured Mini screenshot after the toggle changed visible state',
                      path: 'outputs/saneexample-main.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['outputs/saneexample-main-clicks.json', 'outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected matching customer UI receipt to pass: #{report[:issues].inspect}")
      end
      true
    end

    test('accepts explicit customer UI coverage receipts without completion wording') do
      Dir.mktmpdir('customer-ui-coverage-contract-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: history-row
                title: History row coverage
                surfaces: [History]
                steps: [Verify row action wiring]
                assertions: [Row action remains visible]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_runtime, screenshot]
                user_inputs: [Row action click]
                expected_outputs: [Row action remains visible]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Seeded Mini fixture with a visible history row
                  setup_steps: [Launch the seeded Mini fixture]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'history-row.png'))
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'history row coverage ok')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['history-row'],
              action_results: {
                'history-row' => {
                  coverage_status: 'covered',
                  completion_scope: 'structured_coverage_only',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Seeded Mini fixture with a visible history row after launching the seeded Mini fixture'
                  },
                  declared_inputs: ['Row action click'],
                  covered_assertions: ['Row action remains visible'],
                  evidence: [
                    {
                      type: 'mini_runtime',
                      detail: 'Mini runtime coverage metadata',
                      path: 'outputs/runtime.log'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured Mini screenshot after fixture render',
                      path: 'outputs/history-row.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb history-row',
                    steps_covered: ['Verify row action wiring'],
                    outcome: 'History row covered without claiming live click completion',
                    artifacts: ['outputs/runtime.log', 'outputs/history-row.png']
                  }
                }
              },
              screenshots: ['outputs/history-row.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected explicit coverage receipt to pass: #{report[:issues].inspect}")
      end
      true
    end

    test('customer UI runtime fingerprint ignores test-only source changes') do
      Dir.mktmpdir('customer-ui-test-only-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        test_path = File.join(dir, 'Tests', 'CustomerUIActionContractXCTests.swift')
        File.write(test_path, 'final class CustomerUIActionContractXCTests {}')

        before = nil
        after_test_change = nil
        after_source_change = nil
        Dir.chdir(dir) do
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(test_path, 'final class CustomerUIActionContractXCTests { let changed = true }')
          after_test_change = subject.send(:customer_ui_source_fingerprint)
          File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView { let changed = true }')
          after_source_change = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after_test_change)
        assert(before != after_source_change, 'expected shipped source change to update customer UI fingerprint')
      end
      true
    end

    test('customer UI receipt accepts only a known legacy test-inclusive fingerprint') do
      Dir.mktmpdir('customer-ui-legacy-test-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        test_path = File.join(dir, 'Tests', 'CustomerUIActionContractXCTests.swift')
        File.write(test_path, 'final class CustomerUIActionContractXCTests {}')

        old_time = Time.now - 120
        [File.join(dir, '.saneprocess'), File.join(dir, 'SaneExample', 'ContentView.swift'), File.join(dir, 'Tests', 'CustomerUIActions.yml'), test_path].each do |path|
          File.utime(old_time, old_time, path)
        end

        legacy_fingerprint = nil
        current_fingerprint = nil
        receipt = nil
        Dir.chdir(dir) do
          legacy_fingerprint = subject.send(:customer_ui_source_fingerprint, include_tests: true)
          current_fingerprint = subject.send(:customer_ui_source_fingerprint)
          receipt = {
            'source_fingerprint' => legacy_fingerprint,
            'generated_at' => (Time.now - 60).utc.iso8601
          }
          assert(subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, current_fingerprint))
          File.write(test_path, 'final class CustomerUIActionContractXCTests { let changed = true }')
          assert(subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, current_fingerprint))
          File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView { let changed = true }')
          assert(!subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, current_fingerprint))
        end
      end
      true
    end

    test('customer UI receipt rejects arbitrary legacy-looking fingerprints') do
      Dir.mktmpdir('customer-ui-arbitrary-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        test_path = File.join(dir, 'Tests', 'CustomerUIActionContractXCTests.swift')
        File.write(test_path, 'final class CustomerUIActionContractXCTests {}')

        Dir.chdir(dir) do
          current_fingerprint = subject.send(:customer_ui_source_fingerprint)
          bogus_receipt = {
            'source_fingerprint' => 'a' * 64,
            'generated_at' => (Time.now - 60).utc.iso8601
          }
          File.write(test_path, 'final class CustomerUIActionContractXCTests { let changed = true }')
          File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView { let changed = true }')
          assert(!subject.send(:customer_ui_receipt_source_fingerprint_current?, bogus_receipt, current_fingerprint))
        end
      end
      true
    end

    test('customer UI runtime fingerprint ignores script and QA harness files') do
      Dir.mktmpdir('customer-ui-script-test-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Scripts'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        test_path = File.join(dir, 'Scripts', 'qa_test.rb')
        File.write(test_path, 'puts :old')

        before = nil
        after_test_change = nil
        after_qa_change = nil
        after_customer_ui_script_change = nil
        Dir.chdir(dir) do
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(test_path, 'puts :new')
          after_test_change = subject.send(:customer_ui_source_fingerprint)
          File.write(File.join(dir, 'Scripts', 'qa.rb'), 'puts :release_orchestration')
          after_qa_change = subject.send(:customer_ui_source_fingerprint)
          File.write(File.join(dir, 'Scripts', 'customer_ui_action_sweep.rb'), 'puts :runtime')
          after_customer_ui_script_change = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after_test_change)
        assert_eq(before, after_qa_change, 'release QA orchestration changes should not stale customer UI visual proof')
        assert_eq(before, after_customer_ui_script_change, 'customer UI runner changes should not stale customer UI visual proof')
      end
      true
    end

    test('customer UI runtime fingerprint ignores project metadata and version churn') do
      Dir.mktmpdir('customer-ui-project-metadata-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample.xcodeproj'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        File.write(
          File.join(dir, 'project.yml'),
          "packages:\n  SaneUI:\n    revision: old\nsettings:\n  MARKETING_VERSION: \"1.0.0\"\n  CURRENT_PROJECT_VERSION: \"100\"\n"
        )
        File.write(
          File.join(dir, 'SaneExample.xcodeproj', 'project.pbxproj'),
          "MARKETING_VERSION = 1.0.0;\nCURRENT_PROJECT_VERSION = 100;\nproductRefGroup = ABC;\n"
        )

        before = nil
        after = nil
        Dir.chdir(dir) do
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(
            File.join(dir, 'project.yml'),
            "packages:\n  SaneUI:\n    revision: new\nsettings:\n  MARKETING_VERSION: \"1.0.1\"\n  CURRENT_PROJECT_VERSION: \"101\"\n"
          )
          File.write(
            File.join(dir, 'SaneExample.xcodeproj', 'project.pbxproj'),
            "compatibilityVersion = \"Xcode 14.0\";\nMARKETING_VERSION = 1.0.1;\nCURRENT_PROJECT_VERSION = 101;\n"
          )
          after = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after, 'project metadata/version changes should not stale customer UI visual proof')
      end
      true
    end

    test('customer UI runtime fingerprint includes shared SaneUI source') do
      Dir.mktmpdir('customer-ui-shared-source-fingerprint-') do |root|
        app = File.join(root, 'apps', 'SaneExample')
        shared = File.join(root, 'infra', 'SaneUI', 'Sources', 'SaneUI', 'License', 'LicenseSettingsView.swift')
        FileUtils.mkdir_p(File.join(app, 'SaneExample'))
        FileUtils.mkdir_p(File.dirname(shared))
        File.write(File.join(app, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(app, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(shared, 'struct LicenseSettingsView {}')

        before = nil
        after_shared_change = nil
        Dir.chdir(app) do
          subject.saneprocess_repo_root = File.join(root, 'infra', 'SaneProcess')
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(shared, 'struct LicenseSettingsView { let changed = true }')
          after_shared_change = subject.send(:customer_ui_source_fingerprint)
        end

        assert(before != after_shared_change, 'expected shared SaneUI source change to update customer UI fingerprint')
      end
      true
    end

    test('customer UI runtime fingerprint ignores release and contract harness files') do
      Dir.mktmpdir('customer-ui-release-source-fingerprint-') do |root|
        app = File.join(root, 'apps', 'SaneExample')
        process_root = File.join(root, 'infra', 'SaneProcess')
        release_rb = File.join(process_root, 'scripts', 'sanemaster', 'release.rb')
        release_sh = File.join(process_root, 'scripts', 'release.sh')
        ui_contract = File.join(process_root, 'scripts', 'sanemaster', 'customer_ui_contract.rb')
        FileUtils.mkdir_p(File.join(app, 'SaneExample'))
        FileUtils.mkdir_p(File.dirname(release_rb))
        File.write(File.join(app, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(app, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(release_rb, 'release orchestration old')
        File.write(release_sh, 'release shell old')
        File.write(ui_contract, 'customer ui contract old')

        before = nil
        after_release_change = nil
        after_contract_change = nil
        Dir.chdir(app) do
          subject.saneprocess_repo_root = process_root
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(release_rb, 'release orchestration new')
          File.write(release_sh, 'release shell new')
          after_release_change = subject.send(:customer_ui_source_fingerprint)
          File.write(ui_contract, 'customer ui contract new')
          after_contract_change = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after_release_change)
        assert_eq(before, after_contract_change, 'customer UI contract changes should not stale existing app visual proof')
      end
      true
    end

    test('customer UI runtime fingerprint ignores outreach metadata changes') do
      Dir.mktmpdir('customer-ui-outreach-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        File.write(File.join(dir, '.outreach.yml'), "known_facts:\n  - old copy\n")
        FileUtils.mkdir_p(File.join(dir, 'Scripts'))
        File.write(File.join(dir, 'Scripts', 'check_outreach_opportunities.rb'), 'old outreach script')

        before = nil
        after = nil
        Dir.chdir(dir) do
          before = subject.send(:customer_ui_source_fingerprint)
          File.write('.outreach.yml', "known_facts:\n  - updated copy\n")
          File.write(File.join('Scripts', 'check_outreach_opportunities.rb'), 'new outreach script')
          after = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after, 'outreach metadata should not stale customer UI runtime proof')
      end
      true
    end

    test('customer UI runtime fingerprint ignores release signing helper changes') do
      Dir.mktmpdir('customer-ui-signing-helper-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'Scripts'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(dir, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        File.write(File.join(dir, 'Scripts', 'sign_update.swift'), 'old signing helper')

        before = nil
        after = nil
        Dir.chdir(dir) do
          before = subject.send(:customer_ui_source_fingerprint)
          File.write(File.join('Scripts', 'sign_update.swift'), 'new signing helper')
          after = subject.send(:customer_ui_source_fingerprint)
        end

        assert_eq(before, after, 'release signing helper changes should not stale customer UI runtime proof')
      end
      true
    end

    test('customer UI receipt accepts unchanged source fingerprint for app proof') do
      Dir.mktmpdir('customer-ui-legacy-harness-fingerprint-') do |root|
        app = File.join(root, 'apps', 'SaneExample')
        process_root = File.join(root, 'infra', 'SaneProcess')
        FileUtils.mkdir_p(File.join(app, 'SaneExample'))
        FileUtils.mkdir_p(File.join(app, 'Scripts'))
        FileUtils.mkdir_p(File.join(process_root, 'scripts', 'sanemaster'))
        File.write(File.join(app, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(app, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(File.join(app, 'Scripts', 'qa.rb'), 'puts :release_orchestration')
        File.write(File.join(process_root, 'scripts', 'release.sh'), 'release shell')
        File.write(File.join(process_root, 'scripts', 'SaneMaster.rb'), 'master')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'release.rb'), 'release ruby')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'release_readiness.rb'), 'readiness')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'release_guardrail_test.rb'), 'release tests')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'test_mode.rb'), 'test mode')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'visual_smoke.rb'), 'visual smoke')
        File.write(File.join(process_root, 'scripts', 'sanemaster', 'customer_ui_contract.rb'), 'validator')

        Dir.chdir(app) do
          subject.saneprocess_repo_root = process_root
          current = subject.send(:customer_ui_source_fingerprint)
          legacy = subject.send(:customer_ui_source_fingerprint, include_release_harness: true)
          assert(current != legacy, 'release-harness-inclusive fingerprint should include release harness files')

          generated_at = Time.now - 60
          old_time = generated_at - 60
          [
            File.join(app, '.saneprocess'),
            File.join(app, 'SaneExample', 'ContentView.swift'),
            File.join(app, 'Scripts', 'qa.rb')
          ].each { |path| File.utime(old_time, old_time, path) }
          receipt = { 'source_fingerprint' => legacy, 'generated_at' => generated_at.utc.iso8601 }
          assert(subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, current))

          File.write(File.join(process_root, 'scripts', 'sanemaster', 'release.rb'), 'release ruby changed')
          changed_legacy = subject.send(:customer_ui_source_fingerprint, include_release_harness: true)
          assert(changed_legacy != legacy, 'release harness changes should move the harness-inclusive fingerprint')
          assert(subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, current), 'release harness changes alone should not stale app visual proof')

          File.write(File.join(app, 'SaneExample', 'ContentView.swift'), 'struct ContentView { let changed = true }')
          changed_current = subject.send(:customer_ui_source_fingerprint)
          assert(!subject.send(:customer_ui_receipt_source_fingerprint_current?, receipt, changed_current))
        end
      end
      true
    end

    test('release status fingerprint includes shared SaneUI source for app UI changes') do
      Dir.mktmpdir('release-status-shared-source-fingerprint-') do |root|
        app = File.join(root, 'apps', 'SaneExample')
        shared = File.join(root, 'infra', 'SaneUI', 'Sources', 'SaneUI', 'License', 'LicenseSettingsView.swift')
        FileUtils.mkdir_p(File.join(app, 'SaneExample'))
        FileUtils.mkdir_p(File.dirname(shared))
        File.write(File.join(app, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(app, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(shared, 'struct LicenseSettingsView {}')

        before = nil
        after_shared_change = nil
        Dir.chdir(app) do
          subject.saneprocess_repo_root = File.join(root, 'infra', 'SaneProcess')
          before = subject.send(:release_status_source_fingerprint, app)
          File.write(shared, 'struct LicenseSettingsView { let changed = true }')
          after_shared_change = subject.send(:release_status_source_fingerprint, app)
        end

        assert(before != after_shared_change, 'expected shared SaneUI source change to update release status fingerprint')
      end
      true
    end

    test('requires actions to map back to historical failure classes') do
      Dir.mktmpdir('customer-ui-history-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
              - id: invalid-history-class
                title: Invalid history class is blocked
                surfaces: [Main window]
                steps: [Click another toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [made_up_failure]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        issues = report[:issues].join("\n")
        assert(!report[:ok], 'expected missing/invalid historical failure classes to block')
        assert_includes(issues, 'primary-toggle: missing historical_failure_classes')
        assert_includes(issues, 'invalid-history-class: historical_failure_classes must use known values')
      end
      true
    end

    test('requires functional seeded state and output expectations for completion workflows') do
      Dir.mktmpdir('customer-ui-functional-state-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: ai-command
                title: AI command returns a result
                surfaces: [Main window]
                steps: [Type prompt, click Run]
                assertions: [Result appears]
                evidence: [model response]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_click, model_response]
                historical_failure_classes: [external_integration_stub]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        issues = report[:issues].join("\n")
        assert(!report[:ok], 'expected unseeded completion workflow to block')
        assert_includes(issues, 'ai-command: missing functional_state')
        assert_includes(issues, 'ai-command: full/fixture completion actions must declare user_inputs or fixture_paths')
        assert_includes(issues, 'ai-command: full/fixture completion actions must declare expected_outputs')
      end
      true
    end

    test('requires the standard runtime state matrix when mandated') do
      Dir.mktmpdir('customer-ui-runtime-matrix-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            require_standard_runtime_state_matrix: true
            runtime_state_matrix:
              cold_launch_relaunch:
                why: Customers start here.
                action_ids: [startup]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime]
                runner: scripts/customer_ui_action_sweep.rb
            actions:
              - id: startup
                title: Startup works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Status item appears]
                evidence: [runtime proof]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime]
                historical_failure_classes: [install_update_packaging]
                functional_state:
                  description: Clean launch fixture
                  setup_steps: [Reset app state]
                user_inputs: [Launch app]
                expected_outputs: [Status item appears]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected incomplete standard runtime state matrix to block')
        assert_includes(report[:issues].join("\n"), 'runtime_state_matrix missing standard state(s)')
      end
      true
    end

    test('requires receipts to prove functional state and completion output') do
      Dir.mktmpdir('customer-ui-output-proof-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: ai-command
                title: AI command returns a result
                surfaces: [Main window]
                steps: [Type prompt, click Run]
                assertions: [Result appears]
                evidence: [model response]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_click, model_response]
                historical_failure_classes: [external_integration_stub]
                functional_state:
                  description: AI backend connected with a seeded command prompt field
                  setup_steps: [Start local model service, launch app with demo account]
                user_inputs: [Summarize the seeded project]
                expected_outputs: [Non-empty generated answer appears in the output panel]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-ai.png'))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['ai-command'],
              action_results: {
                'ai-command' => {
                  status: 'passed',
                  proof_level: 'full_runtime_completion',
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'Clicked Run on the Mini'
                    },
                    {
                      type: 'model_response',
                      detail: 'Model response captured from output panel'
                    }
                  ]
                }
              },
              screenshots: ['outputs/saneexample-ai.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        issues = report[:issues].join("\n")
        assert(!report[:ok], 'expected missing functional/output receipt proof to block')
        assert_includes(issues, 'ai-command: missing functional_state proof')
        assert_includes(issues, 'ai-command: missing exercised user inputs from receipt')
        assert_includes(issues, 'ai-command: missing output_assertions proving expected outcomes')
      end
      true
    end

    test('blocks stale customer UI receipt after source changes') do
      Dir.mktmpdir('stale-customer-ui-contract-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        source_path = File.join(dir, 'SaneExample', 'ContentView.swift')
        File.write(source_path, 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'Clicked primary toggle on the Mini and observed state change',
                      path: 'outputs/saneexample-main-clicks.json'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured Mini screenshot after the toggle changed visible state',
                      path: 'outputs/saneexample-main.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['outputs/saneexample-main-clicks.json', 'outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          File.write(source_path, 'struct ContentView { let changed = true }')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected stale customer UI receipt to block')
        assert_includes(report[:issues].join("\n"), 'source fingerprint is stale')
      end
      true
    end

    test('allows tracked .sane receipt without making the source fingerprint circular') do
      Dir.mktmpdir('tracked-customer-ui-receipt-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, '.sane'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, '.sane', 'saneexample-main.png'))
          File.write(File.join(dir, '.sane', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, '.sane', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'Clicked primary toggle on the Mini and observed state change',
                      path: '.sane/saneexample-main-clicks.json'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured Mini screenshot after the toggle changed visible state',
                      path: '.sane/saneexample-main.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['.sane/saneexample-main-clicks.json', '.sane/saneexample-main.png']
                  }
                }
              },
              screenshots: ['.sane/saneexample-main.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected tracked .sane customer UI receipt to pass: #{report[:issues].inspect}")
      end
      true
    end

    test('accepts local Air customer UI receipts only with explicit approval') do
      Dir.mktmpdir('air-customer-ui-receipt-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary Toggle
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Local Air fallback test fixture
                  setup_steps: [Launch the approved local test fixture before clicking]
          YAML
        )

        local_host = 'sj-macbook-air.local'
        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: local_host,
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Approved Air fixture loaded'
                  },
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'applescript=toggle ok',
                      path: 'outputs/saneexample-main-clicks.json'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured local Air screenshot after click',
                      path: 'outputs/saneexample-main.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the approved Air click',
                    artifacts: ['outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )

          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          assert(!report[:ok], 'expected local receipt to fail without explicit Air approval')
          assert(report[:issues].any? { |issue| issue.include?('explicitly approved local Air fallback') },
                 "expected Air approval issue, got #{report[:issues].inspect}")

          with_env('SANE_APPROVE_LOCAL_UI_ON_AIR' => 'MR. SANE APPROVES LOCAL UI ON AIR') do
            report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          end
        end

        assert(report[:ok], "expected approved Air receipt to pass: #{report[:issues].inspect}")
      end
      true
    end

    test('ignores SaneMaster scratch files when validating a customer UI receipt') do
      Dir.mktmpdir('customer-ui-scratch-files-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    {
                      type: 'mini_click',
                      detail: 'Clicked primary toggle on the Mini and observed state change',
                      path: 'outputs/saneexample-main-clicks.json'
                    },
                    {
                      type: 'screenshot',
                      detail: 'Captured Mini screenshot after the toggle changed visible state',
                      path: 'outputs/saneexample-main.png'
                    }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['outputs/saneexample-main-clicks.json', 'outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          FileUtils.mkdir_p(File.join(dir, '.sanemaster'))
          File.write(File.join(dir, '.sanemaster', 'release_preflight_status.json'), '{"status":"running"}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected SaneMaster scratch files not to stale receipt: #{report[:issues].inspect}")
      end
      true
    end

    test('ignores client-local MCP, agent, and dependency cache config when validating a customer UI receipt') do
      Dir.mktmpdir('customer-ui-client-config-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    { type: 'mini_click', detail: 'Clicked primary toggle on the Mini', path: 'outputs/saneexample-main-clicks.json' },
                    { type: 'screenshot', detail: 'Captured Mini screenshot after the toggle changed visible state', path: 'outputs/saneexample-main.png' }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['outputs/saneexample-main-clicks.json', 'outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          FileUtils.mkdir_p(File.join(dir, '.claude'))
          FileUtils.mkdir_p(File.join(dir, '.codex'))
          FileUtils.mkdir_p(File.join(dir, 'node_modules', '.cache', 'wrangler'))
          File.write(File.join(dir, '.mcp.json'), '{"mcpServers":{}}')
          File.write(File.join(dir, '.claude', 'settings.local.json'), '{"local":true}')
          File.write(File.join(dir, '.codex', 'session.json'), '{"local":true}')
          File.write(File.join(dir, 'node_modules', '.cache', 'wrangler', 'pages.json'), '{"account":"local"}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected client-local config not to stale customer UI receipt: #{report[:issues].inspect}")
      end
      true
    end

    test('blocks coarse customer UI receipts that only list covered ids') do
      Dir.mktmpdir('coarse-customer-ui-contract-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected coarse customer UI receipt to block')
        assert_includes(report[:issues].join("\n"), 'missing per-action results')
      end
      true
    end

    test('requires runtime receipts to include structured workflow proof') do
      Dir.mktmpdir('customer-ui-workflow-proof-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          File.write(File.join(dir, 'outputs', 'saneexample-main-clicks.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    { type: 'mini_click', detail: 'Clicked primary toggle', path: 'outputs/saneexample-main-clicks.json' },
                    { type: 'screenshot', detail: 'Captured result', path: 'outputs/saneexample-main.png' }
                  ]
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected runtime receipt without workflow proof to block')
        assert_includes(report[:issues].join("\n"), 'primary-toggle: missing structured workflow proof')
      end
      true
    end

    test('requires action-scoped evidence artifacts for customer workflow receipts') do
      Dir.mktmpdir('customer-ui-evidence-artifacts-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: primary-toggle
                title: Primary toggle works
                surfaces: [Main window]
                steps: [Click primary toggle]
                assertions: [Visible state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default seeded test window with the primary toggle visible
                  setup_steps: [Launch the Mini test fixture before clicking]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'saneexample-main.png'))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['primary-toggle'],
              action_results: {
                'primary-toggle' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: {
                    status: 'established',
                    detail: 'Default Mini test fixture loaded before clicking'
                  },
                  evidence: [
                    { type: 'mini_click', detail: 'Clicked primary toggle' },
                    { type: 'screenshot', detail: 'Captured result', path: 'outputs/saneexample-main.png' }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb primary-toggle',
                    steps_completed: ['Click primary toggle'],
                    outcome: 'Visible state changed after the Mini click',
                    artifacts: ['outputs/saneexample-main.png']
                  }
                }
              },
              screenshots: ['outputs/saneexample-main.png']
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected missing action evidence artifact path to block')
        assert_includes(report[:issues].join("\n"), 'primary-toggle: evidence #1 mini_click missing artifact path')
      end
      true
    end

    test('rejects customer UI receipts that contain blocking status text') do
      Dir.mktmpdir('customer-ui-blocking-status-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: health-action
                title: Health status is clean
                surfaces: [Health tab]
                steps: [Open Health]
                assertions: [Status rows are clean]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [layout_visual_regression]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'health.png'))
          File.write(File.join(dir, 'outputs', 'health-click.json'), '{"clicked":true}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          File.write(
            File.join(dir, 'outputs', 'customer_ui_action_receipt.json'),
            JSON.pretty_generate(
              app: 'SaneExample',
              status: 'passed',
              host: 'mini',
              generated_at: Time.now.utc.iso8601,
              manifest_sha256: report[:manifest_sha256],
              source_fingerprint: report[:source_fingerprint],
              tested_action_ids: ['health-action'],
              screenshots: ['outputs/health.png'],
              action_results: {
                'health-action' => {
                  status: 'passed',
                  proof_level: 'runtime_visual',
                  functional_state: { status: 'established', detail: 'Default fixture' },
                  evidence: [
                    { type: 'mini_click', detail: 'settings_ax_tab_index=5 text=Health :: Menu Bar GeometryNeeds CheckSaneBar ItemsDetached', path: 'outputs/health-click.json' },
                    { type: 'screenshot', detail: 'Captured Health tab', path: 'outputs/health.png' }
                  ],
                  workflow: {
                    runner: 'scripts/customer_ui_action_sweep.rb health-action',
                    steps_completed: ['Open Health'],
                    outcome: 'Health tab captured',
                    artifacts: ['outputs/health-click.json', 'outputs/health.png']
                  }
                }
              }
            )
          )
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected warning status text to block customer UI contract')
        assert_includes(report[:issues].join("\n"), 'health-action: customer UI evidence contains blocking status text: Needs Check, Detached')
      end
      true
    end

    test('rejects reused screenshot evidence across different release actions') do
      Dir.mktmpdir('customer-ui-reused-screenshots-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: first-action
                title: First action works
                surfaces: [Main window]
                steps: [Click first]
                assertions: [First state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
              - id: second-action
                title: Second action works
                surfaces: [Main window]
                steps: [Click second]
                assertions: [Second state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'shared.png'))
          File.write(File.join(dir, 'outputs', 'first-click.json'), '{"clicked":"first"}')
          File.write(File.join(dir, 'outputs', 'second-click.json'), '{"clicked":"second"}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          base = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: %w[first-action second-action],
            screenshots: ['outputs/shared.png']
          }
          base[:action_results] = {
            'first-action' => {
              status: 'passed',
              proof_level: 'runtime_visual',
              functional_state: { status: 'established', detail: 'Default fixture' },
              evidence: [
                { type: 'mini_click', detail: 'Clicked first', path: 'outputs/first-click.json' },
                { type: 'screenshot', detail: 'Captured first', path: 'outputs/shared.png' }
              ],
              workflow: {
                runner: 'scripts/customer_ui_action_sweep.rb first-action',
                steps_completed: ['Click first'],
                outcome: 'First state changed',
                artifacts: ['outputs/first-click.json', 'outputs/shared.png']
              }
            },
            'second-action' => {
              status: 'passed',
              proof_level: 'runtime_visual',
              functional_state: { status: 'established', detail: 'Default fixture' },
              evidence: [
                { type: 'mini_click', detail: 'Clicked second', path: 'outputs/second-click.json' },
                { type: 'screenshot', detail: 'Captured second', path: 'outputs/shared.png' }
              ],
              workflow: {
                runner: 'scripts/customer_ui_action_sweep.rb second-action',
                steps_completed: ['Click second'],
                outcome: 'Second state changed',
                artifacts: ['outputs/second-click.json', 'outputs/shared.png']
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(base))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected reused screenshot to block release proof')
        assert_includes(report[:issues].join("\n"), 'Screenshot artifact reused across release actions')
      end
      true
    end

    test('rejects screenshot reuse when only PNG metadata differs') do
      Dir.mktmpdir('customer-ui-reused-pixels-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: appearance-customization-actions
                title: First action works
                surfaces: [Main window]
                steps: [Click first]
                assertions: [First state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
              - id: startup-wake-appearance-recovery
                title: Second action works
                surfaces: [Main window]
                steps: [Click second]
                assertions: [Second state changes]
                evidence: [screenshot]
                required_proof_level: runtime_visual
                required_evidence_types: [mini_click, screenshot]
                historical_failure_classes: [activation_noop]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png_with_text(File.join(dir, 'outputs', 'first.png'), text: 'appearance-customization-actions')
          write_test_png_with_text(File.join(dir, 'outputs', 'second.png'), text: 'startup-wake-appearance-recovery')
          File.write(File.join(dir, 'outputs', 'first-click.json'), '{"clicked":"first"}')
          File.write(File.join(dir, 'outputs', 'second-click.json'), '{"clicked":"second"}')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: %w[appearance-customization-actions startup-wake-appearance-recovery],
            screenshots: ['outputs/first.png', 'outputs/second.png'],
            action_results: {
              'appearance-customization-actions' => {
                status: 'passed',
                proof_level: 'runtime_visual',
                functional_state: { status: 'established', detail: 'Default fixture' },
                evidence: [
                  { type: 'mini_click', detail: 'Clicked first', path: 'outputs/first-click.json' },
                  { type: 'screenshot', detail: 'Captured first', path: 'outputs/first.png' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb appearance-customization-actions',
                  steps_completed: ['Click first'],
                  outcome: 'First state changed',
                  artifacts: ['outputs/first-click.json', 'outputs/first.png']
                }
              },
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'runtime_visual',
                functional_state: { status: 'established', detail: 'Default fixture' },
                evidence: [
                  { type: 'mini_click', detail: 'Clicked second', path: 'outputs/second-click.json' },
                  { type: 'screenshot', detail: 'Captured second', path: 'outputs/second.png' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Click second'],
                  outcome: 'Second state changed',
                  artifacts: ['outputs/second-click.json', 'outputs/second.png']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected reused screenshot pixels to block release proof')
        assert_includes(report[:issues].join("\n"), 'Identical screenshot pixels reused across release actions')
      end
      true
    end

    test('customer UI contract fails failed runtime state rows') do
      Dir.mktmpdir('customer-ui-runtime-state-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              fullscreen_transition:
                why: Fullscreen transitions can regress menu-bar visuals.
                action_ids: [appearance-action]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                runner: scripts/customer_ui_action_sweep.rb
            actions:
              - id: appearance-action
                title: Appearance action works
                surfaces: [Menu bar]
                steps: [Toggle appearance]
                assertions: [Tint remains visible]
                evidence: [screenshot]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                historical_failure_classes: [layout_visual_regression]
                functional_state:
                  description: Default fixture
                  setup_steps: [Launch fixture]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'appearance.png'))
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Appearance tint pixels ok')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['appearance-action'],
            runtime_state_results: [
              { id: 'fullscreen_transition', status: 'failed', evidence_paths: [] }
            ],
            screenshots: ['outputs/appearance.png'],
            action_results: {
              'appearance-action' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                evidence: [
                  { type: 'mini_runtime', detail: '/tmp/sanebar_runtime.log: Appearance tint pixels ok', path: 'outputs/runtime.log' },
                  { type: 'screenshot', detail: 'Captured appearance', path: 'outputs/appearance.png' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb appearance-action',
                  steps_completed: ['Toggle appearance'],
                  outcome: 'Tint remained visible',
                  artifacts: ['outputs/runtime.log', 'outputs/appearance.png']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected failed runtime state row to block release proof')
        assert_includes(report[:issues].join("\n"), 'runtime_state_results fullscreen_transition: status is "failed"')
      end
      true
    end

    test('customer UI contract requires receipts for every runtime matrix row') do
      Dir.mktmpdir('customer-ui-runtime-row-coverage-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              fullscreen_transition:
                why: Fullscreen transitions can regress menu-bar visuals.
                action_ids: [appearance-action]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                runner: scripts/customer_ui_action_sweep.rb
              wake_visible_zone_persistence:
                why: Wake can move visible icons into hidden zones.
                action_ids: [appearance-action]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                runner: scripts/wake_layout_probe.rb
            actions:
              - id: appearance-action
                title: Appearance action works
                surfaces: [Menu bar]
                steps: [Toggle appearance]
                assertions: [Tint remains correct]
                evidence: [screenshot]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                historical_failure_classes: [layout_visual_regression]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Toggle appearance]
                expected_outputs: [Tint remains correct]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'appearance.png'))
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Appearance tint pixels ok')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['appearance-action'],
            runtime_state_results: [
              {
                id: 'fullscreen_transition',
                status: 'passed',
                evidence_types: %w[mini_runtime screenshot],
                evidence_paths: ['outputs/runtime.log', 'outputs/appearance.png']
              }
            ],
            screenshots: ['outputs/appearance.png'],
            action_results: {
              'appearance-action' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Toggle appearance'],
                output_assertions: ['Tint remains correct'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Appearance runtime log', path: 'outputs/runtime.log' },
                  { type: 'screenshot', detail: 'Captured appearance', path: 'outputs/appearance.png' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb appearance-action',
                  steps_completed: ['Toggle appearance'],
                  outcome: 'Tint remained correct',
                  artifacts: ['outputs/runtime.log', 'outputs/appearance.png']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected missing runtime matrix receipt row to block release proof')
        assert_includes(report[:issues].join("\n"), 'Receipt runtime_state_results missing manifest state(s): wake_visible_zone_persistence')
      end
      true
    end

    test('customer UI contract requires runtime rows to prove manifest scenarios') do
      Dir.mktmpdir('customer-ui-runtime-scenarios-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              fullscreen_transition:
                why: Fullscreen transitions can regress menu-bar visuals.
                action_ids: [appearance-action]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot, log]
                runner: scripts/customer_ui_action_sweep.rb
                required_scenarios:
                  - native fullscreen enter and exit
                  - Reduce Transparency enabled
            actions:
              - id: appearance-action
                title: Appearance action works
                surfaces: [Menu bar]
                steps: [Toggle appearance]
                assertions: [Tint remains correct]
                evidence: [screenshot]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, screenshot]
                historical_failure_classes: [layout_visual_regression]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Toggle appearance]
                expected_outputs: [Tint remains correct]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          write_test_png(File.join(dir, 'outputs', 'appearance.png'))
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Appearance tint pixels ok')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['appearance-action'],
            runtime_state_results: [
              {
                id: 'fullscreen_transition',
                status: 'passed',
                evidence_types: %w[mini_runtime screenshot log],
                evidence_paths: ['outputs/runtime.log', 'outputs/appearance.png'],
                completed_scenarios: ['native fullscreen enter and exit']
              }
            ],
            screenshots: ['outputs/appearance.png'],
            action_results: {
              'appearance-action' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Toggle appearance'],
                output_assertions: ['Tint remains correct'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Appearance runtime log', path: 'outputs/runtime.log' },
                  { type: 'screenshot', detail: 'Captured appearance', path: 'outputs/appearance.png' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb appearance-action',
                  steps_completed: ['Toggle appearance'],
                  outcome: 'Tint remained correct',
                  artifacts: ['outputs/runtime.log', 'outputs/appearance.png']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected missing runtime scenario proof to block release proof')
        assert_includes(report[:issues].join("\n"), 'runtime_state_results fullscreen_transition: missing required scenario proof(s): Reduce Transparency enabled')
      end
      true
    end

    test('customer UI runtime rows require candidate build metadata') do
      missing = subject.send(
        :customer_ui_runtime_candidate_receipt_issues,
        'runtime_state_results cold_launch',
        {}
      )
      assert_includes(missing.join("\n"), 'missing runtime candidate metadata')

      Dir.mktmpdir('customer-ui-runtime-candidate-') do |dir|
        File.write(
          File.join(dir, 'project.yml'),
          "settings:\n  base:\n    MARKETING_VERSION: \"2.1.74\"\n    CURRENT_PROJECT_VERSION: \"2174\"\n"
        )
        Dir.chdir(dir) do
          mismatched = subject.send(
            :customer_ui_runtime_candidate_receipt_issues,
            'runtime_state_results cold_launch',
            {
              'runtime_candidate' => {
                'app_path' => '/Applications/SaneBar.app',
                'app_version' => '2.1.73',
                'app_build' => '2173'
              }
            }
          )
          assert_includes(mismatched.join("\n"), 'runtime candidate version "2.1.73" does not match project "2.1.74"')
          assert_includes(mismatched.join("\n"), 'runtime candidate build "2173" does not match project "2174"')
        end
      end
      true
    end

    test('customer UI contract rejects temp-only resource soak runtime evidence') do
      temp_artifact = "/tmp/sanebar_runtime_resource_soak_guardrail_#{Process.pid}.json"
      temp_log = "/tmp/sanebar_runtime_resource_soak_guardrail_#{Process.pid}.log"
      File.write(temp_artifact, JSON.pretty_generate({ status: 'pass' }))
      File.write(temp_log, "status=pass\n")

      Dir.mktmpdir('customer-ui-resource-soak-proof-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              resource_soak_growth:
                why: Release candidates must prove resource growth from durable Mini soak artifacts.
                action_ids: [startup-wake-appearance-recovery]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                runner: scripts/customer_ui_action_sweep.rb
            actions:
              - id: startup-wake-appearance-recovery
                title: Startup wake recovery works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Runtime remains stable]
                evidence: [runtime]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Launch app]
                expected_outputs: [Runtime remains stable]
                historical_failure_classes: [hardware_or_tcc_runtime]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Runtime remains stable')
          write_test_png(File.join(dir, 'outputs', 'runtime.png'))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['startup-wake-appearance-recovery'],
            runtime_state_results: [
              {
                id: 'resource_soak_growth',
                status: 'passed',
                evidence_types: %w[mini_runtime log state_receipt],
                evidence_paths: [temp_artifact, temp_log],
                completed_scenarios: ['adaptive Mini resource check passed for this release build']
              }
            ],
            screenshots: ['outputs/runtime.png'],
            action_results: {
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Launch app'],
                output_assertions: ['Runtime remains stable'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'log', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'state_receipt', detail: 'Resource soak receipt', path: 'outputs/runtime.log' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Launch app'],
                  outcome: 'Runtime remained stable',
                  artifacts: ['outputs/runtime.log']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected temp-only resource soak evidence to block release proof')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'runtime_state_results resource_soak_growth: resource soak evidence must be durable')
        assert_includes(issues, 'runtime_state_results resource_soak_growth: missing durable resource-soak evidence under outputs/customer-ui')
      end
      true
    ensure
      FileUtils.rm_f([temp_artifact, temp_log].compact)
    end

    test('customer UI contract accepts durable resource soak keyword candidate log') do
      Dir.mktmpdir('customer-ui-resource-soak-keyword-proof-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        artifact_path, log_path = write_resource_soak_pair(
          dir,
          version: '2.1.72',
          build: '2172',
          keyword_candidate: true
        )
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              resource_soak_growth:
                why: Release candidates must prove resource growth from durable Mini soak artifacts.
                action_ids: [startup-wake-appearance-recovery]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                runner: scripts/customer_ui_action_sweep.rb
                required_scenarios:
                  - adaptive Mini resource check passed for this release build
                  - average CPU remains within idle budget
                  - RSS and physical footprint do not grow beyond the short-soak release budget
            actions:
              - id: startup-wake-appearance-recovery
                title: Startup wake recovery works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Runtime remains stable]
                evidence: [runtime]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Launch app]
                expected_outputs: [Runtime remains stable]
                historical_failure_classes: [hardware_or_tcc_runtime]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Runtime remains stable')
          write_test_png(File.join(dir, 'outputs', 'runtime.png'))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['startup-wake-appearance-recovery'],
            runtime_state_results: [
              {
                id: 'resource_soak_growth',
                status: 'passed',
                runtime_candidate: {
                  app_path: '/Applications/SaneExample.app',
                  app_version: '2.1.72',
                  app_build: '2172'
                },
                evidence_types: %w[mini_runtime log state_receipt],
                evidence_paths: [artifact_path, log_path],
                completed_scenarios: [
                  'adaptive Mini resource check passed for this release build',
                  'average CPU remains within idle budget',
                  'RSS and physical footprint do not grow beyond the short-soak release budget'
                ]
              }
            ],
            screenshots: ['outputs/runtime.png'],
            action_results: {
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Launch app'],
                output_assertions: ['Runtime remains stable'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Resource soak', path: log_path },
                  { type: 'screenshot', detail: 'Runtime screenshot', path: 'outputs/runtime.png' },
                  { type: 'log', detail: 'Resource soak', path: log_path },
                  { type: 'state_receipt', detail: 'Resource soak artifact', path: artifact_path }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Launch app'],
                  outcome: 'Runtime remained stable',
                  artifacts: [artifact_path, log_path, 'outputs/runtime.png']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected durable keyword-format resource soak proof to pass: #{report[:issues].join("\n")}")
      end
      true
    end

    test('customer UI contract rejects missing durable resource soak paths') do
      Dir.mktmpdir('customer-ui-resource-soak-missing-proof-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs', 'customer-ui'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              resource_soak_growth:
                why: Release candidates must prove resource growth from durable Mini soak artifacts.
                action_ids: [startup-wake-appearance-recovery]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                required_scenarios:
                  - adaptive Mini resource check passed for this release build
            actions:
              - id: startup-wake-appearance-recovery
                title: Startup wake recovery works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Runtime remains stable]
                evidence: [runtime]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Launch app]
                expected_outputs: [Runtime remains stable]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Runtime remains stable')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['startup-wake-appearance-recovery'],
            runtime_state_results: [
              {
                id: 'resource_soak_growth',
                status: 'passed',
                evidence_types: %w[mini_runtime log state_receipt],
                evidence_paths: [
                  'outputs/customer-ui/resource-soak-missing.json',
                  'outputs/customer-ui/resource-soak-missing.log'
                ],
                completed_scenarios: ['adaptive Mini resource check passed for this release build']
              }
            ],
            screenshots: [],
            action_results: {
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Launch app'],
                output_assertions: ['Runtime remains stable'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'log', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'state_receipt', detail: 'Resource soak receipt', path: 'outputs/runtime.log' }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Launch app'],
                  outcome: 'Runtime remained stable',
                  artifacts: ['outputs/runtime.log']
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected missing durable resource soak files to block release proof')
        assert_includes(report[:issues].join("\n"), 'durable resource-soak evidence path(s) do not exist')
      end
      true
    end

    test('customer UI contract rejects durable resource soak without sibling log evidence') do
      Dir.mktmpdir('customer-ui-resource-soak-json-only-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'project.yml'), <<~YAML)
          settings:
            base:
              MARKETING_VERSION: "2.1.62"
              CURRENT_PROJECT_VERSION: "2162"
        YAML
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              resource_soak_growth:
                why: Release candidates must prove resource growth from durable Mini soak artifacts.
                action_ids: [startup-wake-appearance-recovery]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                required_scenarios:
                  - adaptive Mini resource check passed for this release build
            actions:
              - id: startup-wake-appearance-recovery
                title: Startup wake recovery works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Runtime remains stable]
                evidence: [runtime]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Launch app]
                expected_outputs: [Runtime remains stable]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          artifact_path, = write_resource_soak_pair(dir, version: '2.1.62', build: '2162', include_log: false)
          artifact_rel = artifact_path.sub("#{dir}/", '')
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Runtime remains stable')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['startup-wake-appearance-recovery'],
            runtime_state_results: [
              {
                id: 'resource_soak_growth',
                status: 'passed',
                evidence_types: %w[mini_runtime log state_receipt],
                evidence_paths: [artifact_rel],
                completed_scenarios: ['adaptive Mini resource check passed for this release build'],
                runtime_candidate: {
                  app_path: '/Applications/SaneExample.app',
                  app_version: '2.1.62',
                  app_build: '2162'
                }
              }
            ],
            screenshots: [],
            action_results: {
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Launch app'],
                output_assertions: ['Runtime remains stable'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'log', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'state_receipt', detail: 'Resource soak receipt', path: artifact_rel }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Launch app'],
                  outcome: 'Runtime remained stable',
                  artifacts: ['outputs/runtime.log', artifact_rel]
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected JSON-only durable resource soak evidence to block release proof')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'durable resource-soak log sibling is missing from evidence_paths')
        assert_includes(issues, 'durable resource-soak log sibling is missing')
      end
      true
    end

    test('customer UI contract rejects durable resource soak from a different candidate') do
      Dir.mktmpdir('customer-ui-resource-soak-wrong-candidate-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'project.yml'), <<~YAML)
          settings:
            base:
              MARKETING_VERSION: "2.1.62"
              CURRENT_PROJECT_VERSION: "2162"
        YAML
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            runtime_state_matrix:
              resource_soak_growth:
                why: Release candidates must prove resource growth from durable Mini soak artifacts.
                action_ids: [startup-wake-appearance-recovery]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                required_scenarios:
                  - adaptive Mini resource check passed for this release build
            actions:
              - id: startup-wake-appearance-recovery
                title: Startup wake recovery works
                surfaces: [Menu bar]
                steps: [Launch app]
                assertions: [Runtime remains stable]
                evidence: [runtime]
                required_proof_level: full_runtime_completion
                required_evidence_types: [mini_runtime, log, state_receipt]
                functional_state:
                  description: Default fixture
                  fixture_paths: [outputs/runtime.log]
                user_inputs: [Launch app]
                expected_outputs: [Runtime remains stable]
          YAML
        )

        report = nil
        Dir.chdir(dir) do
          artifact_path, log_path = write_resource_soak_pair(dir, version: '2.1.61', build: '2161')
          artifact_rel = artifact_path.sub("#{dir}/", '')
          log_rel = log_path.sub("#{dir}/", '')
          File.write(File.join(dir, 'outputs', 'runtime.log'), 'Runtime remains stable')
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: report[:manifest_sha256],
            source_fingerprint: report[:source_fingerprint],
            tested_action_ids: ['startup-wake-appearance-recovery'],
            runtime_state_results: [
              {
                id: 'resource_soak_growth',
                status: 'passed',
                evidence_types: %w[mini_runtime log state_receipt],
                evidence_paths: [artifact_rel, log_rel],
                completed_scenarios: ['adaptive Mini resource check passed for this release build'],
                runtime_candidate: {
                  app_path: '/Applications/SaneExample.app',
                  app_version: '2.1.62',
                  app_build: '2162'
                }
              }
            ],
            screenshots: [],
            action_results: {
              'startup-wake-appearance-recovery' => {
                status: 'passed',
                proof_level: 'full_runtime_completion',
                functional_state: { status: 'established', detail: 'Default fixture' },
                inputs: ['Launch app'],
                output_assertions: ['Runtime remains stable'],
                evidence: [
                  { type: 'mini_runtime', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'log', detail: 'Runtime log', path: 'outputs/runtime.log' },
                  { type: 'state_receipt', detail: 'Resource soak receipt', path: artifact_rel }
                ],
                workflow: {
                  runner: 'scripts/customer_ui_action_sweep.rb startup-wake-appearance-recovery',
                  steps_completed: ['Launch app'],
                  outcome: 'Runtime remained stable',
                  artifacts: ['outputs/runtime.log', artifact_rel, log_rel]
                }
              }
            }
          }
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected wrong-candidate durable resource soak evidence to block release proof')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'resource-soak artifact candidate version 2.1.61 does not match project MARKETING_VERSION 2.1.62')
        assert_includes(issues, 'resource-soak artifact candidate build 2161 does not match project CURRENT_PROJECT_VERSION 2162')
        assert_includes(issues, 'resource-soak artifact candidate app_version 2.1.61 does not match receipt runtime_candidate 2.1.62')
        assert_includes(issues, 'resource-soak artifact candidate app_build 2161 does not match receipt runtime_candidate 2162')
      end
      true
    end

    test('standard customer UI sweep dry-run finds the app workflow runner') do
      Dir.mktmpdir('customer-ui-sweep-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'scripts', 'customer_ui_action_sweep.rb'), "#!/usr/bin/env ruby\n")

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_sweep_report(dry_run: true)
        end

        assert(report[:ok], "expected dry-run sweep to pass: #{report[:issues].inspect}")
        assert_eq(report[:script_path], 'scripts/customer_ui_action_sweep.rb')
      end
      true
    end

    test('customer UI receipt host accepts full Mini hostname') do
      with_env('SANE_APPROVE_LOCAL_UI_ON_AIR' => nil) do
        assert(subject.send(:customer_ui_receipt_host_allowed?, 'mini'))
        assert(subject.send(:customer_ui_receipt_host_allowed?, 'stephans-mac-mini.local'))
        assert(subject.send(:customer_ui_receipt_host_allowed?, 'Stephans-Mac-Mini'))
        assert(!subject.send(:customer_ui_receipt_host_allowed?, 'stephansmac'))
        assert(!subject.send(:customer_ui_receipt_host_allowed?, 'macbook-air'))
      end
      true
    end

    test('customer UI Mini host detection is based on host identity, not username') do
      source = File.read(File.expand_path('customer_ui_contract.rb', __dir__), encoding: Encoding::UTF_8)

      assert_includes(source, "Socket.gethostname.to_s.downcase")
      assert_includes(source, "'/usr/sbin/scutil', '--get', 'ComputerName'")
      assert(!source.include?("ENV.fetch('USER', '').downcase == 'stephansmac'"),
             'customer UI proof must not accept the Air just because it uses the same account name')
      true
    end

    test('resource soak writes contract-compatible Mini runtime artifact') do
      artifact_path = '/tmp/sanebar_runtime_resource_soak.json'
      log_path = '/tmp/sanebar_runtime_resource_soak.log'
      FileUtils.rm_f([artifact_path, log_path])

      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [{
          pid: 12_345,
          app_path: "/Applications/#{app_name}.app",
          app_version: '1.2.3',
          app_build: '123',
          process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
        }]
      end
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
      end

      report = nil
      with_env('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '0') do
        report = subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--no-exit'])
      end

      assert(report[:ok], "expected resource soak to pass: #{report[:issues].inspect}")
      payload = JSON.parse(File.read(artifact_path))
      assert_eq(payload['status'], 'pass')
      assert_eq(payload['candidate']['app_version'], '1.2.3')
      assert_includes(payload['evidence_types'], 'mini_runtime')
      assert_includes(payload['evidence_paths'], log_path)
      assert_eq(payload['missing_sample_count'], 0)
      assert_eq(payload['physical_sample_count'], 1)
      assert_eq(payload['physical_missing_sample_count'], 0)
      assert_eq(payload['adaptive_status'], 'early_pass')
      assert_eq(payload['sample_span_seconds'], 0.0)
      assert_eq(payload['samples'].length, 1)
      assert_includes(payload['samples'].first.keys, 'elapsed_seconds')
      assert_eq(report[:sample_span_seconds], 0.0)
      assert_includes(payload['completed_scenarios'], 'adaptive Mini resource check passed for this release build')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
      FileUtils.rm_f(['/tmp/sanebar_runtime_resource_soak.json', '/tmp/sanebar_runtime_resource_soak.log'])
    end

    test('resource soak refuses symlinked artifact and log outputs') do
      Dir.mktmpdir('resource-soak-symlink-') do |dir|
        artifact_target = File.join(dir, 'artifact-target.json')
        log_target = File.join(dir, 'log-target.log')
        artifact_link = File.join(dir, 'resource.json')
        log_link = File.join(dir, 'resource.log')
        File.write(artifact_target, 'artifact-original')
        File.write(log_target, 'log-original')
        File.symlink(artifact_target, artifact_link)
        File.symlink(log_target, log_link)

        subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
          [{
            pid: 12_345,
            app_path: "/Applications/#{app_name}.app",
            app_version: '1.2.3',
            app_build: '123',
            process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
          }]
        end
        subject.define_singleton_method(:resource_soak_sample) do |_pid|
          { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
        end

        with_env(
          'SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '0',
          'SANEMASTER_RESOURCE_SOAK_ARTIFACT_PATH' => artifact_link,
          'SANEMASTER_RESOURCE_SOAK_LOG_PATH' => log_link
        ) do
          raised = false
          begin
            subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--no-exit'])
          rescue Errno::ELOOP, RuntimeError
            raised = true
          end
          assert(raised, 'expected symlinked resource soak outputs to be rejected')
        end

        assert_eq(File.read(artifact_target), 'artifact-original')
        assert_eq(File.read(log_target), 'log-original')
      end
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
    end

    test('resource soak refuses symlinked parent output directories') do
      Dir.mktmpdir('resource-soak-parent-symlink-') do |dir|
        real_dir = File.join(dir, 'real')
        link_dir = File.join(dir, 'link')
        FileUtils.mkdir_p(real_dir)
        File.symlink(real_dir, link_dir)

        subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
          [{
            pid: 12_345,
            app_path: "/Applications/#{app_name}.app",
            app_version: '1.2.3',
            app_build: '123',
            process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
          }]
        end
        subject.define_singleton_method(:resource_soak_sample) do |_pid|
          { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
        end

        with_env(
          'SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '0',
          'SANEMASTER_RESOURCE_SOAK_ARTIFACT_PATH' => File.join(link_dir, 'resource.json'),
          'SANEMASTER_RESOURCE_SOAK_LOG_PATH' => File.join(link_dir, 'resource.log')
        ) do
          raised = false
          begin
            subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--no-exit'])
          rescue RuntimeError
            raised = true
          end
          assert(raised, 'expected symlinked parent resource soak output directories to be rejected')
        end

        assert(!File.exist?(File.join(real_dir, 'resource.json')), 'resource artifact should not be written through symlink parent')
        assert(!File.exist?(File.join(real_dir, 'resource.log')), 'resource log should not be written through symlink parent')
      end
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
    end

    test('customer UI durable resource proof rejects symlinked parent directories') do
      Dir.mktmpdir('customer-ui-resource-parent-symlink-') do |dir|
        File.write(
          File.join(dir, 'project.yml'),
          "settings:\n  MARKETING_VERSION: \"2.1.74\"\n  CURRENT_PROJECT_VERSION: \"2174\"\n"
        )
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        real_dir = File.join(dir, 'real-customer-ui')
        FileUtils.mkdir_p(real_dir)
        File.symlink(real_dir, File.join(dir, 'outputs', 'customer-ui'))
        File.write(File.join(real_dir, 'resource-soak-sample.json'), JSON.pretty_generate(status: 'pass'))
        File.write(File.join(real_dir, 'resource-soak-sample.log'), "status=pass\n")

        Dir.chdir(dir) do
          receipt_row = {
            'evidence_paths' => [
              'outputs/customer-ui/resource-soak-sample.json',
              'outputs/customer-ui/resource-soak-sample.log'
            ]
          }
          issues = subject.send(
            :customer_ui_resource_soak_runtime_receipt_issues,
            'runtime_state_results resource_soak_growth',
            receipt_row
          )

          assert_includes(
            issues.join("\n"),
            'durable resource-soak evidence path(s) do not exist or are unsafe'
          )
        end
      end
      true
    end

    test('fixed resource soak does not satisfy adaptive release scenario') do
      artifact_path = '/tmp/sanebar_runtime_resource_soak_fixed.json'
      log_path = '/tmp/sanebar_runtime_resource_soak_fixed.log'
      adaptive_artifact_path = '/tmp/sanebar_runtime_resource_soak.json'
      FileUtils.rm_f([artifact_path, log_path, adaptive_artifact_path])

      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [{
          pid: 12_345,
          app_path: "/Applications/#{app_name}.app",
          app_version: '1.2.3',
          app_build: '123',
          process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
        }]
      end
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
      end

      report = nil
      report = subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--fixed', '--no-exit'])

      assert(report[:ok], "expected fixed resource soak to pass: #{report[:issues].inspect}")
      payload = JSON.parse(File.read(artifact_path))
      assert_eq(payload['adaptive'], false)
      assert_eq(payload['adaptive_status'], 'fixed')
      assert(!payload['completed_scenarios'].include?('adaptive Mini resource check passed for this release build'), 'fixed soak must not satisfy adaptive scenario')
      assert_includes(payload['completed_scenarios'], 'fixed-duration Mini resource check passed for this release build')
      assert(!File.exist?(adaptive_artifact_path), 'fixed diagnostic soak must not overwrite the adaptive release artifact')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
      FileUtils.rm_f([
                       '/tmp/sanebar_runtime_resource_soak_fixed.json',
                       '/tmp/sanebar_runtime_resource_soak_fixed.log',
                       '/tmp/sanebar_runtime_resource_soak.json',
                       '/tmp/sanebar_runtime_resource_soak.log'
                     ])
    end

    test('resource soak rejects stale installed candidate version before sampling') do
      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [{
          pid: 12_345,
          app_path: "/Applications/#{app_name}.app",
          app_version: '2.1.70',
          app_build: '2170',
          process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
        }]
      end
      sampled = false
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        sampled = true
        { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
      end

      Dir.mktmpdir('resource-soak-version-') do |dir|
        File.write(
          File.join(dir, 'project.yml'),
          <<~YAML
            settings:
              base:
                MARKETING_VERSION: "2.1.71"
                CURRENT_PROJECT_VERSION: "2171"
          YAML
        )
        Dir.chdir(dir) do
          report = subject.resource_soak_report(['--app', 'SaneBar', '--duration-seconds', '0', '--no-exit'])
          assert(!report[:ok], 'stale installed candidate should fail resource soak')
          assert_includes(report[:issues].join("\n"), 'Running candidate version 2.1.70 does not match project MARKETING_VERSION 2.1.71')
          assert_includes(report[:issues].join("\n"), 'Running candidate build 2170 does not match project CURRENT_PROJECT_VERSION 2171')
          assert(!sampled, 'resource soak should fail before sampling a stale installed candidate')
        end
      end
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
    end

    test('resource soak rejects process started before Applications executable replacement') do
      issues = subject.send(
        :resource_soak_candidate_version_issues,
        {
          pid: 12_345,
          app_version: '2.1.71',
          app_build: '2171',
          process_started_at: '2026-06-17T12:00:00Z',
          app_executable_mtime: '2026-06-17T12:05:00Z'
        }
      )

      assert_includes(issues.join("\n"), 'started before /Applications executable was last replaced')
      true
    end

    test('resource soak rejects multiple Applications candidates before sampling') do
      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [
          {
            pid: 11_111,
            app_path: "/Applications/#{app_name}.app",
            app_version: '1.2.3',
            app_build: '123',
            process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
          },
          {
            pid: 22_222,
            app_path: "/Applications/#{app_name}.app",
            app_version: '1.2.3',
            app_build: '123',
            process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
          }
        ]
      end
      sampled = false
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        sampled = true
        { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
      end

      report = subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--no-exit'])

      assert(!report[:ok], 'multiple running app candidates should fail resource soak')
      assert_includes(report[:issues].join("\n"), 'Multiple SaneExample processes are running from /Applications: 11111, 22222')
      assert(!sampled, 'resource soak should fail before sampling ambiguous candidates')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
    end

    test('resource soak fails when process samples disappear mid-run') do
      artifact_path = '/tmp/sanebar_runtime_resource_soak.json'
      log_path = '/tmp/sanebar_runtime_resource_soak.log'
      FileUtils.rm_f([artifact_path, log_path])

      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [{
          pid: 12_345,
          app_path: "/Applications/#{app_name}.app",
          app_version: '1.2.3',
          app_build: '123',
          process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
        }]
      end
      sample_calls = 0
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        sample_calls += 1
        if sample_calls > 1
          nil
        else
          { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
        end
      end

      report = nil
      with_env('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '1') do
        report = subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '1', '--interval-seconds', '1', '--no-exit'])
      end

      assert(!report[:ok], 'expected missing samples to fail resource soak')
      assert_includes(report[:issues].join("\n"), 'missing process samples: 1')
      payload = JSON.parse(File.read(artifact_path))
      assert_eq(payload['status'], 'fail')
      assert_eq(payload['missing_sample_count'], 1)
      assert_eq(payload['samples'].length, 1)
      assert_includes(File.read(log_path), 'sample_missing')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
      FileUtils.rm_f(['/tmp/sanebar_runtime_resource_soak.json', '/tmp/sanebar_runtime_resource_soak.log'])
    end

    test('resource soak fails when collected sample span is too short') do
      issues = subject.send(
        :resource_soak_issues,
        {
          sample_count: 2,
          avg_cpu: 0.1,
          peak_cpu: 0.2,
          avg_rss_mb: 80.0,
          peak_rss_mb: 81.0,
          rss_growth_mb: 1.0,
          peak_physical_footprint_mb: 60.0,
          physical_footprint_growth_mb: 1.0,
          sample_span_seconds: 20.0
        },
        {
          duration_seconds: 600,
          min_duration_seconds: 600,
          interval_seconds: 10,
          cpu_avg_max: 5,
          rss_peak_mb_max: 512,
          rss_growth_mb_max: 40,
          physical_peak_mb_max: 512,
          physical_growth_mb_max: 40
        },
        missing_sample_count: 0
      )

      assert_includes(issues.join("\n"), 'sampled span 20.0s is shorter than required 589.0s')
      true
    end

    test('resource soak adaptive state passes stable candidate at minimum duration') do
      options = subject.send(:parse_resource_soak_args, ['--app', 'SaneExample', '--duration-seconds', '600', '--no-exit'])
      samples = (0..48).map do |index|
        {
          sampled_at: '2026-06-18T01:00:00Z',
          elapsed_seconds: index * 5.0,
          cpu: index.even? ? 0.2 : 0.1,
          rss_mb: 80.0 + (index * 0.01),
          physical_footprint_mb: 60.0 + (index * 0.005)
        }
      end
      metrics = subject.send(:resource_soak_metrics, samples)
      state = subject.send(
        :resource_soak_adaptive_state,
        metrics,
        options,
        elapsed_seconds: 240.0,
        missing_sample_count: 0,
        fail_streak: 0
      )

      assert_eq(state[:status], 'early_pass')
      assert_includes(state[:reasons].join("\n"), 'stable resource profile')
      assert(metrics[:rss_slope_mb_per_min].to_f < 1.0, "expected low RSS slope, got #{metrics[:rss_slope_mb_per_min]}")
      true
    end

    test('resource soak adaptive state rejects sparse physical footprint sampling') do
      options = subject.send(:parse_resource_soak_args, ['--app', 'SaneExample', '--duration-seconds', '600', '--no-exit'])
      samples = [
        {
          sampled_at: '2026-06-18T01:00:00Z',
          elapsed_seconds: 0.0,
          cpu: 0.2,
          rss_mb: 80.0,
          physical_footprint_mb: 60.0
        },
        {
          sampled_at: '2026-06-18T01:00:05Z',
          elapsed_seconds: 5.0,
          cpu: 0.1,
          rss_mb: 80.2,
          physical_footprint_mb: nil
        }
      ]
      metrics = subject.send(:resource_soak_metrics, samples, options)
      state = subject.send(
        :resource_soak_adaptive_state,
        metrics,
        options,
        elapsed_seconds: 5.0,
        missing_sample_count: 0,
        fail_streak: 0
      )

      assert_eq(metrics[:physical_sample_count], 1)
      assert_eq(metrics[:physical_missing_sample_count], 1)
      assert_eq(state[:status], 'fail')
      assert_includes(state[:issues].join("\n"), 'physical footprint missing for 1 sample(s)')
      true
    end

    test('resource soak adaptive state fails after sustained rolling CPU threshold breach') do
      options = subject.send(:parse_resource_soak_args, ['--app', 'SaneExample', '--duration-seconds', '600', '--no-exit'])
      samples = (0..8).map do |index|
        {
          sampled_at: '2026-06-18T01:00:00Z',
          elapsed_seconds: index * 5.0,
          cpu: 10.0,
          rss_mb: 80.0,
          physical_footprint_mb: 60.0
        }
      end
      metrics = subject.send(:resource_soak_metrics, samples)
      first = subject.send(:resource_soak_adaptive_state, metrics, options, elapsed_seconds: 40.0, missing_sample_count: 0, fail_streak: 0)
      second = subject.send(:resource_soak_adaptive_state, metrics, options, elapsed_seconds: 45.0, missing_sample_count: 0, fail_streak: first[:fail_streak])
      third = subject.send(:resource_soak_adaptive_state, metrics, options, elapsed_seconds: 50.0, missing_sample_count: 0, fail_streak: second[:fail_streak])

      assert_eq(first[:status], 'running')
      assert_eq(second[:status], 'running')
      assert_eq(third[:status], 'fail')
      assert_includes(third[:issues].join("\n"), 'rollingAvgCpu60s 10.0% > 8.0%')
      true
    end

    test('resource soak adaptive state waits for minimum duration before memory trend failure') do
      options = subject.send(:parse_resource_soak_args, ['--app', 'SaneExample', '--duration-seconds', '600', '--no-exit'])
      samples = (0..7).map do |index|
        {
          sampled_at: '2026-06-18T01:00:00Z',
          elapsed_seconds: index * 5.0,
          cpu: 0.0,
          rss_mb: index < 4 ? 80.0 : 120.0,
          physical_footprint_mb: index < 4 ? 50.0 : 75.0
        }
      end
      metrics = subject.send(:resource_soak_metrics, samples, options)
      state = subject.send(
        :resource_soak_adaptive_state,
        metrics,
        options,
        elapsed_seconds: 35.0,
        missing_sample_count: 0,
        fail_streak: 2
      )

      assert_eq(state[:status], 'running')
      assert_eq(state[:fail_streak], 0)
      assert(metrics[:rss_slope_mb_per_min].to_f > options[:adaptive_rss_slope_mb_per_min_max])
      assert(metrics[:physical_footprint_slope_mb_per_min].to_f > options[:adaptive_physical_slope_mb_per_min_max])
      true
    end

    test('resource soak progress is suppressed for json output') do
      artifact_path = '/tmp/sanebar_runtime_resource_soak.json'
      log_path = '/tmp/sanebar_runtime_resource_soak.log'
      FileUtils.rm_f([artifact_path, log_path])

      subject.define_singleton_method(:resource_soak_running_app_candidates) do |app_name|
        [{
          pid: 12_345,
          app_path: "/Applications/#{app_name}.app",
          app_version: '1.2.3',
          app_build: '123',
          process_path: "/Applications/#{app_name}.app/Contents/MacOS/#{app_name}"
        }]
      end
      subject.define_singleton_method(:resource_soak_sample) do |_pid|
        { cpu: 0.2, rss_mb: 80.0, physical_footprint_mb: 60.0 }
      end

      output = nil
      with_env('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '0') do
        output = capture_stdout do
          report = subject.resource_soak_report(['--app', 'SaneExample', '--duration-seconds', '0', '--json'])
          assert(report[:ok], "expected json resource soak to pass: #{report[:issues].inspect}")
        end
      end

      assert(!output.include?('resource soak progress'), 'json resource soak must not emit progress lines')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_running_app_candidates) rescue nil
      subject.singleton_class.remove_method(:resource_soak_sample) rescue nil
      FileUtils.rm_f(['/tmp/sanebar_runtime_resource_soak.json', '/tmp/sanebar_runtime_resource_soak.log'])
    end

    test('resource soak parses spaced macOS physical footprint units') do
      footprint_output = <<~TEXT
        Auxiliary data:
            phys_footprint: 79 MB
            phys_footprint_peak: 84 MB
      TEXT

      assert_eq(subject.send(:resource_soak_parse_footprint_mb, footprint_output), 79.0)
      true
    end

    test('customer UI sweep launches visible target before cleanup and visual precheck') do
      Dir.mktmpdir('customer-ui-launch-target-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'scripts', 'customer_ui_action_sweep.rb'), "#!/usr/bin/env ruby\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: visible-flow
                title: Visible Flow
                surfaces: ["Main window"]
                steps: ["Open window"]
                assertions: ["Window is visible"]
                evidence: ["Mini screenshot"]
                release_required: true
                required_proof_level: runtime_visual
                required_evidence_types: [visual_smoke]
                historical_failure_classes: [window_not_launched]
                functional_state:
                  description: Ready
                  not_required_reason: No state needed
          YAML
        )

        calls = []
        subject.define_singleton_method(:customer_ui_mini_host?) { true }
        subject.define_singleton_method(:customer_ui_cleanup_before_sweep) do |app|
          calls << [:cleanup, app]
          []
        end
        subject.define_singleton_method(:customer_ui_visual_precheck) do |app|
          calls << [:visual_precheck, app]
          { ok: true, issues: [] }
        end
        subject.define_singleton_method(:customer_ui_contract_report) do |config: nil, strict_visual: false|
          calls << [:contract, config && config['name'], strict_visual]
          { ok: true, issues: [] }
        end
        subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
          calls << cmd
          [cmd.join(' '), Struct.new(:success?).new(true)]
        end

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_sweep_report(dry_run: false)
        end

        assert(report[:ok], "expected customer UI sweep to pass: #{report.inspect}")
        assert_eq(calls[0], ['./scripts/SaneMaster.rb', 'launch'])
        assert_eq(calls[1], [:cleanup, 'SaneExample'])
        assert_eq(calls[2], [:visual_precheck, 'SaneExample'])
        assert_eq(calls[3], [RbConfig.ruby, 'scripts/customer_ui_action_sweep.rb'])
      end
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_mini_host?) rescue nil
      subject.singleton_class.remove_method(:customer_ui_cleanup_before_sweep) rescue nil
      subject.singleton_class.remove_method(:customer_ui_visual_precheck) rescue nil
      subject.singleton_class.remove_method(:customer_ui_contract_report) rescue nil
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end

    test('SaneBar customer UI sweep auto-launches the release app when preflight cleanup stopped it') do
      Dir.mktmpdir('customer-ui-sanebar-autolaunch-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneBar\n")
        File.write(File.join(dir, 'scripts', 'customer_ui_action_sweep.rb'), "#!/usr/bin/env ruby\n")
        File.write(File.join(dir, 'scripts', 'qa.rb'), "#!/usr/bin/env ruby\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            actions:
              - id: appearance-action
                title: Appearance action
                release_required: true
                required_proof_level: runtime_visual
                evidence:
                  - type: screenshot
                    path: outputs/appearance.png
                functional_state:
                  description: Ready to capture
                  not_required_reason: No state needed
          YAML
        )

        launched = false
        calls = []
        subject.define_singleton_method(:customer_ui_mini_host?) { true }
        subject.define_singleton_method(:resource_soak_running_app_candidate) do |_app|
          launched ? { pid: 123, app_path: '/Applications/SaneBar.app' } : nil
        end
        subject.define_singleton_method(:customer_ui_cleanup_before_sweep) do |app|
          calls << [:cleanup, app]
          []
        end
        subject.define_singleton_method(:customer_ui_visual_precheck) do |app|
          calls << [:visual_precheck, app]
          { ok: true, issues: [] }
        end
        subject.define_singleton_method(:customer_ui_contract_report) do |config: nil, strict_visual: false|
          calls << [:contract, config && config['name'], strict_visual]
          { ok: true, issues: [] }
        end
        subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
          calls << cmd
          launched = true if cmd == ['./scripts/SaneMaster.rb', 'test_mode', '--release', '--no-logs']
          [cmd.join(' '), Struct.new(:success?).new(true)]
        end

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_sweep_report(dry_run: false)
        end

        assert(report[:ok], "expected customer UI sweep to pass after auto-launch: #{report.inspect}")
        assert_includes(calls, ['./scripts/SaneMaster.rb', 'test_mode', '--release', '--no-logs'])
        assert(calls.any? do |call|
          call[0].is_a?(Hash) &&
            call[0]['SANEPROCESS_RUNTIME_SMOKE_ONLY'] == '1' &&
            call[0]['SANEBAR_RUN_RUNTIME_SMOKE'] == '1' &&
            call[0]['SANEBAR_STARTUP_PROBE_RESOURCE_SOAK_AFTER_155'] == '0' &&
            !call[0].key?('SANEPROCESS_RELEASE_PREFLIGHT') &&
            !call[0].key?('SANEBAR_RELEASE_PREFLIGHT') &&
            call[1] == RbConfig.ruby &&
            ['Scripts/qa.rb', 'scripts/qa.rb'].include?(call[2])
        end, "expected SaneBar customer UI sweep to refresh runtime smoke before workflow: #{calls.inspect}")
        resource_soak_index = calls.index do |call|
          call[0].is_a?(Hash) &&
            call[0]['SANEMASTER_RESOURCE_SOAK_MIN_SECONDS'] == '240' &&
            call[1, 4] == ['./scripts/SaneMaster.rb', 'resource_soak', '--adaptive', '--duration-seconds']
        end
        assert(resource_soak_index, "expected SaneBar customer UI sweep to refresh resource soak before workflow: #{calls.inspect}")
        cleanup_calls = calls.select { |call| call == [:cleanup, 'SaneBar'] }
        assert_eq(cleanup_calls.length, 2, "expected SaneBar customer UI sweep to clean before and after runtime smoke: #{calls.inspect}")
        last_cleanup_index = calls.rindex([:cleanup, 'SaneBar'])
        visual_precheck_index = calls.index([:visual_precheck, 'SaneBar'])
        assert(last_cleanup_index && visual_precheck_index && last_cleanup_index < visual_precheck_index, "expected post-runtime cleanup before visual precheck: #{calls.inspect}")
        action_index = calls.index([RbConfig.ruby, 'scripts/customer_ui_action_sweep.rb'])
        assert(action_index, "expected SaneBar customer UI sweep to run action workflow: #{calls.inspect}")
        assert(resource_soak_index < action_index, "expected resource soak before action workflow: #{calls.inspect}")
      end
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_mini_host?) rescue nil
      subject.singleton_class.remove_method(:resource_soak_running_app_candidate) rescue nil
      subject.singleton_class.remove_method(:customer_ui_cleanup_before_sweep) rescue nil
      subject.singleton_class.remove_method(:customer_ui_visual_precheck) rescue nil
      subject.singleton_class.remove_method(:customer_ui_contract_report) rescue nil
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end

    test('App Store strict visual mode requires screenshot evidence for every release action') do
      Dir.mktmpdir('customer-ui-strict-visual-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        FileUtils.mkdir_p(File.join(dir, 'SaneExample'))
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'SaneExample', 'ContentView.swift'), 'struct ContentView {}')
        manifest_path = File.join(dir, 'Tests', 'CustomerUIActions.yml')
        File.write(
          manifest_path,
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: widget-lock-state
                title: Widget lock state works
                surfaces: [Widget]
                steps: [Render locked widget]
                assertions: [Upgrade route is visible]
                evidence: [fixture]
                required_proof_level: fixture_completion
                required_evidence_types: [fixture]
                historical_failure_classes: [pro_basic_gate_drift]
                functional_state:
                  description: Basic fixture
                  fixture_paths: [Tests/Fixtures/widget.json]
                user_inputs: [Render locked widget]
                expected_outputs: [Upgrade route is visible]
          YAML
        )
        File.write(File.join(dir, 'outputs', 'widget.json'), '{"locked":true}')

        strict_report = nil
        relaxed_report = nil
        Dir.chdir(dir) do
          first_report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          receipt = {
            app: 'SaneExample',
            status: 'passed',
            host: 'mini',
            generated_at: Time.now.utc.iso8601,
            manifest_sha256: first_report[:manifest_sha256],
            source_fingerprint: first_report[:source_fingerprint],
            tested_action_ids: ['widget-lock-state'],
            screenshots: ['outputs/widget.png'],
            action_results: {
              'widget-lock-state' => {
                status: 'passed',
                proof_level: 'fixture_completion',
                functional_state: { status: 'established', detail: 'Basic fixture' },
                inputs: ['Render locked widget'],
                output_assertions: ['Upgrade route is visible'],
                evidence: [
                  { type: 'fixture', detail: 'Rendered locked widget fixture', path: 'outputs/widget.json' }
                ]
              }
            }
          }
          write_test_png(File.join(dir, 'outputs', 'widget.png'))
          File.write(File.join(dir, 'outputs', 'customer_ui_action_receipt.json'), JSON.pretty_generate(receipt))
          relaxed_report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' })
          strict_report = subject.customer_ui_contract_report(config: { 'name' => 'SaneExample' }, strict_visual: true)
        end

        assert(relaxed_report[:ok], "expected non-strict contract to pass: #{relaxed_report[:issues].inspect}")
        assert(!strict_report[:ok], 'expected strict App Store visual contract to block missing action screenshot')
        assert_includes(strict_report[:issues].join("\n"), 'App Store strict visual gate requires screenshot/visual evidence')
      end
      true
    end

    test('customer UI sweep blocks runtime visual work when Mini screenshot precheck is dirty') do
      Dir.mktmpdir('customer-ui-visual-precheck-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'scripts', 'customer_ui_action_sweep.rb'), "#!/usr/bin/env ruby\n")
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: capture-flow
                title: Capture Flow
                surfaces: ["Main menu"]
                steps: ["Click Capture"]
                assertions: ["Picker appears"]
                evidence: ["Mini screenshot"]
                release_required: true
                required_proof_level: runtime_visual
                required_evidence_types: [visual_smoke]
                historical_failure_classes: [permission_recovery_dead_end]
                functional_state:
                  description: Ready to capture
                  not_required_reason: No state needed
          YAML
        )

        subject.define_singleton_method(:customer_ui_mini_host?) { true }
        subject.define_singleton_method(:customer_ui_cleanup_before_sweep) { |_app| [] }
        subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
          if cmd == ['./scripts/SaneMaster.rb', 'launch']
            ['launched', Struct.new(:success?).new(true)]
          elsif cmd.include?('visual_smoke')
            [
              '{"ok":false,"reason":"Mini visual workspace is dirty: Terminal has 1 open window(s)","cleanliness":{"issues":["Terminal has 1 open window(s)"]},"artifacts":[]}',
              Struct.new(:success?).new(false)
            ]
          else
            raise "sweep runner must not run after failed visual precheck: #{cmd.inspect}"
          end
        end

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_sweep_report(dry_run: false)
        end

        assert(!report[:ok], 'expected dirty visual precheck to block the customer UI sweep')
        assert_includes(report[:issues].join("\n"), 'Mini visual precheck failed before customer UI sweep')
        assert_includes(report[:issues].join("\n"), 'Terminal has 1 open window')
      end
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_mini_host?) rescue nil
      subject.singleton_class.remove_method(:customer_ui_cleanup_before_sweep) rescue nil
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end

    test('customer UI visual precheck parses JSON after local routing warnings') do
      parsed = subject.send(
        :customer_ui_parse_json_object,
        "⚠️  Mini-first bypass active (--local or SANEMASTER_FORCE_LOCAL=1); running locally.\n{\"ok\":true,\"artifacts\":[\"outputs/visual.png\"]}\n"
      )

      assert_eq(parsed['ok'], true)
      assert_eq(parsed['artifacts'], ['outputs/visual.png'])
      true
    end

    test('customer UI sweep command runner uses bounded process capture') do
      source = File.read(File.join(__dir__, 'customer_ui_contract.rb'))

      assert_includes(source, 'CUSTOMER_UI_COMMAND_TIMEOUT_SECONDS = 1800.0')
      assert_includes(source, 'Open3.popen2e(*command, pgroup: true)')
      assert_includes(source, 'wait_thr.join(0.2)')
      assert_includes(source, 'customer_ui_descendant_pids(wait_thr.pid)')
      assert_includes(source, "Process.kill('TERM', pid)")
      assert_includes(source, "Process.kill('KILL', pid)")
      assert_includes(source, 'customer_ui_drain_command_output(stdout_err, output')
      assert_includes(source, 'customer_ui_stream_command_output(chunk)')
      assert_includes(source, 'customer_ui_should_emit_heartbeat?')
      assert(!source.include?("def customer_ui_run_command(*command)\n      Open3.capture2e(*command)\n    end"))
      true
    end

    test('customer UI sweep command runner streams child progress to stderr') do
      runner = Object.new
      runner.extend(SaneMasterModules::CustomerUIContract)
      output = nil
      status = nil
      stderr = capture_stderr do
        with_env(
          'SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT' => '2',
          'SANEMASTER_CUSTOMER_UI_STREAM_PROGRESS' => '1'
        ) do
          output, status = runner.send(
            :customer_ui_run_command,
            RbConfig.ruby,
            '-e',
            'STDOUT.sync = true; puts "child progress line"'
          )
        end
      end

      assert(status.success?, 'expected child command to pass')
      assert_includes(output, 'child progress line')
      assert_includes(stderr, 'child progress line')
      true
    end

    test('customer UI live app logs are receipt-only by default') do
      runner = Object.new
      runner.extend(SaneMasterModules::CustomerUIContract)
      stderr = capture_stderr do
        with_env(
          'SANEMASTER_CUSTOMER_UI_STREAM_PROGRESS' => '1',
          'SANEMASTER_CUSTOMER_UI_LIVE_LOG_STDOUT' => nil
        ) do
          runner.send(
            :customer_ui_stream_live_log_chunk,
            "2026-06-20 I SaneBar[1:1] [com.sanebar.app:MenuBarManager] noisy live line\n"
          )
        end
      end

      assert_eq(stderr, '')
      true
    end

    test('customer UI sweep command runner emits quiet heartbeat before timeout') do
      runner = Object.new
      runner.extend(SaneMasterModules::CustomerUIContract)
      output = nil
      status = nil
      stderr = capture_stderr do
        with_env(
          'SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT' => '2',
          'SANEMASTER_CUSTOMER_UI_PROGRESS_HEARTBEAT_SECONDS' => '0.1',
          'SANEMASTER_CUSTOMER_UI_STREAM_PROGRESS' => '1'
        ) do
          output, status = runner.send(:customer_ui_run_command, RbConfig.ruby, '-e', 'sleep 0.35')
        end
      end

      assert(status.success?, "expected quiet child to finish successfully, output=#{output.inspect}")
      assert_includes(stderr, 'customer UI command still running')
      true
    end

    test('customer UI sweep command runner refreshes heartbeat while child is noisy') do
      runner_class = Class.new do
        include SaneMasterModules::CustomerUIContract

        attr_reader :heartbeats

        def initialize
          @heartbeats = []
        end

        def customer_ui_write_command_heartbeat(path, **payload)
          @heartbeats << payload.merge(elapsed_seconds: (Time.now - payload[:started_at]).round(1))
          super
        end
      end

      Dir.mktmpdir('customer-ui-noisy-heartbeat-') do |dir|
        Dir.chdir(dir) do
          runner = runner_class.new
          script = 'STDOUT.sync = true; deadline = Time.now + 0.4; while Time.now < deadline; puts "tick"; sleep 0.03; end'
          with_env(
            'SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT' => '2',
            'SANEMASTER_CUSTOMER_UI_PROGRESS_HEARTBEAT_SECONDS' => '0.1',
            'SANEMASTER_CUSTOMER_UI_STREAM_PROGRESS' => '0'
          ) do
            _output, status = runner.send(:customer_ui_run_command, RbConfig.ruby, '-e', script)
            assert(status.success?, 'expected noisy child to finish successfully')
          end

          running_heartbeats = runner.heartbeats.select { |payload| payload[:status] == 'running' && payload[:note] == 'heartbeat' }
          assert(running_heartbeats.any?, "expected running heartbeat refreshes, got #{runner.heartbeats.inspect}")
          assert(running_heartbeats.any? { |payload| payload[:elapsed_seconds].positive? }, 'expected refreshed heartbeat to carry elapsed time')
        end
      end
      true
    end

    test('customer UI sweep command runner times out stuck children') do
      runner = Object.new
      runner.extend(SaneMasterModules::CustomerUIContract)
      with_env('SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT' => '0.3') do
        started_at = Time.now
        output, status = runner.send(:customer_ui_run_command, RbConfig.ruby, '-e', 'sleep 5')
        elapsed = Time.now - started_at

        assert(!status.success?, 'expected timed out customer UI child to fail')
        assert(elapsed < 3.0, "expected timeout to return quickly, elapsed=#{elapsed}")
        assert_includes(output, 'customer UI command timeout')
      end
      true
    end

    test('customer UI sweep command runner kills spawned descendants on timeout') do
      runner = Object.new
      runner.extend(SaneMasterModules::CustomerUIContract)
      Dir.mktmpdir('customer-ui-timeout-descendant-') do |dir|
        child_pid_path = File.join(dir, 'child.pid')
        script = <<~RUBY
          child = Process.spawn(#{RbConfig.ruby.inspect}, '-e', 'sleep 30')
          File.write(#{child_pid_path.inspect}, child.to_s)
          sleep 30
        RUBY

        with_env('SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT' => '0.3') do
          _output, status = runner.send(:customer_ui_run_command, RbConfig.ruby, '-e', script)
          assert(!status.success?, 'expected timed out customer UI child to fail')
        end

        child_pid = File.read(child_pid_path).to_i
        sleep 0.5
        child_alive = begin
          Process.kill(0, child_pid)
          true
        rescue Errno::ESRCH
          false
        end
        assert(!child_alive, "expected timeout cleanup to kill descendant pid #{child_pid}")
      ensure
        begin
          Process.kill('KILL', child_pid) if child_pid&.positive?
        rescue Errno::ESRCH, Errno::EINVAL
          nil
        end
      end
      true
    end

    test('customer UI sweep blocks app-owned install prompts before running the workflow') do
      Dir.mktmpdir('customer-ui-move-prompt-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'scripts', 'customer_ui_action_sweep.rb'), "#!/usr/bin/env ruby\n")

        subject.define_singleton_method(:customer_ui_mini_host?) { true }
        subject.define_singleton_method(:customer_ui_cleanup_before_sweep) do |_app|
          ['Mini visual workspace cleanup failed before customer UI sweep: SaneExample has an unresolved app install/move prompt']
        end
        subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
          raise "sweep runner must not run while install prompt is visible: #{cmd.inspect}"
        end

        report = nil
        Dir.chdir(dir) do
          report = subject.customer_ui_sweep_report(dry_run: false)
        end

        assert(!report[:ok], 'expected app install/move prompt to block the customer UI sweep')
        assert_includes(report[:issues].join("\n"), 'unresolved app install/move prompt')
      end
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_mini_host?) rescue nil
      subject.singleton_class.remove_method(:customer_ui_cleanup_before_sweep) rescue nil
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end

    test('Mini visual workspace guard allows explicit windowless precheck while preserving prompt blockers') do
      guard = File.expand_path('../mini/mini-visual-workspace-guard.sh', __dir__)
      source = File.read(guard)

      assert_includes(source, 'WINDOWLESS_TARGET_APPS="SaneBar"')
      assert_includes(source, '--allow-windowless-target')
      assert_includes(source, 'ALLOW_WINDOWLESS_TARGET=true')
      assert_includes(source, 'windowless_target=false')
      assert_includes(source, 'if $ALLOW_WINDOWLESS_TARGET; then')
      assert_includes(source, 'if ! $windowless_target; then')
      assert_includes(source, '[ "$target_windows" != "0" ]')
      assert_includes(source, 'if ! $windowless_target || [ "$target_windows" != "0" ]; then')
      assert_includes(source, 'target_app_prompt_blockers_timeout 3')
      assert_includes(source, 'has an unresolved app install/move prompt')
      true
    end

    test('customer UI cleanup uses windowless target mode while still running the visual guard') do
      calls = []
      subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
        calls << cmd
        ['{"ok":true}', Struct.new(:success?).new(true)]
      end

      issues = subject.send(:customer_ui_cleanup_before_sweep, 'SaneClip')

      assert(issues.empty?, "expected cleanup to pass, got #{issues.inspect}")
      command = calls.fetch(0)
      assert_includes(command, '--cleanup')
      assert_includes(command, '--app')
      assert_includes(command, 'SaneClip')
      assert_includes(command, '--allow-windowless-target')
      assert_includes(command, '--json')
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end

    test('customer UI visual precheck allows supplemental menu bar image when full screenshot is usable') do
      Dir.mktmpdir('customer-ui-visual-precheck-menu-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Tests'))
        screen = File.join(dir, 'screen.png')
        menu = File.join(dir, 'menu.png')
        write_test_png(screen, width: 1920, height: 1080)
        write_test_png(menu, width: 1920, height: 30)
        File.write(
          File.join(dir, 'Tests', 'CustomerUIActions.yml'),
          <<~YAML
            version: 1
            app: SaneExample
            actions:
              - id: capture-flow
                title: Capture Flow
                surfaces: ["Main menu"]
                steps: ["Click Capture"]
                assertions: ["Picker appears"]
                evidence: ["Mini screenshot"]
                release_required: true
                required_proof_level: runtime_visual
                required_evidence_types: [visual_smoke]
                functional_state:
                  description: Ready to capture
                  not_required_reason: No state needed
          YAML
        )

        subject.define_singleton_method(:customer_ui_run_command) do |*cmd|
          if cmd.include?('visual_smoke')
            [
              JSON.generate({ ok: true, artifacts: [screen, menu] }),
              Struct.new(:success?).new(true)
            ]
          else
            raise "unexpected command: #{cmd.inspect}"
          end
        end

        report = nil
        Dir.chdir(dir) do
          report = subject.send(:customer_ui_visual_precheck, 'SaneExample')
        end

        assert(report[:ok], "expected full screenshot to satisfy visual precheck, got #{report.inspect}")
      end
      true
    ensure
      subject.singleton_class.remove_method(:customer_ui_run_command) rescue nil
    end
  end

  test_category('Launch readiness') do
    test('passes for an already-launched app with fresh green preflight proof') do
      Dir.mktmpdir('launch-readiness-pass-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: meaningfully_launched
              rule: Keep monitoring opportunities; do not burn another major launch without a new product story.
              scheduled:
                - cadence: weekly
                  channel: Opportunity monitoring
                  action: Scan high-fit opportunities and only reply with builder disclosure.
                  gate: No duplicate launch post.
                  success_metric: 0-2 high-fit replies or a recorded no-go.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: ready_to_schedule
              audience: Mac users
              problem: Crowded workflows
              solution: Native utility
              primary_story: Clear product story
              pricing_proof: Website and checkout verified
              privacy_proof: Privacy page verified
              proof_assets:
                - type: screenshot
                  status: current
                  path: docs/images/hero.png
              channel_plan:
                product_hunt: scheduled
                hacker_news: fallback
              go_no_go:
                rule: Fresh proof required.
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.utc.iso8601,
            projectName: 'SaneExample',
            status: 'passed',
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected launch readiness to pass: #{report.inspect}")
      end
      true
    end

    test('already-launched apps treat weak relaunch blockers and stale release proof as warnings') do
      Dir.mktmpdir('launch-readiness-already-launched-advisory-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: meaningfully_launched
              rule: Real launch already happened; only run targeted support-surface ops unless a new story exists.
              scheduled:
                - cadence: weekly
                  channel: Opportunity monitoring
                  action: Scan high-fit opportunity threads.
                  gate: No duplicate relaunch posts.
                  success_metric: 0-2 high-fit replies or a recorded no-go.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: ready_to_schedule
              audience: Mac users
              problem: Crowded workflows
              solution: Native utility
              primary_story: Clear product story
              pricing_proof: Website and checkout verified
              privacy_proof: Privacy page verified
              proof_assets:
                - type: screenshot
                  status: current
                  path: docs/images/hero.png
              channel_plan:
                product_hunt: no_go_until_major_release_story
              go_no_go:
                rule: Major relaunch only with a real new story.
              weak_launch_blockers:
                - Already launched on Product Hunt/HN; do not relaunch without a new product story.
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: (Time.now.utc - (9 * 86_400)).iso8601,
            projectName: 'SaneExample',
            status: 'failed',
            issueCount: 2,
            warningCount: 1,
            issues: ['Tests failing'],
            warnings: ['Pending customer emails']
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(report[:ok], "expected already-launched support lane to stay green: #{report.inspect}")
        warnings = report[:warnings].join("\n")
        assert_includes(warnings, 'Outstanding weak-launch blocker: Already launched on Product Hunt/HN; do not relaunch without a new product story. (major-launch advisory only for already-launched product)')
        assert_includes(warnings, 'Latest release_preflight proof is stale')
        assert_includes(warnings, 'Latest release_preflight is not green: failed (2 issue(s))')
      end
      true
    end

    test('release status snapshots include source fingerprint for freshness checks') do
      Dir.mktmpdir('release-status-source-fingerprint-') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'project.yml'), "name: SaneExample\n")
        system('git', '-C', dir, 'init', '-q')
        system('git', '-C', dir, 'add', '.')
        system('git', '-C', dir, 'commit', '-q', '-m', 'initial')

        status_path = File.join(dir, 'outputs', 'release_preflight_status.json')
        Dir.chdir(dir) do
          subject.write_release_status_snapshot(
            path: status_path,
            status: 'passed',
            issues: [],
            warnings: []
          )
        end

        payload = JSON.parse(File.read(status_path))
        fingerprint = payload['sourceFingerprint'].to_s
        assert_eq(fingerprint.length, 64)
        assert_match(fingerprint, /\A[0-9a-f]{64}\z/)
      end
      true
    end

    test('release status source freshness includes download redirects') do
      Dir.mktmpdir('release-status-redirect-fingerprint-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'docs'))
        FileUtils.mkdir_p(File.join(dir, 'website'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(File.join(dir, 'project.yml'), "name: SaneExample\n")
        File.write(File.join(dir, 'docs', '_redirects'), "/download /updates/SaneExample-1.0.0.zip 302\n")
        File.write(File.join(dir, 'website', '_redirects'), "/download /updates/SaneExample-1.0.0.zip 302\n")
        system('git', '-C', dir, 'init', '-q')
        system('git', '-C', dir, 'add', '.')
        system('git', '-C', dir, 'commit', '-q', '-m', 'initial')

        files = subject.send(:release_status_source_files, dir)
        assert_includes(files, 'docs/_redirects')
        assert_includes(files, 'website/_redirects')
        assert(subject.send(:release_status_source_file?, dir, 'docs/_redirects'))
        assert(subject.send(:release_status_source_file?, dir, 'website/_redirects'))
      end
      true
    end

    test('blocks unresolved weak-launch package blockers') do
      Dir.mktmpdir('launch-readiness-package-blockers-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: launch_candidate
              rule: No weak launch.
              scheduled:
                - date: "2026-05-20"
                  time: "10:00"
                  channel: Product Hunt
                  action: Launch only if ready.
                  gate: Exact user approval required.
                  success_metric: URL recorded.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: package_defined_assets_needed
              audience: Mac users
              problem: Problem
              solution: Solution
              primary_story: Story
              pricing_proof: Checked
              privacy_proof: Checked
              proof_assets:
                - type: video
                  status: needed
                  path: Videos/demo.mp4
              channel_plan:
                product_hunt: prepare_after_video
                hacker_news: fallback
              go_no_go:
                rule: No public launch until assets are ready.
              weak_launch_blockers:
                - No hosted video yet.
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.utc.iso8601,
            projectName: 'SaneExample',
            status: 'passed',
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected weak-launch package blocker to block')
        assert_includes(report[:issues].join("\n"), 'Outstanding weak-launch blocker: No hosted video yet.')
      end
      true
    end

    test('blocks expired date-bound launch offer copy') do
      Dir.mktmpdir('launch-readiness-expired-offer-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: active_launch_window
              rule: Keep offer copy current before public launch work.
              offer_window:
                starts: "1999-12-01"
                ends: "2000-01-01"
                message: "$9.99 with code OLD until January 1, 2000."
              scheduled:
                - date: "2026-05-20"
                  time: "10:00"
                  channel: Product Hunt
                  action: Launch only if ready.
                  gate: Exact user approval required.
                  success_metric: URL recorded.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: ready_to_schedule
              audience: Mac users
              problem: Problem
              solution: Solution
              primary_story: Story
              pricing_proof: Checked
              privacy_proof: Checked
              proof_assets:
                - type: video
                  status: current
                  path: Videos/demo.mp4
              channel_plan:
                product_hunt: scheduled
              go_no_go:
                rule: No stale offer copy.
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.utc.iso8601,
            projectName: 'SaneExample',
            status: 'passed',
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected expired offer copy to block launch readiness')
        assert_includes(report[:issues].join("\n"), 'launch_calendar.offer_window ended on 2000-01-01')
      end
      true
    end

    test('blocks when meaningful-launch requirements are still listed') do
      Dir.mktmpdir('launch-readiness-requirements-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: released_but_no_meaningful_public_launch_yet
              rule: Do not launch until the package is complete.
              required_before_meaningful_launch:
                - 30-second demo asset
                - Fresh Mini verify/customer UI proof
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: package_in_progress
              audience: Finder power users
              problem: Finder actions are clumsy
              solution: Right-click automation
              primary_story: Focused Finder workflow demo
              pricing_proof: Website shows Basic free and Pro once pricing.
              privacy_proof: Privacy page states files stay local.
              proof_assets:
                - type: screenshot
                  status: ready
                  path: outputs/demo.png
              channel_plan:
                product_hunt: prepare
              go_no_go:
                owner: Mr. Sane
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.utc.iso8601,
            projectName: 'SaneExample',
            status: 'passed',
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected launch readiness to block on unresolved requirements')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'Missing meaningful-launch requirement completion: 30-second demo asset')
        assert_includes(issues, 'Missing meaningful-launch requirement completion: Fresh Mini verify/customer UI proof')
      end
      true
    end

    test('blocks when launch blockers remain open') do
      Dir.mktmpdir('launch-readiness-blockers-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: released_but_launch_blocked_until_risk_cleanup
              rule: No public launch until current blockers are clean.
              blockers:
                - Piracy page still marked needs_dmca.
                - Open patched-pending issues still need maintainer replies.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: blocked
              audience: Clipboard privacy users
              problem: Clipboard managers leak trust
              solution: Private native clipboard manager
              primary_story: OCR plus encrypted history
              pricing_proof: Website shows Basic free and Pro once pricing.
              privacy_proof: Privacy page states clipboard data stays local.
              proof_assets:
                - type: screenshot
                  status: ready
                  path: outputs/demo.png
              channel_plan:
                product_hunt: hold
              go_no_go:
                owner: Mr. Sane
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.utc.iso8601,
            projectName: 'SaneExample',
            status: 'passed',
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected launch readiness to block on blockers')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'Outstanding launch blocker: Piracy page still marked needs_dmca.')
        assert_includes(issues, 'Outstanding launch blocker: Open patched-pending issues still need maintainer replies.')
      end
      true
    end

    test('live direct-download apps keep launch-package blockers hard but downgrade stale release proof') do
      Dir.mktmpdir('launch-readiness-live-direct-download-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: released_but_no_meaningful_public_launch_yet
              rule: Direct-download release is live, but a major launch still needs package approval.
              current_release_state:
                version: "1.2.3"
                status: live_direct_download
                evidence: Website and appcast match.
              required_before_meaningful_launch:
                - 30-second demo asset
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: package_in_progress
              audience: Finder power users
              problem: Finder actions are clumsy
              solution: Right-click automation
              primary_story: Focused Finder workflow demo
              pricing_proof: Website shows Basic free and Pro once pricing.
              privacy_proof: Privacy page states files stay local.
              proof_assets:
                - type: screenshot
                  status: ready
                  path: outputs/demo.png
              channel_plan:
                product_hunt: prepare
              go_no_go:
                owner: Mr. Sane
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: (Time.now.utc - (9 * 86_400)).iso8601,
            projectName: 'SaneExample',
            status: 'failed',
            issueCount: 2,
            warningCount: 1,
            issues: ['Tests failing'],
            warnings: ['Pending customer emails']
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected unresolved launch-package blockers to stay hard red')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'Missing meaningful-launch requirement completion: 30-second demo asset')
        warnings = report[:warnings].join("\n")
        assert_includes(warnings, 'Latest release_preflight proof is stale')
        assert_includes(warnings, 'Latest release_preflight is not green: failed (2 issue(s))')
      end
      true
    end

    test('blocks stale or failed release preflight proof') do
      Dir.mktmpdir('launch-readiness-stale-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: SaneExample\n")
        File.write(
          File.join(dir, '.outreach.yml'),
          <<~YAML
            launch_calendar:
              classification: launch_candidate
              rule: Every launch needs current runtime proof first.
              scheduled:
                - date: "2026-05-20"
                  time: "10:00"
                  channel: Product Hunt
                  action: Launch the public package.
                  gate: Fresh proof required.
                  success_metric: Public launch is either scheduled or marked no-go.
            public_posting_policy:
              approval_required: true
              disclosure_required: Always say "I built SaneExample".
            launch_package:
              status: ready_to_schedule
              audience: Indie developers
              problem: Daily dashboard fatigue
              solution: Native sales tracker
              primary_story: Private direct provider sync
              pricing_proof: Website shows the live launch offer and regular price.
              privacy_proof: Privacy page states provider data never goes through SaneApps servers.
              proof_assets:
                - type: video
                  status: ready
                  url: https://example.com/demo.mp4
              channel_plan:
                product_hunt: schedule
              go_no_go:
                owner: Mr. Sane
              weak_launch_blockers: []
          YAML
        )
        File.write(
          File.join(dir, 'outputs', 'release_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: (Time.now.utc - (9 * 86_400)).iso8601,
            projectName: 'SaneExample',
            status: 'failed',
            issueCount: 2,
            warningCount: 1,
            issues: ['Tests failing'],
            warnings: ['Pending customer emails']
          )
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.launch_readiness_report(config: { 'name' => 'SaneExample' })
        end

        assert(!report[:ok], 'expected stale/failed preflight proof to block')
        issues = report[:issues].join("\n")
        assert_includes(issues, 'Latest release_preflight is not green: failed (2 issue(s))')
        assert_includes(issues, 'Latest release_preflight proof is stale')
        warnings = report[:warnings].join("\n")
        assert_includes(warnings, 'Latest release_preflight still has 1 warning(s)')
      end
      true
    end
  end

  test_category('App Store lane gating') do
    test('resolves ASC credentials from env without SaneApps fallback') do
      Dir.mktmpdir('asc-credentials-') do |dir|
        key_path = File.join(dir, 'AuthKey_TEST.p8')
        File.write(key_path, 'not-a-real-key')
        with_env(
          'SANE_NO_KEYCHAIN' => '1',
          'ASC_AUTH_KEY_ID' => 'TESTKEY123',
          'ASC_AUTH_ISSUER_ID' => '00000000-0000-0000-0000-000000000000',
          'ASC_AUTH_KEY_PATH' => key_path,
          'ASC_KEY_ID' => nil,
          'ASC_ISSUER_ID' => nil,
          'ASC_KEY_PATH' => nil
        ) do
          credentials = subject.send(:resolved_asc_credentials)
          assert_eq(credentials[:key_id], 'TESTKEY123')
          assert_eq(credentials[:issuer_id], '00000000-0000-0000-0000-000000000000')
          assert_eq(credentials[:key_path], key_path)
        end
      end
      true
    end

    test('missing ASC credentials do not synthesize SaneApps defaults') do
      with_env(
        'SANE_NO_KEYCHAIN' => '1',
        'ASC_AUTH_KEY_ID' => '',
        'ASC_AUTH_ISSUER_ID' => '',
        'ASC_AUTH_KEY_PATH' => '',
        'ASC_KEY_ID' => '',
        'ASC_ISSUER_ID' => '',
        'ASC_KEY_PATH' => ''
      ) do
        credentials = subject.send(:resolved_asc_credentials)
        assert_eq(credentials[:key_id], '')
        assert_eq(credentials[:issuer_id], '')
        assert_eq(credentials[:key_path], '')
      end
      true
    end

    test('appstore preflight skips projects whose App Store lane is disabled') do
      Dir.mktmpdir('disabled-appstore-lane-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: DirectOnlyApp
            appstore:
              enabled: false
              app_id: "1234567890"
          YAML
        )

        result = nil
        output = nil
        Dir.chdir(dir) do
          output = capture_stdout { result = subject.appstore_preflight([]) }
        end

        assert_eq(result, true)
        assert_includes(output, 'App Store lane disabled in .saneprocess')
        assert_includes(output, 'Use release_preflight for direct-download release readiness')
      end
      true
    end

    test('detects missing app-level App Store availability') do
      subject.stub_asc_json_with_status(
        '/apps/123/appAvailabilityV2',
        404,
        {
          'errors' => [
            { 'detail' => "There is no resource of type 'appAvailabilities' with id '123'" }
          ]
        }
      )

      status = subject.send(:asc_app_availability_status, app_id: '123')

      assert_eq(status[:exists], false)
      assert_eq(status[:http_code], 404)
      true
    end

    test('accepts app-level availability only when all territory rows are available') do
      subject.stub_asc_json_with_status(
        '/apps/123/appAvailabilityV2',
        200,
        {
          'data' => {
            'id' => '123',
            'type' => 'appAvailabilities',
            'attributes' => { 'availableInNewTerritories' => true }
          }
        }
      )
      subject.stub_asc_json_with_status(
        '/appAvailabilities/123/relationships/territoryAvailabilities?limit=200',
        200,
        {
          'data' => [
            { 'type' => 'territoryAvailabilities', 'id' => 'usa' },
            { 'type' => 'territoryAvailabilities', 'id' => 'can' }
          ],
          'meta' => { 'paging' => { 'total' => 2 } }
        },
        base: 'https://api.appstoreconnect.apple.com/v2'
      )
      subject.stub_asc_json_with_status(
        '/appAvailabilities/123/territoryAvailabilities?limit=200',
        200,
        {
          'data' => [
            { 'attributes' => { 'contentStatuses' => ['AVAILABLE'] } },
            { 'attributes' => { 'contentStatuses' => ['AVAILABLE'] } }
          ]
        },
        base: 'https://api.appstoreconnect.apple.com/v2'
      )

      status = subject.send(:asc_app_availability_status, app_id: '123')

      assert_eq(status[:exists], true)
      assert_eq(status[:territory_total], 2)
      assert_eq(status[:available_count], 2)
      assert_eq(status[:all_territories_available], true)
      true
    end

    test('privacy manifest guard blocks missing required reason API declarations') do
      Dir.mktmpdir('privacy-manifest-required-reasons-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Core'))
        File.write(File.join(dir, 'Core', 'Settings.swift'), 'let enabled = UserDefaults.standard.bool(forKey: "enabled")')
        manifest = File.join(dir, 'PrivacyInfo.xcprivacy')
        File.write(
          manifest,
          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
              <key>NSPrivacyTracking</key>
              <false/>
              <key>NSPrivacyCollectedDataTypes</key>
              <array/>
              <key>NSPrivacyAccessedAPITypes</key>
              <array/>
            </dict>
            </plist>
          XML
        )

        report = nil
        Dir.chdir(dir) do
          report = subject.send(
            :privacy_manifest_guardrail_report,
            manifest_paths: [manifest],
            project_yml_content: 'sources: [PrivacyInfo.xcprivacy]'
          )
        end

        assert_includes(report[:issues], 'PrivacyInfo.xcprivacy missing required reason API category NSPrivacyAccessedAPICategoryUserDefaults')
      end
      true
    end

    test('treats entitlements as optional for iOS-only App Store lanes') do
      assert(subject.send(:ios_only_appstore_submission?, %w[ios]))
      assert(!subject.send(:ios_only_appstore_submission?, %w[ios macos]))
      true
    end

    test('reads iOS deployment target from project.yml for iOS App Store lanes') do
      summary = subject.send(
        :appstore_deployment_target_summary,
        config: {},
        appstore_config: { 'platforms' => ['ios'] },
        project_yml_content: <<~YAML
          options:
            deploymentTarget:
              iOS: 17.0
        YAML
      )

      assert_eq(summary, 'iOS 17.0')
      true
    end
  end

  test_category('Subscription purchase-flow guardrails') do
    test('blocks auto-renewable subscriptions without in-app legal links and renewal terms') do
      report = subject.send(
        :subscription_purchase_flow_guardrail_report,
        source_blob: <<~SWIFT,
          import StoreKit
          struct PaywallView {
            let title = "SaneScan Pro"
            let copy = "Unlimited scans"
            func purchasePro(_ product: Product) async {
              print(product.displayName)
              print(product.displayPrice)
            }
            func restorePurchases() async {}
          }
        SWIFT
        appstore_config: {
          'privacy_policy_url' => 'https://example.com/privacy/',
          'iap' => {
            'type' => 'auto_renewable_subscription',
            'display_name' => 'SaneScan Pro Yearly'
          }
        },
        config: {}
      )

      assert(report[:applicable], 'expected subscription guardrail to apply')
      issues = report[:issues].join("\n")
      assert_includes(issues, 'functional Terms of Use/EULA link inside the app')
      assert_includes(issues, 'functional Privacy Policy link inside the app')
      assert_includes(issues, 'renewal duration/term copy')
      assert_includes(issues, 'cancellation/manage-subscription copy')
      true
    end

    test('accepts complete auto-renewable subscription purchase disclosure') do
      report = subject.send(
        :subscription_purchase_flow_guardrail_report,
        source_blob: <<~SWIFT,
          import StoreKit
          import SwiftUI

          struct PaywallView: View {
            let product: Product
            var body: some View {
              VStack {
                Text("SaneScan Pro Yearly")
                Text("Unlimited scans and batch import are provided during each yearly subscription period.")
                Text("Billed once per year. Cancel anytime in subscription settings.")
                Button { Task { await purchasePro(product) } } label: {
                  Text(product.displayName)
                  Text(product.displayPrice)
                }
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy/")!)
                Button("Restore Purchases") { Task { await restorePurchases() } }
              }
            }
          }
        SWIFT
        appstore_config: {
          'privacy_policy_url' => 'https://example.com/privacy/',
          'iap' => {
            'type' => 'auto_renewable_subscription',
            'display_name' => 'SaneScan Pro Yearly'
          }
        },
        config: {}
      )

      assert(report[:issues].empty?, "expected complete disclosure to pass: #{report[:issues].inspect}")
      true
    end
  end

  test_category('Metadata URL health') do
    test('follows redirects to a healthy final URL') do
      subject.stub_url_status('https://example.com/support', code: 301, location: '/help')
      subject.stub_url_status('https://example.com/help', code: 200)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(report[:ok], 'expected redirect chain to be treated as healthy')
      assert_eq(report[:code], 200)
      assert_eq(report[:final_url], 'https://example.com/help')
      true
    end

    test('fails on HTTP errors') do
      subject.stub_url_status('https://example.com/support', code: 404)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(!report[:ok], 'expected 404 to fail')
      assert_eq(report[:error], 'HTTP 404')
      true
    end
  end

  test_category('Release test lane policy') do
    test('release preflight blocks macOS 26 ScreenCaptureKit symbols below the release minimum') do
      Dir.mktmpdir('api-compat-') do |dir|
        source = File.join(dir, 'ScreenCaptureService.swift')
        File.write(source, "let configuration = SCScreenshotConfiguration()\n")

        report = subject.send(
          :api_compatibility_guardrail_report,
          config: { 'release' => { 'min_system_version' => '15.0' } },
          source_files: [source]
        )

        assert(report[:applicable], 'expected release API compatibility report to apply')
        assert_eq(report[:issues].length, 1)
        assert_includes(report[:issues].first, 'requires macOS 26.0')
        assert_includes(report[:issues].first, 'release.min_system_version is 15.0')
      end
      true
    end

    test('release preflight allows macOS 26 symbols when the release minimum is high enough') do
      Dir.mktmpdir('api-compat-') do |dir|
        source = File.join(dir, 'ScreenCaptureService.swift')
        File.write(source, "let configuration = SCScreenshotConfiguration()\n")

        report = subject.send(
          :api_compatibility_guardrail_report,
          config: { 'release' => { 'min_system_version' => '26.0' } },
          source_files: [source]
        )

        assert(report[:applicable], 'expected release API compatibility report to apply')
        assert_eq(report[:issues], [])
      end
      true
    end

    test('release preflight treats older public channels as prepublish drift only while appcast is also older') do
      assert(subject.send(:prepublish_channel_version_drift?, channel_version: '2.1.58', project_version: '2.1.59'))
      assert(!subject.send(:prepublish_channel_version_drift?, channel_version: '2.1.59', project_version: '2.1.59'))
      assert(!subject.send(:prepublish_channel_version_drift?, channel_version: '2.1.60', project_version: '2.1.59'))

      release_source = File.read(File.join(__dir__, 'release.rb'))
      assert_includes(release_source, 'Homebrew cask version #{cask_version} is older than project MARKETING_VERSION #{project_version} (expected before publish)')
      assert_includes(release_source, 'channel_version: local_latest_appcast_version')
      true
    end

    test('release preflight runs cheap policy QA before expensive verify and full QA') do
      release_source = File.read(File.join(__dir__, 'release.rb'))
      preflight_body = release_source[/def release_preflight\(_args\).*?^\s+def release_gate_fixture_reports/m]

      policy_index = preflight_body.index('Project QA policy guardrails')
      verify_index = preflight_body.index("heartbeat_label: 'SaneMaster verify'")
      full_qa_index = preflight_body.rindex("Project QA guardrails... '")
      summary_index = preflight_body.index('# Summary')

      assert(policy_index && verify_index && policy_index < verify_index,
             'expected policy-only QA before expensive verify')
      assert(verify_index && summary_index && verify_index < summary_index,
             'expected expensive verify near the end before summary')
      assert(full_qa_index && verify_index && verify_index < full_qa_index,
             'expected full project QA after verify')
      assert_includes preflight_body, 'policy_only: true'
      assert_includes preflight_body, 'skipped (fix cheap release blocker(s) first)'
      assert_includes preflight_body, 'timeout_seconds: release_verify_timeout_seconds'
      assert_includes release_source, 'Open3.popen2e(env, *cmd, pgroup: true)'
      assert_includes release_source, 'terminate_release_command_process(wait_thr.pid'
      true
    end

    test('policy-only project QA env omits runtime smoke flags') do
      policy_env = subject.send(:release_project_qa_env, app_name: 'SaneBar', policy_only: true)
      full_env = subject.send(:release_project_qa_env, app_name: 'SaneBar', policy_only: false)
      reused_runtime_env = subject.send(:release_project_qa_env, app_name: 'SaneBar', policy_only: false, skip_runtime_smoke: true)

      assert_eq(policy_env['SANEPROCESS_RELEASE_POLICY_ONLY'], '1')
      assert_eq(policy_env['SANEBAR_RELEASE_POLICY_ONLY'], '1')
      assert(!policy_env.key?('SANEPROCESS_RUN_RUNTIME_SMOKE'), 'policy-only QA must not request runtime smoke')
      assert(!policy_env.key?('SANEBAR_RUN_RUNTIME_SMOKE'), 'policy-only QA must not request app runtime smoke')
      assert_eq(full_env['SANEPROCESS_RUN_RUNTIME_SMOKE'], '1')
      assert_eq(full_env['SANEBAR_RUN_RUNTIME_SMOKE'], '1')
      assert_eq(reused_runtime_env['SANEPROCESS_RELEASE_PREFLIGHT'], '1')
      assert_eq(reused_runtime_env['SANEPROCESS_RUN_STABILITY_SUITE'], '1')
      assert_eq(reused_runtime_env['SANEBAR_RELEASE_PREFLIGHT'], '1')
      assert_eq(reused_runtime_env['SANEBAR_RUN_STABILITY_SUITE'], '1')
      assert(!reused_runtime_env.key?('SANEPROCESS_RUN_RUNTIME_SMOKE'), 'fresh customer UI runtime proof should let full QA skip duplicate runtime smoke')
      assert(!reused_runtime_env.key?('SANEBAR_RUN_RUNTIME_SMOKE'), 'fresh customer UI runtime proof should let app QA skip duplicate runtime smoke')
      assert_eq(reused_runtime_env['SANEPROCESS_REUSE_CUSTOMER_UI_RUNTIME_PROOF'], '1')
      assert_eq(reused_runtime_env['SANEBAR_REUSE_CUSTOMER_UI_RUNTIME_PROOF'], '1')
      true
    end

    test('release preflight reuses fresh customer UI runtime proof only for same candidate') do
      Dir.mktmpdir('release-runtime-proof-reuse-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        FileUtils.mkdir_p(File.join(dir, 'SaneBar'))
        visual_source = File.join(dir, 'SaneBar', 'ContentView.swift')
        File.write(visual_source, 'struct ContentView {}')
        File.write(
          File.join(dir, 'project.yml'),
          "settings:\n  MARKETING_VERSION: \"2.1.74\"\n  CURRENT_PROJECT_VERSION: \"2174\"\n"
        )
        evidence_dir = File.join(dir, 'outputs', 'customer-ui', 'evidence')
        runtime_preflight_dir = File.join(dir, 'outputs', 'runtime-preflight')
        FileUtils.mkdir_p(evidence_dir)
        FileUtils.mkdir_p(runtime_preflight_dir)
        receipt_path = File.join(dir, 'outputs', 'customer_ui_action_receipt.json')
        runtime_rows = %w[
          fullscreen_maximize_transition
          wake_visible_zone_persistence
          dynamic_helper_wake_drift
          shared_bundle_exact_id_moves
          hover_auto_rehide
          license_clipboard_paste
          resource_soak_growth
        ].map do |id|
          evidence_paths = case id
                           when 'hover_auto_rehide'
                             ['outputs/runtime-preflight/sanebar_runtime_hover_rehide.json']
                           when 'license_clipboard_paste'
                             ['outputs/runtime-preflight/sanebar_runtime_license_paste.json']
                           else
                             ["outputs/customer-ui/evidence/#{id}.json"]
                           end
          {
            'id' => id,
            'status' => 'passed',
            'evidence_paths' => evidence_paths,
            'runtime_candidate' => {
              'app_path' => '/Applications/SaneBar.app',
              'app_version' => '2.1.74',
              'app_build' => '2174'
            }
          }
        end.tap do |rows|
          rows.each do |row|
            row['evidence_paths'].each do |relative_path|
              path = File.join(dir, relative_path)
              FileUtils.mkdir_p(File.dirname(path))
              File.write(path, JSON.pretty_generate(status: 'passed', id: row['id']))
            end
          end
        end
        receipt = {
          'app' => 'SaneBar',
          'status' => 'passed',
          'generated_at' => (Time.now.utc - 60).iso8601,
          'evidence' => {
            'app_version' => '2.1.74',
            'app_build' => '2174'
          },
          'runtime_state_results' => runtime_rows
        }
        Dir.chdir(dir) do
          fingerprint = subject.send(:customer_ui_source_fingerprint)
          receipt['source_fingerprint'] = fingerprint
          File.write(receipt_path, JSON.pretty_generate(receipt))
          report = { ok: true, receipt_path: 'outputs/customer_ui_action_receipt.json', source_fingerprint: fingerprint }
          assert(subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))

          receipt['source_fingerprint'] = '0' * 64
          File.write(visual_source, 'struct ContentView { let changed = true }')
          File.write(receipt_path, JSON.pretty_generate(receipt))
          assert(!subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))
          receipt['source_fingerprint'] = fingerprint
          File.write(receipt_path, JSON.pretty_generate(receipt))

          receipt['runtime_state_results'].first['runtime_candidate']['app_build'] = '2173'
          File.write(receipt_path, JSON.pretty_generate(receipt))
          assert(!subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))

          receipt['runtime_state_results'].first['runtime_candidate']['app_build'] = '2174'
          receipt['runtime_state_results'][1]['runtime_candidate']['app_path'] = '/Applications/Other.app'
          File.write(receipt_path, JSON.pretty_generate(receipt))
          assert(!subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))

          receipt['runtime_state_results'][1]['runtime_candidate']['app_path'] = '/Applications/SaneBar.app'
          receipt['runtime_state_results'][2]['evidence_paths'] = ['outputs/customer-ui/evidence/missing.json']
          File.write(receipt_path, JSON.pretty_generate(receipt))
          assert(!subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))

          receipt['runtime_state_results'][2]['evidence_paths'] = ['outputs/customer-ui/evidence/dynamic_helper_wake_drift.json']
          receipt['generated_at'] = (Time.now.utc + 10 * 60).iso8601
          File.write(receipt_path, JSON.pretty_generate(receipt))
          assert(!subject.send(:release_customer_ui_runtime_smoke_reusable?, report, app_name: 'SaneBar'))
        end
      end
      true
    end

    test('release preflight treats auto-reconcile source stashes as release blockers') do
      files = [
        'SaneClick/SaneClickApp.swift',
        'Tests/AppStoreReviewGuardrailTests.swift',
        '.DS_Store',
        'fastlane/report.xml',
        '.claude/tool_count.json'
      ]

      blocking = subject.send(:blocking_auto_reconcile_stash_files, files)

      assert_eq(blocking, ['SaneClick/SaneClickApp.swift', 'Tests/AppStoreReviewGuardrailTests.swift'])
      true
    end

    test('release preflight allows only known generated noise in auto-reconcile stashes') do
      files = [
        './.DS_Store',
        'default.profraw',
        'fastlane/reports/rubocop.html',
        '.claude/audit_log.jsonl',
        '.claude/research.md'
      ]

      blocking = subject.send(:blocking_auto_reconcile_stash_files, files)

      assert_eq(blocking, ['.claude/research.md'])
      true
    end

    test('release preflight detects real auto-reconcile git stashes') do
      Dir.mktmpdir('auto-reconcile-stash-') do |dir|
        git = lambda do |*args|
          output, status = Open3.capture2e('git', '-C', dir, *args)
          assert(status.success?, "git #{args.join(' ')} failed: #{output}")
          output
        end

        git.call('init')
        git.call('config', 'user.email', 'test@example.invalid')
        git.call('config', 'user.name', 'SaneProcess Test')
        FileUtils.mkdir_p(File.join(dir, 'SaneClick'))
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = true\n")
        git.call('add', '.')
        git.call('commit', '-m', 'baseline')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('stash', 'push', '-m', 'auto-reconcile-20260509-test')

        reports = subject.send(:auto_reconcile_stash_reports, repo_path: dir)

        assert_eq(reports.length, 1)
        assert_eq(reports.first[:ref], 'stash@{0}')
        assert(reports.first[:stash_sha].to_s.match?(/\A[0-9a-f]{40}\z/), 'expected stash SHA in report')
        assert_eq(reports.first[:blocking_files], ['SaneClick/SaneClickApp.swift'])
      end
      true
    end

    test('release preflight can mark an exact auto-reconcile stash as reviewed') do
      report = {
        ref: 'stash@{0}',
        stash_sha: 'abc123',
        subject: 'On main: auto-reconcile-20260509-test',
        blocking_files: ['SaneClick/SaneClickApp.swift']
      }
      config = {
        'release' => {
          'reviewed_auto_reconcile_stashes' => [
            {
              'stash_sha' => 'abc123',
              'subject' => 'On main: auto-reconcile-20260509-test',
              'decision' => 'superseded',
              'reason' => 'Reviewed against current release candidate; stale App Store-only branch work is not part of direct release.'
            }
          ]
        }
      }

      assert(subject.send(:reviewed_auto_reconcile_stash?, config, report), 'expected exact reviewed stash to be allowed')
      true
    end

    test('release preflight refuses reviewed auto-reconcile entries without a reason') do
      report = {
        ref: 'stash@{0}',
        stash_sha: 'abc123',
        subject: 'On main: auto-reconcile-20260509-test',
        blocking_files: ['SaneClick/SaneClickApp.swift']
      }
      config = {
        'release' => {
          'reviewed_auto_reconcile_stashes' => [
            {
              'stash_sha' => 'abc123',
              'subject' => 'On main: auto-reconcile-20260509-test',
              'decision' => 'superseded',
              'reason' => ''
            }
          ]
        }
      }

      assert(!subject.send(:reviewed_auto_reconcile_stash?, config, report), 'expected missing review reason to keep blocking')
      true
    end

    test('release preflight ignores auto-reconcile stash content already present in HEAD') do
      Dir.mktmpdir('auto-reconcile-stash-applied-') do |dir|
        git = lambda do |*args|
          output, status = Open3.capture2e('git', '-C', dir, *args)
          assert(status.success?, "git #{args.join(' ')} failed: #{output}")
          output
        end

        git.call('init')
        git.call('config', 'user.email', 'test@example.invalid')
        git.call('config', 'user.name', 'SaneProcess Test')
        FileUtils.mkdir_p(File.join(dir, 'SaneClick'))
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = true\n")
        git.call('add', '.')
        git.call('commit', '-m', 'baseline')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('stash', 'push', '-m', 'auto-reconcile-20260509-test')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('add', '.')
        git.call('commit', '-m', 'recover stashed work')

        reports = subject.send(:auto_reconcile_stash_reports, repo_path: dir)

        assert_eq(reports.length, 0)
      end
      true
    end

    test('release.sh prefers SaneMaster verify before raw xcodebuild fallbacks') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      verify_index = release_script.index('Using SaneMaster verify as the authoritative release test lane.')
      xcodebuild_index = release_script.index('xcodebuild "${args[@]}"')

      assert(!verify_index.nil?, 'expected release.sh to invoke SaneMaster verify first')
      assert(!xcodebuild_index.nil?, 'expected raw xcodebuild fallback to remain available')
      assert(verify_index < xcodebuild_index, 'expected SaneMaster verify path before raw xcodebuild fallback')
      true
    end

    test('release.sh trusts fresh SaneMaster release_preflight proof before raw project QA') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      receipt_index = release_script.index('fresh_release_preflight_receipt_summary')
      qa_index = release_script.index('ruby "${qa_script}"')

      assert(!receipt_index.nil?, 'expected release.sh to validate fresh release_preflight receipt')
      assert(!qa_index.nil?, 'expected raw project QA fallback to remain available')
      assert(receipt_index < qa_index, 'expected release_preflight receipt path before raw project QA fallback')
      assert_includes(release_script, 'sourceFingerprint')
      assert_includes(release_script, "payload['miniRuntime'] == true")
      assert_includes(release_script, 'release_preflight was not generated on Mini runtime')
      assert_includes(release_script, 'process_root = File.expand_path(ARGV[3])')
      assert_includes(release_script, 'SaneProcess/#{relative_path}')
      assert_includes(release_script, 'SaneApps/#{relative_path}')
      assert_includes(release_script, "File.join(process_root, 'scripts', 'sanemaster'")
      assert_includes(release_script, "File.join(process_root, 'scripts', 'hooks'")
      assert_includes(release_script, "File.join(saneapps_root, 'infra', 'SaneUI', 'Sources'")
      assert_includes(release_script, 'customer UI receipt is stale for release_preflight reuse')
      assert_includes(release_script, '(?:css|html|js|json|xml)')
      assert_includes(release_script, "path == 'docs/_redirects' || path == 'website/_redirects'")
      assert_includes(release_script, 'Project QA guardrails covered by fresh SaneMaster release_preflight receipt')
      true
    end

    test('release.sh bounds GitHub API fallback and keeps bearer tokens out of curl argv') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      release_module = File.read(File.expand_path('release.rb', __dir__))

      assert_includes(release_script, 'SANEPROCESS_GH_API_TIMEOUT_SECONDS')
      assert_includes(release_script, 'subprocess.run(')
      assert_includes(release_script, 'timeout=timeout')
      assert(!release_script.include?('body=$(gh api "${github_api_path}"'), 'expected gh api to run through bounded subprocess wrapper')
      assert_includes(release_script, 'gh_open_count_with_timeout')
      assert_includes(release_script, 'gh_pr_list_with_timeout')
      assert(!release_script.include?('OPEN_ISSUES=$(gh issue list'), 'expected GitHub issue gate to run through bounded helper')
      assert(!release_script.include?('OPEN_PRS=$(gh pr list'), 'expected GitHub PR gate to run through bounded helper')
      assert_includes(release_module, 'capture_github_command_with_timeout')
      assert_includes(release_module, 'gh command timeout after')
      assert(!release_module.include?("Open3.capture2e({ 'PATH' => tool_path }, gh_bin, 'issue'"), 'expected Ruby issue preflight to use bounded GitHub helper')
      assert(!release_module.include?("Open3.capture2e({ 'PATH' => tool_path }, gh_bin, 'pr'"), 'expected Ruby PR preflight to use bounded GitHub helper')
      assert_includes(release_script, 'create_curl_bearer_header_file')
      assert_includes(release_script, 'RELEASE_SECRET_TEMP_PATHS')
      assert_includes(release_script, 'cleanup_secret_temp_file')
      assert_includes(release_script, '-H "@${auth_header_file}"')
      assert_includes(release_script, '-H "@${EMAIL_AUTH_HEADER_FILE}"')
      assert_includes(release_script, '-H "@${CF_AUTH_HEADER_FILE}"')
      assert(!release_script.include?('-H "Authorization: Bearer ${api_key}"'), 'email webhook token must not be passed in curl argv')
      assert(!release_script.include?('-H "Authorization: Bearer ${EMAIL_API_KEY}"'), 'pending email token must not be passed in curl argv')
      assert(!release_script.include?('-H "Authorization: Bearer ${CF_TOKEN}"'), 'Cloudflare token must not be passed in curl argv')
      true
    end

    test('release.sh skips duplicate verify when fresh release_preflight proof matches candidate') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      run_tests_body = release_script[/run_tests\(\) \{.*?^}/m]

      assert(!run_tests_body.nil?, 'expected run_tests body in release.sh')
      assert_includes(run_tests_body, 'fresh_release_preflight_receipt_summary')
      assert_includes(run_tests_body, 'Skipping duplicate SaneMaster verify')
      assert_includes(run_tests_body, 'SANEPROCESS_RELEASE_ALWAYS_RUN_TESTS=1')
      true
    end

    test('release.sh fans out public post-release HTTP probes before sequential credential checks') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      post_release_body = release_script[/run_post_release_checks\(\) \{.*?^}/m]

      assert(!post_release_body.nil?, 'expected run_post_release_checks body in release.sh')
      assert_includes(post_release_body, 'post-release-probes')
      assert_includes(post_release_body, 'sane-post-release-probes.XXXXXX')
      assert_includes(post_release_body, 'dist_browser.err')
      assert_includes(post_release_body, 'release_probe_status_text')
      assert_includes(post_release_body, 'post-release-probes-${RELEASE_RUN_ID}.txt')
      assert_includes(post_release_body, 'probe_pids+=("$!")')
      assert_includes(post_release_body, 'wait "${probe_pid}" || true')
      assert_includes(post_release_body, 'write_post_release_probe_receipt "${probe_dir}" "${probe_receipt_path}" "probes_finished"')
      assert_includes(post_release_body, 'write_post_release_probe_receipt "${probe_dir}" "${probe_receipt_path}" "passed" "${download_redirect_status}"')
      assert(post_release_body.index('extract_http_status "${dist_url}"') < post_release_body.index('verify_dist_archive_bundle_version'), 'expected public URL probes before archive verification')
      assert(post_release_body.index('verify_lemonsqueezy_hosted_file_sync') > post_release_body.index('wait "${probe_pid}" || true'), 'credential-backed hosted file sync should remain after public probe fan-out')
      true
    end

    test('release.sh accepts Lemon custom checkout cart redirects after matched first hop') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      post_release_body = release_script[/run_post_release_checks\(\) \{.*?^}/m]

      assert(!post_release_body.nil?, 'expected run_post_release_checks body in release.sh')
      assert_includes(post_release_body, 'checkout_first_hop_ok')
      assert_includes(post_release_body, 'lemonsqueezy\\.com/checkout/?(\\?.*)?$')
      assert_includes(post_release_body, 'lemonsqueezy\\.com/checkout/cart/')
      assert_includes(post_release_body, '"custom=1"')
      assert_includes(post_release_body, "Lemon's custom-checkout cart")
      true
    end

    test('release.sh skips checkout verification when product config has no checkout') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      post_release_body = release_script[/run_post_release_checks\(\) \{.*?^}/m]

      assert(!post_release_body.nil?, 'expected run_post_release_checks body in release.sh')
      assert_includes(post_release_body, 'configured_checkout_url=$(lookup_checkout_url_for_slug "${LOWER_APP_NAME}")')
      assert_includes(post_release_body, 'has_configured_checkout=false')
      assert_includes(post_release_body, "printf 'skipped: no configured checkout\\n' > \"${probe_dir}/checkout.status\"")
      assert_includes(post_release_body, 'Skipping checkout verification: ${LOWER_APP_NAME} has no configured checkout in products.yml.')
      assert_includes(release_script, 'Skipping checkout link verification: ${LOWER_APP_NAME} has no configured checkout in products.yml.')
      true
    end

    test('release.sh checks Homebrew GitHub API before raw propagation loop') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      post_release_body = release_script[/run_post_release_checks\(\) \{.*?^}/m]

      api_probe_index = post_release_body.index('cask_api_probe=$(fetch_github_contents_file_body')
      raw_loop_index = post_release_body.index('cask_body=$(curl --connect-timeout 10 --max-time 20 -fsSL "${cask_raw_url}"')
      assert_includes(release_script, 'fetch_github_contents_file_body')
      assert(!api_probe_index.nil?, 'expected GitHub API Homebrew probe without requiring gh')
      assert(!raw_loop_index.nil?, 'expected raw Homebrew fallback')
      assert(api_probe_index < raw_loop_index, 'expected GitHub API Homebrew check before raw fallback')
      true
    end

    test('release.sh non-strict missing Homebrew cask does not skip later post-release checks') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))
      post_release_body = release_script[/run_post_release_checks\(\) \{.*?^}/m]
      missing_cask_branch = post_release_body[/No Homebrew cask found.*?Homebrew cask did not converge/m]

      assert(!missing_cask_branch.nil?, 'expected explicit missing Homebrew cask branch')
      assert(!missing_cask_branch.include?('return 0'), 'missing optional cask must not return from all post-release checks')
      assert(
        post_release_body.index('No Homebrew cask found') < post_release_body.index('Website download flow'),
        'website checks must run after optional Homebrew skip'
      )
      true
    end

    test('release.sh dotenv parser ignores shell functions and conditionals') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, '[[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue')
      assert_includes(release_script, 'line="${line#export }"')
      true
    end

    test('release.sh does not run external model README checks during publish') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert(!release_script.include?('Checking README sync with shipped features'), 'release.sh should not spend release time on model README sync')
      true
    end

    test('release.sh does not duplicate changelog entries on retry') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'CHANGELOG.md already has v${VERSION} entry; leaving it unchanged.')
      assert_includes(release_script, 'grep -Eq "^## \\\\[${VERSION//./\\\\.}\\\\]([[:space:]]|-)"')
      true
    end

    test('release.sh fails when Cloudflare Pages deploy fails') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'SANEPROCESS_WRANGLER_VERSION="${SANEPROCESS_WRANGLER_VERSION:-4.104.0}"')
      assert_includes(release_script, 'if ! npx --yes "${WRANGLER_NPX_PACKAGE}" pages deploy "${DEPLOY_DIR}" \\')
      assert_includes(release_script, 'log_error "Website deploy failed."')
      assert_includes(release_script, 'log_error "Pages deploy failed."')
      true
    end

    test('release.sh blocks post-release completion when Lemon hosted file is stale') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      helper_index = release_script.index('verify_lemonsqueezy_hosted_file_sync()')
      call_index = release_script.index('if ! verify_lemonsqueezy_hosted_file_sync; then')
      success_index = release_script.index('RELEASE v${VERSION} DEPLOYED SUCCESSFULLY')

      assert(!helper_index.nil?, 'expected Lemon hosted-file verification helper')
      assert(!call_index.nil?, 'expected post-release checks to call Lemon hosted-file verification')
      assert(!success_index.nil?, 'expected release success banner')
      assert(call_index < success_index, 'expected Lemon hosted-file verification before release success')
      assert_includes(release_script, 'ruby "${sanemaster_script}" hosted_file_actions --json')
      assert_includes(release_script, 'Lemon Squeezy hosted file still needs dashboard sync')
      true
    end

    test('release.sh exposes targeted post-release verification recovery mode') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, '--post-release-checks-only')
      assert_includes(release_script, 'POST_RELEASE_CHECKS_ONLY=false')
      assert_includes(release_script, 'if [ "${POST_RELEASE_CHECKS_ONLY}" = true ]; then')
      assert_includes(release_script, '--post-release-checks-only requires --version X.Y.Z')
      assert_includes(release_script, 'Post-release recovery build inferred from live appcast')
      assert_includes(release_script, 'Post-release recovery SHA256 inferred from live dist ZIP')
      assert_includes(release_script, 'run_post_release_checks')
      assert_includes(release_script, 'Targeted post-release verification passed')
      true
    end

    test('release.sh tells operators not to rerun full release after post-release failure') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'Do not rerun the full release for this failure.')
      assert_includes(release_script, 'Fix the failed public-channel item, then rerun only post-release verification:')
      assert_includes(release_script, '--project ${PROJECT_ROOT} --version ${VERSION} --post-release-checks-only')
      true
    end

    test('release.sh does not hardcode SaneApps ASC credentials') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert(!release_script.include?('AuthKey_S34998ZCRT.p8'), 'release.sh should not hardcode the SaneApps key path')
      assert(!release_script.include?('ASC_AUTH_KEY_ID:-S34998ZCRT'), 'release.sh should not default to the SaneApps key id')
      assert(!release_script.include?('ASC_AUTH_ISSUER_ID:-c98b1e0a'), 'release.sh should not default to the SaneApps issuer id')
      assert_includes(release_script, 'App Store releases require ASC API credentials.')
      assert_includes(release_script, 'Set ASC_AUTH_KEY_PATH, ASC_AUTH_KEY_ID, ASC_AUTH_ISSUER_ID')
      true
    end

    test('release.sh does not mutate login keychain state by default') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'SANEPROCESS_MUTATE_LOGIN_KEYCHAIN_STATE:-0')
      assert_includes(release_script, 'SANEPROCESS_FORCE_KEYCHAIN_PARTITION:-0')
      true
    end

    test('SaneMaster wrapper prelude caches keychain partition grants') do
      prelude = File.read(File.expand_path('../sanemaster-wrapper-prelude.sh', __dir__))

      assert_includes(prelude, 'saneprocess_run_with_timeout()')
      assert_includes(prelude, 'stamp_root="${HOME}/.cache/saneprocess/keychain-partitions"')
      assert_includes(prelude, 'keychain_mtime="$(stat -f %m "${keychain}"')
      assert_includes(prelude, 'printf \'%s\\n%s\\n%s\\n\' "${keychain}" "${keychain_mtime}" "${identities}"')
      assert_includes(prelude, 'SANEPROCESS_GRANT_KEYCHAIN_PARTITION_ACCESS:-${SANEMASTER_GRANT_KEYCHAIN_PARTITION_ACCESS:-0}')
      assert_includes(prelude, 'SANEPROCESS_FORCE_KEYCHAIN_PARTITION:-0')
      assert_includes(prelude, 'SANEPROCESS_KEYCHAIN_PARTITION_TIMEOUT:-8')
      assert_includes(prelude, 'security set-key-partition-list')
      assert(!prelude.include?('-D "${identity}"'), 'wrapper prelude should not run partition grants once per identity')
      assert(!prelude.include?('printf \'%s\\n\' "${identities}" | while'), 'wrapper prelude should not pipe identities into a partition grant loop')
      true
    end

    test('release.sh repairs stale editable ASC lanes before version-state preflight') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      repair_index = release_script.index('--repair-version-state')
      preflight_index = release_script.index('--preflight-version-state')

      assert(!repair_index.nil?, 'expected release.sh to request ASC lane repair before preflight')
      assert(!preflight_index.nil?, 'expected release.sh to run ASC version-state preflight')
      assert(repair_index < preflight_index, 'expected ASC repair flag before preflight flag')
      true
    end

    test('release.sh commits website metadata pages alongside appcast updates') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, '"docs/index.html"')
      assert_includes(release_script, '"docs/download.html"')
      assert_includes(release_script, '"website/index.html"')
      assert_includes(release_script, '"website/download.html"')
      assert_includes(release_script, '"docs/_redirects"')
      assert_includes(release_script, '"website/_redirects"')
      assert_includes(release_script, 'REDIRECTS_FILE="${SITE_DIR}/_redirects"')
      assert_includes(release_script, 'download redirect(s) in $(basename "${SITE_DIR}")/_redirects')
      assert_includes(release_script, 'sync release metadata for v${VERSION}')
      ship_guard = File.read(File.expand_path('../hooks/sane_ship_guard.rb', __dir__))
      assert_includes(ship_guard, "path == 'docs/appcast.xml' || path == 'docs/_redirects' || path.end_with?('/appcast.xml')")
      true
    end

    test('release.sh accepts websites that route downloads through /download') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'local download_page_url="https://${SITE_HOST}/download"')
      assert_includes(release_script, 'local homepage_download_ver=""')
      assert_includes(release_script, 'Website download link points to v${homepage_download_ver}, expected v${VERSION}: ${site_url}')
      assert_includes(release_script, 'Website download flow verified via ${download_page_url}: ${expected_download_url}')
      true
    end

    test('release.sh verifies appcast manual download links during website deploys') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'appcast_link_for_version()')
      assert_includes(release_script, 'verify_local_appcast_link_route()')
      assert_includes(release_script, 'verify_live_appcast_link_route()')
      assert_includes(release_script, 'Website-only deploy blocked: appcast link ${appcast_link} has no local route')
      assert_includes(release_script, 'Live appcast manual download link')
      assert_includes(release_script, 'Appcast manual download link')
      true
    end

    test('release.sh falls back to a clean webhook clone when the local worker checkout is dirty or behind') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'resolve_release_webhook_checkout()')
      assert_includes(release_script, 'using a clean temporary clone for webhook release sync')
      assert_includes(release_script, 'git clone --no-checkout "${remote_url}" "${clean_repo}"')
      assert_includes(release_script, 'WEBHOOK_WORK_DIR="${clean_repo}"')
      assert(!release_script.include?('Refusing to deploy a mixed Worker checkout.'),
             'expected the old hard stop on dirty sane-email-automation checkout to be removed')
      true
    end
  end

  test_category('Release gate fixtures') do
    test('finds app-specific gate fixtures in the SaneProcess fixture registry') do
      Dir.mktmpdir('release-gates-') do |dir|
        fixtures_dir = File.join(dir, 'test', 'fixtures', 'gates')
        FileUtils.mkdir_p(fixtures_dir)
        File.write(
          File.join(fixtures_dir, 'sanebar_icon_visibility_drag.json'),
          JSON.generate(
            'rules' => [
              {
                'id' => 'sanebar-icon',
                'trigger' => 'SaneBar icon visibility drag',
                'seed' => 'SaneBar icon visibility drag regressed',
                'block' => ['Release SaneBar icon visibility drag without coverage'],
                'allow' => ['Release SaneClip listing update']
              }
            ]
          )
        )
        File.write(File.join(fixtures_dir, 'saneclip_listing.json'), '{}')
        subject.saneprocess_repo_root = dir

        paths = subject.send(:release_gate_fixture_paths, 'SaneBar')
        reports = subject.send(:release_gate_fixture_reports, 'SaneBar')

        assert_eq(paths.length, 1)
        assert(paths.first.end_with?('sanebar_icon_visibility_drag.json'))
        assert_eq(reports.length, 1)
        assert(reports.first[:passed], "expected fixture to pass: #{reports.first.inspect}")
      end
      true
    end

    test('reports malformed app-specific gate fixtures as failed release evidence') do
      Dir.mktmpdir('release-gates-bad-') do |dir|
        fixtures_dir = File.join(dir, 'test', 'fixtures', 'gates')
        FileUtils.mkdir_p(fixtures_dir)
        File.write(File.join(fixtures_dir, 'sanebar_bad.json'), '{"rules": [')
        subject.saneprocess_repo_root = dir

        reports = subject.send(:release_gate_fixture_reports, 'SaneBar')

        assert_eq(reports.length, 1)
        assert_eq(reports.first[:passed], false)
      end
      true
    end
  end

  test_category('Artifact marker detection') do
    test('detects donation and support markers in App Store artifacts') do
      hits = subject.send(
        :appstore_donation_markers,
        "Sponsor on GitHub\nSupport independent development\nBTC"
      )

      assert_includes(hits, 'GitHub Sponsors link/copy')
      assert_includes(hits, 'supporter appeal copy')
      assert_includes(hits, 'crypto donation copy')
      true
    end

    test('detects outside-update markers in App Store artifacts') do
      hits = subject.send(
        :appstore_update_markers,
        strings_out: "SaneSparkleRow\nCheck for updates automatically\nSoftware Updates\nUpdateService",
        otool_out: "@rpath/Sparkle.framework/Versions/B/Sparkle"
      )

      assert_includes(hits, 'Sparkle framework linkage')
      assert_includes(hits, 'Sparkle settings UI')
      assert_includes(hits, 'updater service type')
      true
    end

    test('ignores generic updater copy without a real updater signal') do
      hits = subject.send(
        :appstore_update_markers,
        strings_out: "SaneSparkleRow\nCheck for updates automatically\nCheck for updates right now\nSoftware Updates",
        otool_out: ''
      )

      assert_eq(hits, [])
      true
    end

    test('detects direct purchase markers in App Store artifacts') do
      hits = subject.send(
        :appstore_direct_purchase_markers,
        "Use Purchase Key\nActivation Code\nhttps://go.saneapps.com/buy/saneclick"
      )

      assert_includes(hits, 'website checkout URL')
      assert_includes(hits, 'purchase key entry copy')
      true
    end

    test('ignores generic license-key copy when StoreKit unlock is configured') do
      hits = subject.send(
        :appstore_direct_purchase_markers,
        "Enter License Key\nLicense",
        built_product_id: 'com.example.unlock'
      )

      assert_eq(hits, [])
      true
    end

    test('warns when watch marketing icon edges are too dark') do
      subject.define_singleton_method(:image_edge_luminance_report) do |_path|
        {
          'average_edge_luminance' => 18.0,
          'min_edge_luminance' => 4.0
        }
      end

      warning = subject.send(:watch_marketing_icon_warning, '/tmp/watch-marketing-1024.png')

      assert_includes(warning, 'Watch marketing icon edges are very dark')
      true
    end
  end

  test_category('Appcast guardrails') do
    test('flags informational appcast entries that cannot route to a manual download page') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_links, xml)

      assert_eq(hits, ['2.2.12'])
      true
    end

    test('accepts informational appcast entries that include a manual download link') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_links, xml)

      assert_eq(hits, [])
      true
    end

    test('flags informational appcast entries that omit a Sparkle build version') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:shortVersionString>2.2.12</sparkle:shortVersionString>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2208</sparkle:belowVersion>
            </sparkle:informationalUpdate>
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_versions, xml)

      assert_eq(hits, ['2.2.12'])
      true
    end

    test('accepts informational appcast entries that include top-level Sparkle versions') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:version>2212</sparkle:version>
            <sparkle:shortVersionString>2.2.12</sparkle:shortVersionString>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2208</sparkle:belowVersion>
            </sparkle:informationalUpdate>
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_versions, xml)

      assert_eq(hits, [])
      true
    end

    test('flags informational appcast entries that compare display versions against numeric build versions') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_mismatched_constraint_versions, xml)

      assert_eq(hits, ['2.2.12'])
      true
    end

    test('accepts informational appcast entries that compare against numeric build cutoffs') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2208</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_mismatched_constraint_versions, xml)

      assert_eq(hits, [])
      true
    end
  end

  test_category('Provisioning profile installer') do
    test('keeps the newest duplicate download and installs it by UUID') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(downloads_dir)

        older = File.join(downloads_dir, 'SaneClick_Mac_App_Store.provisionprofile')
        newer = File.join(downloads_dir, 'SaneClick_Mac_App_Store-2.provisionprofile')
        File.write(older, 'older')
        File.write(newer, 'newer')
        File.utime(Time.now - 60, Time.now - 60, older)
        File.utime(Time.now, Time.now, newer)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          {
            'Name' => 'SaneClick Mac App Store',
            'UUID' => (path.end_with?('-2.provisionprofile') || path.include?('uuid-new')) ? 'uuid-new' : 'uuid-old'
          }
        end

        results = subject.send(
          :install_provisioning_profiles,
          [older, newer],
          remove_source: false,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        installed = results.find { |result| !result[:skipped] }
        skipped = results.find { |result| result[:skipped] }

        assert_eq(installed[:uuid], 'uuid-new')
        assert_eq(installed[:ok], true)
        assert(File.exist?(File.join(xcode_dir, 'uuid-new.provisionprofile')))
        assert_eq(skipped[:reason], 'older duplicate download')
      end
      true
    end

    test('removes skipped duplicate downloads when delete-source is enabled') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(downloads_dir)

        older = File.join(downloads_dir, 'SaneClick_Finder_Sync_Mac_App_Store.provisionprofile')
        newer = File.join(downloads_dir, 'SaneClick_Finder_Sync_Mac_App_Store-2.provisionprofile')
        File.write(older, 'older')
        File.write(newer, 'newer')
        File.utime(Time.now - 60, Time.now - 60, older)
        File.utime(Time.now, Time.now, newer)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          {
            'Name' => 'SaneClick Finder Sync Mac App Store',
            'UUID' => (path.end_with?('-2.provisionprofile') || path.include?('uuid-new')) ? 'uuid-new' : 'uuid-old'
          }
        end

        results = subject.send(
          :install_provisioning_profiles,
          [older, newer],
          remove_source: true,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        skipped = results.find { |result| result[:skipped] }
        installed = results.find { |result| !result[:skipped] }

        assert(!File.exist?(older), 'expected skipped duplicate source to be deleted')
        assert(!File.exist?(newer), 'expected installed source to be deleted')
        assert_eq(skipped[:removed_source], true)
        assert_eq(installed[:removed_source], true)
      end
      true
    end

    test('breaks duplicate ties by the newer profile lifetime instead of filesystem order') do
      Dir.mktmpdir do |dir|
        first = File.join(dir, 'A-SaneClip.mobileprovision')
        second = File.join(dir, 'B-SaneClip.mobileprovision')
        File.write(first, 'first')
        File.write(second, 'second')
        same_time = Time.now
        File.utime(same_time, same_time, first)
        File.utime(same_time, same_time, second)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.end_with?('A-SaneClip.mobileprovision')
            {
              'Name' => 'SaneClip iOS App Store',
              'UUID' => 'uuid-old',
              'CreationDate' => '2026-04-01 12:00:00 +0000',
              'ExpirationDate' => '2026-04-15 12:00:00 +0000'
            }
          else
            {
              'Name' => 'SaneClip iOS App Store',
              'UUID' => 'uuid-new',
              'CreationDate' => '2026-04-02 12:00:00 +0000',
              'ExpirationDate' => '2026-05-15 12:00:00 +0000'
            }
          end
        end

        selection = subject.send(:canonicalize_provisioning_profile_inputs, [first, second])

        assert_eq(selection[:chosen].length, 1)
        assert_eq(selection[:chosen].first[:uuid], 'uuid-new')
        assert_eq(selection[:skipped].first[:uuid], 'uuid-old')
      end
      true
    end

    test('prefers Apple Distribution app store profiles over stale 3rd party profiles with the same name') do
      Dir.mktmpdir do |dir|
        legacy = File.join(dir, 'SaneClick_Finder_Sync_Mac_App_Store.provisionprofile')
        modern = File.join(dir, 'SaneClick_Finder_Sync_Mac_App_Store-2.provisionprofile')
        File.write(legacy, 'legacy')
        File.write(modern, 'modern')
        same_time = Time.now
        File.utime(same_time, same_time, legacy)
        File.utime(same_time, same_time, modern)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.end_with?('-2.provisionprofile')
            {
              'Name' => 'SaneClick Finder Sync Mac App Store',
              'UUID' => 'uuid-modern',
              'CreationDate' => '2026-04-03 19:06:58 +0000',
              'ExpirationDate' => '2027-03-09 21:13:27 +0000',
              'DeveloperCertificates' => [{ 'CommonName' => 'Apple Distribution: Stephan Joseph (M78L6FXD48)' }]
            }
          else
            {
              'Name' => 'SaneClick Finder Sync Mac App Store',
              'UUID' => 'uuid-legacy',
              'CreationDate' => '2026-03-26 17:29:29 +0000',
              'ExpirationDate' => '2027-03-09 21:17:04 +0000',
              'DeveloperCertificates' => [{ 'CommonName' => '3rd Party Mac Developer Application: Stephan Joseph (M78L6FXD48)' }]
            }
          end
        end

        selection = subject.send(:canonicalize_provisioning_profile_inputs, [legacy, modern])

        assert_eq(selection[:chosen].length, 1)
        assert_eq(selection[:chosen].first[:uuid], 'uuid-modern')
        assert_eq(selection[:skipped].first[:uuid], 'uuid-legacy')
      end
      true
    end

    test('removes stale installed copies with the same name before copying the new profile') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(mobile_dir)
        FileUtils.mkdir_p(downloads_dir)

        stale = File.join(mobile_dir, 'uuid-old.mobileprovision')
        fresh = File.join(downloads_dir, 'SaneClip_iOS_App_Store.mobileprovision')
        File.write(stale, 'stale')
        File.write(fresh, 'fresh')

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.include?('uuid-old')
            { 'Name' => 'SaneClip iOS App Store', 'UUID' => 'uuid-old' }
          else
            { 'Name' => 'SaneClip iOS App Store', 'UUID' => 'uuid-new' }
          end
        end

        results = subject.send(
          :install_provisioning_profiles,
          [fresh],
          remove_source: true,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        installed = results.find { |result| result[:ok] && !result[:skipped] }
        assert(!File.exist?(stale), 'expected stale installed profile to be removed')
        assert(File.exist?(File.join(mobile_dir, 'uuid-new.mobileprovision')))
        assert(!File.exist?(fresh), 'expected source download to be deleted after successful install')
        assert_includes(installed[:removed_existing], stale)
      end
      true
    end
  end

  test_category('App Store target graph audit') do
    test('fails when the App Store scheme reuses the direct macOS target') do
      manifest = {
        'schemes' => {
          'SaneClick' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } },
          'SaneClick-AppStore' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } }
        },
        'targets' => {
          'SaneClick' => {
            'type' => 'application',
            'platform' => 'macOS',
            'dependencies' => [{ 'package' => 'Sparkle' }]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneClick',
        appstore_scheme: 'SaneClick-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store scheme SaneClick-AppStore reuses direct application target(s): SaneClick')
      assert_includes(hits, 'App Store target SaneClick still links Sparkle at the target graph level')
      true
    end

    test('fails when the App Store target still relies on strip scripts or Sparkle plist keys') do
      manifest = {
        'schemes' => {
          'SaneSales' => { 'build' => { 'targets' => { 'SaneSales' => 'all' } } },
          'SaneSales-AppStore' => { 'build' => { 'targets' => { 'SaneSalesAppStore' => 'all' } } }
        },
        'targets' => {
          'SaneSales' => {
            'type' => 'application',
            'platform' => 'macOS'
          },
          'SaneSalesAppStore' => {
            'type' => 'application',
            'platform' => 'macOS',
            'info' => { 'properties' => { 'SUFeedURL' => 'https://example.com/appcast.xml' } },
            'postBuildScripts' => [
              { 'name' => 'Strip Sparkle for App Store', 'script' => 'ruby weaken_sparkle.rb "$APP_BINARY"' }
            ]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneSales',
        appstore_scheme: 'SaneSales-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store target SaneSalesAppStore still declares Sparkle Info.plist keys (SUFeedURL)')
      assert_includes(hits, 'App Store target SaneSalesAppStore still relies on Sparkle strip/weaken scripts')
      true
    end
  end

  test_category('Reviewer IAP path guardrails') do
    test('accepts FOUND from Safari probe even if Safari exits non-zero') do
      subject.stub_osascript_jxa("FOUND\nERROR:Error: Can't convert types.\n", success: false)

      found = subject.send(
        :appstore_version_ui_includes_iap?,
        app_id: '123',
        platform: 'macos',
        product_id: 'com.example.unlock'
      )

      assert_eq(found, true)
      true
    end

    test('scopes Safari IAP probe to the requested platform version page URL') do
      subject.stub_osascript_jxa("MISSING\n", success: true)

      subject.send(
        :appstore_version_ui_includes_iap?,
        app_id: '123',
        platform: 'macos',
        product_id: 'com.example.unlock'
      )

      assert_includes(subject.last_jxa_script, 'location.href')
      assert_includes(subject.last_jxa_script, 'https://appstoreconnect.apple.com/apps/123/distribution/macos/version/inflight')
      true
    end

    test('fails when review notes do not tell App Review where to find Pro') do
      report = subject.send(
        :reviewer_access_guardrail_report,
        source_blob: {
          'all' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n",
          'macos' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        },
        appstore_config: {
          'review_notes' => 'Basic is free. Pro is a one-time in-app purchase. No external checkout or license keys.'
        },
        platforms: ['macos']
      )

      assert_includes(
        report[:issues],
        '[macos] Review notes do not tell App Review where to find the optional Pro unlock (for example Settings > License or another visible Unlock Pro path)'
      )
      assert_includes(
        report[:warnings],
        '[macos] Onboarding paywall appears one-shot in code, but review notes do not mention a durable post-onboarding upgrade path like Settings > License'
      )
      true
    end

    test('fails when review notes mention Settings > License but source has no license surface') do
      report = subject.send(
        :reviewer_access_guardrail_report,
        source_blob: {
          'all' => "import Foundation\nfinal class LicenseService {}\nfunc purchasePro() {}\n",
          'ios' => "import Foundation\nfinal class LicenseService {}\nfunc purchasePro() {}\n"
        },
        appstore_config: {
          'review_notes_by_platform' => {
            'ios' => 'Basic is free. Unlock Pro is optional. Open Settings > License and tap Unlock Pro. No external checkout or license keys.'
          }
        },
        platforms: ['ios']
      )

      assert_includes(
        report[:issues],
        '[ios] Review notes mention a License screen/section, but no License surface exists in the ios source'
      )
      true
    end

  end

  test_category('ASC version lane guardrails') do
    test('fails when a different editable ASC lane exists for the platform') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-1', 'attributes' => { 'versionString' => '1.2.2', 'appStoreState' => 'REJECTED' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '1.2.3'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], 'conflict: 1.2.2 (REJECTED)')
      assert_includes(
        report[:issues],
        'App Store Connect has editable macos lane(s) 1.2.2 (REJECTED), but local target is 1.2.3. Retarget or clear that lane before submission.'
      )
      true
    end

    test('passes when the target ASC lane already matches the local version') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=IOS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-2', 'attributes' => { 'versionString' => '2.0.0', 'appStoreState' => 'READY_FOR_REVIEW' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'ios',
        version_string: '2.0.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '2.0.0 (READY_FOR_REVIEW)')
      assert_eq(report[:issues], [])
      true
    end

    test('fails when the local version already exists in a final ASC state') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-3', 'attributes' => { 'versionString' => '3.1.0', 'appStoreState' => 'READY_FOR_SALE' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '3.1.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '3.1.0 (READY_FOR_SALE)')
      assert_includes(
        report[:issues],
        'App Store Connect already has macos version 3.1.0 in final state READY_FOR_SALE — bump MARKETING_VERSION before submission.'
      )
      true
    end

    test('fails when ASC Game Center is enabled but the iOS build has no entitlement') do
      subject.stub_asc_json(
        '/apps/game-center-app/appStoreVersions?filter[platform]=IOS&limit=200',
        {
          'data' => [
            { 'id' => 'ios-version-1', 'attributes' => { 'versionString' => '1.0', 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }
          ]
        }
      )
      subject.stub_asc_json(
        '/appStoreVersions/ios-version-1/gameCenterAppVersion',
        {
          'data' => {
            'id' => 'gc-version-1',
            'type' => 'gameCenterAppVersions',
            'attributes' => { 'enabled' => true }
          }
        }
      )

      report = subject.send(
        :asc_game_center_guardrail_report,
        app_id: 'game-center-app',
        platform: 'ios',
        version_string: '1.0',
        entitlement_paths: [],
        project_yml_content: ''
      )

      assert(report[:applicable], 'expected Game Center report to apply')
      assert_eq(report[:summary], 'enabled in ASC')
      assert_includes(
        report[:issues],
        'App Store Connect Game Center is enabled for this iOS version, but the build has no com.apple.developer.game-center entitlement.'
      )
      true
    end

    test('passes when ASC Game Center is disabled for a non-game iOS app') do
      subject.stub_asc_json(
        '/apps/non-game-app/appStoreVersions?filter[platform]=IOS&limit=200',
        {
          'data' => [
            { 'id' => 'ios-version-2', 'attributes' => { 'versionString' => '1.0', 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }
          ]
        }
      )
      subject.stub_asc_json(
        '/appStoreVersions/ios-version-2/gameCenterAppVersion',
        {
          'data' => {
            'id' => 'gc-version-2',
            'type' => 'gameCenterAppVersions',
            'attributes' => { 'enabled' => false }
          }
        }
      )

      report = subject.send(
        :asc_game_center_guardrail_report,
        app_id: 'non-game-app',
        platform: 'ios',
        version_string: '1.0',
        entitlement_paths: [],
        project_yml_content: ''
      )

      assert(report[:applicable], 'expected Game Center report to apply')
      assert_eq(report[:summary], 'disabled in ASC')
      assert_eq(report[:issues], [])
      true
    end
  end

  test_category('macOS App Store signing audit') do
    test('ignores test bundles when collecting macOS App Store signing targets') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          targets:
            MainApp:
              type: application
              platform: macOS
              bundleId: com.example.app
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "Apple Distribution"
            MainAppTests:
              type: bundle.unit-test
              platform: macOS
              bundleId: com.example.appTests
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "-"
        YAML

        targets = subject.send(:appstore_macos_signing_targets, project_yml)

        assert_eq(targets.length, 1)
        assert_eq(targets.first[:name], 'MainApp')
      end
      true
    end
  end

  test_category('Verify output parsing') do
    test('does not treat mixed pass and failure output as a release-safe success') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
        /tmp/SaneVideoTests.swift:42: error: -[SaneVideoTests.ExampleTests testExample] : XCTAssertTrue failed
        ** TEST FAILED **
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'expected failure markers to be detected')
      assert(!subject.send(:verify_output_indicates_success?, body), 'mixed output must not be treated as success')
      true
    end

    test('accepts a clean Swift Testing summary when no failure markers are present') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'clean output should not report failure')
      assert(subject.send(:verify_output_indicates_success?, body), 'clean output should still count as success')
      true
    end

    test('accepts verify clean-pass override even when raw runner failure markers are present') do
      body = <<~LOG
        ** TEST FAILED **
        ✅ 7 targets (clean pass despite a non-zero runner exit)
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detectable')
      assert(subject.send(:verify_output_indicates_success?, body), 'clean-pass override should win for release preflight parsing')
      true
    end

    test('treats auto-dedupe-only verify output as release-safe cleanup') do
      body = <<~LOG
        🧹 Auto-deduping runtime app copies for SaneBar...
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
            - /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'dedupe cleanup should not look like a test failure')
      assert(subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'dedupe-only cleanup should count as release-safe cleanup')
      true
    end

    test('does not treat mixed test failure plus dedupe cleanup as release-safe cleanup') do
      body = <<~LOG
        ** TEST FAILED **
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detected')
      assert(!subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'real test failures must not be treated as dedupe-only cleanup')
      true
    end
  end
end)
