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
  return true if path.start_with?('website/')
  return true if path == 'docs/appcast.xml' || path == 'docs/_redirects' || path.end_with?('/appcast.xml')

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
    'fastlane/test_output/',
    'node_modules/',
    'outputs/',
    'releases/',
    'vendor/bundle/',
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
  input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

def shell_unquote(value)
  text = value.to_s.strip
  if (text.start_with?('"') && text.end_with?('"')) ||
     (text.start_with?("'") && text.end_with?("'"))
    text[1..-2]
  else
    text
  end
end

def command_project_dir(command)
  if command =~ /\bcd\s+((?:"[^"]+"|'[^']+'|\S+))\s*(?:&&|;|\n)/
    return File.expand_path(shell_unquote(Regexp.last_match(1)))
  end

  if command =~ /--project\s+((?:"[^"]+"|'[^']+'|\S+))/
    return File.expand_path(shell_unquote(Regexp.last_match(1)))
  end

  Dir.pwd
end

# Only gate release.sh/SaneMaster release with --full or --deploy.
# --website-only is EXEMPT: it deploys marketing copy (docs/ + appcast) with no
# app build, signing, or App Store submission, so it does not need app /ship
# clearance. Wrong price/version/links on the live site are verified directly
# after deploy instead. (Full app releases via --full/--deploy still require it.)
# Match: release.sh (with optional path prefix) or SaneMaster release.
# Strip quoted strings first so commit messages like
#   git commit -m "fix release.sh --full flow" don't false-positive
unquoted = command.gsub(/"(?:[^"\\]|\\.)*"/m, '').gsub(/'[^']*'/m, '')
# Also strip heredoc bodies (<<'EOF' ... EOF or <<EOF ... EOF)
unquoted = unquoted.sub(/<<-?'?\w+'?.*/m, '')
is_release = unquoted.match?(/(?:bash\s+|sh\s+)?(?:\S+\/)?(?:full_)?release\.sh\b/)
is_sanemaster_release = unquoted.match?(/(?:ruby\s+)?(?:\S+\/)?SaneMaster(?:_standalone)?\.rb\s+release\b/)
has_gate_flag = unquoted.match?(/--(?:full|deploy)\b/)
exit 0 unless (is_release || is_sanemaster_release) && has_gate_flag

# Determine project directory from --project flag or current directory
project_dir = command_project_dir(command)

# Read .saneprocess to get app name
saneprocess_path = File.join(project_dir, '.saneprocess')
unless File.exist?(saneprocess_path)
  # Not a SaneApps project — allow (other guards handle non-SaneApps)
  exit 0
end

# Extract app name from .saneprocess (YAML-like: "name: AppName")
app_name = nil
File.readlines(saneprocess_path, encoding: Encoding::UTF_8).each do |line|
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

# Every clearance must identify the exact project and reviewed commit. Optional
# identity fields turn a signed but incomplete token into an indefinite bypass.
clearance_project = data['project_dir'].to_s.strip
clearance_sha = data['git_sha'].to_s.strip
project_matches = begin
  !clearance_project.empty? && File.realpath(clearance_project) == File.realpath(project_dir)
rescue Errno::ENOENT, Errno::EACCES
  false
end
unless project_matches
  warn "🔴 BLOCKED: Clearance project mismatch for #{app_name}"
  warn "   Clearance dir: #{clearance_project.empty? ? '(missing)' : clearance_project}"
  warn "   Current dir:   #{project_dir}"
  exit 2
end
unless clearance_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  warn "🔴 BLOCKED: Ship clearance is missing a valid git_sha for #{app_name}"
  warn '   Run /ship again to bind clearance to the reviewed commit.'
  exit 2
end

# Check whether commits after clearance changed release-relevant inputs.
current_sha = `git -C #{project_dir.shellescape} rev-parse HEAD 2>/dev/null`.strip
unless current_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  warn "🔴 BLOCKED: Could not resolve the current git SHA for #{app_name}"
  exit 2
end
if release_relevant_commits_changed?(project_dir, clearance_sha, current_sha)
  warn "🔴 BLOCKED: Release-relevant code changed since /ship clearance for #{app_name}"
  warn "   Clearance SHA: #{clearance_sha[0..7]}"
  warn "   Current HEAD:  #{current_sha[0..7]}"
  warn ''
  warn '   Run /ship again. Receipt-only, docs-only, and generated-output commits do not invalidate clearance.'
  exit 2
end

# Check expiry. Missing or malformed timestamps must fail closed; otherwise a
# corrupted signed token becomes effectively permanent.
begin
  expires = Time.parse(data['expires_at'].to_s)
rescue ArgumentError, TypeError
  expires = nil
end
unless expires && expires > Time.now.utc
  warn "🔴 BLOCKED: Ship clearance is missing, malformed, or expired for #{app_name}"
  warn "   Cleared at: #{data['cleared_at']}"
  warn "   Expires at: #{data['expires_at'].to_s.empty? ? '(missing)' : data['expires_at']}"
  warn ''
  warn '   Clearance has a 4-hour TTL. Run /ship again.'
  exit 2
end

# All checks passed — clearance is valid
exit 0
