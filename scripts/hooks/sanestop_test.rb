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
require_relative 'sanestop_persistence_test'

module SaneStopTest
  def self.ensure_git_repo!
    _out, status = Open3.capture2e('git', '-C', Dir.pwd, 'rev-parse', '--show-toplevel')
    return if status.success?

    system('git', 'init', '-q', chdir: Dir.pwd)
    system('git', 'config', 'user.email', 'test@example.com', chdir: Dir.pwd)
    system('git', 'config', 'user.name', 'Test', chdir: Dir.pwd)
    system('git', 'add', '.', chdir: Dir.pwd)
    system('git', 'commit', '-q', '-m', 'init', chdir: Dir.pwd)
  end

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

  # Build a throwaway git repo with a non-doc source file, then chdir into it so
  # RULE #4's net-uncommitted-diff check sees a real working tree. STATE_FILE is
  # resolved once at load (not cwd-dependent), so StateManager state set by the
  # caller stays visible inside the chdir. When committed: true the source file
  # is committed (clean tree); otherwise it is left uncommitted (dirty tree).
  def self.with_git_repo(committed:)
    Dir.mktmpdir('sanestop-rule4') do |tmpdir|
      Dir.chdir(tmpdir) do
        system('git', 'init', '-q', chdir: tmpdir)
        system('git', 'config', 'user.email', 'test@example.com', chdir: tmpdir)
        system('git', 'config', 'user.name', 'Test', chdir: tmpdir)
        File.write(File.join(tmpdir, 'seed.txt'), "seed\n")
        system('git', 'add', '.', chdir: tmpdir)
        system('git', 'commit', '-q', '-m', 'init', chdir: tmpdir)

        swift = File.join(tmpdir, 'App.swift')
        File.write(swift, "struct App {}\n")
        if committed
          system('git', 'add', 'App.swift', chdir: tmpdir)
          system('git', 'commit', '-q', '-m', 'add app', chdir: tmpdir)
        end
        yield swift, tmpdir
      end
    end
  end

  def self.run(process_stop_proc, check_score_variance_proc, check_weasel_words_proc, calculate_sop_score_proc, log_file)
    warn 'SaneStop Self-Test'
    warn '=' * 40
    ensure_git_repo!

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

    # Test 2: Uncommitted non-doc edits + NO verification = BLOCK (Rule #4).
    # The edited source file is left dirty in a real working tree, so net-diff
    # has something to verify.
    exit_code = nil
    with_git_repo(committed: false) do |swift, _tmp|
      StateManager.update(:edits) do |e|
        e[:count] = 5
        e[:unique_files] = [swift]
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
    end

    if exit_code == 2
      passed += 1
      warn '  PASS: Uncommitted edits without verification -> BLOCK (exit 2)'
    else
      failed += 1
      warn "  FAIL: Should block uncommitted unverified edits, got exit #{exit_code}"
    end

    # Test 2-net: Committed + pushed work (clean tree) -> ALLOW even with no
    # verify metric this session. This is the RULE #4 fix: the cumulative edit
    # counter used to fire forever after a release was committed, satisfiable
    # only by a fresh build. A clean working tree must clear the gate.
    exit_code = nil
    with_git_repo(committed: true) do |swift, _tmp|
      StateManager.update(:edits) do |e|
        e[:count] = 233
        e[:unique_files] = [swift]
        e
      end
      StateManager.reset(:verification)
      StateManager.update(:handoff_tracking) do |h|
        h[:handoff_updated] = true
        h[:memory_updated] = true
        h
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false)
      $stderr.reopen(original_stderr)
    end

    if exit_code == 0
      passed += 1
      warn '  PASS: Committed edits (clean tree) -> allow stop (no infinite verify loop)'
    else
      failed += 1
      warn "  FAIL: Committed/clean-tree edits should allow stop, got exit #{exit_code}"
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

    # Test 2b-2: Blocked stops still write session_end accounting, tokens, and block outcomes
    with_git_repo(committed: false) do |swift, tmpdir|
      old_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
      metrics_path = File.join(tmpdir, 'process_metrics.jsonl')
      transcript_path = File.join(tmpdir, 'transcript.jsonl')
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = metrics_path
      File.write(transcript_path, JSON.generate('message' => { 'usage' => { 'input_tokens' => 10, 'output_tokens' => 5, 'cache_read_input_tokens' => 4 } }) + "\n")

      StateManager.update(:edits) do |e|
        e[:count] = 1
        e[:unique_files] = [swift]
        e[:last_edit_at] = Time.now.iso8601
        e
      end
      StateManager.reset(:verification)
      StateManager.update(:handoff_tracking) do |h|
        h[:handoff_updated] = true
        h[:memory_updated] = true
        h
      end
      StateManager.update(:enforcement) do |e|
        e[:session_started_at] = (Time.now - 60).iso8601
        e[:blocks] = [{ timestamp: Time.now.iso8601, rule: 'Rule #4' }]
        e
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false, transcript_path)
      $stderr.reopen(original_stderr)

      rows = File.readlines(metrics_path, chomp: true).map { |line| JSON.parse(line) }
      session_end = rows.find { |row| row['type'] == 'session_end' }
      receipt = rows.find { |row| row['type'] == 'session_receipt' }
      outcomes = rows.select { |row| row['type'] == 'block_outcome' }
      if exit_code == 2 &&
         session_end &&
         session_end['outcome'] == 'blocked' &&
         session_end['stop_blocked'] == true &&
         session_end['block_family'] == 'verification' &&
         session_end['transcript_total_tokens'] == 19 &&
         receipt &&
         receipt['outcome'] == 'blocked' &&
         outcomes.any? { |row| row['rule_family'] == 'Rule #4' } &&
         outcomes.any? { |row| row['rule_family'] == 'verification' }
        passed += 1
        warn '  PASS: Blocked stop records session_end, transcript tokens, and block_outcome rows'
      else
        failed += 1
        warn '  FAIL: Blocked stop should record session_end, transcript tokens, and block_outcome rows'
      end
    ensure
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics_path
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

    Dir.mktmpdir('sanestop-sop-override') do |tmpdir|
      old_csv_path = ENV['SANE_SOP_CSV_PATH']
      old_jsonl_path = ENV['SANE_SOP_JSONL_PATH']
      ENV['SANE_SOP_CSV_PATH'] = File.join(tmpdir, 'sop_ratings.csv')
      ENV['SANE_SOP_JSONL_PATH'] = File.join(tmpdir, 'sop_ratings.jsonl')
      StateManager.reset(:edits)
      StateManager.reset(:verification)
      StateManager.reset(:circuit_breaker)
      StateManager.reset(:handoff_tracking)
      StateManager.update(:enforcement) { |e| e[:blocks] = []; e }

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_stop_proc.call(false)
      $stderr.reopen(original_stderr)

      if exit_code == 0 && File.exist?(ENV['SANE_SOP_CSV_PATH']) && File.exist?(ENV['SANE_SOP_JSONL_PATH'])
        passed += 1
        warn '  PASS: SOP receipt paths honor environment override'
      else
        failed += 1
        warn '  FAIL: SOP receipt paths should honor environment override'
      end
    ensure
      if old_csv_path
        ENV['SANE_SOP_CSV_PATH'] = old_csv_path
      else
        ENV.delete('SANE_SOP_CSV_PATH')
      end
      if old_jsonl_path
        ENV['SANE_SOP_JSONL_PATH'] = old_jsonl_path
      else
        ENV.delete('SANE_SOP_JSONL_PATH')
      end
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

    persistence_passed, persistence_failed = SaneStopPersistenceTest.run(process_stop_proc)
    passed += persistence_passed
    failed += persistence_failed
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
