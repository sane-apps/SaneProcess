# frozen_string_literal: true

# ==============================================================================
# Context Compact Warning
# ==============================================================================
# Monitors transcript size and warns user to run /compact before auto-compact
# destroys context. Called from PostToolUse (sanetrack.rb) so it fires during
# the session, not just at session end.
#
# Design: File.size is a fast stat() call. find_transcript caches the path.
# The expensive warning only fires when threshold is crossed.
# ==============================================================================

require_relative 'state_manager'
require_relative 'project_root'

module ContextCompact
  CLAUDE_DIR = File.expand_path('../../../.claude', __dir__)
  CONTEXT_WARN_THRESHOLD = 800_000  # bytes (~80% practical context in JSONL)
  CONTEXT_WARNED_FILE = File.join(CLAUDE_DIR, 'context_warned_size.txt')

  @cached_transcript_path = nil

  def self.find_transcript
    return @cached_transcript_path if @cached_transcript_path

    project_dir = SaneProjectRoot.resolve
    sanitized = project_dir.gsub('/', '-')
    session_dir = File.expand_path("~/.claude/projects/#{sanitized}")
    return nil unless Dir.exist?(session_dir)

    @cached_transcript_path = Dir.glob(File.join(session_dir, '*.jsonl')).max_by { |f| File.mtime(f) }
  rescue StandardError
    nil
  end

  def self.check_and_warn(transcript_path = nil)
    path = transcript_path || find_transcript
    return unless path && File.exist?(path)

    size = File.size(path)
    return if size < CONTEXT_WARN_THRESHOLD

    # Don't spam - only re-warn if 200KB more since last warning
    if File.exist?(CONTEXT_WARNED_FILE)
      last_size = File.read(CONTEXT_WARNED_FILE).to_i rescue 0
      return if size - last_size < 200_000
    end
    File.write(CONTEXT_WARNED_FILE, size.to_s) rescue nil

    cmd = generate_compact_command
    warn ''
    warn '=' * 60
    warn 'CONTEXT ~80% — COMPACT NOW BEFORE AUTO-COMPACT'
    warn ''
    warn 'Copy/paste this:'
    warn ''
    warn cmd
    warn ''
    warn '=' * 60
    warn ''
  end

  def self.generate_compact_command
    edits = StateManager.get(:edits)
    planning = StateManager.get(:planning)
    verification = StateManager.get(:verification)
    task_ctx = StateManager.get(:task_context)

    parts = []
    files = (edits[:unique_files] || []).map { |f| File.basename(f) }.uniq
    parts << "files: #{files.join(', ')}" if files.any?
    parts << "#{edits[:count]} edits" if (edits[:count] || 0) > 0
    parts << "plan pending approval" if planning[:required] && !planning[:plan_approved]
    if verification[:tests_passed] || verification[:verification_succeeded] || verification[:tests_run]
      parts << "tests passed"
    elsif (edits[:count] || 0) > 0
      parts << "tests NOT YET RUN"
    end
    kw = task_ctx[:task_keywords] || []
    parts << "task: #{kw.join(', ')}" if kw.any?

    ctx = parts.any? ? parts.join(', ') : 'work in progress'
    "/compact keep #{ctx}. Archive routine tool output."
  end
end
