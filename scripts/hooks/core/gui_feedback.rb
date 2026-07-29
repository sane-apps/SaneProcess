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
  CURSOR_STATE_PATH = File.expand_path('~/.cursor/sane_gui_feedback.json').freeze
  PENDING_TTL_SECONDS = 30 * 60

  # Mutations that change a GUI/portal surface. Click return is not proof.
  # Do NOT match bare `osascript` — completion chimes use
  # `osascript -e 'display notification …'` and are not portal clicks.
  GUI_ACTION_PATTERNS = [
    /\bSystem Events\b/i,
    /\bclick\b.*\b(?:button|menu item|UI element|checkbox|radio)\b/i,
    /\bkeystroke\b/i,
    /\bkey code\b/i,
    /\btell application\b.*\bBrave\b/i,
    /\bBrave Browser\b.*\b(?:click|keystroke|execute|javascript|do JavaScript)\b/i,
    /\bappstoreconnect\.apple\.com\b/i,
    /\bApple Developer\b/i,
    /\bResolution Center\b/i,
    /\bUpdate Review\b/i,
    /\bSubmit for Review\b/i,
    /\bpeekaboo\b.*\bclick\b/i,
    /\bmini-gui-run\.sh\b/i,
    /\bcliclick\b/i,
    /\bxdotool\b/i
  ].freeze

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
    /\bAX\b.*\b(?:UI element|attribute|description)\b/i,
    /\baccessibility\b/i,
    /\bget (?:every |the )?(?:dialog|sheet|window|button|static text)\b/i,
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
    return false if benign_osascript?(text)
    return false if feedback_poll?(text) && !mutationish?(text)

    GUI_ACTION_PATTERNS.any? { |pattern| text.match?(pattern) }
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

  def track_command!(command)
    text = command.to_s
    return :noop if text.strip.empty?

    if feedback_poll?(text)
      clear_pending!
      return :cleared
    end

    return :noop unless gui_action?(text)

    mark_pending!(text)
    :pending
  end

  def mark_pending!(command)
    summary = command.to_s.gsub(/\s+/, ' ').strip[0, 180]
    write_cursor_state(
      pending: true,
      last_action: summary,
      last_action_at: Time.now.iso8601,
      cleared_at: nil
    )
    track_state_manager_pending!(summary)
  end

  def clear_pending!
    write_cursor_state(
      pending: false,
      last_action: cursor_state[:last_action],
      last_action_at: cursor_state[:last_action_at],
      cleared_at: Time.now.iso8601
    )
    track_state_manager_cleared!
  end

  def pending?
    state = merged_pending_state
    return false unless state[:pending]
    return false if stale?(state[:last_action_at])

    true
  end

  def pending_summary
    merged_pending_state[:last_action].to_s
  end

  def cursor_after_shell_payload(command:, output: nil)
    result = track_command!(command)
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

  def cursor_stop_followup(status:, loop_count:)
    return nil unless status.to_s == 'completed'
    return nil if loop_count.to_i >= 2
    return nil unless pending?

    action = pending_summary
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

  def cursor_state
    return {} unless File.file?(CURSOR_STATE_PATH)

    raw = JSON.parse(File.read(CURSOR_STATE_PATH))
    {
      pending: raw['pending'] == true,
      last_action: raw['last_action'],
      last_action_at: raw['last_action_at'],
      cleared_at: raw['cleared_at']
    }
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def write_cursor_state(pending:, last_action:, last_action_at:, cleared_at:)
    FileUtils.mkdir_p(File.dirname(CURSOR_STATE_PATH))
    payload = {
      pending: pending,
      last_action: last_action,
      last_action_at: last_action_at,
      cleared_at: cleared_at
    }
    File.write(CURSOR_STATE_PATH, JSON.pretty_generate(payload))
  rescue StandardError
    # Fail open — never break the agent loop on state I/O.
  end

  def track_state_manager_pending!(summary)
    return unless defined?(StateManager)

    StateManager.update(:gui_feedback) do |state|
      state ||= {}
      state[:pending] = true
      state[:last_action] = summary
      state[:last_action_at] = Time.now.iso8601
      state[:cleared_at] = nil
      state
    end
  rescue StandardError
    nil
  end

  def track_state_manager_cleared!
    return unless defined?(StateManager)

    StateManager.update(:gui_feedback) do |state|
      state ||= {}
      state[:pending] = false
      state[:cleared_at] = Time.now.iso8601
      state
    end
  rescue StandardError
    nil
  end

  def merged_pending_state
    sm = {}
    if defined?(StateManager)
      begin
        sm = StateManager.get(:gui_feedback) || {}
      rescue StandardError
        sm = {}
      end
    end
    file = cursor_state
    # Prefer the freshest pending marker.
    candidates = [sm, file].select { |h| h[:pending] || h['pending'] }
    return file.merge(sm) if candidates.empty?

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
