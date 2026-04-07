#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

class ReleaseRoutingHarness < SaneMaster
  attr_reader :system_calls, :ff_calls

  def initialize
    @system_calls = []
    @existing_paths = []
    @directory_paths = []
    @ff_calls = []
    @webhook_repo_root = nil
    @repo_dirty = {}
    @branches = {}
    @heads = {}
    @remote_sync = {}
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

  def set_webhook_repo_root(path)
    @webhook_repo_root = path
  end

  def set_repo_dirty(repo, dirty)
    @repo_dirty[repo] = dirty
  end

  def set_branch(repo, branch)
    @branches[repo] = branch
  end

  def set_head(repo, head)
    @heads[repo] = head
  end

  def set_remote_sync(repo, status)
    @remote_sync[repo] = status
  end

  def sane_email_automation_repo_root
    @webhook_repo_root || super
  end

  def fast_forward_local_repo_from_origin!(repo_dir, label:)
    @ff_calls << { repo_dir:, label: }
  end

  def repo_has_uncommitted_changes_at?(repo_dir)
    @repo_dirty.fetch(repo_dir, false)
  end

  def current_git_branch(repo_dir)
    @branches.fetch(repo_dir, 'main')
  end

  def current_git_head(repo_dir)
    @heads.fetch(repo_dir, 'abc123')
  end

  def local_repo_remote_sync_context(repo_dir, branch, head)
    { 'status' => @remote_sync.fetch(repo_dir, 'matches'), 'branch' => branch, 'remote_ref' => head }
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

  test_category('Workspace sync to mini') do
    test('excludes local worktree archives and outputs from routed workspace sync') do
      with_temp_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, '.worktrees', 'archive'))
        FileUtils.mkdir_p(File.join(repo, 'outputs', 'huge'))

        subject.system_calls.clear
        subject.send(:sync_local_dir_to_mini!, repo, '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar', label: nil)

        rsync_call = subject.system_calls.find { |call| call.first == 'rsync' }
        assert(rsync_call, 'expected an rsync call')
        assert_includes(rsync_call, '.worktrees')
        assert_includes(rsync_call, 'outputs')
        true
      end
    end
  end

  test_category('Workspace pruning on mini') do
    test('prunes stale routed workspaces while protecting the current scratch root') do
      with_temp_repo do |repo|
        subject.system_calls.clear

        current_root = '/Users/stephansmac/.sanemaster/routed-workspaces/current123'
        subject.send(:prune_stale_mini_release_workspaces!, repo, current_workspace_root: current_root, keep_days: 3, min_keep: 2)

        ssh_call = subject.system_calls.find { |call| call.first == 'ssh' && call.include?('mini') }
        assert(ssh_call, 'expected an ssh prune call')
        remote_cmd = ssh_call.reverse.find { |entry| entry.is_a?(String) && entry.include?('keep_days=3') }
        assert_includes(remote_cmd, '/Users/stephansmac/.sanemaster/routed-workspaces')
        assert_includes(remote_cmd, 'current123')
        assert_includes(remote_cmd, 'keep_days=3')
        assert_includes(remote_cmd, 'min_keep=2')
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

  test_category('Support repo sync after routed release') do
    test('fast-forwards sane-email-automation from origin after routed release') do
      with_temp_repo do |repo|
        subject.ff_calls.clear
        subject.set_webhook_repo_root(repo)

        subject.send(:sync_release_support_repos_from_origin!)

        assert_eq(subject.ff_calls.length, 1, 'expected one fast-forward sync call')
        assert_eq(subject.ff_calls.first[:repo_dir], repo)
        assert_eq(subject.ff_calls.first[:label], 'sane-email-automation')
        true
      end
    end
  end

  test_category('Mini repo normalization after routed verify') do
    test('resets the mini branch to origin when the local repo is clean and matched') do
      with_temp_repo do |repo|
        subject.system_calls.clear
        subject.set_repo_dirty(repo, false)
        subject.set_branch(repo, 'main')
        subject.set_head(repo, '0189a7b')
        subject.set_remote_sync(repo, 'matches')

        subject.send(:normalize_mini_repo_after_route!, repo, '/Users/stephansmac/SaneApps/apps/SaneClip', label: 'workspace')

        ssh_call = subject.system_calls.find { |call| call.first == 'ssh' && call.include?('mini') }
        assert(ssh_call, 'expected an ssh normalization call')
        remote_cmd = ssh_call.reverse.find { |entry| entry.is_a?(String) && entry.include?('git fetch origin') }
        assert_includes(remote_cmd, 'git fetch origin "$branch"')
        assert_includes(remote_cmd, 'git reset --mixed "origin/$branch"')
        true
      end
    end

    test('skips normalization when the local repo still has uncommitted changes') do
      with_temp_repo do |repo|
        subject.system_calls.clear
        subject.set_repo_dirty(repo, true)

        subject.send(:normalize_mini_repo_after_route!, repo, '/Users/stephansmac/SaneApps/apps/SaneClip', label: 'workspace')

        ssh_call = subject.system_calls.find { |call| call.first == 'ssh' && call.include?('mini') }
        assert_eq(ssh_call, nil, 'expected no ssh call when local repo is dirty')
        true
      end
    end
  end
end)
