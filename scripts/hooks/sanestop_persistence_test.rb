#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'json'
require 'time'
require 'open3'
require 'fileutils'
require_relative 'core/state_manager'

module SaneStopPersistenceTest
  def self.run(process_stop_proc)
    passed = 0
    failed = 0
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
      s[:runner_proved] = false
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

    # Guidance must name both supported independent-review routes. Task-only
    # wording incorrectly rejects completed read-only Codex fan-out lanes.
    captured = StringIO.new
    original_stderr = $stderr
    $stderr = captured
    exit_code = process_stop_proc.call(false)
    $stderr = original_stderr
    guidance = captured.string
    if exit_code == 2 && guidance.include?('completed native Task reviews') &&
       guidance.include?('authoritative read-only Codex fan-out receipts')
      passed += 1
      warn '  PASS: docs_audit block names completed native and authoritative receipt routes'
    else
      failed += 1
      warn "  FAIL: docs_audit guidance should name both review routes: #{guidance.inspect[0..200]}"
    end

    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 0
      s[:runner_proved] = true
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
      s[:invoked_at] = Time.now.iso8601
      s[:subagents_spawned] = 4
      s[:codex_review_lanes_completed] = 1
      s[:codex_review_invoked_at] = s[:invoked_at]
      s[:runner_proved] = false
      s[:runner_commands] = []
      s
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: native agents and completed Codex review lanes combine for coverage'
    else
      failed += 1
      warn "  FAIL: combined native/Codex review coverage should allow stop, got #{exit_code}"
    end

    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 5
      s[:runner_proved] = false
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
      s[:runner_proved] = true
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
      s[:runner_proved] = false
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
      s[:runner_proved] = false
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
      s[:runner_proved] = true
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
        s[:runner_proved] = false
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
        s[:runner_proved] = true
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
    # A genuine gate requires a REAL customer-facing UI file that this session
    # actually edited (present on disk AND in edits[:unique_files]). Phantom
    # basenames alone must no longer block (see phantom-file false-positive fix).
    real_ui_dir = File.join(Dir.pwd, 'outputs', 'sanestop-test-Views')
    FileUtils.mkdir_p(real_ui_dir)
    real_ui_file = File.join(real_ui_dir, 'ContentView.swift')
    File.write(real_ui_file, "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"hi\") } }\n")
    # count:0 keeps the Rule #4 verification gate (which keys on edit count) out
    # of the way so these tests isolate the VISUAL gate; the visual filter keys
    # on edits[:unique_files] membership, not the counter.
    StateManager.update(:edits) do |e|
      e[:unique_files] = [real_ui_file]
      e[:count] = 0
      e
    end
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:reason] = 'prompt_requested_visual_verification'
      v[:required_files] = [File.basename(real_ui_file)]
      v[:required_files_paths] = [real_ui_file]
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
        screenshots: [screenshot_path],
        claims: [
          {
            id: 'sanestop-fixture',
            claim: 'Structured visual receipt maps the verified UI claim to a screenshot',
            status: 'passed',
            screenshots: [screenshot_path]
          }
        ]
      )
    )
    StateManager.reset(:handoff_tracking)
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:required_files] = [File.basename(real_ui_file)]
      v[:required_files_paths] = [real_ui_file]
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
    FileUtils.rm_rf(real_ui_dir)
    StateManager.reset(:visual_verification)
    StateManager.reset(:edits)

    # Phantom-file false positive: names of UI-looking files that either do not
    # exist on disk or were never edited by this session's own Edit/Write must
    # NOT block stop. (Regression: scraped basenames like ClipboardItemCell.swift
    # for files absent from the repo were flagged as customer_facing_ui_file_edited.)
    StateManager.reset(:edits)
    StateManager.reset(:visual_verification)
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:reason] = 'customer_facing_ui_file_edited'
      v[:required_files] = %w[ClipboardItemCell.swift HistoryTab.swift PinnedTab.swift]
      v[:required_files_paths] = [
        File.join(Dir.pwd, 'Sources', 'Views', 'ClipboardItemCell.swift'),
        File.join(Dir.pwd, 'Sources', 'Views', 'HistoryTab.swift'),
        File.join(Dir.pwd, 'Sources', 'Views', 'PinnedTab.swift')
      ]
      v
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Phantom UI files (nonexistent / never-edited) do not block stop'
    else
      failed += 1
      warn "  FAIL: Phantom UI files should not block stop, got #{exit_code}"
    end
    StateManager.reset(:visual_verification)
    StateManager.reset(:edits)

    # Second phantom variant: a real, on-disk UI file that was NOT edited by this
    # session (present in required_files_paths but absent from edits[:unique_files])
    # must also not block — it was merely read/referenced, not edited here.
    unedited_dir = File.join(Dir.pwd, 'outputs', 'sanestop-test-unedited-Views')
    FileUtils.mkdir_p(unedited_dir)
    unedited_file = File.join(unedited_dir, 'HistoryTab.swift')
    File.write(unedited_file, "import SwiftUI\nstruct HistoryTab: View { var body: some View { EmptyView() } }\n")
    StateManager.update(:edits) do |e|
      e[:unique_files] = [File.join(Dir.pwd, 'scripts', 'sanemaster', 'verify.rb')]
      e[:count] = 0
      e
    end
    StateManager.update(:visual_verification) do |v|
      v[:required] = true
      v[:reason] = 'customer_facing_ui_file_edited'
      v[:required_files] = [File.basename(unedited_file)]
      v[:required_files_paths] = [unedited_file]
      v
    end
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    if exit_code == 0
      passed += 1
      warn '  PASS: Existing-but-unedited UI file does not block stop'
    else
      failed += 1
      warn "  FAIL: Existing-but-unedited UI file should not block stop, got #{exit_code}"
    end
    FileUtils.rm_rf(unedited_dir)
    StateManager.reset(:visual_verification)
    StateManager.reset(:edits)

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
    rows = File.readlines(ENV['SANEMASTER_PROCESS_METRICS_PATH'], chomp: true, encoding: Encoding::UTF_8).map { |line| JSON.parse(line) }
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
    SaneStopTest.write_verify_metric(ENV['SANEMASTER_PROCESS_METRICS_PATH'])
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


      [passed, failed]
    end
  end
