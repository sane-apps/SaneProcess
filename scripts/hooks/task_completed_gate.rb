#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

# TaskCompleted hook: blocks task completion when required verification is missing
# Checks for recent test/build results from local or mini builds

require 'json'
require 'time'
require 'yaml'
require 'digest'
require 'open3'
require 'set'
require_relative 'core/process_metrics'
require_relative 'core/project_root'
require_relative 'core/visual_receipt'

begin
  input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

cwd = SaneProjectRoot.resolve
task_subject = input['task_subject'] || 'unknown task'
DOC_ONLY_EXTENSIONS = %w[.md .txt .mdx .rst .adoc].freeze

def saneprocess_project_name(cwd)
  app_name = cwd.match(%r{SaneApps/apps/(\w+)})&.[](1)
  return app_name if app_name

  manifest_path = File.join(cwd, '.saneprocess')
  return nil unless File.exist?(manifest_path)

  manifest = YAML.safe_load(File.read(manifest_path, encoding: Encoding::UTF_8)) || {}
  manifest['name'] || File.basename(cwd)
rescue StandardError
  File.exist?(File.join(cwd, '.saneprocess')) ? File.basename(cwd) : nil
end

project_name = saneprocess_project_name(cwd)
exit 0 unless project_name

def visual_state(cwd)
  state_file = File.join(cwd, '.claude', 'state.json')
  return {} unless File.exist?(state_file)

  JSON.parse(File.read(state_file, encoding: Encoding::UTF_8))['visual_verification'] || {}
rescue JSON::ParserError, Errno::ENOENT
  {}
end

def hook_state_section(cwd, section)
  state_file = File.join(cwd, '.claude', 'state.json')
  return {} unless File.exist?(state_file)

  state = JSON.parse(File.read(state_file, encoding: Encoding::UTF_8))
  state[section.to_s] || {}
rescue JSON::ParserError, Errno::ENOENT
  {}
end

def git_changed_path?(cwd, expanded_path)
  root_out, root_status = Open3.capture2e('git', '-C', cwd, 'rev-parse', '--show-toplevel')
  return false unless root_status.success?

  root = File.expand_path(root_out.strip)
  path = File.expand_path(expanded_path)
  return false unless path == root || path.start_with?("#{root}/")

  rel = path == root ? '.' : path.delete_prefix("#{root}/")
  out, status = Open3.capture2e('git', '-C', root, 'status', '--porcelain=v1', '--', rel)
  status.success? && !out.strip.empty?
rescue StandardError
  false
end

def non_doc_edits(cwd)
  edits = hook_state_section(cwd, :edits)
  edit_count = edits['count'].to_i
  files = Array(edits['unique_files'])
  return [] if edit_count.zero?

  project_root = File.expand_path(cwd)
  files.each_with_object([]) do |path, kept|
    raw_path = path.to_s
    next if raw_path.empty?
    next if DOC_ONLY_EXTENSIONS.include?(File.extname(raw_path).downcase)

    expanded_path = File.expand_path(raw_path.start_with?('/') ? raw_path : File.join(project_root, raw_path))
    next unless expanded_path == project_root || expanded_path.start_with?("#{project_root}/")

    # Stale state can carry edit entries from an older project/session. Ignore
    # paths that are neither present nor a current git deletion/change.
    next unless File.exist?(expanded_path) || git_changed_path?(project_root, expanded_path)

    kept << expanded_path
  end
end

# Resolve symlinked prefixes (e.g. ~/SaneApps aliases) so dirty-path comparison
# is exact instead of basename-fuzzy. Falls back to the input on any error,
# including paths whose file no longer exists (git deletions).
def normalize_tree_path(path)
  File.realdirpath(path)
rescue StandardError
  path
end

# Net uncommitted working-tree paths (modified, staged, or untracked),
# normalized to absolute paths. nil when cwd is not inside a git repo or git is
# unavailable. Parity with sanestop_finalize RULE #4: the gate judges NET source
# state, not the cumulative session edit counter — work that was committed (or
# reset to origin) leaves a clean tree and must not re-fire this block forever.
# The old counter-only behavior let state.json accumulate hundreds of stale
# entries (including files from long-retired tooling) that made completion
# unsatisfiable without a fresh verify even when nothing was actually pending.
def uncommitted_working_tree_paths(cwd)
  root_out, root_status = Open3.capture2e('git', '-C', cwd, 'rev-parse', '--show-toplevel')
  return nil unless root_status.success?

  root = root_out.strip
  out, status = Open3.capture2e('git', '-C', root, 'status', '--porcelain', '--untracked-files=all')
  return nil unless status.success?

  # map+compact, not filter_map: hooks run under the system ruby (2.6), where
  # Enumerator#filter_map does not exist — it raised NoMethodError into the
  # rescue below, silently reverting this gate to counter behavior (the exact
  # stale-entry deadlock the net-diff judgment exists to fix).
  paths = out.each_line.map do |line|
    path = line[3..-1]&.strip
    next nil if path.nil? || path.empty?

    # Rename entries are "old -> new"; the new path is what currently exists.
    path = path.split(' -> ').last if path.include?(' -> ')
    # git quotes paths with special characters.
    path = path[1..-2] if path.start_with?('"') && path.end_with?('"')
    normalize_tree_path(File.expand_path(path, root))
  end.compact

  baseline = Array(hook_state_section(cwd, :edits)['baseline_dirty_files']).map do |path|
    normalize_tree_path(File.expand_path(path.to_s, root))
  end
  paths - baseline
rescue StandardError
  nil
end

def live_customer_facing_ui_files(cwd, visual)
  candidates = Array(visual['required_files_paths'])
  return [] if candidates.empty?

  edits = hook_state_section(cwd, :edits)
  baseline = Array(edits['baseline_dirty_files']).map do |path|
    normalize_tree_path(File.expand_path(path.to_s, cwd))
  end.to_set
  edited = Array(edits['unique_files']).map do |path|
    normalize_tree_path(File.expand_path(path.to_s, cwd))
  end.to_set

  candidates.map do |path|
    expanded = normalize_tree_path(File.expand_path(path.to_s, cwd))
    next nil unless edited.include?(expanded)
    next nil if baseline.include?(expanded)
    next nil unless File.exist?(expanded)

    expanded
  end.compact
rescue StandardError
  []
end

def current_source_fingerprint(cwd)
  root_out, root_status = Open3.capture2e('git', '-C', cwd, 'rev-parse', '--show-toplevel')
  return 'unknown' unless root_status.success?

  root = root_out.strip
  parts = []
  [
    %w[rev-parse HEAD],
    %w[status --porcelain=v1 --untracked-files=all],
    %w[diff --binary],
    %w[diff --cached --binary]
  ].each do |command|
    out, = Open3.capture2e('git', '-C', root, *command)
    parts << out
  end
  Digest::SHA256.hexdigest(parts.join("\n---\n"))
rescue StandardError
  'unknown'
end

def last_edit_time(cwd)
  edits = hook_state_section(cwd, :edits)
  raw = edits['last_edit_at'] || hook_state_section(cwd, :verification)['last_test_at']
  raw ? Time.parse(raw.to_s) : nil
rescue ArgumentError
  nil
end

def mini_or_structured_fallback?(event)
  SaneProcessMetrics.mini_or_structured_fallback?(event)
end

def recent_verified_metric?(cwd, project_name, max_age_seconds: 1_800)
  path = SaneProcessMetrics.metrics_path
  return false unless File.exist?(path)

  cutoff = Time.now - max_age_seconds
  after_edit = last_edit_time(cwd)
  current_fingerprint = current_source_fingerprint(cwd)
  project_root = File.expand_path(cwd)

  File.readlines(path, chomp: true, encoding: Encoding::UTF_8).map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end.compact
     .select { |event| event['type'] == 'verify' }
     .select { |event| SaneProcessMetrics.authoritative_verify_event?(event, require_source_fingerprint: true) }
     .select { |event| event['project'].to_s == project_name.to_s || File.expand_path(event['cwd'].to_s) == project_root }
     .any? do |event|
       timestamp = Time.parse(event['timestamp'].to_s)
       next false if timestamp < cutoff
       next false if after_edit && timestamp < after_edit

       receipt_fingerprint = event['source_fingerprint'].to_s
       next false if receipt_fingerprint.empty? || receipt_fingerprint == 'unknown'
       next false if current_fingerprint == 'unknown'

       receipt_fingerprint == current_fingerprint
     rescue ArgumentError
       false
     end
rescue StandardError
  false
end

visual = visual_state(cwd)
real_ui_files = live_customer_facing_ui_files(cwd, visual)
explicit_visual_request = visual['reason'] == 'prompt_requested_visual_verification'
if visual['required'] && (explicit_visual_request || real_ui_files.any?)
  visual_started_at = last_edit_time(cwd) || Time.now - 3600
  receipt_paths = SaneVisualReceipt.valid_receipt_paths(
    cwd: cwd,
    candidate_paths: Array(visual['audit_files']),
    started_at: visual_started_at
  )

  if receipt_paths.empty?
    warn "🔴 Task \"#{task_subject}\" completed without required visual screenshot audit"
    warn '   Visual UI work requires a structured JSON receipt, not loose screenshot paths or filename matches.'
    warn '   Accepted receipts: outputs/customer_ui_action_receipt.json or outputs/visual-audit*/ with Mini host, passed status, inspected=true, and existing screenshots.'
    exit 2
  end
end

non_doc_files = non_doc_edits(cwd)

# Judge NET state, not the cumulative session counter (parity with sanestop
# RULE #4): of the session's non-doc edits, only those STILL uncommitted in the
# working tree require fresh proof. Committed work is resolved. When git state
# is unknown (non-repo cwd), keep the counter behavior so coverage is not lost.
dirty_paths = uncommitted_working_tree_paths(cwd)
unless dirty_paths.nil?
  dirty_set = dirty_paths.to_set
  non_doc_files = non_doc_files.select do |path|
    dirty_set.include?(normalize_tree_path(File.expand_path(path)))
  end
end

exit 0 if non_doc_files.empty?

if recent_verified_metric?(cwd, project_name)
  warn "✅ Task \"#{task_subject}\" completed — verified by structured SaneMaster metric"
  exit 0
else
  warn "🔴 Task \"#{task_subject}\" completed without recent test verification"
  warn "   Gate scope: project '#{project_name}' at #{cwd} (resolved from the session cwd — if this task belongs to a different repo, cd into that repo first)"
  warn "   Uncommitted non-doc edits: #{non_doc_files.map { |path| File.basename(path) }.uniq.first(6).join(', ')}"
  warn '   Required proof: a fresh SaneMaster verify metric with counted tests, matching source fingerprint, and current project.'
  warn '   Run: ./scripts/SaneMaster.rb verify'
  warn '   (Committed work — a clean working tree — is already treated as resolved.)'
  exit 2
end
