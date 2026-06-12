#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneStop Test Suite
# ==============================================================================
# Extracted from sanestop.rb per Rule #10 (file size limit)
# Run: ruby sanestop.rb --self-test
# ==============================================================================

require 'stringio'
require 'tmpdir'
require 'json'
require 'time'
require 'digest'
require 'open3'
require 'fileutils'
require_relative 'core/state_manager'

module SaneStopTest
  def self.source_fingerprint
    root_out, root_status = Open3.capture2e('git', '-C', Dir.pwd, 'rev-parse', '--show-toplevel')
    return 'unknown' unless root_status.success?

    root = root_out.strip
    parts = []
    [
      %w[rev-parse HEAD],
      %w[status --porcelain=v1 --untracked-files=all],
      %w[diff --binary],
      %w[diff --cached --binary]
    ].each do |command|
      out, = Open3.capture2e('git', '-C', root, *command)
      parts << out
    end
    Digest::SHA256.hexdigest(parts.join("\n---\n"))
  end

  def self.write_verify_metric(path, success: true, tests_run: 12, timestamp: Time.now.utc.iso8601)
    File.write(path, JSON.generate(
      timestamp: timestamp,
      type: 'verify',
      success: success,
      tests_run: tests_run,
      evidence_strength: tests_run.to_i.positive? ? 'tested' : 'build_only',
      host: 'mini',
      source_fingerprint: source_fingerprint
    ) + "\n")
  end

  def self.run(process_stop_proc, check_score_variance_proc, check_weasel_words_proc, calculate_sop_score_proc, log_file)
    warn 'SaneStop Self-Test'
    warn '=' * 40

    # Reset state
    StateManager.reset(:edits)
    StateManager.reset(:research)
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:handoff_tracking)
    StateManager.reset(:visual_verification)

    passed = 0
    failed = 0

    # Test 1: No edits = no reminder
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: No edits -> allow stop'
    else
      failed += 1
      warn '  FAIL: Should allow stop with no edits'
    end

    # Test 2: With edits + NO verification = BLOCK (Rule #4)
    StateManager.update(:edits) do |e|
      e[:count] = 5
      e[:unique_files] = ['/a.swift', '/b.swift', '/c.swift']
      e
    end
    StateManager.reset(:verification)
    # Mark handoff as updated so handoff check doesn't interfere with Rule #4 test
    StateManager.update(:handoff_tracking) do |h|
      h[:handoff_updated] = true
      h[:memory_updated] = true
      h
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Edits without verification -> BLOCK (exit 2)'
    else
      failed += 1
      warn "  FAIL: Should block unverified edits, got exit #{exit_code}"
    end

    # Test 2b: With edits + structured verification metric = allow stop
    StateManager.update(:verification) do |v|
      v[:tests_run] = true
      v[:last_test_at] = Time.now.iso8601
      v[:test_commands] = ['xcodebuild test']
      v[:tests_passed] = true
      v[:verification_succeeded] = true
      v
    end

    Dir.mktmpdir('sanestop-strong-verify') do |tmpdir|
      old_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = File.join(tmpdir, 'process_metrics.jsonl')
      write_verify_metric(ENV['SANEMASTER_PROCESS_METRICS_PATH'])
      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false)
      $stderr.reopen(original_stderr)
    ensure
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics_path
    end

    if exit_code == 0
      passed += 1
      warn '  PASS: Edits with structured verification -> allow stop'
    else
      failed += 1
      warn "  FAIL: Verified edits should allow stop, got exit #{exit_code}"
    end

    # Test 2c: Doc-only edits = allow stop without verification
    StateManager.update(:edits) do |e|
      e[:count] = 2
      e[:unique_files] = ['/docs/README.md', '/CHANGELOG.md']
      e
    end
    StateManager.reset(:verification)
    StateManager.reset(:handoff_tracking)
    StateManager.reset(:visual_verification)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Doc-only edits -> allow stop without verification'
    else
      failed += 1
      warn "  FAIL: Doc-only edits should allow stop, got exit #{exit_code}"
    end

    # Test 3: stop_hook_active = skip processing
    exit_code = process_stop_proc.call(true)
    if exit_code == 0
      passed += 1
      warn '  PASS: stop_hook_active -> skip processing'
    else
      failed += 1
      warn '  FAIL: Should skip when stop_hook_active'
    end

    # Test 4: Session logging works
    if File.exist?(log_file)
      last_line = File.readlines(log_file).last
      entry = JSON.parse(last_line)
      if entry['edits'].is_a?(Integer)
        passed += 1
        warn '  PASS: Session logging'
      else
        failed += 1
        warn '  FAIL: Session logging incorrect'
      end
    else
      failed += 1
      warn '  FAIL: Log file not created'
    end

    # === SCORE VARIANCE DETECTION TESTS ===
    warn ''
    warn 'Testing score variance detection:'

    # Test: Low variance + high mean fires warning
    StateManager.update(:patterns) do |p|
      p[:session_scores] = [9, 9, 9, 9, 9, 9]
      p
    end
    original_stderr = $stderr.clone
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_score_variance_proc.call(9)
    $stderr = original_stderr
    if captured_stderr.string.include?('SCORE VARIANCE WARNING')
      passed += 1
      warn '  PASS: Score variance fires on suspicious consistency'
    else
      failed += 1
      warn '  FAIL: Score variance should warn on all-9s'
    end

    # Test: Normal variance passes silently
    StateManager.update(:patterns) do |p|
      p[:session_scores] = [6, 8, 7, 9, 5, 8]
      p
    end
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_score_variance_proc.call(7)
    $stderr = original_stderr
    if !captured_stderr.string.include?('SCORE VARIANCE WARNING')
      passed += 1
      warn '  PASS: Normal variance passes silently'
    else
      failed += 1
      warn '  FAIL: Normal variance should not warn'
    end

    Dir.mktmpdir('sanestop-metrics') do |tmpdir|
      old_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
      metrics_path = File.join(tmpdir, 'process_metrics.jsonl')
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = metrics_path
      StateManager.update(:enforcement) do |e|
        e[:session_started_at] = (Time.now - 60).iso8601
        e[:blocks] = []
        e
      end

      File.write(
        metrics_path,
        [
          { timestamp: (Time.now - 30).utc.iso8601, type: 'verify', success: false, tests_run: 0 },
          { timestamp: (Time.now - 20).utc.iso8601, type: 'verify', success: true, tests_run: 12 }
        ].map { |event| JSON.generate(event) }.join("\n") + "\n"
      )
      if calculate_sop_score_proc.call({}) == 8
        passed += 1
        warn '  PASS: Recovered verify failure caps SOP score at 8'
      else
        failed += 1
        warn '  FAIL: Recovered verify failure should cap SOP score at 8'
      end

      File.write(
        metrics_path,
        JSON.generate({ timestamp: (Time.now - 10).utc.iso8601, type: 'verify', success: false, tests_run: 7 }) + "\n"
      )
      if calculate_sop_score_proc.call({}) == 6
        passed += 1
        warn '  PASS: Unrecovered verify failure caps SOP score at 6'
      else
        failed += 1
        warn '  FAIL: Unrecovered verify failure should cap SOP score at 6'
      end

      File.write(
        metrics_path,
        JSON.generate({ timestamp: (Time.now - 5).utc.iso8601, type: 'verify', success: true, tests_run: 0, evidence_strength: 'build_only' }) + "\n"
      )
      if calculate_sop_score_proc.call({}) == 8
        passed += 1
        warn '  PASS: Green zero-test verify caps SOP score at 8'
      else
        failed += 1
        warn '  FAIL: Green zero-test verify should cap SOP score at 8'
      end
    ensure
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics_path
    end

    # === WEASEL WORD DETECTION TESTS ===
    warn ''
    warn 'Testing weasel word detection:'

    StateManager.update(:action_log) do |_|
      [
        { tool: 'Edit', input_summary: 'used tools to fix various issues', success: true },
        { tool: 'Edit', input_summary: 'made changes and followed process', success: true },
        { tool: 'Edit', input_summary: 'cleaned up some code etc', success: true }
      ]
    end
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_weasel_words_proc.call
    $stderr = original_stderr
    if captured_stderr.string.include?('WEASEL WORD WARNING')
      passed += 1
      warn '  PASS: Weasel word detection fires on vague language'
    else
      failed += 1
      warn '  FAIL: Weasel words should be detected'
    end

    # Cleanup
    StateManager.update(:action_log) { |_| [] }
    StateManager.update(:patterns) { |p| p[:session_scores] = []; p }

    # === HANDOFF ENFORCEMENT TESTS ===
    warn ''
    warn 'Testing handoff enforcement:'

    # Test: Significant edits without handoff update = BLOCK
    StateManager.reset(:edits)
    StateManager.reset(:verification)
    StateManager.reset(:handoff_tracking)
    StateManager.update(:handoff_tracking) do |h|
      h[:significant_edits] = 3
      h[:significant_files] = ['SKILL.md', 'sanetrack.rb', 'sanestop.rb']
      h[:handoff_updated] = false
      h[:memory_updated] = false
      h
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: Significant edits without handoff -> BLOCK (exit 2)'
    else
      failed += 1
      warn "  FAIL: Should block without handoff, got exit #{exit_code}"
    end

    # Test: Significant edits WITH handoff + memory = allow
    StateManager.reset(:verification)
    StateManager.update(:handoff_tracking) do |h|
      h[:significant_edits] = 3
      h[:significant_files] = ['SKILL.md', 'sanetrack.rb', 'sanestop.rb']
      h[:handoff_updated] = true
      h[:memory_updated] = true
      h
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Significant edits with handoff + memory -> allow'
    else
      failed += 1
      warn "  FAIL: Should allow with handoff+memory, got exit #{exit_code}"
    end

    # Test: Few edits (below threshold) without handoff = allow
    StateManager.reset(:handoff_tracking)
    StateManager.update(:handoff_tracking) do |h|
      h[:significant_edits] = 1
      h[:significant_files] = ['one_file.rb']
      h[:handoff_updated] = false
      h[:memory_updated] = false
      h
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Below-threshold edits without handoff -> allow'
    else
      failed += 1
      warn "  FAIL: Below threshold should allow, got exit #{exit_code}"
    end

    # Test: Always-persist file below threshold still blocks without handoff/memory
    StateManager.reset(:handoff_tracking)
    StateManager.update(:handoff_tracking) do |h|
      h[:significant_edits] = 1
      h[:significant_files] = ['sanestop.rb']
      h[:always_persist_required] = true
      h[:always_persist_files] = ['sanestop.rb']
      h[:handoff_updated] = false
      h[:memory_updated] = false
      h
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: Always-persist work blocks even below threshold'
    else
      failed += 1
      warn "  FAIL: Always-persist work should block, got exit #{exit_code}"
    end

    # Test: Always-persist file with handoff + memory allows stop
    StateManager.reset(:verification)
    StateManager.update(:handoff_tracking) do |h|
      h[:significant_edits] = 1
      h[:significant_files] = ['sanestop.rb']
      h[:always_persist_required] = true
      h[:always_persist_files] = ['sanestop.rb']
      h[:handoff_updated] = true
      h[:memory_updated] = true
      h
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Always-persist work allows stop after handoff + memory'
    else
      failed += 1
      warn "  FAIL: Always-persist work should allow with handoff+memory, got exit #{exit_code}"
    end

    # === TOOL DISCOVERY ENFORCEMENT TESTS ===
    warn ''
    warn 'Testing tool discovery enforcement:'

    StateManager.reset(:skill)
    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 0
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: docs_audit without subagents blocks stop'
    else
      failed += 1
      warn "  FAIL: docs_audit without subagents should block, got #{exit_code}"
    end

    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 0
      s[:runner_used] = true
      s[:runner_commands] = ['python3 scripts/automation/gpt_audit.py --title Test']
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: docs_audit runner-only path still blocks stop'
    else
      failed += 1
      warn "  FAIL: docs_audit runner-only path should block, got #{exit_code}"
    end

    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 5
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: docs_audit subagent swarm allows stop'
    else
      failed += 1
      warn "  FAIL: docs_audit subagent swarm should allow stop, got #{exit_code}"
    end

    # Regression: a valid runner receipt satisfies a runner-backed skill (status)
    # even when the Skill tool was never invoked — the startup gate routinely blocks
    # the Skill call, so `invoked` stays false. Without the fix this emits a false
    # "status ... was required but NOT invoked" warning.
    require 'stringio'
    StateManager.reset(:verification)
    StateManager.reset(:edits)
    StateManager.reset(:handoff_tracking)
    StateManager.reset(:visual_verification)
    StateManager.reset(:skill)
    StateManager.update(:skill) do |s|
      s[:required] = 'status'
      s[:invoked] = false
      s[:runner_used] = true
      s[:runner_proved] = true
      s[:subagents_spawned] = 0
      s[:runner_commands] = ['ruby scripts/SaneMaster.rb status']
      s
    end
    captured = StringIO.new
    real_stderr = $stderr
    $stderr = captured
    runner_exit = process_stop_proc.call(false)
    $stderr = real_stderr
    if runner_exit == 0 && !captured.string.include?('NOT invoked')
      passed += 1
      warn '  PASS: runner receipt satisfies status skill (no false not-invoked warning)'
    else
      failed += 1
      warn "  FAIL: runner-backed status warned not-invoked (exit=#{runner_exit}, warned=#{captured.string.include?('NOT invoked')})"
    end

    previous_audit_output_dir = ENV['SANE_AUDIT_OUTPUT_DIR']
    audit_root = Dir.mktmpdir('sane_audit_outputs_test')
    audit_output_dir = File.join(audit_root, 'sane_audit_outputs')
    ENV['SANE_AUDIT_OUTPUT_DIR'] = audit_output_dir
    FileUtils.mkdir_p(audit_output_dir)
    StateManager.update(:skill) do |s|
      s[:required] = 'sane_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 9
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: sane_audit missing summary blocks stop'
    else
      failed += 1
      warn "  FAIL: sane_audit missing summary should block, got #{exit_code}"
    end

    %w[
      q0-config.md
      q6-release.md
      q7-website.md
      q8-signing.md
      q9-support.md
      q10-docs.md
      q11-tooling.md
      q12-runtime-resources.md
      q13-historical-regression.md
    ].each do |file|
      File.write(
        "#{audit_output_dir}/#{file}",
        <<~MD
          # #{file}

          ## Score
          10/10

          ## Critical Issues
          None.

          ## Warnings
          None.

          ## Passed Checks
          - Check passed.

          ## Checked Evidence
          - Evidence checked.

          ## Summary
          This fixture is intentionally complete enough to satisfy the sane_audit
          structural gate. It proves the stop hook rejects placeholders while
          allowing a real report shape with the required audit sections.

          ## Residual Risk
          None for this test fixture.
        MD
      )
    end
    File.write(
      "#{audit_output_dir}/summary.md",
      <<~MD
        # Summary

        ## Per-Perspective Scores
        - q0-config.md: 10/10
        - q6-release.md: 10/10
        - q7-website.md: 10/10
        - q8-signing.md: 10/10
        - q9-support.md: 10/10
        - q10-docs.md: 10/10
        - q11-tooling.md: 10/10
        - q12-runtime-resources.md: 10/10
        - q13-historical-regression.md: 10/10

        ## Root-Cause Matrix
        | Issues | Root Cause | Current Coverage | Would Catch Today? |
        |--------|------------|------------------|--------------------|
        | #1 | Example | Named test | Yes |

        ## Checked Evidence
        - all sources checked
      MD
    )
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: sane_audit summary proof allows stop'
    else
      failed += 1
      warn "  FAIL: sane_audit summary proof should allow stop, got #{exit_code}"
    end
    ENV['SANE_AUDIT_OUTPUT_DIR'] = previous_audit_output_dir
    FileUtils.rm_rf(audit_root)

    StateManager.reset(:skill)
    StateManager.update(:skill) do |s|
      s[:required] = 'evolve'
      s[:required_prompt] = 'missing screenshot diff tool'
      s[:invoked] = true
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: Missing tool-discovery receipt blocks stop'
    else
      failed += 1
      warn "  FAIL: Missing tool-discovery receipt should block, got exit #{exit_code}"
    end

    StateManager.update(:skill) do |s|
      s[:required] = 'evolve'
      s[:required_prompt] = 'missing screenshot diff tool'
      s[:invoked] = true
      s[:runner_used] = true
      s[:runner_commands] = ['ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"']
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Tool-discovery receipt allows stop'
    else
      failed += 1
      warn "  FAIL: Tool-discovery receipt should allow stop, got exit #{exit_code}"
    end

    {
      'status' => 'ruby scripts/SaneMaster.rb status',
      'verify' => 'ruby scripts/SaneMaster.rb verify',
      'ship' => 'ruby scripts/SaneMaster.rb release_preflight',
      'check_inbox' => 'ruby scripts/SaneMaster.rb check_inbox'
    }.each do |workflow, runner_command|
      StateManager.reset(:skill)
      StateManager.update(:skill) do |s|
        s[:required] = workflow
        s[:required_prompt] = "workflow #{workflow}"
        s[:invoked] = true
        s[:runner_used] = false
        s[:runner_commands] = []
        s
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false)
      $stderr.reopen(original_stderr)
      if exit_code == 2
        passed += 1
        warn "  PASS: Missing #{workflow} runner proof blocks stop"
      else
        failed += 1
        warn "  FAIL: Missing #{workflow} runner proof should block stop, got #{exit_code}"
      end

      StateManager.update(:skill) do |s|
        s[:required] = workflow
        s[:required_prompt] = "workflow #{workflow}"
        s[:invoked] = true
        s[:runner_used] = true
        s[:runner_commands] = [runner_command]
        if workflow == 'ship'
          clearance_path = File.join(Dir.mktmpdir('ship-clearance-proof'), 'TestApp.json')
          File.write(clearance_path, '{}')
          s[:runner_proof] = { clearance_path: clearance_path }
        end
        s
      end
      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false)
      $stderr.reopen(original_stderr)
      if exit_code == 0
        passed += 1
        warn "  PASS: #{workflow} runner proof allows stop"
      else
        failed += 1
        warn "  FAIL: #{workflow} runner proof should allow stop, got #{exit_code}"
      end
    end

    # Cleanup
    StateManager.reset(:handoff_tracking)
    StateManager.reset(:skill)

    # === VISUAL VERIFICATION ENFORCEMENT TESTS ===
    warn ''
    warn 'Testing visual verification enforcement:'

    StateManager.reset(:edits)
    StateManager.reset(:verification)
    StateManager.reset(:handoff_tracking)
    StateManager.reset(:visual_verification)
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:reason] = 'prompt_requested_visual_verification'
      v[:required_files] = ['ContentView.swift']
      v
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: Missing visual screenshot audit blocks stop'
    else
      failed += 1
      warn "  FAIL: Missing visual screenshot audit should block, got #{exit_code}"
    end

    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:evidence_commands] = ['xcrun simctl io DEVICE screenshot outputs/visual-audit/01.png']
      v[:audit_recorded] = true
      v[:audit_files] = ['SESSION_HANDOFF.md']
      v
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 2
      passed += 1
      warn '  PASS: Loose visual state without structured receipt blocks stop'
    else
      failed += 1
      warn "  FAIL: Loose visual state without structured receipt should block stop, got #{exit_code}"
    end

    visual_dir = File.join(Dir.pwd, 'outputs', 'visual-audit-sanestop-test')
    FileUtils.mkdir_p(visual_dir)
    screenshot_path = File.join(visual_dir, 'screen.png')
    receipt_path = File.join(visual_dir, 'receipt.json')
    File.write(screenshot_path, "png fixture\n")
    File.write(
      receipt_path,
      JSON.pretty_generate(
        type: 'visual_audit',
        status: 'passed',
        host: 'mini',
        inspected: true,
        generated_at: Time.now.utc.iso8601,
        screenshots: [screenshot_path]
      )
    )
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:audit_files] = [receipt_path]
      v
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Structured visual receipt allows stop'
    else
      failed += 1
      warn "  FAIL: Structured visual receipt should allow stop, got #{exit_code}"
    end
    FileUtils.rm_rf(visual_dir)
    StateManager.reset(:visual_verification)

    # === Q4 VALIDATION: SESSION TRACKING TESTS ===
    warn ''
    warn 'Testing validation metrics (Q1/Q4):'

    # Reset for clean test
    StateManager.reset(:validation)
    StateManager.reset(:edits)
    StateManager.reset(:verification)
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:handoff_tracking)
    StateManager.update(:enforcement) { |e| e[:blocks] = []; e }
    ENV['SANEMASTER_PROCESS_METRICS_PATH'] ||= File.join(Dir.tmpdir, "sanestop-validation-#{$$}.jsonl")
    File.write(ENV['SANEMASTER_PROCESS_METRICS_PATH'], '')

    # Test: Session end increments sessions_total
    previous_client = ENV['SANE_AGENT_CLIENT']
    ENV['SANE_AGENT_CLIENT'] = 'codex'
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if previous_client
      ENV['SANE_AGENT_CLIENT'] = previous_client
    else
      ENV.delete('SANE_AGENT_CLIENT')
    end
    validation = StateManager.get(:validation)
    if validation[:sessions_total] == 1
      passed += 1
      warn '  PASS: sessions_total incremented on session end'
    else
      failed += 1
      warn "  FAIL: Expected sessions_total=1, got #{validation[:sessions_total]}"
    end
    rows = File.readlines(ENV['SANEMASTER_PROCESS_METRICS_PATH'], chomp: true).map { |line| JSON.parse(line) }
    session_receipt = rows.find { |row| row['type'] == 'session_receipt' }
    if session_receipt &&
       session_receipt['schema_version'] == 2 &&
       !session_receipt['session_id'].to_s.empty? &&
       session_receipt['client_kind'] == 'codex' &&
       !session_receipt['receipt_id'].to_s.empty? &&
       !session_receipt['host'].to_s.empty? &&
       !session_receipt['source_fingerprint'].to_s.empty? &&
       session_receipt.key?('duration_ms') &&
       session_receipt.key?('final_verify_success')
      passed += 1
      warn '  PASS: client-neutral session receipt recorded'
    else
      failed += 1
      warn '  FAIL: Expected client-neutral session_receipt metric with required fields'
    end

    # Test: Session with strong verify metric marks sessions_with_tests_passing
    StateManager.update(:verification) do |v|
      v[:tests_run] = true
      v[:tests_passed] = true
      v[:verification_succeeded] = true
      v[:last_test_at] = Time.now.iso8601
      v
    end
    write_verify_metric(ENV['SANEMASTER_PROCESS_METRICS_PATH'])
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    validation = StateManager.get(:validation)
    if validation[:sessions_with_tests_passing] == 1
      passed += 1
      warn '  PASS: sessions_with_tests_passing incremented when tests ran'
    else
      failed += 1
      warn "  FAIL: Expected sessions_with_tests_passing=1, got #{validation[:sessions_with_tests_passing]}"
    end

    # Test: Session with tripped breaker tracks sessions_with_breaker_trip
    StateManager.update(:circuit_breaker) do |cb|
      cb[:tripped] = true
      cb[:tripped_at] = Time.now.iso8601
      cb
    end
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    validation = StateManager.get(:validation)
    if validation[:sessions_with_breaker_trip] == 1
      passed += 1
      warn '  PASS: sessions_with_breaker_trip incremented'
    else
      failed += 1
      warn "  FAIL: Expected sessions_with_breaker_trip=1, got #{validation[:sessions_with_breaker_trip]}"
    end

    # Test: first_tracked and last_updated are set
    if validation[:first_tracked] && validation[:last_updated]
      passed += 1
      warn '  PASS: Timestamps set (first_tracked, last_updated)'
    else
      failed += 1
      warn "  FAIL: Timestamps missing: first=#{validation[:first_tracked]}, last=#{validation[:last_updated]}"
    end

    # Cleanup validation state
    StateManager.reset(:validation)
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:verification)

    # === JSON INTEGRATION TESTS ===
    warn ''
    warn 'Testing JSON parsing (integration):'

    require 'open3'

    # Reset state for integration tests
    StateManager.reset(:edits)
    StateManager.reset(:verification)
    StateManager.reset(:handoff_tracking)

    script_path = File.expand_path('sanestop.rb', __dir__)

    # Test valid JSON (no edits = exit 0)
    json_input = '{"stop_hook_active":false}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Valid JSON parsed correctly (exit 0)'
    else
      failed += 1
      warn "  FAIL: Valid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test JSON with stop_hook_active = true
    json_input = '{"stop_hook_active":true}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: stop_hook_active=true skips processing (exit 0)'
    else
      failed += 1
      warn "  FAIL: stop_hook_active=true should exit 0, got #{status.exitstatus}"
    end

    # Test invalid JSON doesn't crash
    json_input = 'definitely not json'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Invalid JSON returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test empty input doesn't crash
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: '')
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Empty input returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Empty input should return exit 0, got #{status.exitstatus}"
    end

    warn ''
    warn "#{passed}/#{passed + failed} tests passed"

    if failed == 0
      warn ''
      warn 'ALL TESTS PASSED'
      0
    else
      warn ''
      warn "#{failed} TESTS FAILED"
      1
    end
  end
end
