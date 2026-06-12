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
require_relative 'core/process_metrics'
require_relative 'core/visual_receipt'

begin
  input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

cwd = Dir.pwd
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

def non_doc_edits(cwd)
  edits = hook_state_section(cwd, :edits)
  edit_count = edits['count'].to_i
  files = Array(edits['unique_files'])
  return [] if edit_count.zero?

  files.reject { |path| DOC_ONLY_EXTENSIONS.include?(File.extname(path.to_s).downcase) }
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
if visual['required']
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
exit 0 if non_doc_files.empty?

if recent_verified_metric?(cwd, project_name)
  warn "✅ Task \"#{task_subject}\" completed — verified by structured SaneMaster metric"
  exit 0
else
  warn "🔴 Task \"#{task_subject}\" completed without recent test verification"
  warn "   Non-doc edits: #{non_doc_files.map { |path| File.basename(path) }.uniq.first(6).join(', ')}"
  warn '   Required proof: a fresh SaneMaster verify metric with counted tests, matching source fingerprint, and current project.'
  warn '   Run: ./scripts/SaneMaster.rb verify'
  exit 2
end
