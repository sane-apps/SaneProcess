#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
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

class ReleaseGuardrailHarness
  include SaneMasterModules::CustomerUIContract
  include SaneMasterModules::GateReview
  include SaneMasterModules::Release

  def initialize
    @stubbed_url_statuses = {}
    @stubbed_asc_paths = {}
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
          if cmd.include?('visual_smoke')
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

    test('release.sh does not hardcode SaneApps ASC credentials') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert(!release_script.include?('AuthKey_S34998ZCRT.p8'), 'release.sh should not hardcode the SaneApps key path')
      assert(!release_script.include?('ASC_AUTH_KEY_ID:-S34998ZCRT'), 'release.sh should not default to the SaneApps key id')
      assert(!release_script.include?('ASC_AUTH_ISSUER_ID:-c98b1e0a'), 'release.sh should not default to the SaneApps issuer id')
      assert_includes(release_script, 'App Store releases require ASC API credentials.')
      assert_includes(release_script, 'Set ASC_AUTH_KEY_PATH, ASC_AUTH_KEY_ID, ASC_AUTH_ISSUER_ID')
      true
    end

    test('release.sh commits website metadata pages alongside appcast updates') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, '"docs/index.html"')
      assert_includes(release_script, '"docs/download.html"')
      assert_includes(release_script, '"website/index.html"')
      assert_includes(release_script, '"website/download.html"')
      assert_includes(release_script, 'sync release metadata for v${VERSION}')
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
