# frozen_string_literal: true

# ==============================================================================
# SaneTrack Release/Verification Proof Helpers
# ==============================================================================
# Release preflight, ship clearance, and process-metric proof lookups for
# sanetrack.rb (PostToolUse hook). Split out of sanetrack.rb to keep the hook
# under the Rule #10 size limit.
# ==============================================================================

require 'json'
require 'shellwords'
require 'time'
require_relative 'state_signer'
require_relative 'release_receipt_signer'

# Canonical SaneProcess repo root. SaneMaster.rb tool_discovery always writes its
# receipt under <SaneProcess>/outputs/, regardless of the project cwd, so the
# evolve runner-proof check must look there too — otherwise the gate can never be
# satisfied from an app repo (Dir.pwd would be e.g. SaneBar, where no receipt lands).
# Overridable via SANEPROCESS_ROOT so self-tests can isolate the receipt search.
def saneprocess_root
  ENV['SANEPROCESS_ROOT'] || File.expand_path('../..', __dir__)
end

def latest_recent_file(glob)
  roots = [Dir.pwd, saneprocess_root].uniq
  path = roots.flat_map { |root| Dir.glob(File.join(root, glob)) }
              .select { |candidate| File.file?(candidate) }
              .max_by { |candidate| File.mtime(candidate) rescue Time.at(0) }
  return nil unless path && recent_time?(File.mtime(path))

  yield(path)
end

def latest_authoritative_tool_discovery_receipt(command)
  expected_query = command_query_value(command)
  latest_recent_file('outputs/tool-discovery/*.json') do |path|
    receipt = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    next nil unless authoritative_tool_discovery_receipt?(receipt, expected_query)

    {
      type: 'tool_discovery_receipt',
      path: path,
      query: receipt['query'],
      route: receipt['route']
    }
  end
rescue JSON::ParserError, SystemCallError
  nil
end

def command_query_value(command)
  tokens = Shellwords.split(command.to_s)
  index = tokens.index('--query')
  return tokens[index + 1].to_s.strip if index && tokens[index + 1]

  prefix = '--query='
  match = tokens.find { |token| token.start_with?(prefix) }
  match ? match[prefix.length..].to_s.strip : ''
rescue ArgumentError
  ''
end

def authoritative_tool_discovery_receipt?(receipt, expected_query)
  return false unless receipt['authoritative'] == true
  return false unless receipt['route'].to_s == 'SaneMaster.rb tool_discovery'
  return false if expected_query.to_s.strip.empty?
  return false unless receipt['query'].to_s.strip == expected_query.to_s.strip

  doctor_status = receipt.dig('summary', 'doctor_status') || receipt.dig('checks', 'doctor', 'status')
  validation_status = receipt.dig('summary', 'validation_status') || receipt.dig('checks', 'validation_report', 'status')
  return false if doctor_status.to_s.empty? || doctor_status.to_s == 'skipped'
  return false if validation_status.to_s.empty? || validation_status.to_s == 'skipped'

  true
end

def release_preflight_receipt_signer
  Thread.current[:saneprocess_sanetrack_release_receipt_signer] || ReleaseReceiptSigner.production
end

def release_preflight_proof(runner_receipt: nil, receipt_signer: nil)
  return nil unless runner_receipt.is_a?(Hash)

  path = File.join(Dir.pwd, 'outputs', 'release_preflight_status.json')
  return nil unless File.file?(path) && recent_time?(File.mtime(path))

  signer = receipt_signer || release_preflight_receipt_signer
  data = signer.read(path, producer: 'saneprocess.release_preflight.v1')
  return nil unless data.is_a?(Hash)
  return nil unless data['status'].to_s == 'passed'
  return nil unless Array(data['issues']).empty?
  return nil unless data['miniRuntime'] == true

  started_at = Time.parse(runner_receipt[:started_at].to_s)
  completed_at = Time.parse(runner_receipt[:completed_at].to_s)
  generated_at = Time.parse(data['generatedAt'].to_s)
  return nil unless generated_at.between?(started_at - 1, completed_at + 1)
  return nil if generated_at > Time.now.utc + 300

  current_fingerprint = runner_receipt[:source_fingerprint].to_s
  receipt_fingerprint = data['sourceFingerprint'].to_s
  return nil unless current_fingerprint.match?(/\A[0-9a-f]{64}\z/)
  return nil unless receipt_fingerprint == current_fingerprint

  verify = data['verifyEvidence']
  return nil unless verify.is_a?(Hash) && verify['type'].to_s == 'verify' && verify['success'] == true
  return nil unless verify['testsRun'].to_i.positive?
  return nil unless verify['host'].to_s.downcase.include?('mini')
  return nil unless File.realpath(verify['cwd'].to_s) == File.realpath(Dir.pwd)
  return nil unless verify['sourceFingerprint'].to_s == current_fingerprint
  verify_at = Time.parse(verify['timestamp'].to_s)
  return nil unless verify_at.between?(started_at - 1, generated_at + 1)

  clearance = ship_clearance_proof
  return nil unless clearance

  {
    type: 'release_preflight_status',
    path: path,
    generated_at: data['generatedAt'],
    status: data['status'],
    clearance_path: clearance[:path],
    app: clearance[:app],
    fingerprint: runner_receipt[:fingerprint],
    workflow_receipt_id: runner_receipt[:receipt_id]
  }
rescue StandardError
  nil
end

def ship_clearance_proof(project_dir = Dir.pwd)
  saneprocess_path = File.join(project_dir, '.saneprocess')
  return nil unless File.file?(saneprocess_path)

  app_name = File.readlines(saneprocess_path, encoding: Encoding::UTF_8).map { |line| line[/\Aname:\s*(\S+)/, 1] }.compact.first
  return nil if app_name.to_s.empty?

  clearance_path = File.expand_path("~/.claude/ship_clearance/#{app_name}.json")
  return nil unless File.file?(clearance_path)

  require_relative 'state_signer'
  data = StateSigner.read_verified(clearance_path)
  return nil unless data && data['app'] == app_name
  clearance_project = data['project_dir'].to_s.strip
  return nil if clearance_project.empty?
  return nil unless File.realpath(clearance_project) == File.realpath(project_dir)

  expires = Time.parse(data['expires_at'].to_s)
  return nil unless expires > Time.now.utc

  current_sha = `git -C #{project_dir.shellescape} rev-parse HEAD 2>/dev/null`.strip
  clearance_sha = data['git_sha'].to_s.strip
  return nil unless clearance_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  return nil unless current_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  return nil if release_relevant_clearance_commits_changed?(project_dir, clearance_sha, current_sha)

  { path: clearance_path, app: app_name }
rescue StandardError
  nil
end

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

def release_relevant_clearance_commits_changed?(project_dir, old_sha, current_sha)
  return true if old_sha.to_s.empty? || current_sha.to_s.empty?
  return false if old_sha == current_sha

  out = `git -C #{project_dir.shellescape} diff --name-only #{old_sha.shellescape}..#{current_sha.shellescape} 2>/dev/null`
  return true if out.to_s.empty? && !$?.success?

  out.each_line.map(&:strip).reject(&:empty?).any? do |path|
    release_relevant_clearance_path?(project_dir, path)
  end
end

def latest_recent_process_metric(type)
  events = recent_process_metric_events(type)
  events.reverse.find { |event| yield(event) }
end

def recent_process_metric_events(type)
  path = SaneProcessMetrics.metrics_path
  return [] unless File.file?(path)

  current_cwd = File.expand_path(Dir.pwd)
  File.readlines(path, chomp: true, encoding: Encoding::UTF_8).map do |line|
    next if line.strip.empty?

    event = JSON.parse(line)
    next unless event['type'].to_s == type.to_s
    next unless recent_time?(parse_time(event['timestamp']))

    event_cwd = event['cwd'].to_s.empty? ? current_cwd : File.expand_path(event['cwd'].to_s)
    next unless event_cwd == current_cwd

    event
  rescue JSON::ParserError
    nil
  end.compact
end

def parse_time(value)
  Time.parse(value.to_s)
rescue StandardError
  Time.at(0)
end

def recent_time?(time, max_age_seconds = 15 * 60)
  time && (Time.now - time).abs <= max_age_seconds
end
