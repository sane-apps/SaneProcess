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
# Validated via StateSigner (HMAC-signed, git SHA checked, 4-hour TTL).

require 'json'
require 'time'

CLEARANCE_DIR = File.expand_path('~/.claude/ship_clearance')
CLEARANCE_TTL_SECONDS = 4 * 3600 # 4 hours

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
is_release = command.match?(/(?:bash\s+|sh\s+)?(?:\S+\/)?(?:full_)?release\.sh\b/)
has_gate_flag = command.match?(/--(?:full|deploy)\b/)
exit 0 unless is_release && has_gate_flag

# Always allow SaneMaster.rb (preflight checks etc.)
exit 0 if command.match?(/\bSaneMaster\.rb\b/)

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

# Check git SHA matches current HEAD
current_sha = `git -C #{project_dir} rev-parse HEAD 2>/dev/null`.strip
if data['git_sha'] && data['git_sha'] != current_sha
  warn "🔴 BLOCKED: Code changed since /ship clearance for #{app_name}"
  warn "   Clearance SHA: #{data['git_sha'][0..7]}"
  warn "   Current HEAD:  #{current_sha[0..7]}"
  warn ''
  warn '   A commit was made after clearance. Run /ship again.'
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
