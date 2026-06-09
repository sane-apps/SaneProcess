#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_ship_guard.rb — PreToolUse hook
# Blocks `release.sh --full` and `release.sh --deploy` without valid /ship clearance.
#
# BLOCKS:
#   - release.sh --full (without clearance)
#   - release.sh --deploy (without clearance)
#
# ALLOWS:
#   - release.sh without --full/--deploy (local build only)
#   - SaneMaster.rb release_preflight / appstore_preflight (always allowed)
#   - Any command when valid clearance exists
#
# Clearance is written by /ship skill at ~/.claude/ship_clearance/<AppName>.json
# Validated via StateSigner (HMAC-signed, release-relevant source drift checked, 4-hour TTL).

require 'json'
require 'shellwords'
require 'time'

CLEARANCE_DIR = File.expand_path('~/.claude/ship_clearance')
CLEARANCE_TTL_SECONDS = 4 * 3600 # 4 hours

def release_relevant_clearance_path?(project_dir, relative_path)
  path = relative_path.to_s
  return false if path.empty?
  return true if path == '.saneprocess'
  return true if %w[Package.resolved Package.swift project.yml].include?(path)
  return true if path.end_with?('.xcodeproj/project.pbxproj')

  app_folder = File.basename(File.expand_path(project_dir))
  return true if path.start_with?("#{app_folder}/")
  return true if path.start_with?('Config/', 'Scripts/', 'Shared/', 'Sources/', 'Tests/', 'scripts/')

  return false if %w[
    AGENTS.md ARCHITECTURE.md CLAUDE.md DEVELOPMENT.md README.md SESSION_HANDOFF.md
  ].include?(path)
  return false if path.start_with?(
    '.build/',
    '.claude/',
    '.codex/',
    '.git/',
    '.sane/',
    '.sanemaster/',
    '.serena/',
    'DerivedData/',
    'build/',
    'docs/',
    'fastlane/test_output/',
    'node_modules/',
    'outputs/',
    'releases/',
    'vendor/bundle/',
    'website/'
  )

  %w[
    .c .cc .cpp .entitlements .h .json .metal .m .mm .plist .rb .sh .storyboard
    .swift .xcconfig .xcprivacy .xcstrings .xib .yaml .yml
  ].include?(File.extname(path))
end

def release_relevant_commits_changed?(project_dir, old_sha, current_sha)
  return true if old_sha.to_s.empty? || current_sha.to_s.empty?
  return false if old_sha == current_sha

  out = `git -C #{project_dir.shellescape} diff --name-only #{old_sha.shellescape}..#{current_sha.shellescape} 2>/dev/null`
  return true if out.to_s.empty? && !$?.success?

  out.each_line.map(&:strip).reject(&:empty?).any? do |path|
    release_relevant_clearance_path?(project_dir, path)
  end
end

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

# Only gate release.sh with --full or --deploy
# Match: release.sh (with optional path prefix) AND --full or --deploy flag
# Strip quoted strings first so commit messages like
#   git commit -m "fix release.sh --full flow" don't false-positive
unquoted = command.gsub(/"(?:[^"\\]|\\.)*"/m, '').gsub(/'[^']*'/m, '')
# Also strip heredoc bodies (<<'EOF' ... EOF or <<EOF ... EOF)
unquoted = unquoted.sub(/<<-?'?\w+'?.*/m, '')
is_release = unquoted.match?(/(?:bash\s+|sh\s+)?(?:\S+\/)?(?:full_)?release\.sh\b/)
has_gate_flag = unquoted.match?(/--(?:full|deploy)\b/)
exit 0 unless is_release && has_gate_flag

# Determine project directory from --project flag or current directory
project_dir = if command =~ /--project\s+(\S+)/
                $1.gsub(/["']/, '')
              else
                Dir.pwd
              end

# Read .saneprocess to get app name
saneprocess_path = File.join(project_dir, '.saneprocess')
unless File.exist?(saneprocess_path)
  # Not a SaneApps project — allow (other guards handle non-SaneApps)
  exit 0
end

# Extract app name from .saneprocess (YAML-like: "name: AppName")
app_name = nil
File.readlines(saneprocess_path).each do |line|
  if line =~ /\Aname:\s*(\S+)/
    app_name = $1
    break
  end
end

unless app_name
  warn '🔴 BLOCKED: Cannot determine app name from .saneprocess'
  warn '   .saneprocess must have a "name:" field.'
  exit 2
end

# Check for clearance token
clearance_path = File.join(CLEARANCE_DIR, "#{app_name}.json")
unless File.exist?(clearance_path)
  warn "🔴 BLOCKED: No /ship clearance for #{app_name}"
  warn '   Run /ship first to clear the pre-submission pipeline.'
  warn ''
  warn '   The /ship pipeline runs: preflight → docs-audit → critic → clearance'
  warn '   Once cleared, release.sh --full/--deploy will be allowed.'
  exit 2
end

# Validate clearance via StateSigner
require_relative 'state_signer'

data = StateSigner.read_verified(clearance_path)
unless data
  warn "🔴 BLOCKED: Ship clearance signature invalid for #{app_name}"
  warn '   The clearance file has been tampered with or is corrupted.'
  warn '   Run /ship again to generate fresh clearance.'
  exit 2
end

# Check app name matches
unless data['app'] == app_name
  warn "🔴 BLOCKED: Clearance is for #{data['app']}, not #{app_name}"
  warn '   Run /ship in the correct project directory.'
  exit 2
end

# Check whether commits after clearance changed release-relevant inputs.
current_sha = `git -C #{project_dir.shellescape} rev-parse HEAD 2>/dev/null`.strip
if data['git_sha'] && release_relevant_commits_changed?(project_dir, data['git_sha'], current_sha)
  warn "🔴 BLOCKED: Release-relevant code changed since /ship clearance for #{app_name}"
  warn "   Clearance SHA: #{data['git_sha'][0..7]}"
  warn "   Current HEAD:  #{current_sha[0..7]}"
  warn ''
  warn '   Run /ship again. Receipt-only, docs-only, and generated-output commits do not invalidate clearance.'
  exit 2
end

# Check expiry
if data['expires_at']
  expires = Time.parse(data['expires_at']) rescue nil
  if expires && Time.now.utc > expires
    warn "🔴 BLOCKED: Ship clearance expired for #{app_name}"
    warn "   Cleared at: #{data['cleared_at']}"
    warn "   Expired at: #{data['expires_at']}"
    warn ''
    warn '   Clearance has a 4-hour TTL. Run /ship again.'
    exit 2
  end
end

# Check project directory matches
if data['project_dir'] && data['project_dir'] != project_dir
  warn "🔴 BLOCKED: Clearance project mismatch for #{app_name}"
  warn "   Clearance dir: #{data['project_dir']}"
  warn "   Current dir:   #{project_dir}"
  exit 2
end

# All checks passed — clearance is valid
exit 0
