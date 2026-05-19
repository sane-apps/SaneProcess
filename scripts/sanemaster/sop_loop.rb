# frozen_string_literal: true

# ==============================================================================
# SaneLoop Module - Native Ruby implementation (no external dependencies)
# ==============================================================================
#
# Replaces ralph-wiggum plugin with pure Ruby. No shell parsing issues.
# Integrates with SaneMaster and hooks for enforcement.
#
# Commands:
#   saneloop start "Task" --max-iterations 15 --criteria "X" --promise "Y"
#   saneloop status
#   saneloop check <id>
#   saneloop log "action" "result"
#   saneloop complete
#   saneloop cancel
#
# ==============================================================================

require 'json'
require 'fileutils'
require_relative '../hooks/core/sop_score'

module SaneMasterModules
  module SOPLoop
    SANELOOP_STATE_FILE = '.claude/saneloop-state.json'
    VERIFY_STATE_FILE = '.claude/sop-verify-state.json'
    RESEARCH_LOCK_FILE = '.claude/research-locks.json'
    RESEARCH_MD_FILE = '.claude/research.md'
    AUTO_RESEARCH_LOCK_REFRESH_SECONDS = 900
    AUTO_RESEARCH_LOCK_APPS = %w[SaneBar SaneClip].freeze
    SATISFACTION_FILE = '.claude/process_satisfaction.json'
    REQUIREMENTS_FILE = '.claude/prompt_requirements.json'
    ENFORCEMENT_LOG = '.claude/enforcement_log.jsonl'
    TRACKING_FILE = '.claude/rule_tracking.jsonl'

    # ===========================================================================
    # saneloop - Main entry point for SaneLoop commands
    # ===========================================================================
    def saneloop(args)
      subcommand = args.shift || 'status'

      case subcommand
      when 'start'
        saneloop_start(args)
      when 'status', 's'
        saneloop_status(args)
      when 'check', 'c'
        saneloop_check(args)
      when 'log', 'l'
        saneloop_log(args)
      when 'summary', 'sum'
        saneloop_summary(args)
      when 'complete', 'done'
        saneloop_complete(args)
      when 'cancel', 'stop'
        saneloop_cancel(args)
      when 'help', '-h', '--help'
        saneloop_help
      else
        warn "Unknown saneloop command: #{subcommand}"
        saneloop_help
      end
    end

    # ===========================================================================
    # saneloop start - Initialize a new loop with structured spec
    # ===========================================================================
    def saneloop_start(args)
      if saneloop_active?
        warn '❌ A SaneLoop is already active!'
        warn '   Use: ./scripts/SaneMaster.rb saneloop status'
        warn '   Or:  ./scripts/SaneMaster.rb saneloop cancel'
        return
      end

      # Clear stale enforcement state - fresh loop = fresh requirements
      clear_enforcement_state

      # Parse arguments
      task = []
      max_iterations = 15
      criteria = []
      research_steps = []
      self_eval = []
      promise = nil

      i = 0
      while i < args.length
        case args[i]
        when '--max-iterations', '-m'
          max_iterations = args[i + 1].to_i
          i += 2
        when '--criteria', '-c'
          criteria << args[i + 1]
          i += 2
        when '--research', '-r'
          research_steps << args[i + 1]
          i += 2
        when '--eval', '-e'
          self_eval << args[i + 1]
          i += 2
        when '--promise', '-p'
          promise = args[i + 1]
          i += 2
        else
          task << args[i]
          i += 1
        end
      end

      task_str = task.join(' ')

      if task_str.empty?
        warn '❌ No task provided'
        warn ''
        warn 'Usage: ./scripts/SaneMaster.rb saneloop start "Task description" [options]'
        warn ''
        warn 'Options:'
        warn '  --max-iterations N   Maximum iterations (default: 15)'
        warn '  --criteria "text"    Add acceptance criterion (repeatable)'
        warn '  --research "step"    Add research step (repeatable)'
        warn '  --eval "question"    Add self-eval question (repeatable)'
        warn '  --promise "text"     Completion promise (required)'
        return
      end

      if promise.nil? || promise.empty?
        warn '❌ Completion promise required'
        warn '   Add: --promise "Statement that must be true to complete"'
        return
      end

      # Build state
      state = {
        active: true,
        iteration: 1,
        max_iterations: max_iterations,
        started_at: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        task: task_str,
        research_steps: research_steps.empty? ? default_research_steps : research_steps,
        acceptance_criteria: criteria.map.with_index(1) do |c, id|
          { id: id, text: c, checked: false }
        end,
        self_eval_rubric: self_eval.empty? ? default_self_eval : self_eval,
        completion_promise: promise,
        iteration_log: []
      }

      save_saneloop_state(state)

      puts ''
      puts "✅ SANELOOP: #{task_str}"
      puts "   Max: #{max_iterations} | Promise: #{promise}"
      puts ''
      puts 'Criteria:'
      state[:acceptance_criteria].each { |c| puts "  [ ] #{c[:id]}. #{c[:text]}" }
      puts ''
      puts 'Commands: status, check N, log "X", complete'
    end

    # ===========================================================================
    # saneloop status - Show current loop state
    # ===========================================================================
    def saneloop_status(_args)
      unless saneloop_active?
        puts 'No SaneLoop active.'
        puts ''
        puts 'Start one with: ./scripts/SaneMaster.rb saneloop start "Task" --promise "Done"'
        return
      end

      state = load_saneloop_state

      checked = state[:acceptance_criteria].count { |c| c[:checked] }
      total = state[:acceptance_criteria].length

      puts ''
      puts "SANELOOP: #{state[:task]}"
      puts "Progress: #{checked}/#{total} | Iter: #{state[:iteration]}/#{state[:max_iterations]}"
      puts ''
      state[:acceptance_criteria].each do |c|
        mark = c[:checked] ? '✅' : '  '
        puts "#{mark} #{c[:id]}. #{c[:text]}"
      end
    end

    # ===========================================================================
    # saneloop check - Mark a criterion as done
    # ===========================================================================
    def saneloop_check(args)
      unless saneloop_active?
        warn '❌ No SaneLoop active'
        return
      end

      id = args.first&.to_i
      if id.nil? || id < 1
        warn '❌ Provide criterion ID: saneloop check 1'
        return
      end

      state = load_saneloop_state
      criterion = state[:acceptance_criteria].find { |c| c[:id] == id }

      if criterion.nil?
        warn "❌ No criterion with ID #{id}"
        return
      end

      criterion[:checked] = true
      save_saneloop_state(state)

      puts "✅ Checked: #{criterion[:text]}"

      checked = state[:acceptance_criteria].count { |c| c[:checked] }
      total = state[:acceptance_criteria].length
      puts "   Progress: #{checked}/#{total}"
    end

    # ===========================================================================
    # saneloop log - Record an iteration
    # ===========================================================================
    def saneloop_log(args)
      unless saneloop_active?
        warn '❌ No SaneLoop active'
        return
      end

      action = args[0] || 'No action specified'
      result = args[1] || 'No result specified'
      rule = args[2]

      state = load_saneloop_state

      entry = {
        num: state[:iteration],
        action: action,
        result: result,
        timestamp: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      }
      entry[:rule] = rule if rule

      state[:iteration_log] << entry
      state[:iteration] += 1
      save_saneloop_state(state)

      puts "📝 Logged iteration #{entry[:num]}: #{action}"

      if state[:iteration] > state[:max_iterations]
        warn ''
        warn '⚠️  MAX ITERATIONS REACHED!'
        warn "   You've hit #{state[:max_iterations]} iterations."
        warn '   Review your approach before continuing.'
      end
    end

    # ===========================================================================
    # saneloop summary - Provide LEAN session summary (required before complete)
    # ===========================================================================
    # Format: Rating, Done, Next (3 lines that fit on screen)
    # If rating is low, "Next" explains why (includes missed rules)
    # ===========================================================================
    def saneloop_summary(_args)
      unless saneloop_active?
        warn '❌ No SaneLoop active'
        return
      end

      state = load_saneloop_state
      violations = count_session_violations(state[:started_at])
      sop_score = calculate_sop_score(violations)
      missed_rules = get_missed_rules(state[:started_at])

      # Lean prompt - no collapse
      puts ''
      puts "SOP: #{sop_score}/10 | Missed: #{missed_rules.any? ? missed_rules.join(', ') : 'none'}"
      puts 'Format: Rating | Done | Next (end with "END")'
      puts ''

      summary_lines = []
      loop do
        line = $stdin.gets
        break if line.nil? || line.strip == 'END'

        summary_lines << line.rstrip
      end

      summary = summary_lines.reject(&:empty?).join("\n")

      # Validate lean format
      errors = validate_lean_summary(summary, sop_score, missed_rules)

      if errors.any?
        warn ''
        warn "❌ INVALID: #{errors.join(' | ')}"
        warn ''
        return
      end

      # Store validated summary
      state[:summary_provided] = true
      state[:summary_text] = summary
      state[:sop_score] = sop_score
      save_saneloop_state(state)

      puts ''
      puts '✅ Accepted. Run: saneloop complete'
    end

    def validate_lean_summary(summary, expected_sop, missed_rules)
      errors = []

      # Must have Rating line
      unless summary.match?(/^Rating:/i)
        errors << 'Missing "Rating:" line'
      end

      # Must have Done line
      unless summary.match?(/^Done:/i)
        errors << 'Missing "Done:" line'
      end

      # Must have Next line
      unless summary.match?(/^Next:/i)
        errors << 'Missing "Next:" line'
      end

      # Validate SOP score matches
      rating_match = summary.match(/Rating:.*SOP:\s*(\d+)/i)
      if rating_match
        claimed_sop = rating_match[1].to_i
        if claimed_sop != expected_sop
          errors << "SOP mismatch: claimed #{claimed_sop}, actual #{expected_sop}"
        end
      end

      # If there were violations, Next must mention fixing them
      if missed_rules.any?
        next_line = summary.lines.find { |l| l.match?(/^Next:/i) } || ''
        has_fix_mention = missed_rules.any? do |rule|
          next_line.downcase.include?(rule.to_s.downcase) ||
            next_line.downcase.include?('rule') ||
            next_line.downcase.include?('fix') ||
            next_line.downcase.include?('stop')
        end
        unless has_fix_mention
          errors << "Next must address missed rules: #{missed_rules.join(', ')}"
        end
      end

      errors
    end

    # Get list of rules violated this session
    def get_missed_rules(started_at)
      return [] unless File.exist?(TRACKING_FILE)

      start_time = Time.parse(started_at)
      rules = []

      File.readlines(TRACKING_FILE).each do |line|
        entry = JSON.parse(line, symbolize_names: true)
        next unless entry[:type] == 'violation'

        begin
          entry_time = Time.parse(entry[:timestamp])
          next if entry_time < start_time
        rescue StandardError
          next
        end

        rules << entry[:rule]
      end

      rules.uniq
    rescue StandardError
      []
    end

    # Count unique rule violations since session start
    def count_session_violations(started_at)
      return 0 unless File.exist?(TRACKING_FILE)

      start_time = Time.parse(started_at)
      violations = []

      File.readlines(TRACKING_FILE).each do |line|
        entry = JSON.parse(line, symbolize_names: true)
        next unless entry[:type] == 'violation'

        begin
          entry_time = Time.parse(entry[:timestamp])
          next if entry_time < start_time
        rescue StandardError
          next
        end

        violations << entry[:rule]
      end

      violations.uniq.count
    rescue StandardError
      0
    end

    # Calculate SOP Compliance score from violation count
    def calculate_sop_score(violations)
      SaneSOPScore.score(block_count: violations.to_i)[:score]
    end

    # ===========================================================================
    # saneloop complete - Finish the loop (validates criteria)
    # ===========================================================================
    def saneloop_complete(_args)
      unless saneloop_active?
        warn '❌ No SaneLoop active'
        return
      end

      state = load_saneloop_state

      unchecked = state[:acceptance_criteria].reject { |c| c[:checked] }

      if unchecked.any?
        warn '❌ Cannot complete - unchecked criteria:'
        unchecked.each { |c| warn "   [ ] #{c[:id]}. #{c[:text]}" }
        warn ''
        warn 'Use: saneloop check N to mark criteria as done'
        return
      end

      # Check for session summary
      unless state[:summary_provided]
        warn ''
        warn '❌ Run: saneloop summary (then: saneloop complete)'
        warn ''
        return
      end

      # All criteria checked - complete the loop (lean output - no collapse)
      puts ''
      puts '✅ SANELOOP COMPLETE'
      puts state[:summary_text]
      puts ''

      # Archive and clear
      archive_saneloop(state)
      clear_saneloop_state
      clear_enforcement_state
    end

    # ===========================================================================
    # saneloop cancel - Abort the loop (still requires summary for accountability)
    # ===========================================================================
    def saneloop_cancel(_args)
      unless saneloop_active?
        puts 'No SaneLoop active.'
        return
      end

      state = load_saneloop_state

      # Canceling still requires a summary - accountability matters
      unless state[:summary_provided]
        warn ''
        warn '❌ Run: saneloop summary (then: saneloop cancel)'
        warn ''
        return
      end

      # Lean output - no collapse
      puts ''
      puts '🛑 SANELOOP CANCELLED'
      puts state[:summary_text]
      puts ''

      clear_saneloop_state
      clear_enforcement_state
    end

    # ===========================================================================
    # saneloop help
    # ===========================================================================
    def saneloop_help
      puts <<~HELP
        SaneLoop - Native structured task loop

        USAGE:
          ./scripts/SaneMaster.rb saneloop <command> [options]

        COMMANDS:
          start "Task" [opts]  Start a new loop
          status               Show current state
          check N              Mark criterion N as done
          log "action" "result" Log iteration
          summary              Provide lean summary (required before complete)
          complete             Finish (requires criteria + summary)
          cancel               Abort loop (still requires summary)

        SUMMARY FORMAT (3 lines):
          Rating: X/10 (SOP: X | Perf: X)
          Done: [brief - what was accomplished]
          Next: [actionable - include fixes for missed rules]

        START OPTIONS:
          --max-iterations N   Max iterations (default: 15)
          --criteria "text"    Add criterion (repeatable)
          --promise "text"     Completion promise (REQUIRED)

        EXAMPLE:
          ./scripts/SaneMaster.rb saneloop start "Fix auth bug" \\
            --criteria "Tests pass" \\
            --criteria "No regression" \\
            --promise "Auth works and tests green"

        ALIASES: s=status, c=check, l=log, sum=summary
      HELP
    end

    # ===========================================================================
    # Legacy verify_gate - still useful for Two-Fix Rule
    # ===========================================================================
    def verify_gate(args)
      puts '🚦 --- [ SOP VERIFY GATE ] ---'

      passed = run_verify_check

      state = record_verify_attempt(success: passed, message: 'verify_gate')

      if passed
        puts '✅ Verification passed'
      else
        puts "❌ Verification failed (attempt #{state[:consecutive_failures]})"
      end

      requires_escalation = state[:consecutive_failures] >= 2

      if requires_escalation
        puts ''
        puts '🛑 TWO-FIX RULE TRIGGERED'
        puts '   STOP GUESSING and investigate!'
        puts ''
      end

      save_verify_state(state)

      result = {
        passed: passed,
        consecutive_failures: state[:consecutive_failures],
        requires_escalation: requires_escalation
      }

      puts JSON.pretty_generate(result) if args.include?('--json')
      result
    end

    def reset_escalation(_args)
      clear_verify_escalation!
      puts '✅ Escalation state cleared'
    end

    def research_status(_args = [])
      puts '🔎 --- [ RESEARCH GATE STATUS ] ---'
      puts ''

      state = load_verify_state
      research_time = research_updated_at
      verify_block = verify_escalation_block(state: state, research_time: research_time)
      locks = load_research_locks
      unsatisfied_locks = active_research_locks(locks: locks, research_time: research_time)

      if verify_block.nil? && unsatisfied_locks.empty?
        puts '   Status: 🟢 clear'
        puts "   research.md: #{research_time ? research_time.iso8601 : 'missing'}"
        puts "   locks on file: #{locks.length}"
        puts ''
        return
      end

      puts '   Status: 🔴 research required'
      puts "   research.md: #{research_time ? research_time.iso8601 : 'missing'}"
      puts ''

      if verify_block
        puts '   Verify escalation:'
        puts "   - #{verify_block[:message]}"
        puts ''
      end

      if unsatisfied_locks.any?
        puts '   Research locks:'
        unsatisfied_locks.each do |lock|
          puts "   - #{lock[:slug]}: #{lock[:reason]}"
        end
        puts ''
      end
    end

    def research_lock(args)
      slug = args.shift.to_s.strip
      reason = args.join(' ').strip

      if slug.empty?
        warn '❌ Usage: ./scripts/SaneMaster.rb research_lock <slug> [reason]'
        return
      end

      reason = 'Fresh docs + web + GitHub + local research required before more work.' if reason.empty?
      now = Time.now.iso8601
      locks = load_research_locks.reject { |entry| entry[:slug] == slug }
      locks << { slug: slug, reason: reason, created_at: now }
      save_research_locks(locks)

      puts "🔒 Research lock added: #{slug}"
      puts "   Reason: #{reason}"
      puts "   Created: #{now}"
    end

    def research_unlock(args)
      slug = args.shift.to_s.strip

      if slug.empty?
        warn '❌ Usage: ./scripts/SaneMaster.rb research_unlock <slug|--all>'
        return
      end

      if slug == '--all'
        save_research_locks([])
        puts '🔓 Cleared all research locks'
        return
      end

      locks = load_research_locks
      remaining = locks.reject { |entry| entry[:slug] == slug }
      if remaining.length == locks.length
        warn "❌ No research lock found for #{slug}"
        return
      end

      save_research_locks(remaining)
      puts "🔓 Cleared research lock: #{slug}"
    end

    def ensure_research_gate_clear!(command_name)
      maybe_refresh_auto_research_locks!

      research_time = research_updated_at
      verify_block = verify_escalation_block(research_time: research_time)
      unsatisfied_locks = active_research_locks(research_time: research_time)

      return true if verify_block.nil? && unsatisfied_locks.empty?

      puts '🛑 --- [ RESEARCH REQUIRED ] ---'
      puts "Blocked command: #{command_name}"
      puts ''

      puts "1. #{verify_block[:message]}" if verify_block
      unsatisfied_locks.each_with_index do |lock, index|
        offset = verify_block ? 2 : 1
        puts "#{index + offset}. #{lock[:slug]}: #{lock[:reason]}"
      end

      puts ''
      puts 'Next step: update .claude/research.md with fresh docs + web + GitHub + local findings.'
      puts 'Then rerun the command. This guard auto-clears once research.md is newer than the block.'
      puts ''
      exit 1
    end

    def record_verify_attempt(success:, message:)
      state = load_verify_state

      if success
        state[:consecutive_failures] = 0
        state[:last_result] = 'passed'
        state[:last_failure_at] = nil
        state[:last_failure_message] = nil
        state[:escalated_at] = nil
      else
        state[:consecutive_failures] = state[:consecutive_failures].to_i + 1
        state[:last_result] = 'failed'
        state[:last_failure_at] = Time.now.iso8601
        state[:last_failure_message] = message
        state[:escalated_at] ||= state[:last_failure_at] if state[:consecutive_failures] >= 2
      end

      save_verify_state(state)
      state
    end

    private

    # SaneLoop state helpers
    def saneloop_active?
      return false unless File.exist?(SANELOOP_STATE_FILE)

      state = load_saneloop_state
      state[:active] == true
    end

    def load_saneloop_state
      return {} unless File.exist?(SANELOOP_STATE_FILE)

      JSON.parse(File.read(SANELOOP_STATE_FILE), symbolize_names: true)
    end

    def save_saneloop_state(state)
      FileUtils.mkdir_p(File.dirname(SANELOOP_STATE_FILE))
      File.write(SANELOOP_STATE_FILE, JSON.pretty_generate(state))
    end

    def clear_saneloop_state
      FileUtils.rm_f(SANELOOP_STATE_FILE)
    end

    # Clear all enforcement state files for fresh start
    def clear_enforcement_state
      FileUtils.rm_f(SATISFACTION_FILE)
      FileUtils.rm_f(REQUIREMENTS_FILE)
      FileUtils.rm_f(ENFORCEMENT_LOG)
    end

    def archive_saneloop(state)
      archive_dir = '.claude/saneloop-archive'
      FileUtils.mkdir_p(archive_dir)
      timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
      archive_file = "#{archive_dir}/#{timestamp}.json"
      File.write(archive_file, JSON.pretty_generate(state))
    end

    def default_research_steps
      [
        'Check memory for past failures (mcp__memory__read_graph)',
        'Verify API exists before using (Rule #2)',
        'Read relevant documentation'
      ]
    end

    def default_self_eval
      [
        'Did I verify before trying? (Rule #2)',
        'Did I stop after 2 failures? (Rule #3)',
        'Did I use project tools? (Rule #5)',
        'Did I run the full verify cycle? (Rule #6)'
      ]
    end

    # Verify state helpers (for Two-Fix Rule)
    def load_verify_state
      return {
        consecutive_failures: 0,
        last_result: nil,
        last_failure_at: nil,
        last_failure_message: nil,
        escalated_at: nil
      } unless File.exist?(VERIFY_STATE_FILE)

      JSON.parse(File.read(VERIFY_STATE_FILE), symbolize_names: true)
    end

    def save_verify_state(state)
      FileUtils.mkdir_p(File.dirname(VERIFY_STATE_FILE))
      File.write(VERIFY_STATE_FILE, JSON.pretty_generate(state))
    end

    def clear_verify_escalation!
      state = load_verify_state
      state[:consecutive_failures] = 0
      state[:last_result] = 'cleared'
      state[:last_failure_at] = nil
      state[:last_failure_message] = nil
      state[:escalated_at] = nil
      save_verify_state(state)
    end

    def load_research_locks
      return [] unless File.exist?(RESEARCH_LOCK_FILE)

      JSON.parse(File.read(RESEARCH_LOCK_FILE), symbolize_names: true)
    rescue JSON::ParserError
      []
    end

    def save_research_locks(locks)
      FileUtils.mkdir_p(File.dirname(RESEARCH_LOCK_FILE))
      File.write(RESEARCH_LOCK_FILE, JSON.pretty_generate(locks))
    end

    def research_updated_at
      return nil unless File.exist?(RESEARCH_MD_FILE)

      File.mtime(RESEARCH_MD_FILE)
    end

    def maybe_refresh_auto_research_locks!
      app_name = File.basename(Dir.pwd)
      return unless AUTO_RESEARCH_LOCK_APPS.include?(app_name)

      if File.exist?(RESEARCH_LOCK_FILE)
        age = Time.now - File.mtime(RESEARCH_LOCK_FILE)
        return if age < AUTO_RESEARCH_LOCK_REFRESH_SECONDS
      end

      sync_script = File.expand_path('../../../scripts/check-inbox.sh', __dir__)
      return unless File.exist?(sync_script)

      system(sync_script, 'sync-research-locks', '--app', app_name, '--repo-path', Dir.pwd,
             out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    def active_research_locks(locks: load_research_locks, research_time: research_updated_at)
      locks.select do |lock|
        trigger_time = lock_trigger_time(lock)
        research_time.nil? || trigger_time.nil? || research_time <= trigger_time
      end
    end

    def verify_escalation_block(state: load_verify_state, research_time: research_updated_at)
      return nil unless state[:consecutive_failures].to_i >= 2

      escalated_at = parse_gate_time(state[:escalated_at] || state[:last_failure_at])
      if research_time && escalated_at && research_time > escalated_at
        clear_verify_escalation!
        return nil
      end

      {
        message: "#{state[:consecutive_failures]} failed verify attempts on the same problem. Fresh research is required before more work.",
        last_failure_at: state[:last_failure_at],
        last_failure_message: state[:last_failure_message]
      }
    end

    def parse_gate_time(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def lock_trigger_time(lock)
      parse_gate_time(lock[:source_updated_at] || lock[:created_at])
    end

    def run_verify_check
      system('./scripts/SaneMaster.rb', 'verify', out: File::NULL, err: File::NULL)
    end
  end
end
