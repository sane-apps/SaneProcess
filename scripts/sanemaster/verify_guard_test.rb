#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'verify'

class VerifyHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Verify
end

def init_git_repo(path)
  system('git', 'init', '-q', path) or raise 'git init failed'
  system('git', '-C', path, 'config', 'user.name', 'Codex Test') or raise 'git config user.name failed'
  system('git', '-C', path, 'config', 'user.email', 'codex@example.com') or raise 'git config user.email failed'
  File.write(File.join(path, 'tracked.txt'), "baseline\n")
  system('git', '-C', path, 'add', 'tracked.txt') or raise 'git add failed'
  system('git', '-C', path, 'commit', '-q', '-m', 'baseline') or raise 'git commit failed'
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

exit(run_tests('SaneMaster Verify Repo Drift Tests') do
  subject = VerifyHarness.new

  test_category('Verify repo drift guard') do
    test('reports no introduced drift for a clean repo') do
      Dir.mktmpdir('verify-guard-clean-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_eq(report[:introduced], [])
      end
      true
    end

    test('reports newly modified tracked files') do
      Dir.mktmpdir('verify-guard-modified-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        File.write(File.join(dir, 'tracked.txt'), "changed\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_includes(report[:introduced], ' M tracked.txt')
      end
      true
    end

    test('reports newly introduced untracked files') do
      Dir.mktmpdir('verify-guard-untracked-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        File.write(File.join(dir, 'new.txt'), "hello\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_includes(report[:introduced], '?? new.txt')
      end
      true
    end

    test('does not report baseline dirt that already existed before verify') do
      Dir.mktmpdir('verify-guard-baseline-') do |dir|
        init_git_repo(dir)
        tracked = File.join(dir, 'tracked.txt')
        File.write(tracked, "already dirty\n")
        before = subject.send(:git_status_snapshot, dir)
        File.write(tracked, "still dirty\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_eq(report[:introduced], [])
      end
      true
    end
  end

  test_category('Quality command fallback') do
    test('falls back to rubocop when no fastlane quality lane exists') do
      fallback_called = false
      subject.define_singleton_method(:bundle_available?) { true }
      subject.define_singleton_method(:preferred_bundle_bin) { '/tmp/fake-bundle' }
      subject.define_singleton_method(:capture2e_with_bundle_env) do |*_args|
        ['Could not find lane \'mac quality\'', Struct.new(:success?).new(false)]
      end
      subject.define_singleton_method(:check_rubocop_issues) do
        fallback_called = true
        0
      end

      output = capture_stdout { subject.send(:run_quality_report) }

      assert(fallback_called, 'expected rubocop fallback to run')
      assert_includes(output, 'No fastlane quality lane')
      true
    end

    test('reports a real fastlane quality failure without masking it') do
      subject.define_singleton_method(:bundle_available?) { true }
      subject.define_singleton_method(:preferred_bundle_bin) { '/tmp/fake-bundle' }
      subject.define_singleton_method(:capture2e_with_bundle_env) do |*_args|
        ['fastlane exploded', Struct.new(:success?).new(false)]
      end
      subject.define_singleton_method(:check_rubocop_issues) do
        raise 'rubocop fallback should not run for real fastlane failures'
      end

      output = capture_stdout { subject.send(:run_quality_report) }

      assert_includes(output, 'fastlane exploded')
      assert_includes(output, '❌ Quality report generation failed.')
      true
    end
  end
end)
