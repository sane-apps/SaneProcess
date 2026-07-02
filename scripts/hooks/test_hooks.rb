#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Hook System Integration Tests
# ==============================================================================
# Comprehensive tests for the consolidated hook architecture.
# Run: ruby scripts/hooks/test_hooks.rb
# ==============================================================================

require 'json'
require 'open3'
require 'fileutils'
require 'time'
require_relative 'self_test_environment'

PROJECT_DIR = SelfTestEnvironment.create_project('hook-system-tests')
ENV['CLAUDE_PROJECT_DIR'] = PROJECT_DIR
ENV['CLAUDE_HOOK_SECRET'] ||= 'hook-system-tests-secret'
ENV['SANEMASTER_PROCESS_METRICS_PATH'] = File.join(PROJECT_DIR, '.sanemaster', 'process_metrics.jsonl')

at_exit { FileUtils.rm_rf(PROJECT_DIR) if File.exist?(PROJECT_DIR) }

class HookTests
  attr_reader :passed, :failed, :results

  def initialize
    @passed = 0
    @failed = 0
    @results = []
  end

  def run_all
    puts "=" * 60
    puts "HOOK SYSTEM INTEGRATION TESTS"
    puts "=" * 60
    puts

    # Test StateManager
    test_group("StateManager") do
      test("get/set basic values") { test_state_get_set }
      test("update with block") { test_state_update }
      test("reset section") { test_state_reset }
      test("preserves sections on reset_except") { test_state_reset_except }
      test("non-ASCII state survives locale-less read") { test_state_non_ascii_locale }
    end

    # UTF-8 pinned File.read sites (2026-06-11 encoding audit). These fail
    # SILENTLY without the encoding pin: rescue blocks swallow the parse error
    # and return empty data instead of crashing.
    test_group("UTF-8 Pinned Reads") do
      test("non-ASCII visual receipt survives locale-less read") { test_visual_receipt_non_ascii_locale }
      test("non-ASCII learnings survive locale-less read") { test_learnings_non_ascii_locale }
    end

    # Umbrella-session artifact discovery + transcript project resolution
    test_group("Umbrella Session Fixes") do
      test("visual receipt discovered inside apps/<App>/outputs") { test_visual_receipt_umbrella_discovery }
      test("LS staging resolves --project \$PWD from the command's cd") { test_lemonsqueezy_project_resolution_from_transcript }
    end

    # Blocked-path enforcement through the real sanetools entry point
    test_group("Blocked Paths (entry point)") do
      test("PathDetector blocks ~/.ssh") { test_path_blocks_ssh }
      test("PathDetector blocks /etc") { test_path_blocks_etc }
      test("PathDetector allows project paths") { test_path_allows_project }
      test("PathDetector allows /tmp") { test_path_allows_tmp }
    end

    # Research/bootstrap allowances + Mini-first local-UI blocks (entry point)
    test_group("Entry-Point Enforcement") do
      test("allows research tools") { test_coordinator_allows_research }
      test("blocks dangerous paths on research") { test_coordinator_blocks_dangerous }
      test("startup Bash allowed") { test_coordinator_allows_bootstrap }
      test("blocks local computer-use on MacBook Air") { test_coordinator_blocks_local_computer_use }
      test("blocks hyphen-named computer-use MCP on Air") { test_blocks_hyphen_computer_use }
      test("allows computer-use on Mac Mini") { test_coordinator_allows_mini_computer_use }
    end

    # Test Entry Points
    test_group("Entry Points") do
      test("sanetools.rb syntax valid") { test_entry_syntax('sanetools.rb') }
      test("sanetrack.rb syntax valid") { test_entry_syntax('sanetrack.rb') }
      test("session_start.rb syntax valid") { test_entry_syntax('session_start.rb') }
      test("sanetools_refusal.rb syntax valid") { test_entry_syntax('sanetools_refusal.rb') }
      test("run_hook.sh syntax valid") { test_shell_entry_syntax('run_hook.sh') }
      test("settings use compact hook wrapper") { test_settings_use_hook_wrapper }
    end

    # Test Circuit Breaker
    test_group("Circuit Breaker") do
      test("tracks blocks") { test_circuit_breaker_tracks }
      test("halts after 2x same") { test_circuit_breaker_halts }
    end

    # Summary
    puts
    puts "=" * 60
    puts "RESULTS: #{@passed} passed, #{@failed} failed"
    puts "=" * 60

    @failed == 0
  end

  private

  def test_group(name)
    puts "\n#{name}:"
    puts "-" * 40
    yield
  end

  def test(name)
    result = yield
    if result
      @passed += 1
      puts "  ✅ #{name}"
      @results << { name: name, status: :pass }
    else
      @failed += 1
      puts "  ❌ #{name}"
      @results << { name: name, status: :fail }
    end
  rescue StandardError => e
    @failed += 1
    puts "  ❌ #{name} - #{e.message}"
    @results << { name: name, status: :error, error: e.message }
  end

  # StateManager tests
  def test_state_get_set
    require_relative 'core/state_manager'
    StateManager.reset_all
    StateManager.set(:requirements, :requested, ['saneloop'])
    StateManager.get(:requirements, :requested) == ['saneloop']
  end

  def test_state_update
    require_relative 'core/state_manager'
    StateManager.reset(:edits)
    StateManager.update(:edits) do |e|
      e[:count] = 5
      e
    end
    StateManager.get(:edits, :count) == 5
  end

  def test_state_reset
    require_relative 'core/state_manager'
    StateManager.set(:requirements, :requested, ['test'])
    StateManager.reset(:requirements)
    req = StateManager.get(:requirements, :requested)
    req.nil? || req.empty?
  end

  def test_state_reset_except
    require_relative 'core/state_manager'
    StateManager.set(:enforcement, :halted, true)
    StateManager.set(:requirements, :requested, ['test'])
    StateManager.reset_except(:enforcement)
    req = StateManager.get(:requirements, :requested)
    halted = StateManager.get(:enforcement, :halted)
    (req.nil? || req.empty?) && halted == true
  end

  # Regression: a block reason containing non-ASCII (e.g. an em-dash) used to
  # fail signature verification when the reading process had no UTF-8 locale,
  # silently resetting ALL enforcement state (breaker counts, gate, research).
  def test_state_non_ascii_locale
    require_relative 'core/state_manager'
    StateManager.reset_all
    StateManager.set(:startup_gate, :open, true)
    StateManager.update(:enforcement) do |e|
      e[:blocks] = [{ tool: 'Edit', rule: 'sensitive_file',
                      reason: 'SENSITIVE FILE — CONFIRM INTENT', timestamp: Time.now.iso8601 }]
      e
    end

    # Re-read the state in a subprocess forced to a US-ASCII default external
    # encoding, mimicking a hook invocation without LANG/LC_ALL set.
    script = 'require File.join(ENV["HOOKS_DIR"], "core/state_manager"); ' \
             'exit(StateManager.get(:startup_gate, :open) == true ? 0 : 1)'
    _out, _err, status = Open3.capture3(
      { 'HOOKS_DIR' => __dir__, 'CLAUDE_PROJECT_DIR' => ENV['CLAUDE_PROJECT_DIR'],
        'CLAUDE_HOOK_SECRET' => ENV['CLAUDE_HOOK_SECRET'], 'LANG' => 'C', 'LC_ALL' => 'C' },
      'ruby', '-E', 'US-ASCII', '-e', script
    )
    status.success?
  end

  # A receipt whose JSON contains non-ASCII must still validate when the
  # reading process has no UTF-8 locale. Without the encoding pin in
  # core/visual_receipt.rb, JSON.parse raises and the rescue silently
  # reports the receipt as invalid.
  def test_visual_receipt_non_ascii_locale
    require 'tmpdir'
    require 'time'
    Dir.mktmpdir('receipt-utf8-') do |dir|
      shot = File.join(dir, 'shot.png')
      File.write(shot, 'png')
      receipt_path = File.join(dir, 'outputs', 'customer_ui_action_receipt.json')
      FileUtils.mkdir_p(File.dirname(receipt_path))
      receipt = {
        'status' => 'passed',
        'host' => 'Mac Mini',
        'note' => 'verified — Settings → General',
        'generated_at' => Time.now.iso8601,
        'screenshots' => [shot]
      }
      File.write(receipt_path, JSON.generate(receipt), encoding: Encoding::UTF_8)

      script = 'require File.join(ENV["HOOKS_DIR"], "core/visual_receipt"); ' \
               'ok = SaneVisualReceipt.valid_receipt?(cwd: ENV["RECEIPT_CWD"], path: ENV["RECEIPT_PATH"], started_at: Time.at(0)); ' \
               'exit(ok ? 0 : 1)'
      _out, _err, status = Open3.capture3(
        { 'HOOKS_DIR' => __dir__, 'RECEIPT_CWD' => dir, 'RECEIPT_PATH' => receipt_path,
          'LANG' => 'C', 'LC_ALL' => 'C' },
        'ruby', '-E', 'US-ASCII', '-e', script
      )
      status.success?
    end
  end

  # `release.sh --project $PWD` reaches the transcript unexpanded; the LS
  # staging step must resolve it from the command's own `cd` (ssh-mini
  # pattern) or the entry cwd — never pass the literal `$PWD` through (that
  # produced the unusable "could not resolve version for $PWD" nag, hit live
  # 2026-07-02).
  def test_lemonsqueezy_project_resolution_from_transcript
    require 'tmpdir'
    Dir.mktmpdir('ls-transcript-') do |dir|
      transcript = File.join(dir, 'transcript.jsonl')
      ssh_cmd = %q{ssh mini 'cd ~/SaneApps/apps/FakeApp && ./scripts/release.sh --project $PWD --deploy'}
      entries = [
        { 'cwd' => '/Users/owner/SaneApps', 'command' => ssh_cmd },
        { 'cwd' => '/irrelevant', 'command' => 'echo release.sh mention without deploy' }
      ]
      File.write(transcript, entries.map { |e| JSON.generate(e) }.join("\n") + "\n", encoding: Encoding::UTF_8)

      script = 'require File.join(ENV["HOOKS_DIR"], "sanestop_lemonsqueezy"); ' \
               'project = LemonSqueezyUploads.detect_release_deploy_project(ENV["LS_TRANSCRIPT"]); ' \
               'exit(project == "~/SaneApps/apps/FakeApp" ? 0 : 1)'
      _out, _err, status = Open3.capture3(
        { 'HOOKS_DIR' => __dir__, 'LS_TRANSCRIPT' => transcript, 'LANG' => 'C', 'LC_ALL' => 'C' },
        'ruby', '-E', 'US-ASCII', '-e', script
      )
      status.success?
    end
  end

  # Umbrella sessions (cwd = ~/SaneApps) must discover receipts inside the
  # edited app repo (apps/<App>/outputs/visual-audit*/). Before the umbrella
  # glob, the Stop gate was unsatisfiable from an umbrella session even with a
  # valid receipt on disk (hit live 2026-07-02, SaneClip 2.3.12).
  def test_visual_receipt_umbrella_discovery
    require 'tmpdir'
    require 'time'
    Dir.mktmpdir('receipt-umbrella-') do |umbrella|
      audit_dir = File.join(umbrella, 'apps', 'FakeApp', 'outputs', 'visual-audit-fake')
      FileUtils.mkdir_p(audit_dir)
      shot = File.join(audit_dir, 'shot.png')
      File.write(shot, 'png')
      receipt = {
        'schema' => 'saneprocess.visual_audit',
        'type' => 'visual_audit',
        'status' => 'passed',
        'host' => 'Mac Mini',
        'inspected' => true,
        'generated_at' => Time.now.iso8601,
        'screenshots' => [shot]
      }
      File.write(File.join(audit_dir, 'receipt.json'), JSON.generate(receipt), encoding: Encoding::UTF_8)

      script = 'require File.join(ENV["HOOKS_DIR"], "core/visual_receipt"); ' \
               'paths = SaneVisualReceipt.valid_receipt_paths(cwd: ENV["RECEIPT_CWD"], candidate_paths: [], started_at: Time.at(0)); ' \
               'exit(paths.length == 1 ? 0 : 1)'
      _out, _err, status = Open3.capture3(
        { 'HOOKS_DIR' => __dir__, 'RECEIPT_CWD' => umbrella, 'LANG' => 'C', 'LC_ALL' => 'C' },
        'ruby', '-E', 'US-ASCII', '-e', script
      )
      status.success?
    end
  end

  # Session learnings routinely contain em dashes and arrows. Without the
  # encoding pin in session_briefing.rb, every line fails JSON.parse under a
  # US-ASCII default and the rescue silently returns zero learnings.
  def test_learnings_non_ascii_locale
    require 'tmpdir'
    Dir.mktmpdir('learnings-utf8-') do |home|
      FileUtils.mkdir_p(File.join(home, '.claude'))
      learning = { 'insight' => 'breaker tripped — root cause was «encoding»', 'score' => 9 }
      File.write(File.join(home, '.claude', 'session_learnings.jsonl'),
                 JSON.generate(learning) + "\n", encoding: Encoding::UTF_8)

      script = 'require File.join(ENV["HOOKS_DIR"], "session_briefing"); ' \
               'exit(load_recent_learnings.length == 1 ? 0 : 1)'
      _out, _err, status = Open3.capture3(
        { 'HOOKS_DIR' => __dir__, 'HOME' => home, 'LANG' => 'C', 'LC_ALL' => 'C' },
        'ruby', '-E', 'US-ASCII', '-e', script
      )
      status.success?
    end
  end

  # Blocked-path tests (using entry point)
  def test_path_blocks_ssh
    run_hook('Read', '~/.ssh/id_rsa') == 2
  end

  def test_path_blocks_etc
    run_hook('Read', '/etc/passwd') == 2
  end

  def test_path_allows_project
    run_hook('Read', File.join(File.realpath(PROJECT_DIR), 'README.md')) == 0
  end

  def test_path_allows_tmp
    run_hook('Read', '/tmp/test.txt') == 0
  end

  # Coordinator tests
  def test_coordinator_allows_research
    run_hook('Grep', '/tmp/test') == 0
  end

  def test_coordinator_blocks_dangerous
    run_hook('Read', '~/.aws/credentials') == 2
  end

  def test_coordinator_allows_bootstrap
    run_hook('Bash', 'ruby scripts/validation_report.rb', command: true) == 0
  end

  def test_coordinator_blocks_local_computer_use
    run_hook(
      'mcp__computer_use__get_app_state',
      'Safari',
      app: true,
      extra_env: { 'SANE_FORCE_MACBOOK_AIR_FOR_TEST' => '1' }
    ) == 2
  end

  # Live computer-use MCP tools are hyphen-named (mcp__computer-use__*); the
  # guard pattern must match both spellings or the Mini-first block never fires.
  def test_blocks_hyphen_computer_use
    run_hook(
      'mcp__computer-use__screenshot',
      'Safari',
      app: true,
      extra_env: { 'SANE_FORCE_MACBOOK_AIR_FOR_TEST' => '1' }
    ) == 2
  end

  def test_coordinator_allows_mini_computer_use
    run_hook(
      'mcp__computer_use__get_app_state',
      'Safari',
      app: true,
      extra_env: { 'SANE_FORCE_MAC_MINI_FOR_TEST' => '1' }
    ) == 0
  end

  # Entry point syntax tests
  def test_entry_syntax(file)
    path = File.join(__dir__, file)
    _, status = Open3.capture2e("ruby -c #{path}")
    status.success?
  end

  def test_shell_entry_syntax(file)
    path = File.join(__dir__, file)
    _, status = Open3.capture2e('bash', '-n', path)
    status.success?
  end

  def test_settings_use_hook_wrapper
    settings_path = File.expand_path('../../.claude/settings.json', __dir__)
    settings = JSON.parse(File.read(settings_path))
    commands = settings.fetch('hooks').values.flat_map do |groups|
      groups.flat_map { |group| group.fetch('hooks', []).map { |hook| hook['command'].to_s } }
    end
    wrapped = commands.select { |command| command.include?('run_hook.sh') }

    wrapped.length == 6 &&
      wrapped.all? { |command| command.length < 90 } &&
      commands.none? { |command| command.include?('if [ -n "${CLAUDECODE}${CLAUDE_CODE}" ]') }
  end

  # Circuit breaker tests
  def test_circuit_breaker_tracks
    require_relative 'core/state_manager'
    StateManager.reset(:enforcement)

    # Simulate a block
    StateManager.update(:enforcement) do |e|
      e[:blocks] ||= []
      e[:blocks] << { 'signature' => 'test:Detector', 'at' => Time.now.iso8601 }
      e
    end

    blocks = StateManager.get(:enforcement, :blocks)
    blocks.length == 1
  end

  def test_circuit_breaker_halts
    require_relative 'core/state_manager'
    StateManager.reset(:enforcement)

    # Add 2 identical blocks
    2.times do
      StateManager.update(:enforcement) do |e|
        e[:blocks] ||= []
        e[:blocks] << { 'signature' => 'same:Detector', 'at' => Time.now.iso8601 }

        # Check for halt condition
        recent = e[:blocks].last(2)
        if recent.length >= 2 && recent.all? { |b| (b['signature'] || b[:signature]) == 'same:Detector' }
          e[:halted] = true
        end
        e
      end
    end

    StateManager.get(:enforcement, :halted) == true
  end

  # Helper to run hook with input
  def run_hook(tool, path, command: false, app: false, extra_env: {})
    input = if command
              { 'tool_name' => tool, 'tool_input' => { 'command' => path } }
            elsif app
              { 'tool_name' => tool, 'tool_input' => { 'app' => path } }
            else
              { 'tool_name' => tool, 'tool_input' => { 'file_path' => path } }
            end

    hook_path = File.join(__dir__, 'sanetools.rb')

    stdout, stderr, status = Open3.capture3(
      { 'CLAUDE_PROJECT_DIR' => PROJECT_DIR }.merge(extra_env),
      'ruby', hook_path,
      chdir: PROJECT_DIR,
      stdin_data: JSON.generate(input)
    )

    status.exitstatus
  end
end

# Run tests
if __FILE__ == $PROGRAM_NAME
  tests = HookTests.new
  success = nil
  Dir.chdir(PROJECT_DIR) do
    success = tests.run_all
  end
  exit(success ? 0 : 1)
end
