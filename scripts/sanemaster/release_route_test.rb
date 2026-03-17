#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

class ReleaseRoutingHarness < SaneMaster
  attr_reader :system_calls

  def initialize
    @system_calls = []
    @existing_paths = []
    @directory_paths = []
  end

  def set_existing_paths(paths)
    @existing_paths = paths
  end

  def set_directory_paths(paths)
    @directory_paths = paths
  end

  def mini_path_exists_fast?(remote_path)
    @existing_paths.include?(remote_path)
  end

  def mini_directory?(remote_path)
    @directory_paths.include?(remote_path)
  end

  private

  def system(*args)
    @system_calls << args
    true
  end
end

include TestFramework

def with_temp_repo
  Dir.mktmpdir('sanemaster-release-route') do |dir|
    yield(dir)
  end
end

exit(run_tests('SaneMaster Release Routing Tests') do
  subject = ReleaseRoutingHarness.new

  test_category('Skip-build resume detection') do
    test('only release --skip-build requests artifact resume') do
      assert(subject.send(:release_artifact_resume_requested?, 'release', ['--skip-build']))
      assert(!subject.send(:release_artifact_resume_requested?, 'release', ['--deploy']))
      assert(!subject.send(:release_artifact_resume_requested?, 'release_preflight', ['--skip-build']))
      true
    end
  end

  test_category('Artifact sync to mini') do
    test('syncs build and releases directories when present locally') do
      with_temp_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, 'build'))
        FileUtils.mkdir_p(File.join(repo, 'releases'))

        subject.system_calls.clear
        subject.send(:sync_release_artifacts_to_mini!, repo, '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar')

        rsync_targets = subject.system_calls.select { |call| call.first == 'rsync' }.map(&:last)
        assert_includes(rsync_targets, "mini:/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar/build/")
        assert_includes(rsync_targets, "mini:/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar/releases/")
        true
      end
    end
  end

  test_category('Artifact sync from mini') do
    test('pulls back build and release artifacts from the routed scratch workspace') do
      with_temp_repo do |repo|
        remote_repo = '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar'
        subject.system_calls.clear
        subject.set_existing_paths([
                                   "#{remote_repo}/build",
                                   "#{remote_repo}/releases"
                                 ])
        subject.set_directory_paths([
                                     "#{remote_repo}/build",
                                     "#{remote_repo}/releases"
                                   ])

        subject.send(:sync_release_artifacts_from_mini!, repo, remote_repo)

        rsync_sources = subject.system_calls.select { |call| call.first == 'rsync' }.map { |call| call[3] }
        assert_includes(rsync_sources, "mini:#{remote_repo}/build/")
        assert_includes(rsync_sources, "mini:#{remote_repo}/releases/")
        true
      end
    end

    test('skips remote artifact paths that do not exist') do
      with_temp_repo do |repo|
        subject.system_calls.clear
        subject.set_existing_paths([])
        subject.set_directory_paths([])

        subject.send(:sync_release_artifacts_from_mini!, repo, '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar')

        rsync_calls = subject.system_calls.select { |call| call.first == 'rsync' }
        assert_eq(rsync_calls.length, 0, 'expected no rsync calls when the scratch workspace has no saved artifacts')
        true
      end
    end
  end
end)
