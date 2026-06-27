#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneStop — Session Learnings Capture
# ==============================================================================
# Writes structured session learnings to ~/.claude/session_learnings.jsonl when
# the session had significant work, and caps the file. Extracted from
# sanestop_finalize.rb per Rule #10 (file size limit).
#
# The SESSION_LEARNINGS_* constants are defined in sanestop.rb and referenced
# here at call time (runtime), so load order does not matter.
# ==============================================================================

require 'json'
require 'date'
require 'fileutils'
require_relative 'core/state_manager'

def capture_session_learnings
  edits = StateManager.get(:edits)
  cb = StateManager.get(:circuit_breaker)

  edit_count = edits[:count] || 0
  unique_files = edits[:unique_files] || []
  tripped = cb[:tripped] || false

  # Only capture if significant work happened
  return unless edit_count >= 3 || tripped

  project = File.basename(Dir.pwd)

  session_type = if tripped
                   'recovery'
                 elsif edit_count >= 5
                   'feature'
                 else
                   'maintenance'
                 end

  file_names = unique_files.map { |f| File.basename(f) }.uniq.first(5)
  summary = "#{edit_count} edits across #{unique_files.length} files: #{file_names.join(', ')}"

  entry = {
    date: Date.today.to_s,
    project: project,
    type: session_type,
    summary: summary,
    files: unique_files.first(10),
    failures: cb[:failures] || 0,
    breaker_tripped: tripped
  }

  FileUtils.mkdir_p(File.dirname(SESSION_LEARNINGS_FILE))
  File.open(SESSION_LEARNINGS_FILE, 'a') { |f| f.puts(entry.to_json) }
  enforce_learnings_cap
rescue StandardError => e
  warn "⚠️  Session learnings capture error: #{e.message}" if ENV['DEBUG']
end

def enforce_learnings_cap
  return unless File.exist?(SESSION_LEARNINGS_FILE)

  lines = File.readlines(SESSION_LEARNINGS_FILE, encoding: Encoding::UTF_8)
  return if lines.length <= SESSION_LEARNINGS_MAX_LINES

  overflow = lines.length - SESSION_LEARNINGS_MAX_LINES
  archived = lines.first(overflow)
  kept = lines.last(SESSION_LEARNINGS_MAX_LINES)

  File.open(SESSION_LEARNINGS_ARCHIVE, 'a') { |f| archived.each { |l| f.write(l) } }
  File.write(SESSION_LEARNINGS_FILE, kept.join)
rescue StandardError
  # Don't fail on cap enforcement
end
