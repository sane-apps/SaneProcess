#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'json'
require 'minitest/autorun'

# Regression cases are the ACTUAL commands from the 2026-07-24 CPU incident on
# the Air, so this test fails if the guard ever stops catching them.
class SaneRunawayGuardTest < Minitest::Test
  SCRIPT = File.expand_path('sane_runaway_guard.rb', __dir__)

  def run_guard(command)
    payload = JSON.generate('tool_name' => 'Bash', 'tool_input' => { 'command' => command })
    _out, err, status = Open3.capture3('ruby', SCRIPT, stdin_data: payload)
    [status.exitstatus, err]
  end

  def assert_blocked(command, msg = nil)
    code, err = run_guard(command)
    assert_equal 2, code, msg || "expected block for: #{command}"
    assert_match(/BLOCKED/, err)
  end

  def assert_allowed(command, msg = nil)
    code, = run_guard(command)
    assert_equal 0, code, msg || "expected allow for: #{command}"
  end

  # --- rule 1: unbounded wait loops -------------------------------------
  def test_blocks_the_nine_day_zombie_poller
    # Verbatim shape of the loop found still running after 9 days.
    assert_blocked('until ssh mini \'grep -qE "Release complete" /tmp/sanehosts-ship-1122.log\'; do sleep 60; done')
  end

  def test_blocks_while_true_loop
    assert_blocked('while true; do check.sh; sleep 30; done')
  end

  def test_allows_loop_bounded_by_timeout
    assert_allowed('timeout 900 bash -c "until grep -q ready dev.log; do sleep 5; done"')
  end

  def test_allows_loop_bounded_by_seq
    assert_allowed('for i in $(seq 1 40); do grep -q ready dev.log && break; sleep 30; done')
  end

  # --- rule 2: unniced background loops ---------------------------------
  def test_blocks_unniced_background_loop
    assert_blocked('nohup bash -c "while true; do sync.sh; sleep 60; done" &')
  end

  def test_allows_niced_bounded_background_loop
    assert_allowed('nohup nice -n 10 bash -c "for i in $(seq 1 10); do sync.sh; sleep 60; done" &')
  end

  # --- rule 3: catastrophic backtracking --------------------------------
  def test_blocks_bounded_repeat_recursive_grep
    # Verbatim shape of the greps that pegged a core each for ~15 minutes.
    assert_blocked(%(grep -rn -i -oE '[^<>"]{0,70}(hallucinat|Big AI)[^<>"]{0,70}' sanecite.com/index.html))
  end

  def test_allows_fixed_string_grep
    assert_allowed('grep -rnF "hallucinat" sanecite.com/index.html')
  end

  def test_allows_narrow_positive_class_repeat
    # `[0-9]{1,3}` is normal and cheap. The guard keys on WIDE atoms (`.`, a
    # negated class) with a large bound, not on braces alone, so everyday
    # patterns must keep working or the guard will just get disabled.
    assert_allowed('grep -roE "[0-9]{1,3}" logs/')
  end

  # --- exceptions must be self-explanatory ------------------------------
  def test_rejects_filler_exception
    assert_blocked('SANE_RUNAWAY_OK="ok" until x; do sleep 5; done')
  end

  def test_rejects_short_exception
    assert_blocked('SANE_RUNAWAY_OK="need it" while true; do x; sleep 1; done')
  end

  def test_accepts_specific_justified_exception
    assert_allowed(
      'SANE_RUNAWAY_OK="polling Resend for wave-3 send confirmation, operator watching" ' \
      'until x; do sleep 5; done'
    )
  end

  # --- must not disturb ordinary work -----------------------------------
  def test_allows_ordinary_commands
    assert_allowed('ls -la && git status')
    assert_allowed('python3 build.py --check')
  end
end
