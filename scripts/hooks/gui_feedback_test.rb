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
  state_dir = File.join(dir, 'by-conversation')
  original_path = SaneGuiFeedback::CURSOR_STATE_PATH
  original_dir = SaneGuiFeedback::CURSOR_STATE_DIR
  begin
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_PATH)
    SaneGuiFeedback.send(:remove_const, :CURSOR_STATE_DIR)
    SaneGuiFeedback.const_set(:CURSOR_STATE_PATH, File.join(dir, 'legacy.json'))
    SaneGuiFeedback.const_set(:CURSOR_STATE_DIR, state_dir)

    SaneGuiFeedback.track_command!(
      'playwright fill password=super-secret-value then click button "Update Review"',
      conversation_id: 'chat-a'
    )
    chat_a_scope = SaneGuiFeedback.resolve_scope(conversation_id: 'chat-a')
    failures += 1 unless check('pending after scoped GUI click', SaneGuiFeedback.pending?(scope: chat_a_scope))
    state_path = SaneGuiFeedback.state_file_for(chat_a_scope)
    state_text = File.read(state_path)
    failures += 1 unless check('state stores no raw command or secret', !state_text.include?('super-secret-value'))
    failures += 1 unless check('state directory is private', (File.stat(state_dir).mode & 0o777) == 0o700)
    failures += 1 unless check('state file is private', (File.stat(state_path).mode & 0o777) == 0o600)
    failures += 1 unless check(
      'atomic state write leaves no temp files',
      Dir.children(state_dir).none? { |entry| entry.end_with?('.tmp') }
    )

    payload = SaneGuiFeedback.cursor_after_shell_payload(
      command: 'osascript -e \'click button "Submit"\'',
      output: 'Newer Build Available',
      conversation_id: 'chat-a'
    )
    failures += 1 unless check(
      'cursor after-shell injects additional_context',
      payload.is_a?(Hash) && payload[:additional_context].to_s.include?('GUI ACTION FEEDBACK LOOP')
    )

    SaneGuiFeedback.track_command!('ruby scripts/asc.rb get submission status', conversation_id: 'chat-a')
    failures += 1 unless check('cleared after feedback poll', !SaneGuiFeedback.pending?(scope: chat_a_scope))

    SaneGuiFeedback.track_command!('osascript -e \'click button "Update Review"\'', conversation_id: 'chat-a')
    followup = SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 0, conversation_id: 'chat-a')
    failures += 1 unless check(
      'stop followup when pending',
      followup.to_s.include?('GUI feedback loop incomplete')
    )

    no_followup = SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 2, conversation_id: 'chat-a')
    failures += 1 unless check('stop followup capped', no_followup.nil?)

    other = SaneGuiFeedback.cursor_stop_followup(status: 'completed', loop_count: 0, conversation_id: 'chat-b')
    failures += 1 unless check('pending state does not leak across conversations', other.nil?)

    workspace_only = SaneGuiFeedback.track_command!(
      'osascript -e \'click button "Update Review"\'',
      workspace_roots: ['/same/project']
    )
    failures += 1 unless check('workspace-only state cannot leak across chats', workspace_only == :noop)
    failures += 1 unless check(
      'workspace-only stop cannot read another chat',
      SaneGuiFeedback.cursor_stop_followup(
        status: 'completed', loop_count: 0, workspace_roots: ['/same/project']
      ).nil?
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
