#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the post-release LemonSqueezy-Uploads staging:
#   - sanestop_lemonsqueezy.rb (release detection from the transcript)
#   - stage_lemonsqueezy_uploads.rb (the staging operation)
# Run: ruby sanestop_lemonsqueezy_test.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'sanestop_lemonsqueezy'
require_relative '../stage_lemonsqueezy_uploads'

@passed = 0
@failed = 0

def check(desc)
  ok = yield
  if ok
    @passed += 1
    puts "  PASS: #{desc}"
  else
    @failed += 1
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  @failed += 1
  puts "  FAIL: #{desc} (#{e.class}: #{e.message})"
end

# Build a minimal transcript file containing the given Bash command strings.
def transcript_with(*commands)
  dir = Dir.mktmpdir('ls_transcript')
  path = File.join(dir, 'transcript.jsonl')
  File.open(path, 'w') do |f|
    commands.each do |cmd|
      f.puts JSON.generate({ type: 'tool_use', name: 'Bash', input: { command: cmd } })
    end
  end
  path
end

STAGE = File.expand_path('../stage_lemonsqueezy_uploads.rb', __dir__)

puts 'Testing release detection (sanestop_lemonsqueezy.rb):'

check('detects --project from a release.sh --deploy command') do
  t = transcript_with('ssh mini "bash release.sh --project ~/SaneApps/apps/SaneBar --full --deploy --critical-update"')
  LemonSqueezyUploads.detect_release_deploy_project(t) == '~/SaneApps/apps/SaneBar'
end

check('a quoted --notes containing --deploy does not truncate the match') do
  # The real flag order: --project before --notes, --deploy after. Escape-aware
  # scan must still see --deploy past the quoted notes.
  cmd = 'bash release.sh --project /Users/x/apps/SaneBar --version 2.1.84 --notes "fixes the --deploy popup" --deploy'
  t = transcript_with(cmd)
  LemonSqueezyUploads.detect_release_deploy_project(t) == '/Users/x/apps/SaneBar'
end

check('strips stray quotes around a quoted --project value') do
  t = transcript_with('bash release.sh --deploy --project "/Users/x/apps/SaneBar"')
  LemonSqueezyUploads.detect_release_deploy_project(t) == '/Users/x/apps/SaneBar'
end

check('returns nil when no release command ran') do
  t = transcript_with('ls -la', 'git status', 'ruby qa.rb --project /Users/x/apps/SaneBar')
  LemonSqueezyUploads.detect_release_deploy_project(t).nil?
end

check('a non-release command mentioning --deploy is ignored') do
  t = transcript_with('echo "release.sh would --deploy"', 'grep --deploy file')
  LemonSqueezyUploads.detect_release_deploy_project(t).nil?
end

check('the LAST release command this session wins') do
  t = transcript_with(
    'bash release.sh --project /a/SaneClick --full --deploy',
    'bash release.sh --project /a/SaneBar --full --deploy'
  )
  LemonSqueezyUploads.detect_release_deploy_project(t) == '/a/SaneBar'
end

check('nonexistent transcript path returns nil') do
  LemonSqueezyUploads.detect_release_deploy_project('/no/such/transcript').nil?
end

puts ''
puts 'Testing staging operation (stage_lemonsqueezy_uploads.rb):'

# A fake project whose DIRECTORY is named after the app (real projects are
# ~/SaneApps/apps/<App>, and the script derives the app from basename(project)).
def fake_project(app, version)
  dir = File.join(Dir.mktmpdir('ls_proj'), app)
  FileUtils.mkdir_p(File.join(dir, 'releases'))
  File.write(File.join(dir, 'project.yml'), "settings:\n        MARKETING_VERSION: \"#{version}\"\n")
  File.write(File.join(dir, 'releases', "#{app}-#{version}.zip"), 'ARTIFACT-BYTES')
  dir
end

# A SaneHosts-shaped project: NO project.yml — the version lives in
# Config/Shared.xcconfig as `MARKETING_VERSION = 1.1.22` (note `=`, not `:`).
def fake_xcconfig_project(app, version, filename: 'Shared.xcconfig')
  dir = File.join(Dir.mktmpdir('ls_proj_xc'), app)
  FileUtils.mkdir_p(File.join(dir, 'releases'))
  FileUtils.mkdir_p(File.join(dir, 'Config'))
  File.write(File.join(dir, 'Config', filename),
             "// Shared build settings\nMARKETING_VERSION = #{version}\nCURRENT_PROJECT_VERSION = 1122\n")
  File.write(File.join(dir, 'releases', "#{app}-#{version}.zip"), 'ARTIFACT-BYTES')
  dir
end

def run_stage(project, uploads)
  out, status = Open3.capture2e('ruby', STAGE, '--project', project, '--uploads-dir', uploads, '--json')
  [JSON.parse(out.lines.map(&:strip).find { |l| l.start_with?('{') } || '{}'), status.exitstatus]
rescue StandardError => e
  [{ 'status' => 'exception', 'message' => e.message }, 99]
end

require 'open3'

check('stages the latest ZIP and trashes a dated one, leaving other apps alone') do
  proj = fake_project('SaneBar', '2.1.84')
  uploads = Dir.mktmpdir('ls_uploads')
  File.write(File.join(uploads, 'SaneBar-2.1.80.zip'), 'old')
  File.write(File.join(uploads, 'SaneClick-1.1.12.zip'), 'keep')
  res, code = run_stage(proj, uploads)
  files = Dir.glob(File.join(uploads, '*.zip')).map { |p| File.basename(p) }.sort
  code.zero? && res['status'] == 'staged' &&
    files == ['SaneBar-2.1.84.zip', 'SaneClick-1.1.12.zip']
end

check('idempotent: a second run reports current, no churn') do
  proj = fake_project('SaneBar', '2.1.84')
  uploads = Dir.mktmpdir('ls_uploads')
  run_stage(proj, uploads)
  res, code = run_stage(proj, uploads)
  code.zero? && res['status'] == 'current'
end

check('missing staging folder is a safe no-op (exit 0)') do
  proj = fake_project('SaneBar', '2.1.84')
  res, code = run_stage(proj, '/tmp/ls_no_such_folder_xyz')
  code.zero? && res['status'] == 'noop'
end

check('missing artifact is a real failure (exit 2)') do
  proj = fake_project('SaneBar', '2.1.84')
  uploads = Dir.mktmpdir('ls_uploads')
  res, code = run_stage(proj, uploads)
  # remove the artifact to force the failure on a fresh version
  res2, code2 = Open3.capture2e('ruby', STAGE, '--project', proj, '--uploads-dir', uploads, '--version', '9.9.9', '--json')
  parsed = JSON.parse(res2.lines.map(&:strip).find { |l| l.start_with?('{') } || '{}')
  code.zero? && code2.exitstatus == 2 && parsed['status'] == 'error'
end

puts ''
puts 'Testing version resolution across both project shapes:'

# Regression for the 2026-07-15 incident: SaneHosts has no project.yml, so
# staging silently no-opped every release and ~/Desktop/LemonSqueezy-Uploads
# kept SaneHosts-1.1.20.zip — the build without the Pro padlock and
# large-profile activation fixes — long after 1.1.22 shipped.
check('SaneHosts resolves 1.1.22 from Config/Shared.xcconfig when project.yml is absent') do
  proj = fake_xcconfig_project('SaneHosts', '1.1.22')
  StageLemonSqueezyUploads.marketing_version(proj) == '1.1.22'
end

check('xcconfig project stages the current ZIP and removes the stale one (end-to-end)') do
  proj = fake_xcconfig_project('SaneHosts', '1.1.22')
  uploads = Dir.mktmpdir('ls_uploads')
  File.write(File.join(uploads, 'SaneHosts-1.1.20.zip'), 'stale-build-with-known-bugs')
  File.write(File.join(uploads, 'SaneBar-2.1.89.zip'), 'keep')
  res, code = run_stage(proj, uploads)
  files = Dir.glob(File.join(uploads, '*.zip')).map { |p| File.basename(p) }.sort
  code.zero? && res['status'] == 'staged' &&
    files == ['SaneBar-2.1.89.zip', 'SaneHosts-1.1.22.zip']
end

check('project.yml apps still resolve (xcconfig fallback did not regress them)') do
  StageLemonSqueezyUploads.marketing_version(fake_project('SaneBar', '2.1.89')) == '2.1.89'
end

check('project.yml wins when a project somehow carries both sources') do
  proj = fake_project('SaneBar', '2.1.89')
  FileUtils.mkdir_p(File.join(proj, 'Config'))
  File.write(File.join(proj, 'Config', 'Shared.xcconfig'), "MARKETING_VERSION = 9.9.9\n")
  StageLemonSqueezyUploads.marketing_version(proj) == '2.1.89'
end

check('a $(...) build-setting reference is not mistaken for a version') do
  dir = File.join(Dir.mktmpdir('ls_proj_ref'), 'SaneHosts')
  FileUtils.mkdir_p(File.join(dir, 'Config'))
  File.write(File.join(dir, 'Config', 'Shared.xcconfig'), "MARKETING_VERSION = $(inherited)\n")
  StageLemonSqueezyUploads.marketing_version(dir).nil?
end

check('a non-Shared Config xcconfig is still read') do
  proj = fake_xcconfig_project('SaneHosts', '1.1.22', filename: 'App.xcconfig')
  StageLemonSqueezyUploads.marketing_version(proj) == '1.1.22'
end

check('unresolvable version names both sources in the error') do
  dir = File.join(Dir.mktmpdir('ls_proj_none'), 'SaneHosts')
  FileUtils.mkdir_p(dir)
  uploads = Dir.mktmpdir('ls_uploads')
  res, code = run_stage(dir, uploads)
  code == 2 && res['status'] == 'error' &&
    res['message'].include?('project.yml') && res['message'].downcase.include?('xcconfig')
end

puts ''
puts "#{@passed}/#{@passed + @failed} tests passed"
if @failed.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{@failed} FAILED"
  exit 1
end
