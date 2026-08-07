#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_runaway_guard.rb — PreToolUse Bash guard against CPU-murdering commands.
#
# WHY (2026-07-24 incident): the Air hit load 7.5 and got hot. Cause was three
# concurrent copies of sync-memory-mini.sh pegging ~99% CPU each for up to
# 2h55m, plus two regex greps backtracking over minified HTML, plus a NINE DAY
# old `until ssh mini grep ...; do sleep 60; done` loop still polling a ship log
# for a release that shipped a week earlier.
#
# The committed automation was not the problem: 0 of 17 automation scripts use
# `while true`/`until`. Every runaway was AD-HOC SHELL an agent typed into the
# Bash tool. That is why this guard lives at the Bash boundary and not in the
# scripts, and why the existing session_start_cleanup reaper missed them all —
# it only reaps a positive allowlist of dev servers whose launcher is dead
# (ppid<=1), so a wedged sync with a live parent shell is invisible to it.
#
# Three rules, each with a justified-exception escape hatch:
#   1. A wait/poll loop must be BOUNDED (deadline, iteration cap, or timeout).
#   2. A long-running background job must be `nice`d so it cannot fight the
#      owner's interactive work for CPU.
#   3. No bounded-repeat regex (`.{0,N}`) in a recursive/only-matching grep —
#      that is catastrophic backtracking waiting for a minified file.
#
# Exceptions are deliberately awkward: prefix the command with
#   SANE_RUNAWAY_OK="<specific reason>"
# The reason must be self-explanatory on its own (>=25 chars, not a filler
# word). "ok" and "because I need to" do not pass.

require 'json'

REASON_MIN_LENGTH = 25
FILLER_REASONS = /\A(?:ok(?:ay)?|yes|sure|fine|needed|need it|because|just|temp|temporary|test|testing|trust me|it.s fine)\b/i.freeze

# A loop is "bounded" if any of these appear — a deadline, a counter, or an
# external killer. `until`/`while` waiting is fine; waiting FOREVER is not.
BOUND_MARKERS = [
  /\btimeout\s+\d/,                    # timeout 600 ...
  /\bfor\s+\w+\s+in\s+.*\bseq\b/,      # for i in $(seq 1 40)
  /\bfor\s+\(\(/,                      # for ((i=0;i<40;i++))
  /\bSECONDS\b/,                       # bash deadline idiom
  /\$\(\(\s*\w+\s*\+\+?\s*\)\)/,       # manual counter increment
  /\bmax_?(?:tries|attempts|iter\w*)\b/i,
  /\bgtimeout\s+\d/
].freeze

UNBOUNDED_LOOP = /(?:\bwhile\s+(?:true|:)\b|\buntil\b[^\n;]*;?\s*do\b|\bwhile\b[^\n;]*;?\s*do\b)/.freeze
SLEEP_IN_LOOP = /\bsleep\s+[\d.]/.freeze

# Bounded repeat applied to a WIDE atom — `.` or a negated class `[^...]`.
# Both match almost anything, so a large upper bound over one long line (a
# minified JS/HTML file is one long line) backtracks exponentially.
# A narrow positive class with a small bound (`[0-9]{1,3}`) is normal and fine,
# so the atom and the bound are both checked rather than the braces alone.
WIDE_REPEAT = /(?:\.|\[\^[^\]]*\])\\?\{\d*,(\d+)\\?\}/.freeze
WIDE_REPEAT_DANGER_BOUND = 20
RECURSIVE_GREP = /\bgrep\b[^|;&\n]*\s-\w*[rRo]/.freeze

BACKGROUNDED = /(?:\bnohup\b|&\s*\z|&\s*[;\n])/.freeze
NICED = /\bnice\b/.freeze

def payload_command(payload)
  data = JSON.parse(payload)
  return nil unless data['tool_name'] == 'Bash'

  (data['tool_input'] || {})['command'].to_s
rescue JSON::ParserError
  nil
end

def exception_reason(command)
  m = command.match(/SANE_RUNAWAY_OK=(["'])(.*?)\1/m) || command.match(/SANE_RUNAWAY_OK=(\S+)/)
  return nil unless m

  m[2] || m[1]
end

def justified?(command)
  reason = exception_reason(command)
  return false if reason.nil?

  reason = reason.strip
  return false if reason.length < REASON_MIN_LENGTH
  return false if reason.match?(FILLER_REASONS)

  true
end

def bounded?(command)
  BOUND_MARKERS.any? { |re| command.match?(re) }
end

def unbounded_wait_loop?(command)
  return false unless command.match?(UNBOUNDED_LOOP)
  return false unless command.match?(SLEEP_IN_LOOP) || command.match?(/\bwhile\s+(?:true|:)\b/)

  !bounded?(command)
end

def unniced_background_loop?(command)
  return false unless command.match?(BACKGROUNDED)
  return false unless command.match?(UNBOUNDED_LOOP) || command.match?(SLEEP_IN_LOOP)

  !command.match?(NICED)
end

def pathological_grep?(command)
  return false unless command.match?(RECURSIVE_GREP)

  command.scan(WIDE_REPEAT).any? { |(bound)| bound.to_i >= WIDE_REPEAT_DANGER_BOUND }
end

def refuse(title, detail, fix)
  warn "🔴 BLOCKED: #{title}"
  warn ''
  warn detail
  warn ''
  warn "   ✅ Fix: #{fix}"
  warn ''
  warn '   If this genuinely needs an exception, prefix the command with'
  warn '   SANE_RUNAWAY_OK="<reason>" — the reason must stand on its own'
  warn "   (#{REASON_MIN_LENGTH}+ chars, specific, no filler). It is recorded in the"
  warn '   transcript, so write it for someone reading this later.'
  exit 2
end

payload = $stdin.read.force_encoding(Encoding::UTF_8)
command = payload_command(payload)
exit 0 if command.nil? || command.strip.empty?
exit 0 if justified?(command)

if unbounded_wait_loop?(command)
  refuse(
    'unbounded wait loop (no deadline, no iteration cap)',
    "   A poll loop with no bound runs until something kills it. On 2026-07-24 an\n" \
    "   `until ssh mini grep ...; do sleep 60; done` from a finished session was\n" \
    '   still polling NINE DAYS later, once a minute, forever.',
    'add a bound — `timeout 900 bash -c \'...\'`, `for i in $(seq 1 40)`, or a SECONDS deadline.'
  )
end

if unniced_background_loop?(command)
  refuse(
    'background loop not niced',
    "   A background job at normal priority competes with the owner's interactive\n" \
    "   work for CPU. That is the difference between a job that runs quietly and\n" \
    '   one that makes the machine hot and unusable.',
    'prefix the workload with `nice -n 10` (and run it on the Mini when it is SaneApps work).'
  )
end

if pathological_grep?(command)
  refuse(
    'bounded-repeat regex in a recursive grep (catastrophic backtracking)',
    "   `.{0,N}` around an alternation over generated/minified files backtracks\n" \
    "   exponentially. Two of these pegged a core each for ~15 minutes on\n" \
    '   2026-07-24 before they were killed.',
    'use fixed strings (`grep -F`), or parse with Python/ruby when you need surrounding context.'
  )
end

exit 0
