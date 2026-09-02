# frozen_string_literal: true

# ==============================================================================
# GUI action feedback loop — shared detection for Claude + Cursor hooks
# ==============================================================================
# Owner complaint (2026-07-29): agents click ASC/Brave/osascript controls, treat
# exit 0 / click return as success, and skip reading dialogs, page body, AX, or
# API state. This module is the single detector + reminder text so we do not
# fragment the rule across clients.
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'

module SaneGuiFeedback
  # Legacy global path — read only for migration; never write pending here.
  # Cross-chat leak (2026-09-02): one pending file made T&Z Mini GUI alerts
  # fire in unrelated Cursor chats via the global stop hook.
  CURSOR_STATE_PATH = File.expand_path('~/.cursor/sane_gui_feedback.json').freeze
  CURSOR_STATE_DIR = File.expand_path('~/.cursor/sane_gui_feedback').freeze
  PENDING_TTL_SECONDS = 30 * 60

  # Hard mutations: always a GUI/portal action. Click return is not proof.
  # Do NOT match bare `osascript` — completion chimes use
  # `osascript -e 'display notification …'` and are not portal clicks.
  # Do NOT match bare `System Events` — AX/window reads are feedback polls.
  HARD_GUI_PATTERNS = [
    /\bSystem Events\b.*\b(?:click|keystroke|key code|set value|select menu|perform action)\b/i,
    /\b(?:click|keystroke|key code|set value|select menu|perform action)\b.*\bSystem Events\b/i,
    /\bclick\b.*\b(?:button|menu item|UI element|checkbox|radio)\b/i,
    /\bkeystroke\b/i,
    /\bkey code\b/i,
    /\btell application\b.*\bBrave\b/i,
    /\bBrave Browser\b.*\b(?:click|keystroke|execute|javascript|do JavaScript)\b/i,
    /\bpeekaboo\b.*\bclick\b/i,
    /\bmini-gui-run\.sh\b/i,
    /\bcliclick\b/i,
    /\bxdotool\b/i,
    /\bplaywright\b.*\b(?:click|goto|fill|locator|setInputFiles)\b/i,
    /\bchromium\.connectOverCDP\b/i
  ].freeze

  # Soft portal phrases: only GUI when paired with automation context.
  # Otherwise `git commit -m "... Update Review ..."` false-positives (2026-07-29).
  SOFT_PORTAL_PATTERNS = [
    /\bappstoreconnect\.apple\.com\b/i,
    /\bApple Developer\b/i,
    /\bResolution Center\b/i,
    /\bUpdate Review\b/i,
    /\bSubmit for Review\b/i
  ].freeze

  AUTOMATION_CONTEXT_PATTERNS = [
    /\bosascript\b/i,
    /\bSystem Events\b/i,
    /\bBrave\b/i,
    /\bplaywright\b/i,
    /\bpeekaboo\b/i,
    /\bcliclick\b/i,
    /\bmini-gui-run\.sh\b/i,
    /\bxdotool\b/i,
    /\bconnectOverCDP\b/i,
    /\bfilechooser\b/i
  ].freeze

  # Kept for callers/tests that still reference the combined list.
  GUI_ACTION_PATTERNS = (HARD_GUI_PATTERNS + SOFT_PORTAL_PATTERNS).freeze

  # Completely ignore these even if other patterns match in the same shell blob.
  BENIGN_OSASCRIPT_PATTERNS = [
    /display notification/i,
    /\bbeep\b/i,
    /\bsay\b/i,
    /current date/i,
    /clipboard info/i
  ].freeze

  # Bound polls that count as reading feedback after a GUI mutation.
  FEEDBACK_POLL_PATTERNS = [
    /\bcapture-mini-screenshot\.sh\b/i,
    /\bcapture-web-screenshot\.sh\b/i,
    /\bscreencapture\b/i,
    /\bsimctl\b.*\bscreenshot\b/i,
    /\bxcrun simctl io\b.*\bscreenshot\b/i,
    /\blive-gui-feedback-.*\.png\b/i,
    /\bAX\b.*\b(?:UI element|attribute|description)\b/i,
    /\baccessibility\b/i,
    /\bget (?:every |the )?(?:dialog|sheet|window|button|static text)\b/i,
    /\b(?:name|value|role|description|title) of (?:every |the )?(?:window|button|UI element|process)\b/i,
    /\bentire contents of window\b/i,
    /\bUI elements?\b/i,
    /\bdocument\.body\b/i,
    /\binnerText\b/i,
    /\binnerHTML\b/i,
    /\bquerySelector\b/i,
    /\bpage\.content\b/i,
    /\bpage\.textContent\b/i,
    /\basc\.rb\b.*\b(?:get|show|status|build|submission)\b/i,
    /\bappstoreconnect\.apple\.com\b.*\b(?:curl|http|api)\b/i,
    %r{\bapi\.appstoreconnect\.apple\.com\b}i,
    /\bNewer Build Available\b/i,
    /\bunresolved.?issues\b/i,
    /\bWAITING_FOR_REVIEW\b/i,
    /\bPREPARE_FOR_SUBMISSION\b/i,
    /\bIN_REVIEW\b/i
  ].freeze

  # Signals in command output that mean "read me before claiming done".
  OUTPUT_FEEDBACK_SIGNALS = [
    /newer build available/i,
    /unresolved.?issues/i,
    /are you sure/i,
    /permission (?:is )?required/i,
    /tcc|screen recording|accessibility/i,
    /dialog|sheet|modal|alert/i,
    /error|failed|denied|rejected|blocked/i,
    /waiting for review|prepare for submission|in review/i
  ].freeze

  PORTAL_PROMPT_PATTERN = Regexp.union(
    /\bApp Store Connect\b/i,
    /\bASC\b/,
    /\bResolution Center\b/i,
    /\bApp Review\b/i,
    /\bUpdate Review\b/i,
    /\bSubmit for Review\b/i,
    /\bBrave\b.*\b(?:click|portal|ASC|App Store)\b/i,
    /\bGUI\b.*\b(?:click|automation|portal)\b/i,
    /\bportal\b.*\b(?:click|submit|Brave|ASC)\b/i
  ).freeze

  module_function

  def gui_action?(command)
    text = command.to_s
    return false if text.strip.empty?
    return false if detector_self_exercise?(text)
    return false if benign_osascript?(text)
    return false if git_docs_only?(text)
    return false if feedback_poll?(text) && !mutationish?(text)

    return true if HARD_GUI_PATTERNS.any? { |pattern| text.match?(pattern) }

    soft = SOFT_PORTAL_PATTERNS.any? { |pattern| text.match?(pattern) }
    soft && automation_context?(text)
  end

  # Running the detector's own tests (or inlined SaneGuiFeedback.* checks) embeds
  # "System Events" / "click button" fixture strings in the shell command. Those
  # must not arm pending or the stop hook fires in the wrong chat (2026-09-02).
  def detector_self_exercise?(command)
    text = command.to_s
    return true if text.match?(%r{(?:^|[/\s])gui_feedback_test\.rb\b})
    return true if text.match?(
      /\bSaneGuiFeedback\.(?:gui_action\?|track_command!|cursor_after_shell_payload|cursor_stop_followup|feedback_poll\?|mark_pending!|clear_pending!|pending\?)/
    )
    return true if text.match?(%r{scripts/hooks/core/gui_feedback\.rb}) && text.match?(/\b(?:require|require_relative)\b/)

    false
  end

  def automation_context?(command)
    AUTOMATION_CONTEXT_PATTERNS.any? { |pattern| command.to_s.match?(pattern) }
  end

  # git commit/push/add with portal words in the message is not a GUI click.
  def git_docs_only?(command)
    text = command.to_s
    return false unless text.match?(/\bgit\s+(?:add|commit|push|status|diff|log|show|restore|stash|pull|fetch|rebase|checkout|branch|tag)\b/i)
    return false if HARD_GUI_PATTERNS.any? { |pattern| text.match?(pattern) }
    return false if automation_context?(text)

    true
  end

  def benign_osascript?(command)
    text = command.to_s
    return false unless text.match?(/\bosascript\b/i)
    return true if BENIGN_OSASCRIPT_PATTERNS.any? { |pattern| text.match?(pattern) }

    # osascript with only a notification/chime and no UI mutation verbs.
    !mutationish?(text) &&
      !text.match?(/\bSystem Events\b/i) &&
      !text.match?(/\bBrave\b/i) &&
      !text.match?(/\bappstoreconnect\b/i)
  end

  def feedback_poll?(command)
    text = command.to_s
    return false if text.strip.empty?

    FEEDBACK_POLL_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def mutationish?(command)
    text = command.to_s
    text.match?(/\b(?:click|keystroke|key code|Submit|Update Review|type text|set value)\b/i)
  end

  def output_needs_attention?(output)
    text = output.to_s
    return false if text.strip.empty?

    OUTPUT_FEEDBACK_SIGNALS.any? { |pattern| text.match?(pattern) }
  end

  def portal_prompt?(prompt)
    prompt.to_s.match?(PORTAL_PROMPT_PATTERN)
  end

  def reminder_text(action_summary: nil, output_signal: false)
    summary = action_summary.to_s.strip
    summary = summary[0, 120] unless summary.empty?
    lines = []
    lines << 'GUI ACTION FEEDBACK LOOP (permanent)'
    lines << "  Last GUI mutation: #{summary}" unless summary.empty?
    lines << '  Click/keystroke/osascript exit 0 is NOT success.'
    lines << '  Before claiming done or clicking again:'
    lines << '    1. Re-read the live page/dialog/AX/API state (bound poll).'
    lines << '    2. Name what the UI actually shows (dialog title, build #, status).'
    lines << '    3. Only then decide next click — or stop and report the blocker.'
    lines << '  Capture a Mini screenshot if the surface contradicts expectations.'
    if output_signal
      lines << '  OUTPUT SIGNAL: the last command already showed dialog/page feedback — read it.'
    end
    lines.join("\n")
  end

  def prompt_inject_text
    [
      'GUI ACTION FEEDBACK LOOP REQUIRED for this portal/GUI task:',
      '  After every click/keystroke/osascript/Brave portal action, poll the live',
      '  dialog/page/AX/API state before claiming success. Never treat click return',
      '  as done. If a dialog appears (e.g. Newer Build Available), cancel or resolve',
      '  it deliberately — do not Submit through it blind.'
    ].join("\n")
  end

  def track_command!(command, conversation_id: nil)
    text = command.to_s
    return :noop if text.strip.empty?

    if feedback_poll?(text)
      clear_pending!(conversation_id: conversation_id)
      return :cleared
    end

    return :noop unless gui_action?(text)

    mark_pending!(text, conversation_id: conversation_id)
    :pending
  end

  def mark_pending!(command, conversation_id: nil)
    summary = command.to_s.gsub(/\s+/, ' ').strip[0, 180]
    write_cursor_state(
      conversation_id: conversation_id,
      pending: true,
      last_action: summary,
      last_action_at: Time.now.iso8601,
      cleared_at: nil
    )
    track_state_manager_pending!(summary, conversation_id: conversation_id)
  end

  def clear_pending!(conversation_id: nil)
    prior = cursor_state(conversation_id: conversation_id)
    write_cursor_state(
      conversation_id: conversation_id,
      pending: false,
      last_action: prior[:last_action],
      last_action_at: prior[:last_action_at],
      cleared_at: Time.now.iso8601
    )
    track_state_manager_cleared!(conversation_id: conversation_id)
  end

  def pending?(conversation_id: nil)
    state = merged_pending_state(conversation_id: conversation_id)
    return false unless state[:pending]
    return false if stale?(state[:last_action_at])

    true
  end

  def pending_summary(conversation_id: nil)
    merged_pending_state(conversation_id: conversation_id)[:last_action].to_s
  end

  def cursor_after_shell_payload(command:, output: nil, conversation_id: nil)
    result = track_command!(command, conversation_id: conversation_id)
    signal = output_needs_attention?(output)

    if result == :pending || (gui_action?(command) && signal)
      {
        additional_context: reminder_text(
          action_summary: command.to_s.gsub(/\s+/, ' ').strip,
          output_signal: signal
        )
      }
    elsif result == :cleared
      nil
    elsif signal && gui_action?(command)
      {
        additional_context: reminder_text(
          action_summary: command.to_s.gsub(/\s+/, ' ').strip,
          output_signal: true
        )
      }
    end
  end

  def cursor_stop_followup(status:, loop_count:, conversation_id: nil)
    return nil unless status.to_s == 'completed'
    return nil if loop_count.to_i >= 2
    # No conversation id → do not consult shared/legacy pending (cross-chat leak).
    return nil if conversation_id.to_s.strip.empty?
    return nil unless pending?(conversation_id: conversation_id)

    action = pending_summary(conversation_id: conversation_id)
    action_bit = action.empty? ? 'a GUI/portal mutation' : action
    'GUI feedback loop incomplete. You mutated a GUI/portal surface ' \
      "(#{action_bit}) but did not re-read dialog/page/AX/API state afterward. " \
      'Poll the live surface now, name what it shows, then continue or report the blocker. ' \
      'Do not claim success from click return alone.'
  end

  def stale?(timestamp)
    return true if timestamp.to_s.strip.empty?

    Time.now - Time.parse(timestamp.to_s) > PENDING_TTL_SECONDS
  rescue ArgumentError
    true
  end

  def normalize_conversation_id(conversation_id)
    id = conversation_id.to_s.strip
    return nil if id.empty?

    # Keep filesystem-safe; Cursor ids are usually UUID / hex.
    safe = id.gsub(/[^A-Za-z0-9._:-]/, '_')
    safe.empty? ? nil : safe
  end

  def cursor_state_path(conversation_id: nil)
    safe = normalize_conversation_id(conversation_id)
    return nil unless safe

    File.join(CURSOR_STATE_DIR, "#{safe}.json")
  end

  def cursor_state(conversation_id: nil)
    path = cursor_state_path(conversation_id: conversation_id)
    return {} unless path && File.file?(path)

    raw = JSON.parse(File.read(path))
    {
      pending: raw['pending'] == true,
      last_action: raw['last_action'],
      last_action_at: raw['last_action_at'],
      cleared_at: raw['cleared_at'],
      conversation_id: raw['conversation_id']
    }
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def write_cursor_state(pending:, last_action:, last_action_at:, cleared_at:, conversation_id: nil)
    path = cursor_state_path(conversation_id: conversation_id)
    # Without a conversation id, skip durable Cursor pending so stop hooks in
    # other chats cannot inherit it. Claude still uses StateManager below.
    if path
      FileUtils.mkdir_p(File.dirname(path))
      payload = {
        pending: pending,
        last_action: last_action,
        last_action_at: last_action_at,
        cleared_at: cleared_at,
        conversation_id: normalize_conversation_id(conversation_id)
      }
      File.write(path, JSON.pretty_generate(payload))
    end
    neutralize_legacy_global_state!
  rescue StandardError
    # Fail open — never break the agent loop on state I/O.
  end

  def neutralize_legacy_global_state!
    return unless File.file?(CURSOR_STATE_PATH)

    raw = begin
      JSON.parse(File.read(CURSOR_STATE_PATH))
    rescue JSON::ParserError
      {}
    end
    return if raw['pending'] != true && raw['legacy_disabled'] == true

    File.write(
      CURSOR_STATE_PATH,
      JSON.pretty_generate(
        pending: false,
        last_action: raw['last_action'],
        last_action_at: raw['last_action_at'],
        cleared_at: Time.now.iso8601,
        legacy_disabled: true,
        note: 'Global pending retired 2026-09-02; state is per conversation_id under sane_gui_feedback/'
      )
    )
  rescue StandardError
    nil
  end

  def track_state_manager_pending!(summary, conversation_id: nil)
    return unless defined?(StateManager)

    StateManager.update(:gui_feedback) do |state|
      state ||= {}
      state[:pending] = true
      state[:last_action] = summary
      state[:last_action_at] = Time.now.iso8601
      state[:cleared_at] = nil
      state[:conversation_id] = normalize_conversation_id(conversation_id)
      state
    end
  rescue StandardError
    nil
  end

  def track_state_manager_cleared!(conversation_id: nil)
    return unless defined?(StateManager)

    StateManager.update(:gui_feedback) do |state|
      state ||= {}
      owner = state[:conversation_id] || state['conversation_id']
      mine = normalize_conversation_id(conversation_id)
      # Claude (no conversation id): always clear. Cursor: only clear own row.
      if mine.nil? || owner.nil? || owner.to_s == mine.to_s
        state[:pending] = false
        state[:cleared_at] = Time.now.iso8601
      end
      state
    end
  rescue StandardError
    nil
  end

  def merged_pending_state(conversation_id: nil)
    safe = normalize_conversation_id(conversation_id)
    sm = {}
    if defined?(StateManager)
      begin
        sm = StateManager.get(:gui_feedback) || {}
      rescue StandardError
        sm = {}
      end
    end

    sm_pending = sm[:pending] == true || sm['pending'] == true
    sm_owner = sm[:conversation_id] || sm['conversation_id']

    # Claude sanestop/sanetrack: conversation_id is nil → honor project StateManager.
    # Cursor stop: conversation_id required → only matching scoped file (+ matching SM).
    if safe.nil?
      return {
        pending: sm_pending,
        last_action: sm[:last_action] || sm['last_action'],
        last_action_at: sm[:last_action_at] || sm['last_action_at']
      }
    end

    sm_usable = sm_pending && !sm_owner.to_s.strip.empty? && sm_owner.to_s == safe
    file = cursor_state(conversation_id: conversation_id)
    candidates = []
    candidates << sm if sm_usable
    candidates << file if file[:pending]

    return { pending: false } if candidates.empty?

    candidates.max_by do |h|
      ts = h[:last_action_at] || h['last_action_at']
      begin
        Time.parse(ts.to_s).to_i
      rescue ArgumentError
        0
      end
    end.then do |best|
      {
        pending: true,
        last_action: best[:last_action] || best['last_action'],
        last_action_at: best[:last_action_at] || best['last_action_at']
      }
    end
  end
end
