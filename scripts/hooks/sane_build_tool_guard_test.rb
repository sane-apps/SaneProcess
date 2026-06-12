#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

HOOK_DIR = File.expand_path(__dir__)

$passed = 0
$total = 0

def t(name, ok)
  $total += 1
  if ok
    $passed += 1
    warn "  ✅ #{name}"
  else
    warn "  ❌ #{name}"
  end
end

def run_guard(tool, args, cwd)
  Open3.capture3(
    {
      'SANE_BUILD_TOOL_GUARD_TEST' => '1',
      'SANE_BUILD_TOOL_GUARD_STRICT_TEST' => '1',
      'CODEX_SHELL' => '1'
    },
    File.join(HOOK_DIR, tool),
    *args,
    chdir: cwd
  )
end

warn '=' * 60
warn 'Sane build tool shell guard tests'
warn '=' * 60

Dir.mktmpdir('sane-build-tool-guard-') do |project_dir|
  File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")

  _out, err, status = run_guard('xcodebuild', %w[-scheme SaneBar test], project_dir)
  t('xcodebuild wrapper blocks raw test in .saneprocess repo', status.exitstatus == 2)
  t('xcodebuild block names SaneMaster verify', err.include?('SaneMaster.rb verify'))

  out, err, status = run_guard('xcodebuild', %w[-list], project_dir)
  t('xcodebuild wrapper allows read-only list', status.exitstatus == 0)
  t('xcodebuild read-only path stays quiet', out.include?('xcodebuild_ALLOWED') && err.empty?)

  _out, err, status = run_guard('swift', %w[test], project_dir)
  t('swift wrapper blocks raw swift test in .saneprocess repo', status.exitstatus == 2)
  t('swift block names SaneMaster verify', err.include?('SaneMaster.rb verify'))

  out, err, status = run_guard('swift', %w[-version], project_dir)
  t('swift wrapper allows read-only version', status.exitstatus == 0)
  t('swift read-only path stays quiet', out.include?('swift_ALLOWED') && err.empty?)
end

Dir.mktmpdir('non-sane-build-tool-guard-') do |dir|
  out, err, status = run_guard('swift', %w[test], dir)
  t('swift wrapper allows non-SaneProcess repos', status.exitstatus == 0)
  t('non-SaneProcess allow path stays quiet', out.include?('swift_ALLOWED') && err.empty?)
end

warn ''
warn '=' * 60
warn "#{$passed}/#{$total} tests passed"
if $passed == $total
  warn 'ALL TESTS PASSED'
  exit 0
else
  warn "#{$total - $passed} TESTS FAILED"
  exit 1
end
