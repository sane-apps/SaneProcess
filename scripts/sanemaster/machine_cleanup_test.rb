#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'machine_cleanup'

class MachineCleanupHarness
  include SaneMasterModules::MachineCleanup

  attr_reader :trashed, :emptied, :routed_args

  def initialize(ps_rows: [], disk: {}, sizes: {})
    @ps_rows = ps_rows
    @disk = { ok: true, available_gb: 10, capacity: '95%' }.merge(disk)
    @sizes = sizes
    @trashed = []
    @emptied = 0
  end

  def running_on_mini_host?
    false
  end

  def machine_cleanup_ps_rows
    @ps_rows
  end

  def machine_cleanup_disk_snapshot
    @disk
  end

  def path_size_gb(path)
    @sizes.fetch(File.expand_path(path), 0.0)
  end

  def trash_path(path)
    @trashed << File.expand_path(path)
    true
  end

  def empty_user_trash
    @emptied += 1
    true
  end

  def run_machine_cleanup_on_mini(args)
    @routed_args = args.dup
    true
  end

  def system(*args, **kwargs)
    return true if args.first == 'xcrun'

    super
  end
end

include TestFramework

def with_home
  Dir.mktmpdir('machine-cleanup-home-') do |dir|
    old_home = ENV['HOME']
    ENV['HOME'] = dir
    yield dir
  ensure
    ENV['HOME'] = old_home
  end
end

def mkdir_home_path(home, relative)
  path = File.join(home, relative)
  FileUtils.mkdir_p(path)
  path
end

exit(run_tests('SaneMaster Machine Cleanup Tests') do
  test_category('active work preservation') do
    test('detects active Sane apps from process commands') do
      subject = MachineCleanupHarness.new(ps_rows: [
        { pid: 10, ppid: 1, pgid: 10, stat: 'S', etime: '01:00', command: 'xcodebuild -project SaneScan.xcodeproj test' },
        { pid: 11, ppid: 1, pgid: 11, stat: 'R', etime: '00:30', command: '/tmp/SaneVideo.app/Contents/MacOS/SaneVideo' }
      ])

      active = subject.send(:machine_cleanup_active_inventory)

      assert(active[:apps].key?('SaneScan'), 'expected active SaneScan to be preserved')
      assert(active[:apps].key?('SaneVideo'), 'expected active SaneVideo to be preserved')
      assert_eq(active[:xcodebuild_active], true)
    end

    test('skips active and explicitly preserved DerivedData') do
      with_home do |home|
        active_path = mkdir_home_path(home, 'Library/Developer/Xcode/DerivedData/SaneScan-abc')
        preserved_path = mkdir_home_path(home, 'Library/Developer/Xcode/DerivedData/SaneVideo-def')
        stale_path = mkdir_home_path(home, 'Library/Developer/Xcode/DerivedData/SaneClip-ghi')
        old = Time.now - (5 * 86_400)
        [active_path, preserved_path, stale_path].each { |path| File.utime(old, old, path) }

        sizes = {
          File.expand_path(active_path) => 2.0,
          File.expand_path(preserved_path) => 2.0,
          File.expand_path(stale_path) => 3.0
        }
        subject = MachineCleanupHarness.new(
          ps_rows: [{ pid: 10, ppid: 1, pgid: 10, stat: 'S', etime: '01:00', command: 'xcodebuild -project SaneScan.xcodeproj test' }],
          sizes: sizes
        )

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 2,
          trash_threshold_gb: 99,
          preserve_apps: ['SaneVideo']
        })

        paths = plan[:actions].select { |action| action[:category] == 'inactive_deriveddata' }.map { |action| action[:path] }
        assert_eq(paths, [stale_path])
      end
    end
  end

  test_category('safe cleanup planning') do
    test('preserves --apply when routing cleanup to the Mini') do
      subject = MachineCleanupHarness.new
      forwarded = subject.send(:machine_cleanup_forwarded_args_for_mini, [
        '--host', 'mini',
        '--server',
        '--apply',
        '--preserve-apps', 'SaneBar,SaneClick'
      ])

      assert_eq(forwarded, ['--server', '--apply', '--preserve-apps', 'SaneBar,SaneClick'])
    end

    test('routes original cleanup args after parsing host mini') do
      subject = MachineCleanupHarness.new

      assert_eq(subject.machine_cleanup(['--host', 'mini', '--server', '--apply']), true)
      assert_eq(subject.routed_args, ['--host', 'mini', '--server', '--apply'])
    end

    test('plans cache cleanup only through safe roots and preserves unrelated Trash on apply') do
      with_home do |home|
        cache_path = mkdir_home_path(home, '.cache/huggingface')
        trash_path = mkdir_home_path(home, '.Trash')
        sizes = {
          File.expand_path(cache_path) => 6.0,
          File.expand_path(trash_path) => 2.0
        }
        subject = MachineCleanupHarness.new(sizes: sizes)
        plan = subject.send(:build_machine_cleanup_plan, {
          apply: true,
          host: 'local',
          min_free_gb: 30,
          cache_threshold_gb: 5,
          deriveddata_age_days: 2,
          trash_threshold_gb: 1,
          preserve_apps: []
        })

        categories = plan[:actions].map { |action| action[:category] }
        assert_includes(categories, 'trash')
        assert_includes(categories, 'disposable_cache')

        result = subject.send(:apply_machine_cleanup_plan, plan, quiet: true)
        assert_eq(result[:success], true)
        assert_includes(subject.trashed, File.expand_path(cache_path))
        assert_eq(subject.emptied, 0)
      end
    end

    test('plans only unavailable-simulator pruning while simulator work is active') do
      subject = MachineCleanupHarness.new(ps_rows: [
        { pid: 20, ppid: 1, pgid: 20, stat: 'S', etime: '00:10', command: 'xcrun simctl bootstatus D722DC92 -b' }
      ])

      plan = subject.send(:build_machine_cleanup_plan, {
        apply: false,
        host: 'local',
        min_free_gb: 30,
        cache_threshold_gb: 99,
        deriveddata_age_days: 2,
        trash_threshold_gb: 99,
        preserve_apps: []
      })

      simulator = plan[:actions].find { |action| action[:category] == 'simulator' }
      assert_eq(simulator[:type], 'command')
      assert_eq(simulator[:argv], %w[xcrun simctl delete unavailable])
      assert_includes(simulator[:reason], 'does not shut down or delete active simulator work')
    end

    test('refuses to trash paths outside cleanup-safe roots') do
      subject = MachineCleanupHarness.new

      assert_eq(subject.send(:machine_cleanup_safe_path?, File.expand_path('~/Library/Caches/ms-playwright')), true)
      assert_eq(subject.send(:machine_cleanup_safe_path?, File.expand_path('~/SaneApps/apps/SaneSales')), false)
    end

    test('server mode preserves process evidence and Codex state while pruning generated artifacts') do
      with_home do |home|
        downloads = mkdir_home_path(home, 'Downloads')
        File.write(File.join(downloads, 'old-installer.zip'), 'x')
        process_outputs = mkdir_home_path(home, 'SaneApps/infra/SaneProcess/outputs')
        File.write(File.join(process_outputs, 'old-receipt.json'), '{}')
        repo_build = mkdir_home_path(home, 'SaneApps/apps/SaneBar/.build')
        repo_outputs = mkdir_home_path(home, 'SaneApps/apps/SaneBar/outputs')
        sanevideo_outputs = mkdir_home_path(home, 'SaneApps/apps/SaneVideo/outputs')
        nested_package_build = mkdir_home_path(home, 'SaneApps/apps/SaneHosts/SaneHostsPackage/.build')
        release_work = mkdir_home_path(home, 'SaneApps/release-work')
        codex_sessions = mkdir_home_path(home, '.codex/sessions')
        codex_archived_sessions = mkdir_home_path(home, '.codex/archived_sessions')
        npm_npx = mkdir_home_path(home, '.npm/_npx')
        npm_cache = mkdir_home_path(home, '.npm/_cacache')
        scratch = mkdir_home_path(home, 'scratch')
        codex_runs = mkdir_home_path(home, 'codex-runs')
        xcodebuildmcp_workspaces = mkdir_home_path(home, 'Library/Developer/XcodeBuildMCP/workspaces')
        derived_data = mkdir_home_path(home, 'Library/Developer/Xcode/DerivedData/SaneBar-abc')

        sizes = {
          File.expand_path(downloads) => 0.5,
          File.expand_path(process_outputs) => 1.5,
          File.expand_path(repo_build) => 1.0,
          File.expand_path(repo_outputs) => 2.0,
          File.expand_path(sanevideo_outputs) => 8.0,
          File.expand_path(nested_package_build) => 3.0,
          File.expand_path(release_work) => 4.0,
          File.expand_path(codex_sessions) => 5.0,
          File.expand_path(codex_archived_sessions) => 1.0,
          File.expand_path(npm_npx) => 1.0,
          File.expand_path(npm_cache) => 1.0,
          File.expand_path(scratch) => 2.0,
          File.expand_path(codex_runs) => 0.5,
          File.expand_path(xcodebuildmcp_workspaces) => 0.7,
          File.expand_path(derived_data) => 6.0
        }
        subject = MachineCleanupHarness.new(sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: ['SaneBar']
        })

        paths = plan[:actions].map { |action| action[:path] }.compact
        categories = plan[:actions].map { |action| action[:category] }
        assert(!paths.include?(downloads), 'routine server cleanup must preserve Downloads')
        assert(!paths.include?(process_outputs), 'SaneProcess receipts and dirty-work snapshots must survive cleanup')
        assert(!paths.include?(repo_build), 'explicitly preserved app build artifacts must survive server cleanup')
        assert(!paths.include?(repo_outputs), 'expected generic app outputs to be preserved for QA evidence')
        assert(!paths.include?(sanevideo_outputs), 'whole app output roots must use bounded evidence retention')
        assert_includes(paths, nested_package_build)
        assert_includes(paths, release_work)
        assert(!paths.include?(codex_sessions), 'live Codex session state must survive cleanup')
        assert(!paths.include?(codex_archived_sessions), 'archived Codex session state must survive cleanup')
        assert_includes(paths, npm_npx)
        assert_includes(paths, npm_cache)
        assert_includes(paths, scratch)
        assert(!paths.include?(codex_runs), 'Codex run evidence must survive cleanup')
        assert_includes(paths, xcodebuildmcp_workspaces)
        assert(!paths.include?(derived_data), 'explicitly preserved app DerivedData must survive server cleanup')
        assert_includes(categories, 'server_simulator_delete')
        assert_includes(categories, 'server_simulator_runtime_delete')
      end
    end

    test('plans uv temp cleanup while preserving the active uv archive') do
      with_home do |home|
        tmp_dir = mkdir_home_path(home, '.cache/uv/.tmpOld')
        active_archive = mkdir_home_path(home, '.cache/uv/archive-v0/liveArchive')
        stale_archive = mkdir_home_path(home, '.cache/uv/archive-v0/staleArchive')
        sizes = {
          File.expand_path(tmp_dir) => 2.0,
          File.expand_path(active_archive) => 3.0,
          File.expand_path(stale_archive) => 4.0
        }
        subject = MachineCleanupHarness.new(
          ps_rows: [{ pid: 10, ppid: 1, pgid: 10, stat: 'S', etime: '00:10', command: "#{active_archive}/bin/python server.py" }],
          sizes: sizes
        )

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          min_free_gb: 30,
          cache_threshold_gb: 1,
          deriveddata_age_days: 2,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        tmp_action = plan[:actions].find { |action| action[:category] == 'uv_temp_cache' }
        archive_action = plan[:actions].find { |action| action[:category] == 'uv_archive_cache' }
        assert_eq(tmp_action[:type], 'trash_matching_children')
        assert_eq(archive_action[:except_names], ['liveArchive'])

        result = subject.send(:apply_machine_cleanup_plan, plan, quiet: true)
        assert_eq(result[:success], true)
        assert_includes(subject.trashed, tmp_dir)
        assert_includes(subject.trashed, stale_archive)
        assert(!subject.trashed.include?(active_archive), 'expected active uv archive to be preserved')
      end
    end

    test('server mode plans stale Codex code-sign clone cleanup only when Codex GUI is idle') do
      subject = MachineCleanupHarness.new(sizes: { '/private/var/folders/a/b/X/com.openai.codex.code_sign_clone' => 12.0 })
      subject.define_singleton_method(:server_codex_code_sign_clone_paths) do
        ['/private/var/folders/a/b/X/com.openai.codex.code_sign_clone']
      end

      plan = subject.send(:build_machine_cleanup_plan, {
        apply: false,
        host: 'local',
        server: true,
        min_free_gb: 30,
        cache_threshold_gb: 99,
        deriveddata_age_days: 999,
        trash_threshold_gb: 99,
        preserve_apps: []
      })

      codex_action = plan[:actions].find { |action| action[:category] == 'server_codex_residue' }
      assert_eq(codex_action[:type], 'trash_path')
      assert_eq(subject.send(:machine_cleanup_safe_path?, codex_action[:path]), true)

      active_subject = MachineCleanupHarness.new(
        ps_rows: [{ pid: 20, ppid: 1, pgid: 20, stat: 'S', etime: '01:00', command: '/Applications/Codex.app/Contents/MacOS/Codex' }],
        sizes: { '/private/var/folders/a/b/X/com.openai.codex.code_sign_clone' => 12.0 }
      )
      active_subject.define_singleton_method(:server_codex_code_sign_clone_paths) do
        ['/private/var/folders/a/b/X/com.openai.codex.code_sign_clone']
      end
      active_plan = active_subject.send(:build_machine_cleanup_plan, {
        apply: false,
        host: 'local',
        server: true,
        min_free_gb: 30,
        cache_threshold_gb: 99,
        deriveddata_age_days: 999,
        trash_threshold_gb: 99,
        preserve_apps: []
      })

      skip = active_plan[:actions].find do |action|
        action[:type] == 'skip' && action[:category] == 'server_generated_artifacts'
      end
      assert(skip, 'active Codex GUI should block the entire generated-artifact cleanup lane')
      assert_includes(skip[:reason], 'codex_gui_active')
    end

    test('server mode clears email review media from Desktop without touching SaneVideo evidence') do
      with_home do |home|
        email_media = mkdir_home_path(home, 'Desktop/Screenshots/email-review-media')
        mkdir_home_path(home, 'Desktop/Screenshots/email-review-media/email785')
        linked_media = mkdir_home_path(home, 'Desktop/email785-linked-media')
        email_png = File.join(home, 'Desktop/Screenshots/email785.png')
        FileUtils.mkdir_p(File.dirname(email_png))
        File.write(email_png, 'png')
        sanevideo_media = mkdir_home_path(home, 'Desktop/Screenshots/SaneVideo')
        sizes = {
          File.expand_path(email_media) => 0.02,
          File.expand_path(linked_media) => 0.03,
          File.expand_path(email_png) => 0.01,
          File.expand_path(sanevideo_media) => 5.0
        }
        subject = MachineCleanupHarness.new(sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: ['SaneVideo']
        })

        paths = plan[:actions].select { |action| action[:category] == 'server_desktop_email_media' }.map { |action| action[:path] }
        assert_includes(paths, email_media)
        assert_includes(paths, linked_media)
        assert_includes(paths, email_png)
        assert(!paths.include?(sanevideo_media), 'expected active SaneVideo screenshot evidence to stay untouched')
        assert_eq(subject.send(:machine_cleanup_safe_path?, email_media), true)
        assert_eq(subject.send(:machine_cleanup_safe_path?, email_png), true)
        assert_eq(subject.send(:machine_cleanup_safe_path?, sanevideo_media), false)
      end
    end

    test('desktop email media scan tolerates launchd privacy denial') do
      subject = MachineCleanupHarness.new
      original_glob = Dir.method(:glob)
      Dir.define_singleton_method(:glob) do |pattern|
        raise Errno::EPERM, pattern if pattern.include?('email-review-media')

        original_glob.call(pattern)
      end

      assert(subject.send(:server_desktop_email_media_paths).is_a?(Array), 'expected inaccessible Desktop globs to return an array')
    ensure
      Dir.define_singleton_method(:glob) { |pattern| original_glob.call(pattern) } if original_glob
    end

    test('trash_children clears an explicitly generated folder without trashing folder root') do
      with_home do |home|
        generated = mkdir_home_path(home, 'tmp')
        child = File.join(generated, 'old-build.dmg')
        File.write(child, 'x')
        subject = MachineCleanupHarness.new(sizes: { File.expand_path(generated) => 1.0 })

        plan = {
          actions: [
            {
              type: 'trash_children',
              category: 'server_generated_artifacts',
              path: generated,
              size_gb: 1.0,
              reason: 'test'
            }
          ]
        }
        result = subject.send(:apply_machine_cleanup_plan, plan, quiet: true)

        assert_eq(result[:success], true)
        assert_includes(subject.trashed, child)
        assert(!subject.trashed.include?(generated), 'expected generated root to stay in place')
      end
    end

    test('server exact cleanup list includes Mini layout litter paths and globs') do
      litter = SaneMasterModules::MachineCleanup::SERVER_EXACT_CLEANUP_PATHS
      layout = SaneMasterModules::MachineCleanup::LAYOUT_LITTER_PATHS
      [
        '~/Desktop/SaneClick-E2E*',
        '~/Desktop/SaneClick-Categories*',
        '~/Users',
        '~/SaneApps/Users',
        '~/$HOME',
        '~/LemonSqueezy-Uploads',
        '~/shot',
        '~/memory-bakeoff',
        '~/sanebar-recovery-*',
        '~/sanecite-build'
      ].each do |path|
        assert_includes(litter, path)
        assert_includes(layout, path)
      end
      assert(!litter.include?('~/Desktop/LemonSqueezy-Uploads'),
             'Desktop LemonSqueezy-Uploads is canonical staging and must not be exact-cleanup')

      with_home do |home|
        e2e = mkdir_home_path(home, 'Desktop/SaneClick-E2E.abc123')
        categories = mkdir_home_path(home, 'Desktop/SaneClick-Categories.xyz')
        users = mkdir_home_path(home, 'Users')
        saneapps_users = mkdir_home_path(home, 'SaneApps/Users')
        dollar_home = mkdir_home_path(home, '$HOME')
        ls_home = mkdir_home_path(home, 'LemonSqueezy-Uploads')
        ls_desktop = mkdir_home_path(home, 'Desktop/LemonSqueezy-Uploads')
        recovery = mkdir_home_path(home, 'sanebar-recovery-2026')
        subject = MachineCleanupHarness.new(sizes: {
          File.expand_path(e2e) => 0.1,
          File.expand_path(categories) => 0.1,
          File.expand_path(users) => 0.0,
          File.expand_path(saneapps_users) => 0.0,
          File.expand_path(dollar_home) => 0.0,
          File.expand_path(ls_home) => 0.1,
          File.expand_path(ls_desktop) => 0.1,
          File.expand_path(recovery) => 0.1
        })

        # Default cleanup (no --server) must still plan layout litter, including empty nests.
        default_plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: false,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: []
        })
        default_paths = default_plan[:actions].map { |action| action[:path] }.compact
        assert_includes(default_paths, e2e)
        assert_includes(default_paths, users)
        assert_includes(default_paths, saneapps_users)
        assert_includes(default_paths, dollar_home)
        assert(!default_paths.include?(ls_desktop), 'Desktop LemonSqueezy-Uploads must survive cleanup')

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: []
        })
        paths = plan[:actions].map { |action| action[:path] }.compact

        assert_includes(paths, e2e)
        assert_includes(paths, categories)
        assert_includes(paths, users)
        assert_includes(paths, saneapps_users)
        assert_includes(paths, dollar_home)
        assert_includes(paths, ls_home)
        assert_includes(paths, recovery)
        assert(!paths.include?(ls_desktop), 'Desktop LemonSqueezy-Uploads must survive cleanup')
        assert_eq(subject.send(:machine_cleanup_safe_path?, e2e), true)
        assert_eq(subject.send(:machine_cleanup_safe_path?, dollar_home), true)
        assert_eq(subject.send(:machine_cleanup_safe_path?, ls_desktop), false)
      end
    end

    test('server cleanup rejects symlinked roots and symlinked children') do
      with_home do |home|
        outside = mkdir_home_path(home, 'outside')
        linked_tmp = File.join(home, 'tmp')
        File.symlink(outside, linked_tmp)
        safe_tmp = mkdir_home_path(home, 'SaneApps/tmp')
        linked_child = File.join(safe_tmp, 'linked')
        File.symlink(outside, linked_child)
        subject = MachineCleanupHarness.new

        assert_eq(subject.send(:machine_cleanup_safe_path?, linked_tmp), false)
        assert_eq(subject.send(:machine_cleanup_safe_path?, linked_child), false)
      end
    end

    test('server cleanup refuses app roots and arbitrary source subdirectories') do
      with_home do |home|
        mkdir_home_path(home, 'SaneApps/apps/SaneBar')
        source_outputs = mkdir_home_path(home, 'SaneApps/apps/SaneBar/Sources/Feature/outputs')
        subject = MachineCleanupHarness.new

        assert_eq(subject.send(:machine_cleanup_safe_path?, File.join(home, 'SaneApps/apps/SaneBar')), false)
        assert_eq(subject.send(:machine_cleanup_safe_path?, source_outputs), false)
      end
    end

    test('healthy disk preserves expensive caches but still cleans cheap ones') do
      with_home do |home|
        playwright = mkdir_home_path(home, 'Library/Caches/ms-playwright')
        huggingface = mkdir_home_path(home, '.cache/huggingface')
        homebrew = mkdir_home_path(home, 'Library/Caches/Homebrew')
        sizes = {
          File.expand_path(playwright) => 2.0,
          File.expand_path(huggingface) => 20.0,
          File.expand_path(homebrew) => 6.0
        }
        subject = MachineCleanupHarness.new(disk: { available_gb: 80 }, sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          min_free_gb: 30,
          cache_threshold_gb: 5,
          deriveddata_age_days: 2,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        assert_eq(plan[:disk_pressure], false)
        cleaned = plan[:actions].select { |a| a[:category] == 'disposable_cache' }.map { |a| a[:path] }
        preserved = plan[:actions].select { |a| a[:type] == 'skip' && a[:category] == 'expensive_cache_preserved' }.map { |a| a[:path] }
        assert_includes(cleaned, homebrew)
        assert_includes(preserved, playwright)
        assert_includes(preserved, huggingface)
        assert(!cleaned.include?(playwright), 'expected playwright browsers to survive a healthy-disk cleanup')
        assert(!cleaned.include?(huggingface), 'expected huggingface models to survive a healthy-disk cleanup')
      end
    end

    test('server cleanup never treats SaneVideo customer data as disposable') do
      with_home do |home|
        customer_paths = [
          mkdir_home_path(home, 'Movies/SaneVideo'),
          mkdir_home_path(home, 'Library/Application Support/SaneVideo'),
          mkdir_home_path(home, 'Library/Containers/com.sanevideo.app')
        ]
        sizes = customer_paths.to_h { |path| [File.expand_path(path), 2.0] }
        subject = MachineCleanupHarness.new(disk: { available_gb: 80 }, sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        cleanup_paths = plan[:actions].map { |action| action[:path] }.compact
        customer_paths.each do |path|
          assert(!cleanup_paths.include?(path), "expected customer data to stay out of cleanup plan: #{path}")
          assert_eq(subject.send(:machine_cleanup_safe_path?, path), false)
        end
      end
    end

    test('disk pressure makes expensive caches eligible again') do
      with_home do |home|
        playwright = mkdir_home_path(home, 'Library/Caches/ms-playwright')
        sizes = { File.expand_path(playwright) => 6.0 }
        subject = MachineCleanupHarness.new(disk: { available_gb: 12 }, sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          min_free_gb: 30,
          cache_threshold_gb: 5,
          deriveddata_age_days: 2,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        assert_eq(plan[:disk_pressure], true)
        cleaned = plan[:actions].select { |a| a[:category] == 'disposable_cache' }.map { |a| a[:path] }
        assert_includes(cleaned, playwright)
      end
    end

    test('healthy-disk server reset preserves npm caches and simulator runtimes but still resets devices') do
      with_home do |home|
        npm_npx = mkdir_home_path(home, '.npm/_npx')
        npm_cache = mkdir_home_path(home, '.npm/_cacache')
        sizes = {
          File.expand_path(npm_npx) => 1.0,
          File.expand_path(npm_cache) => 1.0
        }
        subject = MachineCleanupHarness.new(disk: { available_gb: 80 }, sizes: sizes)

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 999,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        categories = plan[:actions].map { |action| action[:category] }
        npm_actions = plan[:actions].select { |a| a[:category] == 'server_expensive_cache' }
        assert_eq(npm_actions.map { |a| a[:type] }.uniq, ['skip'])
        assert_eq(npm_actions.map { |a| a[:path] }.sort, [npm_cache, npm_npx].sort)
        assert_includes(categories, 'server_simulator_delete')
        runtime_action = plan[:actions].find { |a| a[:category] == 'server_simulator_runtime_delete' }
        assert_eq(runtime_action[:type], 'skip')

        # Apply without the simctl command actions (they would really run); skips must be inert.
        trash_only_plan = { actions: plan[:actions].reject { |a| a[:type] == 'command' } }
        result = subject.send(:apply_machine_cleanup_plan, trash_only_plan, quiet: true)
        assert(!subject.trashed.include?(npm_npx), 'expected npx cache (wrangler/playwright CLIs) to survive a healthy-disk server reset')
        assert(!subject.trashed.include?(npm_cache), 'expected npm cacache to survive a healthy-disk server reset')
        assert_eq(result[:success], true)
      end
    end

    test('server mode skips repo artifact pruning while build, training, or Codex work is active') do
      with_home do |home|
        repo_build = mkdir_home_path(home, 'SaneApps/apps/SaneBar/.build')
        subject = MachineCleanupHarness.new(
          ps_rows: [{ pid: 10, ppid: 1, pgid: 10, stat: 'S', etime: '01:00', command: 'xcodebuild -scheme SaneBar build' }],
          sizes: { File.expand_path(repo_build) => 4.0 }
        )

        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false,
          host: 'local',
          server: true,
          min_free_gb: 30,
          cache_threshold_gb: 99,
          deriveddata_age_days: 2,
          trash_threshold_gb: 99,
          preserve_apps: []
        })

        paths = plan[:actions].map { |action| action[:path] }.compact
        categories = plan[:actions].map { |action| action[:category] }
        assert(!paths.include?(repo_build), 'expected active build work to prevent repo artifact pruning')
        assert(!categories.include?('server_deriveddata'), 'expected active build work to prevent DerivedData pruning')
        assert(!categories.include?('server_simulator_delete'), 'expected active build work to prevent simulator reset')
        assert(plan[:actions].any? { |action| action[:type] == 'skip' && action[:category] == 'server_generated_artifacts' })
        assert(plan[:actions].any? { |action| action[:type] == 'skip' && action[:category] == 'server_simulator' })
      end

      with_home do |home|
        repo_build = mkdir_home_path(home, 'SaneApps/apps/SaneBar/.build')
        subject = MachineCleanupHarness.new(
          ps_rows: [{ pid: 20, ppid: 1, pgid: 20, stat: 'S', etime: '01:00', command: '/Applications/Codex.app/Contents/MacOS/Codex' }],
          sizes: { File.expand_path(repo_build) => 4.0 }
        )
        plan = subject.send(:build_machine_cleanup_plan, {
          apply: false, host: 'local', server: true, min_free_gb: 30,
          cache_threshold_gb: 99, deriveddata_age_days: 2,
          trash_threshold_gb: 99, preserve_apps: []
        })
        assert(!plan[:actions].any? { |action| action[:path] == repo_build },
               'active Codex work must block generated artifact pruning')
        assert(plan[:actions].any? { |action| action[:type] == 'skip' && action[:reason].include?('codex_gui_active') })
      end
    end
  end
end)
