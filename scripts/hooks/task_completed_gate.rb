#!/usr/bin/env ruby
# frozen_string_literal: true

# TaskCompleted hook: warns if tests haven't been verified before marking a task done
# Currently WARNS only (exit 0) — change to exit 2 to enforce blocking
# Checks for recent test/build results from local or mini builds

require 'json'
require 'time'

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

# Only check for SaneApps projects
cwd = Dir.pwd
exit 0 unless cwd.include?('SaneApps/apps/')

app_name = cwd.match(%r{SaneApps/apps/(\w+)})&.[](1)
exit 0 unless app_name

task_subject = input['task_subject'] || 'unknown task'

def recent_visual_artifacts(cwd)
  roots = %w[outputs screenshots Screenshots]
  extensions = %w[png jpg jpeg md json]
  cutoff = Time.now - 3600

  roots.flat_map do |root|
    root_path = File.join(cwd, root)
    next [] unless Dir.exist?(root_path)

    extensions.flat_map { |ext| Dir.glob(File.join(root_path, '**', "*.#{ext}")) }
  end.flatten.uniq.select do |path|
    next false unless File.mtime(path) >= cutoff

    File.basename(path).match?(/visual|screenshot|audit/i) ||
      path.match?(%r{/visual[-_]audit}i)
  rescue StandardError
    false
  end
rescue StandardError
  []
end

def visual_state(cwd)
  state_file = File.join(cwd, '.claude', 'state.json')
  return {} unless File.exist?(state_file)

  JSON.parse(File.read(state_file))['visual_verification'] || {}
rescue JSON::ParserError, Errno::ENOENT
  {}
end

visual = visual_state(cwd)
if visual['required']
  has_evidence = Array(visual['evidence_commands']).any? ||
                 Array(visual['screenshot_paths']).any? ||
                 recent_visual_artifacts(cwd).any?
  has_audit = visual['audit_recorded'] == true ||
              Array(visual['audit_files']).any? ||
              recent_visual_artifacts(cwd).any? { |path| path.match?(/\.(md|json)$/i) }

  unless has_evidence && has_audit
    warn "🔴 Task \"#{task_subject}\" completed without required visual screenshot audit"
    warn '   Visual UI work must include clean saved screenshots for every customer-facing view/state.'
    warn '   Also record a written audit receipt with screenshot paths and visual verdicts.'
    warn '   Run Mini visual proof, then update SESSION_HANDOFF.md or outputs/visual-audit*/.'
    exit 2
  end
end

# Check 1: Recent mini build result (within last 10 minutes)
mini_result_file = "/tmp/mini-build-#{app_name}.result"
mini_ok = false
if File.exist?(mini_result_file)
  lines = File.readlines(mini_result_file).map(&:strip)
  if lines[0] == 'PASS' && lines[1]
    result_time = Time.parse(lines[1]) rescue nil
    mini_ok = result_time && (Time.now - result_time) < 600 # 10 minutes
  end
end

# Check 2: Recent local test result (SaneMaster verify writes this)
local_result_file = "/tmp/sanemaster-#{app_name}-verify.result"
local_ok = false
if File.exist?(local_result_file)
  lines = File.readlines(local_result_file).map(&:strip)
  if lines[0] == 'PASS' && lines[1]
    result_time = Time.parse(lines[1]) rescue nil
    local_ok = result_time && (Time.now - result_time) < 600
  end
end

if mini_ok || local_ok
  source = mini_ok ? 'mini' : 'local'
  warn "✅ Task \"#{task_subject}\" completed — verified by #{source} build"
  exit 0
else
  warn "⚠️  Task \"#{task_subject}\" completed without recent test verification"
  warn "   Run: ./scripts/SaneMaster.rb verify  OR  mini-build.sh #{app_name}"
  warn "   (This is a warning — not blocking. Set exit 2 in task_completed_gate.rb to enforce.)"
  exit 0 # Change to `exit 2` to block task completion without tests
end
