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
require 'digest'
require 'securerandom'

module SaneGuiFeedback
  # Legacy single-file path (pre-2026-08-01). Never read it for live state.
  CURSOR_STATE_PATH = File.expand_path('~/.cursor/sane_gui_feedback.json').freeze
  CURSOR_STATE_DIR = File.expand_path('~/.cursor/sane_gui_feedback').freeze
  PENDING_TTL_SECONDS = 30 * 60

  # Hard mutations: always a GUI/portal action. Click return is not proof.
  # Do NOT match bare `osascript` — completion chimes use
  # `osascript -e 'display notification …'` and are not portal clicks.
  HARD_GUI_PATTERNS = [
    /\bSystem Events\b/i,
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
    return false if git_docs_only?(text)
    return false if feedback_poll?(text) && !mutationish?(text)

    return true if HARD_GUI_PATTERNS.any? { |pattern| text.match?(pattern) }

    soft = SOFT_PORTAL_PATTERNS.any? { |pattern| text.match?(pattern) }
    soft && automation_context?(text)
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

  def track_command!(command, conversation_id: nil, workspace_roots: nil)
    text = command.to_s
    return :noop if text.strip.empty?

    scope = resolve_scope(conversation_id: conversation_id, workspace_roots: workspace_roots)

    if feedback_poll?(text)
      clear_pending!(scope: scope)
      return :cleared
    end

    return :noop unless gui_action?(text)

    if scope.nil?
      # Claude's StateManager is session-local. Cursor without a conversation ID
      # must not fall back to machine- or workspace-global state.
      return :noop unless defined?(StateManager)

      track_state_manager_pending!(safe_action_summary(text))
      return :pending
    end

    mark_pending!(text, scope: scope)
    :pending
  end

  def mark_pending!(command, scope: nil)
    summary = safe_action_summary(command)
    write_cursor_state(
      scope: scope,
      pending: true,
      last_action: summary,
      last_action_at: Time.now.iso8601,
      cleared_at: nil
    )
    track_state_manager_pending!(summary)
  end

  def clear_pending!(scope: nil)
    if scope.to_s.empty?
      track_state_manager_cleared!
      return
    end

    prior = cursor_state(scope: scope)
    write_cursor_state(
      scope: scope,
      pending: false,
      last_action: prior[:last_action],
      last_action_at: prior[:last_action_at],
      cleared_at: Time.now.iso8601
    )
    track_state_manager_cleared!
  end

  def pending?(scope: nil)
    state = merged_pending_state(scope: scope)
    return false unless state[:pending]
    return false if stale?(state[:last_action_at])

    true
  end

  def pending_summary(scope: nil)
    merged_pending_state(scope: scope)[:last_action].to_s
  end

  def cursor_after_shell_payload(command:, output: nil, conversation_id: nil, workspace_roots: nil)
    scope = resolve_scope(conversation_id: conversation_id, workspace_roots: workspace_roots)
    result = track_command!(command, conversation_id: conversation_id, workspace_roots: workspace_roots)
    signal = output_needs_attention?(output)

    if result == :pending || (gui_action?(command) && signal && !scope.nil?)
      {
        additional_context: reminder_text(
          action_summary: safe_action_summary(command),
          output_signal: signal
        )
      }
    elsif result == :cleared
      nil
    elsif signal && gui_action?(command) && !scope.nil?
      {
        additional_context: reminder_text(
          action_summary: safe_action_summary(command),
          output_signal: true
        )
      }
    end
  end

  def cursor_stop_followup(status:, loop_count:, conversation_id: nil, workspace_roots: nil)
    return nil unless status.to_s == 'completed'
    return nil if loop_count.to_i >= 2

    scope = resolve_scope(conversation_id: conversation_id, workspace_roots: workspace_roots)
    return nil if scope.nil?
    return nil unless pending?(scope: scope)

    action = pending_summary(scope: scope)
    action_bit = action.empty? ? 'a GUI/portal mutation' : action
    'GUI feedback loop incomplete. You mutated a GUI/portal surface ' \
      "(#{action_bit}) but did not re-read dialog/page/AX/API state afterward. " \
      'Poll the live surface now, name what it shows, then continue or report the blocker. ' \
      'Do not claim success from click return alone.'
  end

  # Cursor conversations are the only safe cross-hook scope. A workspace is
  # shared by multiple chats and recreated the original cross-chat leak.
  def resolve_scope(conversation_id: nil, workspace_roots: nil)
    _ = workspace_roots
    cid = conversation_id.to_s.strip
    return nil if cid.empty?

    "conv:#{Digest::SHA256.hexdigest(cid)}"
  end

  # Persist only a category, never the raw shell command. GUI commands can carry
  # typed passwords, tokens, URLs, VINs, or customer data.
  def safe_action_summary(command)
    text = command.to_s
    return 'Playwright browser mutation' if text.match?(/\bplaywright\b/i)
    return 'Chromium CDP browser mutation' if text.match?(/connectOverCDP/i)
    return 'Brave browser mutation' if text.match?(/\bBrave(?: Browser)?\b/i)
    return 'System Events GUI mutation' if text.match?(/\bSystem Events\b/i)
    return 'AppleScript GUI mutation' if text.match?(/\bosascript\b/i)
    return 'Peekaboo GUI mutation' if text.match?(/\bpeekaboo\b/i)
    return 'cliclick GUI mutation' if text.match?(/\bcliclick\b/i)
    return 'xdotool GUI mutation' if text.match?(/\bxdotool\b/i)
    return 'Mini GUI mutation' if text.match?(/\bmini-gui-run\.sh\b/i)

    'GUI or portal mutation'
  end

  def stale?(timestamp)
    return true if timestamp.to_s.strip.empty?

    Time.now - Time.parse(timestamp.to_s) > PENDING_TTL_SECONDS
  rescue ArgumentError
    true
  end

  def state_file_for(scope)
    digest = Digest::SHA256.hexdigest(scope.to_s)
    File.join(CURSOR_STATE_DIR, "#{digest}.json")
  end

  def cursor_state(scope: nil)
    return {} if scope.to_s.empty?

    path = state_file_for(scope)
    return {} unless File.file?(path)

    raw = JSON.parse(File.read(path))
    {
      pending: raw['pending'] == true,
      last_action: raw['last_action'],
      last_action_at: raw['last_action_at'],
      cleared_at: raw['cleared_at'],
      scope_digest: raw['scope_digest']
    }
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def write_cursor_state(pending:, last_action:, last_action_at:, cleared_at:, scope: nil)
    return if scope.to_s.empty?

    FileUtils.mkdir_p(CURSOR_STATE_DIR, mode: 0o700)
    FileUtils.chmod(0o700, CURSOR_STATE_DIR)
    path = state_file_for(scope)
    temp = File.join(CURSOR_STATE_DIR, ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
    payload = {
      scope_digest: Digest::SHA256.hexdigest(scope.to_s),
      pending: pending,
      last_action: last_action,
      last_action_at: last_action_at,
      cleared_at: cleared_at
    }
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(payload))
      file.write("\n")
      file.flush
      file.fsync
    end
    File.rename(temp, path)
    FileUtils.chmod(0o600, path)
  rescue StandardError
    # Fail open — never break the agent loop on state I/O.
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp && File.exist?(temp)
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

  def merged_pending_state(scope: nil)
    return cursor_state(scope: scope) unless scope.to_s.empty?

    # Unscoped callers are Claude-only and use session-local StateManager.
    sm = {}
    if defined?(StateManager)
      begin
        sm = StateManager.get(:gui_feedback) || {}
      rescue StandardError
        sm = {}
      end
    end
    {
      pending: sm[:pending] == true || sm['pending'] == true,
      last_action: sm[:last_action] || sm['last_action'],
      last_action_at: sm[:last_action_at] || sm['last_action_at']
    }
  end
end
