#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression suite for the sane_test Developer ID re-sign lane
# (2026-07-14, split from app_test_mode_test.rb per the file-size rule).
# Three defects made every healthy Debug re-sign fail (first seen proving the
# SaneHosts Pro padlock fix):
#   1. the single-copy sweep trashed the fresh DerivedData product before
#      re-sign validation could use it as its trust anchor;
#   2. nested-code enumeration rejected the benign Versions/ bundle aliases
#      every standard framework layout contains;
#   3. the nested-signature check required the SaneApps team on third-party
#      services (Sparkle XPCs) that Xcode never re-signs at build time.

require_relative 'hooks/test/test_framework'
require_relative 'sane_test'
require 'fileutils'
require 'tmpdir'

include TestFramework

exit(run_tests('SaneTest Re-sign Lane Tests') do
  test_category('Single-copy and re-sign ordering') do
    test('fresh build product survives until re-sign validation completes') do
      runner = SaneTest.allocate
      order = []
      %i[kill_local clean_local build_debug stage_canonical_copy_local
         dedupe_accessibility_entries_local set_license_mode_local
         ensure_developer_id_signature_local enforce_single_copy_local
         launch_local print_air_ui_test_hints_local].each do |name|
        runner.define_singleton_method(name) { order << name }
      end
      runner.define_singleton_method(:step) { |_label, &block| block.call }
      runner.instance_variable_set(:@release_build, false)
      runner.instance_variable_set(:@fresh, false)
      runner.instance_variable_set(:@reset_tcc, false)
      runner.instance_variable_set(:@free_mode, false)
      runner.instance_variable_set(:@pro_mode, true)
      runner.instance_variable_set(:@no_logs, true)

      runner.send(:run_local)

      resign = order.index(:ensure_developer_id_signature_local)
      sweep = order.index(:enforce_single_copy_local)
      launch = order.index(:launch_local)
      assert(resign && sweep && launch, 'flow must re-sign, sweep, and launch')
      assert(resign < sweep,
             'single-copy sweep must not trash the fresh build product before re-sign validation')
      assert(sweep < launch, 'exactly one runtime copy must be enforced before launch')
      true
    end

    test('single-copy enforcement fails closed when the canonical copy is missing') do
      runner = SaneTest.allocate
      runner.instance_variable_set(:@staged_canonical_app_path, '/tmp/definitely-missing-staged.app')
      exit_error = nil
      begin
        runner.send(:enforce_single_copy_local)
      rescue SystemExit => e
        exit_error = e
      end

      assert(exit_error && !exit_error.success?, 'missing canonical copy must abort')
      true
    end
  end

  test_category('Framework alias enumeration') do
    test('framework-internal bundle aliases are skipped, not rejected') do
      # Standard framework layouts alias nested bundles through Versions/
      # symlinks (Sparkle.framework/Updater.app -> Versions/B/Updater.app).
      # The alias must be skipped once its target stays inside an approved
      # root, while its real bundle is still enumerated for signing.
      Dir.mktmpdir('sane-test-signing-alias') do |dir|
        app = File.join(dir, 'Example.app')
        versions = File.join(app, 'Contents', 'Frameworks', 'Sparkle.framework', 'Versions', 'B')
        real_updater = File.join(versions, 'Updater.app')
        FileUtils.mkdir_p(real_updater)
        File.symlink(
          File.join('Versions', 'B', 'Updater.app'),
          File.join(app, 'Contents', 'Frameworks', 'Sparkle.framework', 'Updater.app')
        )

        paths = SaneTest.allocate.send(:nested_code_paths, app)

        assert_includes(paths, File.expand_path(real_updater))
        alias_path = File.join(app, 'Contents', 'Frameworks', 'Sparkle.framework', 'Updater.app')
        assert(!paths.include?(File.expand_path(alias_path)),
               'framework alias must not be double-signed')
      end
      true
    end

    test('escaping symlinked bundle candidates still raise') do
      Dir.mktmpdir('sane-test-signing-escape') do |dir|
        app = File.join(dir, 'Example.app')
        frameworks = File.join(app, 'Contents', 'Frameworks')
        outside = File.join(dir, 'Injected.framework')
        FileUtils.mkdir_p([frameworks, outside])
        File.symlink(outside, File.join(frameworks, 'Injected.framework'))

        error = nil
        begin
          SaneTest.allocate.send(:nested_code_paths, app)
        rescue SaneTest::SigningValidationError => e
          error = e
        end
        assert(error, 'escaping symlinked nested code must be refused')
        assert_includes(error.message, 'escapes staged app')
      end
      true
    end
  end

  test_category('Two-phase re-sign ordering') do
    test('all nested objects are validated against the pristine tree before any signing') do
      # Regression (2026-07-14): interleaving validation with signing means
      # re-signed XPC children break the parent framework's resource seal
      # before the parent is validated, so the loop rejects its own work.
      runner = SaneTest.allocate
      events = []
      child = '/tmp/App.app/Contents/Frameworks/S.framework/Versions/B/XPCServices/D.xpc'
      parent = '/tmp/App.app/Contents/Frameworks/S.framework'
      runner.define_singleton_method(:trusted_fresh_nested_code_map!) do |_app|
        {
          'Frameworks/S.framework/Versions/B/XPCServices/D.xpc' => '/fresh/D.xpc',
          'Frameworks/S.framework' => '/fresh/S.framework'
        }
      end
      runner.define_singleton_method(:nested_code_paths) { |_app| [child, parent] }
      runner.define_singleton_method(:nested_code_relative_path) do |_app, path|
        path.delete_prefix('/tmp/App.app/Contents/')
      end
      runner.define_singleton_method(:validate_existing_nested_signature!) do |path, trusted_path:, relative_path:|
        events << [:validate, path]
        true
      end
      runner.define_singleton_method(:developer_id_resign_command) { |_identity, path| ['sign', path] }
      runner.define_singleton_method(:capture_signing_command) do |*command|
        events << [:sign, command.last]
        ok = Object.new
        ok.define_singleton_method(:success?) { true }
        ['', ok]
      end
      runner.define_singleton_method(:validate_saneapps_developer_id_signature!) { |_path| true }

      runner.send(:resign_nested_code_with_developer_id, 'Developer ID Application: SaneApps', '/tmp/App.app')

      first_sign = events.index { |kind, _| kind == :sign }
      last_validate = events.rindex { |kind, _| kind == :validate }
      assert(first_sign && last_validate, 'flow must validate and sign')
      assert(last_validate < first_sign,
             'every pristine-tree validation must complete before the first signature changes')
      true
    end
  end

  test_category('Third-party nested signatures') do
    test('third-party nested code matching the fresh build exactly is accepted') do
      # Xcode embed-and-sign leaves Sparkle's nested XPCServices carrying
      # Sparkle's upstream team signature even in a fresh local build. An
      # exact staged==fresh identity (type, identifier, cdhash, team) must be
      # accepted for re-signing.
      runner = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      sparkle_signed = <<~OUTPUT
        Identifier=org.sparkle-project.Downloader
        CDHash=2222222222222222222222222222222222222222
        TeamIdentifier=5AMZQ3E7FL
        designated => identifier "org.sparkle-project.Downloader" and anchor apple generic and certificate leaf[subject.OU] = 5AMZQ3E7FL
      OUTPUT
      runner.define_singleton_method(:code_signature_details) { |_path| [sparkle_signed, success] }
      runner.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| path }
      runner.define_singleton_method(:nested_code_executable_signature_valid?) { |_path| true }

      Dir.mktmpdir('sane-test-thirdparty') do |dir|
        staged = File.join(dir, 'Downloader.xpc')
        fresh = File.join(dir, 'FreshDownloader.xpc')
        FileUtils.mkdir_p([staged, fresh])
        result = runner.send(
          :validate_existing_nested_signature!,
          staged,
          trusted_path: fresh,
          relative_path: 'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc'
        )
        assert(result, 'identical third-party nested code must be accepted for re-signing')
      end
      true
    end

    test('ad-hoc nested code is accepted only as an exact match of the fresh build') do
      # A local Debug build leaves Sparkle's XPCServices AD-HOC signed
      # (Signature=adhoc, TeamIdentifier=not set, cdhash-only designated
      # requirement — measured on a real fresh SaneHosts build). The fresh
      # product is the trust anchor, so an identical staged object must pass
      # and any cdhash drift must still be refused.
      runner = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      adhoc = lambda do |cdhash|
        <<~OUTPUT
          Identifier=org.sparkle-project.DownloaderService
          Signature=adhoc
          CDHash=#{cdhash}
          TeamIdentifier=not set
          # designated => cdhash H"#{cdhash}"
        OUTPUT
      end
      runner.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| path }
      runner.define_singleton_method(:nested_code_executable_signature_valid?) { |_path| true }

      Dir.mktmpdir('sane-test-adhoc') do |dir|
        staged = File.join(dir, 'Downloader.xpc')
        fresh = File.join(dir, 'FreshDownloader.xpc')
        FileUtils.mkdir_p([staged, fresh])

        runner.define_singleton_method(:code_signature_details) do |_path|
          [adhoc.call('3333333333333333333333333333333333333333'), success]
        end
        result = runner.send(
          :validate_existing_nested_signature!,
          staged,
          trusted_path: fresh,
          relative_path: 'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc'
        )
        assert(result, 'identical ad-hoc nested code from the fresh build must be accepted')

        runner.define_singleton_method(:code_signature_details) do |path|
          cdhash = path.include?('Fresh') ? '4444444444444444444444444444444444444444' : '3333333333333333333333333333333333333333'
          [adhoc.call(cdhash), success]
        end
        error = nil
        begin
          runner.send(
            :validate_existing_nested_signature!,
            staged,
            trusted_path: fresh,
            relative_path: 'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc'
          )
        rescue SaneTest::SigningValidationError => e
          error = e
        end
        assert(error, 'ad-hoc nested code differing from the fresh build must be refused')
        assert_includes(error.message, 'cdhash')
      end
      true
    end

    test('nested code whose signature cannot be inspected is refused') do
      runner = SaneTest.allocate
      failed = Object.new
      failed.define_singleton_method(:success?) { false }
      runner.define_singleton_method(:code_signature_details) { |_path| ['', failed] }

      error = nil
      begin
        runner.send(
          :validate_existing_nested_signature!,
          '/tmp/Injected.xpc',
          trusted_path: '/tmp/Fresh.xpc',
          relative_path: 'Frameworks/Injected.xpc'
        )
      rescue SaneTest::SigningValidationError => e
        error = e
      end
      assert(error, 'uninspectable nested code must never be adopted by the SaneApps signature')
      assert_includes(error.message, 'matching SaneApps signature identity')
      true
    end
  end
end)
