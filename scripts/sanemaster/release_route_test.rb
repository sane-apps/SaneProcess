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
    @stash_reports = {}
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

  def set_stash_reports(repo, reports)
    @stash_reports[repo] = reports
  end

  def sane_email_automation_repo_root
    @webhook_repo_root || super
  end

  def fast_forward_local_repo_from_origin!(repo_dir, label:)
    @ff_calls << { repo_dir: repo_dir, label: label }
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

  def auto_reconcile_stash_reports(repo_path:, limit: 30)
    @stash_reports.fetch(repo_path, []).first(limit)
  end

  def map_local_path_to_mini(local_path)
    "/mini#{local_path}"
  end

  def routed_release_path_for_local(local_path, _local_repo = Dir.pwd)
    File.join('/Users/stephansmac/.sanemaster/routed-workspaces/testcase', File.basename(local_path))
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


    test('syncs and remaps an exact App Store preflight package for Mini execution') do
      with_temp_repo do |repo|
        package = File.join(repo, 'Example.pkg')
        File.write(package, 'exact-package-bytes')
        execution_repo = '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/Example'

        subject.system_calls.clear
        Dir.chdir(repo) do
          routed_args, binding_dir = subject.send(
            :route_appstore_preflight_package_to_mini,
            'appstore_preflight',
            ['--platform', 'macos', '--pkg', package],
            execution_repo
          )

          assert_eq(routed_args[0, 2], ['--platform', 'macos'])
          assert_eq(routed_args[2], '--pkg')
          assert(routed_args[3].start_with?(execution_repo), 'expected package path inside the canonical producer project root')
          assert(routed_args[3].end_with?('/Example.pkg'))
          assert(binding_dir && routed_args[3].start_with?(binding_dir))

          rsync_call = subject.system_calls.find { |call| call.first == 'rsync' }
          assert(rsync_call, 'expected exact package rsync')
          assert_includes(rsync_call, '--no-links')
          assert_includes(rsync_call, package)
          assert_includes(rsync_call, "mini:#{routed_args[3]}")

          subject.send(:cleanup_routed_appstore_preflight_package, binding_dir)
          cleanup_call = subject.system_calls.reverse.find { |call| call.first == 'ssh' }
          assert(cleanup_call.any? { |part| part.to_s.include?('/usr/bin/trash') }, 'expected routed binding cleanup')
        end
      end
      true
    end
  end

  test_category('Workspace sync to mini') do
    test('routed workspace cleanup retries and moves aside stale scratch roots') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'remote', 'add', 'origin', 'git@example.invalid:sane-apps/SaneBar.git')

        subject.system_calls.clear
        subject.set_branch(repo, 'main')
        subject.set_head(repo, 'abc123')
        subject.set_remote_sync(repo, 'matches')

        subject.send(:prepare_release_workspace_on_mini!, repo, '/Users/stephansmac/SaneApps/apps/SaneBar')

        ssh_call = subject.system_calls.find do |call|
          call.first == 'ssh' &&
            call.include?('mini') &&
            call.any? { |entry| entry.is_a?(String) && entry.include?('git clone --no-checkout') }
        end
        assert(ssh_call, 'expected an ssh call that prepares the clean routed workspace')
        remote_cmd = ssh_call.reverse.find { |entry| entry.is_a?(String) && entry.include?('git clone --no-checkout') }
        assert_includes(remote_cmd, 'for attempt in range(3):')
        assert_includes(remote_cmd, 'os.replace(scratch_root, stale_root)')
        assert_includes(remote_cmd, '[ ! -e "$scratch_root" ]')
        true
      end
    end

    test('route context carries local auto-reconcile stash blockers into the Mini preflight') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        File.write(File.join(repo, 'README.md'), "test\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'baseline')
        subject.set_stash_reports(
          repo,
          [
            {
              ref: 'stash@{0}',
              subject: 'auto-reconcile-20260509-test',
              blocking_files: ['SaneClipApp.swift']
            }
          ]
        )

        context = subject.send(:local_repo_route_context, repo)

        assert_eq(context['auto_reconcile_stash_reports'].length, 1)
        assert_eq(context['auto_reconcile_stash_reports'].first['ref'], 'stash@{0}')
        assert_eq(context['auto_reconcile_stash_reports'].first['blocking_files'], ['SaneClipApp.swift'])
      end
      true
    end

    test('route context carries added Swift lines for Mini release preflight scanning') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        source_dir = File.join(repo, 'SaneVideo', 'Core', 'Utilities')
        source_path = File.join(source_dir, 'TestEnvironment.swift')
        FileUtils.mkdir_p(source_dir)
        File.write(source_path, "let persisted = UserDefaults.standard.bool(forKey: \"open_editor\")\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'baseline')
        Open3.capture2e('git', '-C', repo, 'tag', 'v1.0.0')
        5.times do |index|
          File.write(File.join(repo, 'README.md'), "history #{index}\n")
          Open3.capture2e('git', '-C', repo, 'add', 'README.md')
          Open3.capture2e('git', '-C', repo, 'commit', '-m', "history #{index}")
        end
        File.write(
          source_path,
          "let persisted = UserDefaults.standard.bool(forKey: \"open_editor\")\nlet alias = \"SANEVIDEO_TEST_ASSET_PATH\"\n"
        )

        context = subject.send(:local_repo_route_context, repo)
        added_lines = context.fetch('recent_swift_diff').lines.select do |line|
          line.start_with?('+') && !line.start_with?('+++')
        end

        assert_eq(added_lines, ["+let alias = \"SANEVIDEO_TEST_ASSET_PATH\"\n"])
        assert_eq(
          context.fetch('recent_changed_swift_files'),
          ['SaneVideo/Core/Utilities/TestEnvironment.swift']
        )
      end
      true
    end

    test('route context carries Swift changes older than five commits since the latest release tag') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        source = File.join(repo, 'Sources', 'Preferences.swift')
        FileUtils.mkdir_p(File.dirname(source))
        File.write(source, "let defaultRate = 1.0\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'released baseline')
        Open3.capture2e('git', '-C', repo, 'tag', 'v1.0.0')
        File.write(source, "let defaultRate = 1.25\nlet defaults = UserDefaults.standard\n")
        Open3.capture2e('git', '-C', repo, 'add', source)
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'defaults change')
        6.times do |index|
          File.write(File.join(repo, 'README.md'), "history #{index}\n")
          Open3.capture2e('git', '-C', repo, 'add', 'README.md')
          Open3.capture2e('git', '-C', repo, 'commit', '-m', "history #{index}")
        end

        context = subject.send(:local_repo_route_context, repo)

        assert_includes(context.fetch('recent_changed_swift_files'), 'Sources/Preferences.swift')
        assert_includes(context.fetch('recent_swift_diff'), '+let defaults = UserDefaults.standard')
      end
      true
    end

    test('route context includes committed Swift from a young repo and untracked production Swift') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        committed = File.join(repo, 'Sources', 'Preferences.swift')
        untracked = File.join(repo, 'Sources', 'NewMigration.swift')
        FileUtils.mkdir_p(File.dirname(committed))
        File.write(committed, "let defaults = UserDefaults.standard\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'young baseline')
        File.write(untracked, "func migrateLegacyDefaults() {}\n")

        context = subject.send(:local_repo_route_context, repo)

        assert_eq(context.fetch('recent_swift_diff_error'), '')
        assert_includes(context.fetch('recent_changed_swift_files'), 'Sources/Preferences.swift')
        assert_includes(context.fetch('recent_changed_swift_files'), 'Sources/NewMigration.swift')
        assert_includes(context.fetch('recent_swift_diff'), '+let defaults = UserDefaults.standard')
        assert_includes(context.fetch('recent_swift_diff'), '+func migrateLegacyDefaults() {}')
      end
      true
    end

    test('routed sync carries signed upgrade proof and immutable evidence instead of route-context JSON') do
      with_temp_repo do |repo|
        subject.send(:sync_local_dir_to_mini!, repo, '/mini/repo')
        rsync = subject.system_calls.find { |call| call.first == 'rsync' }
        assert_includes(rsync, 'outputs/upgrade_path_behavioral_receipt.json')
        assert_includes(rsync, 'outputs/upgrade-path-proof/***')
      end
      true
    end

    test('route context rejects an untracked Swift symlink instead of reading outside the repo') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        File.write(File.join(repo, 'README.md'), "baseline\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'baseline')
        outside = File.join(File.dirname(repo), "outside-#{File.basename(repo)}.swift")
        File.write(outside, "let defaults = UserDefaults.standard\n")
        FileUtils.mkdir_p(File.join(repo, 'Sources'))
        File.symlink(outside, File.join(repo, 'Sources', 'Injected.swift'))

        context = subject.send(:local_repo_route_context, repo)

        assert_includes(context.fetch('recent_swift_diff_error'), 'symlink or non-regular')
        assert(!context.fetch('recent_swift_diff').include?('UserDefaults.standard'))
      ensure
        FileUtils.rm_f(outside) if outside
      end
      true
    end

    test('excludes local worktree archives and generated outputs but keeps canonical UI receipt') do
      with_temp_repo do |repo|
        FileUtils.mkdir_p(File.join(repo, '.worktrees', 'archive'))
        FileUtils.mkdir_p(File.join(repo, '.sane'))
        FileUtils.mkdir_p(File.join(repo, 'outputs', 'huge'))
        FileUtils.mkdir_p(File.join(repo, 'outputs', 'customer-ui'))
        FileUtils.mkdir_p(File.join(repo, 'outputs', 'runtime-preflight'))
        FileUtils.mkdir_p(File.join(repo, 'outputs', 'process-abtest'))
        File.write(File.join(repo, '.sane', 'customer_ui_action_receipt.json'), '{}')
        File.write(File.join(repo, 'outputs', 'qa_status.json'), '{}')
        File.write(File.join(repo, 'outputs', 'release_preflight_status.json'), '{}')
        File.write(File.join(repo, 'outputs', 'customer_ui_action_receipt.json'), '{}')
        File.write(File.join(repo, 'outputs', 'customer-ui', 'mini-click-transcript.json'), '{}')
        File.write(File.join(repo, 'outputs', 'runtime-preflight', 'sanebar_runtime_hover_rehide.json'), '{}')

        subject.system_calls.clear
        subject.send(:sync_local_dir_to_mini!, repo, '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar', label: nil)

        rsync_call = subject.system_calls.find { |call| call.first == 'rsync' }
        assert(rsync_call, 'expected an rsync call')
        assert_includes(rsync_call, '.worktrees')
        assert(!rsync_call.include?('.sane/customer_ui_action_receipt.json'))
        assert_includes(rsync_call, 'outputs/***')
        assert(!rsync_call.include?('outputs/qa_status.json'))
        assert(!rsync_call.include?('outputs/release_preflight_status.json'))
        assert_includes(rsync_call, 'outputs/customer_ui_action_receipt.json')
        assert_includes(rsync_call, 'outputs/customer-ui/')
        assert_includes(rsync_call, 'outputs/customer-ui/***')
        assert_includes(rsync_call, 'outputs/runtime-preflight/')
        assert_includes(rsync_call, 'outputs/runtime-preflight/***')
        assert(!rsync_call.include?('outputs/process-abtest/***'))
        true
      end
    end

    test('syncs only Mini receipt outputs back to the Air') do
      with_temp_repo do |repo|
        remote_repo = '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar'
        remote_outputs = File.join(remote_repo, 'outputs')
        subject.set_existing_paths([remote_outputs])

        subject.system_calls.clear
        subject.send(:sync_outputs_from_mini!, repo, remote_repo)

        rsync_call = subject.system_calls.find { |call| call.first == 'rsync' }
        assert(rsync_call, 'expected a reverse-output rsync call')
        assert_includes(rsync_call, 'qa_status.json')
        assert_includes(rsync_call, 'release_preflight_status.json')
        assert_includes(rsync_call, 'appstore_preflight_status.json')
        assert_includes(rsync_call, 'customer_ui_action_receipt.json')
        assert_includes(rsync_call, 'customer-ui/***')
        assert_includes(rsync_call, 'runtime-preflight/***')
        assert_includes(rsync_call, 'visual_smoke/***')
        assert_includes(rsync_call, 'process-abtest/***')
        assert_includes(rsync_call, '*')
        assert_includes(rsync_call, '--no-links')
        assert_includes(rsync_call, "mini:#{remote_outputs}/")
        true
      end
    end

    test('syncs Mini canonical sane receipt back to the Air') do
      with_temp_repo do |repo|
        remote_repo = '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar'
        remote_outputs = File.join(remote_repo, 'outputs')
        remote_receipt = File.join(remote_repo, '.sane', 'customer_ui_action_receipt.json')
        subject.set_existing_paths([remote_outputs, remote_receipt])

        subject.system_calls.clear
        subject.send(:sync_outputs_from_mini!, repo, remote_repo)

        receipt_call = subject.system_calls.select { |call| call.first == 'rsync' }.find do |call|
          call.include?("mini:#{remote_receipt}")
        end
        assert(receipt_call, 'expected Mini .sane receipt rsync call')
        assert_includes(receipt_call, '--no-links')
        assert_includes(receipt_call, File.join(repo, '.sane') + '/customer_ui_action_receipt.json')
        true
      end
    end

    test('prunes non-receipt Mini outputs after routed runs') do
      remote_repo = '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar'
      remote_outputs = File.join(remote_repo, 'outputs')
      subject.set_existing_paths([remote_outputs])

      subject.system_calls.clear
      subject.send(:cleanup_bulk_outputs_on_mini!, remote_repo)

      ssh_call = subject.system_calls.find { |call| call.first == 'ssh' && call.include?('mini') }
      assert(ssh_call, 'expected ssh cleanup command')
      remote_cmd = ssh_call.find { |part| part.is_a?(String) && part.include?('find "$out"') }.to_s
      assert_includes(remote_cmd, 'base=${path##*/}')
      assert_includes(remote_cmd, 'qa_status.json')
      assert_includes(remote_cmd, 'release_preflight_status.json')
      assert_includes(remote_cmd, 'appstore_preflight_status.json')
      assert_includes(remote_cmd, 'customer_ui_action_receipt.json')
      assert_includes(remote_cmd, 'validation')
      assert_includes(remote_cmd, 'customer-ui')
      assert_includes(remote_cmd, 'runtime-preflight')
      assert_includes(remote_cmd, 'visual_smoke')
      assert_includes(remote_cmd, 'process-abtest')
      assert_includes(remote_cmd, '/usr/bin/trash "$path"')
      true
    end

    test('applies staged deletions after routed workspace rsync') do
      with_temp_repo do |repo|
        Open3.capture2e('git', '-C', repo, 'init')
        Open3.capture2e('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
        Open3.capture2e('git', '-C', repo, 'config', 'user.name', 'SaneProcess Test')
        FileUtils.mkdir_p(File.join(repo, '.claude'))
        File.write(File.join(repo, '.claude', 'internal.md'), "private\n")
        File.write(File.join(repo, 'SESSION_HANDOFF.md'), "handoff\n")
        Open3.capture2e('git', '-C', repo, 'add', '.')
        Open3.capture2e('git', '-C', repo, 'commit', '-m', 'baseline')
        Open3.capture2e('git', '-C', repo, 'rm', '--cached', '.claude/internal.md', 'SESSION_HANDOFF.md')

        assert_eq(
          subject.send(:git_deleted_paths_for_routed_workspace, repo),
          ['.claude/internal.md', 'SESSION_HANDOFF.md']
        )

        subject.system_calls.clear
        subject.send(:apply_git_deleted_paths_to_mini!, repo, '/Users/stephansmac/.sanemaster/routed-workspaces/abcd/SaneApps/apps/SaneBar')

        ssh_call = subject.system_calls.find { |call| call.first == 'ssh' && call.include?('mini') }
        assert(ssh_call, 'expected an ssh deletion sync call')
        remote_cmd = ssh_call.reverse.find { |entry| entry.is_a?(String) && entry.include?('SANEMASTER_DELETED_PATHS=') }
        assert_includes(remote_cmd, '.claude/internal.md')
        assert_includes(remote_cmd, 'SESSION_HANDOFF.md')
      end
      true
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

    test('skips routed support repo sync for release_preflight') do
      with_temp_repo do |repo|
        subject.system_calls.clear
        subject.set_webhook_repo_root(repo)

        result = subject.send(:sync_release_support_repos_to_mini!, release_routed: true, command: 'release_preflight')

        assert_eq(result, nil)
        assert_eq(subject.system_calls.length, 0, 'expected no routing work for release_preflight')
        true
      end
    end

    test('uses a clean mini clone when routed release support repo is dirty locally') do
      with_temp_repo do |repo|
        subject.system_calls.clear
        subject.set_webhook_repo_root(repo)
        subject.set_repo_dirty(repo, true)
        subject.set_branch(repo, 'main')
        subject.set_head(repo, 'abc123')
        subject.set_remote_sync(repo, 'behind')

        routed_repo = subject.send(:sync_release_support_repos_to_mini!, release_routed: true, command: 'release')

        assert(routed_repo.to_s.include?('/Users/stephansmac/.sanemaster/routed-workspaces/'))
        ssh_call = subject.system_calls.find do |call|
          call.first == 'ssh' &&
            call.include?('mini') &&
            call.any? { |entry| entry.is_a?(String) && entry.include?('git clone --no-checkout') }
        end
        assert(ssh_call, 'expected an ssh call that prepares the clean routed support workspace')
        remote_cmd = ssh_call.reverse.find { |entry| entry.is_a?(String) && entry.include?('git clone --no-checkout') }
        assert_includes(remote_cmd, 'git clone --no-checkout')
        assert_includes(remote_cmd, 'git fetch --tags origin')
        assert_includes(remote_cmd, 'git reset --hard "origin/$branch"')
        assert_includes(remote_cmd, "fi\n")
        assert(!remote_cmd.include?("\n      end\n"), 'expected routed support repo shell to use fi, not Ruby end')
        true
      end
    end
  end

  test_category('Mini repo normalization after routed verify') do
    test('Mini host detection never treats the shared username as machine identity') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__), encoding: Encoding::UTF_8)

      assert_includes(source, "Socket.gethostname.to_s.downcase")
      assert_includes(source, "'/usr/sbin/scutil', '--get', 'ComputerName'")
      assert(!source.include?("user == 'stephansmac'"),
             'SaneMaster must not skip Mini routing just because the Air and Mini share a username')
      assert(!source.include?("ENV.fetch('USER', '').downcase"),
             'SaneMaster Mini identity must come from host identity, not USER')
      true
    end

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
