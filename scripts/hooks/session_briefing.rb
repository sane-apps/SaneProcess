#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Session Briefing Module
# ==============================================================================
# Reads .saneprocess manifest and emits a compact, structured briefing that
# gets injected into Claude's context at session start.
#
# This replaces the AI having to "rediscover" project infrastructure every
# session. The briefing is deterministic — same project, same briefing.
#
# Usage:
#   require_relative 'session_briefing'
#   context = build_manifest_briefing(project_dir)
# ==============================================================================

require 'json'
require 'yaml'

SANEPROCESS_PATH = File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.saneprocess')

# Build a compact briefing from the .saneprocess manifest.
# Returns a string to inject into session context, or nil if no manifest.
def build_manifest_briefing(project_dir = nil)
  manifest_path = if project_dir
                    File.join(project_dir, '.saneprocess')
                  else
                    SANEPROCESS_PATH
                  end

  return nil unless File.exist?(manifest_path)

  begin
    m = YAML.load_file(manifest_path)
  rescue StandardError
    return nil
  end

  return nil unless m.is_a?(Hash)

  lines = []
  lines << "## Project: #{m['name']} (#{m['type']})"

  # Commands — the most forgotten, most repeated information
  if m['commands'].is_a?(Hash)
    lines << ''
    lines << '**Commands (USE THESE — do not guess):**'
    m['commands'].each do |cmd, val|
      lines << "  #{cmd}: `#{val}`"
    end
  end

  # MCPs — what's available, so the AI doesn't have to rediscover
  if m['mcps'].is_a?(Array) && m['mcps'].any?
    lines << ''
    lines << "**MCPs available:** #{m['mcps'].join(', ')}"
    lines << '  Research order: apple-docs/context7 FIRST, WebSearch LAST'
  end

  # Required docs — what must exist
  if m['docs'].is_a?(Array) && m['docs'].any?
    lines << ''
    lines << "**Required docs:** #{m['docs'].join(', ')}"
  end

  # Xcode project info
  if m['scheme']
    lines << ''
    lines << "**Xcode:** scheme=#{m['scheme']}"
    lines << "  project=#{m['project']}" if m['project']
  end

  # Website
  if m['website']
    lines << ''
    lines << "**Website:** #{m['website_domain'] || 'yes'}"
  end

  # SaneProcess hooks info
  lines << ''
  lines << '**Hooks:** Centralized (~/SaneApps/infra/SaneProcess/scripts/hooks/)'
  lines << '  Improve hooks in SaneProcess, all projects get the update.'

  lines.join("\n")
end

# Load recent session learnings for briefing context.
# Returns array of parsed learning hashes, newest last.
def load_recent_learnings(count = 5)
  learnings_file = File.expand_path('~/.claude/session_learnings.jsonl')
  return [] unless File.exist?(learnings_file)

  lines = File.readlines(learnings_file).last(count)
  lines.map { |l| JSON.parse(l) rescue nil }.compact
rescue StandardError
  []
end

# Validate manifest completeness — used by compliance checker
def validate_manifest(manifest_path)
  issues = []

  unless File.exist?(manifest_path)
    return ['.saneprocess manifest missing']
  end

  begin
    m = YAML.load_file(manifest_path)
  rescue StandardError => e
    return ["Invalid YAML: #{e.message}"]
  end

  issues << 'Missing: name' unless m['name']
  issues << 'Missing: type' unless m['type']
  issues << 'Missing: commands' unless m['commands'].is_a?(Hash)
  issues << 'Missing: docs' unless m['docs'].is_a?(Array)
  issues << 'Missing: mcps' unless m['mcps'].is_a?(Array)

  # Check required docs actually exist
  project_dir = File.dirname(manifest_path)
  if m['docs'].is_a?(Array)
    m['docs'].each do |doc|
      path = File.join(project_dir, doc)
      issues << "Missing doc: #{doc}" unless File.exist?(path)
    end
  end

  issues
end
