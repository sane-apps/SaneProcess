#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'core/gui_feedback'

failures = 0

def check(name, cond)
  if cond
    warn "  PASS: #{name}"
    true
  else
    warn "  FAIL: #{name}"
    false
  end
end

warn 'gui_feedback.rb self-test'

failures += 1 unless check(
  'osascript click is a GUI action',
  SaneGuiFeedback.gui_action?('osascript -e \'tell application "System Events" to click button "Update Review"\'')
)

failures += 1 unless check(
  'completion chime osascript is NOT a GUI action',
  !SaneGuiFeedback.gui_action?('osascript -e \'display notification "done" with title "SaneProcess"\'')
)

failures += 1 unless check(
  'capture-mini-screenshot is feedback, not a mutation',
  SaneGuiFeedback.feedback_poll?('~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop') &&
    !SaneGuiFeedback.gui_action?('~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop')
)

failures += 1 unless check(
  'ASC API status poll is feedback',
  SaneGuiFeedback.feedback_poll?('ruby scripts/asc.rb get build --id 1120')
)

failures += 1 unless check(
  'Newer Build Available output needs attention',
  SaneGuiFeedback.output_needs_attention?('Dialog: Newer Build Available')
)

failures += 1 unless check(
  'portal prompt detected',
  SaneGuiFeedback.portal_prompt?('Reply in App Store Connect Resolution Center')
)

Dir.mktmpdir do |dir|
  state_path = File.join(dir, 'sane_gui_feedback.json')
  # Temporarily point cursor state at tmp by stubbing constant... use track via write path override.
  # Exercise public API through mark/clear with monkeypatch of CURSOR_STATE_PATH consumer.
  original = SaneGuiFeedback::CURSOR_STATE_PATH
  begin
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_PATH)
    SaneGuiFeedback.const_set(:CURSOR_STATE_PATH, state_path)

    SaneGuiFeedback.track_command!('osascript -e \'click button "Update Review" of window 1\'')
    failures += 1 unless check('pending after GUI click', SaneGuiFeedback.pending?)

    payload = SaneGuiFeedback.cursor_after_shell_payload(
      command: 'osascript -e \'click button "Submit"\'',
      output: 'Newer Build Available'
    )
    failures += 1 unless check(
      'cursor after-shell injects additional_context',
      payload.is_a?(Hash) && payload[:additional_context].to_s.include?('GUI ACTION FEEDBACK LOOP')
    )

    SaneGuiFeedback.track_command!('ruby scripts/asc.rb get submission status')
    failures += 1 unless check('cleared after feedback poll', !SaneGuiFeedback.pending?)

    SaneGuiFeedback.track_command!('osascript -e \'click button "Update Review"\'')
    followup = SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 0)
    failures += 1 unless check(
      'stop followup when pending',
      followup.to_s.include?('GUI feedback loop incomplete')
    )

    no_followup = SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 2)
    failures += 1 unless check('stop followup capped', no_followup.nil?)
  ensure
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_PATH)
    SaneGuiFeedback.const_set(:CURSOR_STATE_PATH, original)
  end
end

if failures.zero?
  warn 'ALL PASS'
  exit 0
else
  warn "FAILED: #{failures}"
  exit 1
end
