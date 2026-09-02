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
  'System Events AX window read is NOT a GUI mutation',
  !SaneGuiFeedback.gui_action?(
    'osascript -e \'tell application "System Events" to tell process "Simulator" to get name of every window\''
  )
)

failures += 1 unless check(
  'System Events AX read counts as feedback poll',
  SaneGuiFeedback.feedback_poll?(
    'osascript -e \'tell application "System Events" to tell process "Simulator" to get name of every window\''
  )
)

failures += 1 unless check(
  'simctl screenshot counts as feedback poll',
  SaneGuiFeedback.feedback_poll?('xcrun simctl io D25D0334 screenshot /tmp/live-gui-feedback-152559.png')
)

failures += 1 unless check(
  'git commit message mentioning Update Review is NOT a GUI action',
  !SaneGuiFeedback.gui_action?(
    "git commit -m \"$(cat <<'EOF'\nDocument ASC hang.\nasc_upload retries before agents claim Update Review success.\nEOF\n)\""
  )
)

failures += 1 unless check(
  'git add/push alone is NOT a GUI action',
  !SaneGuiFeedback.gui_action?(
    'export PATH="/opt/homebrew/bin:$PATH"; cd ~/SaneApps/apps/SaneLot; git add SESSION_HANDOFF.md; git push origin HEAD'
  )
)

failures += 1 unless check(
  'Brave + App Store Connect URL is a GUI action',
  SaneGuiFeedback.gui_action?(
    'osascript -e \'tell application "Brave Browser" to open location "https://appstoreconnect.apple.com"\''
  )
)

failures += 1 unless check(
  'capture-mini-screenshot is feedback, not a mutation',
  SaneGuiFeedback.feedback_poll?('~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop') &&
    !SaneGuiFeedback.gui_action?('~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop')
)

failures += 1 unless check(
  'ASC API status poll is feedback',
  SaneGuiFeedback.feedback_poll?('ruby scripts/asc.rb get submission status')
)

failures += 1 unless check(
  'Newer Build Available output needs attention',
  SaneGuiFeedback.output_needs_attention?('Dialog: Newer Build Available')
)

failures += 1 unless check(
  'portal prompt detected',
  SaneGuiFeedback.portal_prompt?('Reply in App Store Connect Resolution Center')
)

failures += 1 unless check(
  'running gui_feedback_test.rb is NOT a GUI action',
  !SaneGuiFeedback.gui_action?(
    'cd /Users/sj/SaneApps/infra/SaneProcess && ruby scripts/hooks/gui_feedback_test.rb; echo EXIT:$?'
  )
)

failures += 1 unless check(
  'inlined SaneGuiFeedback.track_command! fixture is NOT a GUI action',
  !SaneGuiFeedback.gui_action?(
    'ruby -e \'require "gui_feedback"; SaneGuiFeedback.track_command!("osascript -e tell application \"System Events\" to click button \"X\"", conversation_id: "a")\''
  )
)

Dir.mktmpdir do |dir|
  state_dir = File.join(dir, 'sane_gui_feedback')
  legacy = File.join(dir, 'sane_gui_feedback.json')
  FileUtils.mkdir_p(state_dir)
  File.write(legacy, JSON.pretty_generate(pending: true, last_action: 'LEAKED OTHER CHAT', last_action_at: Time.now.iso8601))

  original_path = SaneGuiFeedback::CURSOR_STATE_PATH
  original_dir = SaneGuiFeedback::CURSOR_STATE_DIR
  begin
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_PATH)
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_DIR)
    SaneGuiFeedback.const_set(:CURSOR_STATE_PATH, legacy)
    SaneGuiFeedback.const_set(:CURSOR_STATE_DIR, state_dir)

    chat_a = 'conv-aaaa'
    chat_b = 'conv-bbbb'

    SaneGuiFeedback.track_command!(
      'osascript -e \'tell application "System Events" to click button "Update Review"\'',
      conversation_id: chat_a
    )
    failures += 1 unless check(
      'pending for chat A after GUI click',
      SaneGuiFeedback.pending?(conversation_id: chat_a)
    )
    failures += 1 unless check(
      'chat B does NOT see chat A pending',
      !SaneGuiFeedback.pending?(conversation_id: chat_b)
    )
    failures += 1 unless check(
      'stop followup only for chat A',
      SaneGuiFeedback.cursor_stop_followup(
        status: 'completed', loop_count: 0, conversation_id: chat_a
      ).to_s.include?('GUI feedback loop incomplete')
    )
    failures += 1 unless check(
      'stop followup empty for chat B',
      SaneGuiFeedback.cursor_stop_followup(
        status: 'completed', loop_count: 0, conversation_id: chat_b
      ).nil?
    )
    failures += 1 unless check(
      'stop without conversation_id never follows up (anti-leak)',
      SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 0).nil?
    )
    failures += 1 unless check(
      'legacy global pending ignored for Cursor stop',
      SaneGuiFeedback.cursor_stop_followup(
        status: 'completed', loop_count: 0, conversation_id: chat_b
      ).nil?
    )

    payload = SaneGuiFeedback.cursor_after_shell_payload(
      command: 'osascript -e \'tell application "System Events" to click button "Submit"\'',
      output: 'Newer Build Available',
      conversation_id: chat_a
    )
    failures += 1 unless check(
      'cursor after-shell injects additional_context',
      payload.is_a?(Hash) && payload[:additional_context].to_s.include?('GUI ACTION FEEDBACK LOOP')
    )

    SaneGuiFeedback.track_command!(
      'ruby scripts/asc.rb get submission status',
      conversation_id: chat_a
    )
    failures += 1 unless check(
      'cleared after feedback poll for chat A',
      !SaneGuiFeedback.pending?(conversation_id: chat_a)
    )

    SaneGuiFeedback.track_command!(
      'osascript -e \'tell application "System Events" to click button "Update Review"\'',
      conversation_id: chat_a
    )
    SaneGuiFeedback.track_command!(
      'xcrun simctl io D25D0334 screenshot /tmp/live-gui-feedback-test.png',
      conversation_id: chat_a
    )
    failures += 1 unless check(
      'simctl screenshot clears pending',
      !SaneGuiFeedback.pending?(conversation_id: chat_a)
    )

    no_followup = SaneGuiFeedback.cursor_stop_followup(
      status: 'completed', loop_count: 2, conversation_id: chat_a
    )
    failures += 1 unless check('stop followup capped', no_followup.nil?)

    legacy_raw = JSON.parse(File.read(legacy))
    failures += 1 unless check(
      'legacy global file neutralized (pending false)',
      legacy_raw['pending'] == false && legacy_raw['legacy_disabled'] == true
    )
  ensure
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_PATH)
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_DIR)
    SaneGuiFeedback.const_set(:CURSOR_STATE_PATH, original_path)
    SaneGuiFeedback.const_set(:CURSOR_STATE_DIR, original_dir)
  end
end

if failures.zero?
  warn 'ALL PASS'
  exit 0
else
  warn "FAILED: #{failures}"
  exit 1
end
