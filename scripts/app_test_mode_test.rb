#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'sane_test'

include TestFramework

SCRIPT_PATH = File.expand_path('app_test_mode.sh', __dir__)
SANE_TEST_PATH = File.expand_path('sane_test.rb', __dir__)

exit(run_tests('App Test Mode Bootstrap Tests') do
  test_category('Bootstrap install path') do
    test('local bootstrap uses release test_mode staging instead of debug launch') do
      source = File.read(SCRIPT_PATH)

      assert_includes(
        source,
        'SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs'
      )
      assert(!source.include?('SANEMASTER_CANONICAL_APP_PATH="$HOME/Applications/${app}.app" ./scripts/SaneMaster.rb launch'),
             'bootstrap should not rely on launch without a prebuilt Debug app')
      true
    end

    test('remote bootstrap uses release test_mode staging instead of debug launch') do
      source = File.read(SCRIPT_PATH)

      assert_includes(
        source,
        'SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs >/tmp/$(to_lower "$app")-bootstrap.log 2>&1'
      )
      true
    end
  end

  test_category('No user Applications fallback') do
    test('app_test_mode avoids ~/Applications installs and transient duplicates') do
      source = File.read(SCRIPT_PATH)

      assert(!source.include?('$HOME/Applications/${app}.app'),
             'app_test_mode should not stage runtime copies into ~/Applications')
      assert_includes(source, '/tmp/saneapps-staging.noindex/${app}.app')
      true
    end
  end

  test_category('No-keychain fallback domain') do
    test('app_test_mode writes fallback data into the app defaults domain and clears legacy domain') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'echo "${bundle_id}"')
      assert_includes(source, 'echo "${bundle_id}.no-keychain"')
      assert(source.include?('defaults delete "$legacy_domain" "$key_key"'),
             'app_test_mode should clear legacy no-keychain fallback keys after writing current defaults')
      true
    end

    test('sane_test writes fallback data into the app defaults domain and clears legacy domain') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def fallback_domain(bundle_id)')
      assert_includes(source, 'bundle_id')
      assert_includes(source, 'def legacy_fallback_domain(bundle_id)')
      assert(source.include?("system('defaults', 'delete', legacy_domain, key"),
             'sane_test should clear legacy no-keychain fallback keys after writing current defaults')
      true
    end
  end

  test_category('True fresh-install reset') do
    test('SaneClick fresh reset clears App Group state through Trash') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(
        source,
        "group_containers: ['M78L6FXD48.group.com.saneclick.app']",
        'SaneClick must declare the App Group that owns scripts and monitored folders'
      )
      assert_includes(
        source,
        'File.expand_path("~/Library/Group Containers/#{container_id}")',
        'local fresh reset must resolve declared App Group containers'
      )
      assert_includes(
        source,
        "system('/usr/bin/trash', path",
        'fresh reset must clear App Group state recoverably'
      )
      true
    end
  end

  test_category('Hardware verification mode') do
    test('sane_test supports real SaneVideo camera launches') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, "@hardware = args.include?('--hardware')")
      assert_includes(source, 'SANEAPPS_PERMISSIONLESS_AUTOMATION=#{permissionless_automation}')
      assert_includes(source, 'SANEVIDEO_ENABLE_HARDWARE_TESTS=#{hardware_tests}')
      assert_includes(source, 'Allow real hardware/permission prompts for SaneVideo camera verification')
      true
    end
  end

  test_category('Gatekeeper launch guard') do
    test('sane_test blocks ad-hoc launches that can show unidentified-developer dialogs') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'Refusing to launch ad-hoc signed')
      assert_includes(source, 'SANETEST_ALLOW_ADHOC_GATEKEEPER_DIALOG')
      assert_includes(source, "'ditto', '--noextattr', '--noacl'")
      true
    end
  end

  # Single-copy/re-sign ordering and third-party nested-signature regressions
  # live in scripts/sane_test_resign_lane_test.rb (Rule #10 size split).
  test_category('Developer ID entitlement preservation') do
    test('re-signing fails closed when the staged app is missing') do
      sanevideo = SaneTest.allocate
      sanevideo.define_singleton_method(:canonical_local_app_path) { '/tmp/definitely-missing-sanevideo.app' }
      exit_error = nil
      begin
        sanevideo.send(:ensure_developer_id_signature_local)
      rescue SystemExit => e
        exit_error = e
      end

      assert(exit_error && !exit_error.success?, 'missing staged app must abort runtime launch')
      true
    end

    test('re-signing fails closed when a Developer ID app has no restorable entitlements') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-entitlements') do |dir|
        app = File.join(dir, 'SaneVideo.app')
        FileUtils.mkdir_p(app)
        sanevideo.define_singleton_method(:canonical_local_app_path) { app }
        sanevideo.define_singleton_method(:signed_entitlements_xml) { |_path| nil }
        sanevideo.define_singleton_method(:developer_id_signed?) { |_path| true }
        sanevideo.define_singleton_method(:fresh_build_entitlements_xml) { |_path| nil }
        exit_error = nil
        begin
          sanevideo.send(:ensure_developer_id_signature_local)
        rescue SystemExit => e
          exit_error = e
        end

        assert(exit_error && !exit_error.success?, 'stripped Developer ID app must not launch')
      end
      true
    end

    test('re-sign command preserves app entitlements without applying them to nested code') do
      sanevideo = SaneTest.allocate
      command = sanevideo.send(
        :developer_id_resign_command,
        'Developer ID Application: SaneApps (M78L6FXD48)',
        '/Applications/SaneVideo.app',
        entitlements_path: '/tmp/sanevideo-preserved.entitlements'
      )

      assert_eq(
        command,
        [
          '/usr/bin/codesign', '--force', '--sign', 'Developer ID Application: SaneApps (M78L6FXD48)',
          '--options', 'runtime', '--preserve-metadata=identifier,requirements,entitlements',
          '--entitlements', '/tmp/sanevideo-preserved.entitlements', '/Applications/SaneVideo.app'
        ]
      )
      assert(!command.include?('--deep'), 'nested frameworks must retain their own signatures and entitlements')
      true
    end

    test('Developer ID selection accepts only the configured SaneApps team') do
      identities = <<~OUTPUT
        1) ABC "Developer ID Application: Other Vendor (OTHERTEAM1)"
        2) DEF "Developer ID Application: SaneApps (M78L6FXD48)"
      OUTPUT
      identity = SaneTest.allocate.send(:developer_id_identity_from_output, identities)

      assert_eq(identity, 'Developer ID Application: SaneApps (M78L6FXD48)')
      true
    end

    test('signing trust-boundary calls ignore PATH-injected security and codesign tools') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-fake-signing-path') do |dir|
        marker = File.join(dir, 'fake-tool-invoked')
        %w[codesign security].each do |tool|
          path = File.join(dir, tool)
          File.write(path, "#!/bin/sh\nprintf invoked >> #{Shellwords.escape(marker)}\nexit 0\n")
          FileUtils.chmod(0o755, path)
        end

        original_path = ENV['PATH']
        original_dyld = ENV['DYLD_INSERT_LIBRARIES']
        begin
          ENV['PATH'] = "#{dir}:#{original_path}"
          ENV['DYLD_INSERT_LIBRARIES'] = '/tmp/injected.dylib'
          missing_app = File.join(dir, 'missing.app')
          sanevideo.send(:code_signature_details, missing_app)
          sanevideo.send(:signed_entitlements_xml, missing_app)
          sanevideo.send(:deep_signature_valid?, missing_app)
          sanevideo.send(:codesigning_identity_output)

          assert(!File.exist?(marker), 'PATH-injected security tools must never execute')
          environment = sanevideo.send(:signing_command_environment)
          assert_eq(environment['PATH'], '/usr/bin:/bin')
          assert(!environment.key?('DYLD_INSERT_LIBRARIES'), 'dangerous parent environment must not cross the signing boundary')
        ensure
          ENV['PATH'] = original_path
          if original_dyld
            ENV['DYLD_INSERT_LIBRARIES'] = original_dyld
          else
            ENV.delete('DYLD_INSERT_LIBRARIES')
          end
        end
      end
      true
    end

    test('post-sign validation requires the SaneApps team and designated requirement') do
      sanevideo = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      valid_details = <<~OUTPUT
        Authority=Developer ID Application: SaneApps (M78L6FXD48)
        TeamIdentifier=M78L6FXD48
        designated => identifier "com.sanevideo.app" and anchor apple generic and certificate leaf[subject.OU] = M78L6FXD48
      OUTPUT
      sanevideo.define_singleton_method(:code_signature_details) { |_path| [valid_details, success] }
      assert(sanevideo.send(:validate_saneapps_developer_id_signature!, '/Applications/SaneVideo.app'))

      invalid_details = valid_details.sub('TeamIdentifier=M78L6FXD48', 'TeamIdentifier=OTHERTEAM1')
      sanevideo.define_singleton_method(:code_signature_details) { |_path| [invalid_details, success] }
      error = nil
      begin
        sanevideo.send(:validate_saneapps_developer_id_signature!, '/Applications/SaneVideo.app')
      rescue SaneTest::SigningValidationError => e
        error = e
      end
      assert(error, 'a different Developer ID team must fail closed')
      true
    end

    test('entitlement extraction returns only the signed plist payload') do
      sanevideo = SaneTest.allocate
      output = <<~OUTPUT
        Executable=/Applications/SaneVideo.app/Contents/MacOS/SaneVideo
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>com.apple.security.device.camera</key><true/></dict></plist>
        Authority=Developer ID Application: SaneApps (M78L6FXD48)
      OUTPUT

      assert_eq(
        sanevideo.send(:entitlement_plist_from_codesign_output, output),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>com.apple.security.device.camera</key><true/></dict></plist>"
      )
      true
    end

    test('nested code is enumerated deepest-first without following framework symlinks') do
      Dir.mktmpdir('sane-test-signing') do |dir|
        app = File.join(dir, 'Example.app')
        framework = File.join(app, 'Contents', 'Frameworks', 'Sparkle.framework')
        updater = File.join(framework, 'Versions', 'B', 'Updater.app')
        xpc = File.join(framework, 'Versions', 'B', 'XPCServices', 'Downloader.xpc')
        dylib = File.join(updater, 'Contents', 'Frameworks', 'Runtime.dylib')
        [framework, updater, xpc, File.dirname(dylib)].each { |path| FileUtils.mkdir_p(path) }
        File.binwrite(dylib, 'signed runtime placeholder')
        File.symlink('Versions/B', File.join(framework, 'Current'))

        paths = SaneTest.allocate.send(:nested_code_paths, app)

        assert_eq(paths.uniq, paths, 'nested paths should never be signed twice')
        assert(paths.index(dylib) < paths.index(updater), 'a nested library must be signed before its app')
        assert(paths.index(xpc) < paths.index(framework), 'an XPC service must be signed before its framework')
        assert(paths.index(updater) < paths.index(framework), 'an updater app must be signed before its framework')
        assert(!paths.any? { |path| path.include?('/Current/') }, 'framework symlink aliases must not be traversed')
      end
      true
    end

    test('nested code enumeration rejects a symlinked bundle candidate') do
      Dir.mktmpdir('sane-test-signing-symlink') do |dir|
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
        assert(error, 'symlinked nested code must not be followed or re-signed')
        assert_includes(error.message, 'symlink')
      end
      true
    end


    test('staged manifest accepts an exact runtime copy including modes and symlink targets') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-manifest-match') do |dir|
        staged = File.join(dir, 'Staged.app')
        fresh = File.join(dir, 'Fresh.app')
        [staged, fresh].each do |app|
          executable = File.join(app, 'Contents', 'MacOS', 'Example')
          resource = File.join(app, 'Contents', 'Resources', 'runtime.json')
          framework_version = File.join(app, 'Contents', 'Frameworks', 'Example.framework', 'Versions', 'A')
          FileUtils.mkdir_p([File.dirname(executable), File.dirname(resource), framework_version])
          File.binwrite(executable, 'runtime executable')
          FileUtils.chmod(0o755, executable)
          File.binwrite(resource, '{"enabled":true}')
          File.symlink('A', File.join(File.dirname(framework_version), 'Current'))
        end

        assert(sanevideo.send(:validate_staged_manifest_matches_fresh!, staged, fresh))
      end
      true
    end

    test('staged manifest rejects a modified runtime resource even when its size is unchanged') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-manifest-modified') do |dir|
        staged = File.join(dir, 'Staged.app')
        fresh = File.join(dir, 'Fresh.app')
        [staged, fresh].each do |app|
          resource = File.join(app, 'Contents', 'Resources', 'runtime.json')
          FileUtils.mkdir_p(File.dirname(resource))
          File.binwrite(resource, '{"mode":"safe"}')
        end
        File.binwrite(File.join(staged, 'Contents', 'Resources', 'runtime.json'), '{"mode":"evil"}')

        error = nil
        begin
          sanevideo.send(:validate_staged_manifest_matches_fresh!, staged, fresh)
        rescue SaneTest::SigningValidationError => e
          error = e
        end

        assert(error, 'modified runtime resources must block nested re-signing')
        assert_includes(error.message, 'sha256')
      end
      true
    end

    test('staged manifest rejects added scripts models and configuration') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-manifest-added') do |dir|
        staged = File.join(dir, 'Staged.app')
        fresh = File.join(dir, 'Fresh.app')
        [staged, fresh].each do |app|
          resource = File.join(app, 'Contents', 'Resources', 'runtime.json')
          FileUtils.mkdir_p(File.dirname(resource))
          File.binwrite(resource, '{"mode":"safe"}')
        end
        injected = File.join(staged, 'Contents', 'Resources', 'Injected.mlmodelc', 'weights.bin')
        FileUtils.mkdir_p(File.dirname(injected))
        File.binwrite(injected, 'untrusted model')

        error = nil
        begin
          sanevideo.send(:validate_staged_manifest_matches_fresh!, staged, fresh)
        rescue SaneTest::SigningValidationError => e
          error = e
        end

        assert(error, 'added runtime content must block nested re-signing')
        assert_includes(error.message, 'added path')
      end
      true
    end

    test('staged manifest rejects executable-mode and symlink-target changes') do
      sanevideo = SaneTest.allocate
      Dir.mktmpdir('sane-test-manifest-metadata') do |dir|
        staged = File.join(dir, 'Staged.app')
        fresh = File.join(dir, 'Fresh.app')
        [staged, fresh].each do |app|
          executable = File.join(app, 'Contents', 'MacOS', 'Example')
          versions = File.join(app, 'Contents', 'Frameworks', 'Example.framework', 'Versions')
          FileUtils.mkdir_p([File.dirname(executable), File.join(versions, 'A'), File.join(versions, 'B')])
          File.binwrite(executable, 'runtime executable')
          FileUtils.chmod(0o755, executable)
          File.symlink('A', File.join(versions, 'Current'))
        end
        FileUtils.chmod(0o644, File.join(staged, 'Contents', 'MacOS', 'Example'))

        mode_error = nil
        begin
          sanevideo.send(:validate_staged_manifest_matches_fresh!, staged, fresh)
        rescue SaneTest::SigningValidationError => e
          mode_error = e
        end
        assert(mode_error, 'executable mode changes must block nested re-signing')
        assert_includes(mode_error.message, 'mode')

        FileUtils.chmod(0o755, File.join(staged, 'Contents', 'MacOS', 'Example'))
        FileUtils.rm_f(File.join(staged, 'Contents', 'Frameworks', 'Example.framework', 'Versions', 'Current'))
        File.symlink('B', File.join(staged, 'Contents', 'Frameworks', 'Example.framework', 'Versions', 'Current'))
        target_error = nil
        begin
          sanevideo.send(:validate_staged_manifest_matches_fresh!, staged, fresh)
        rescue SaneTest::SigningValidationError => e
          target_error = e
        end
        assert(target_error, 'symlink target changes must block nested re-signing')
        assert_includes(target_error.message, 'target')
      end
      true
    end

    test('nested re-sign validation rejects unsigned injected code') do
      sanevideo = SaneTest.allocate
      failed = Object.new
      failed.define_singleton_method(:success?) { false }
      sanevideo.define_singleton_method(:code_signature_details) { |_path| ['', failed] }

      error = nil
      begin
        sanevideo.send(
          :validate_existing_nested_signature!,
          '/tmp/Injected.framework',
          trusted_path: '/tmp/Fresh.framework',
          relative_path: 'Frameworks/Injected.framework'
        )
      rescue SaneTest::SigningValidationError => e
        error = e
      end
      assert(error, 'unsigned nested code must not be adopted by the SaneApps signature')
      true
    end

    test('nested re-sign validation rejects code signed by another developer team') do
      sanevideo = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      other_team = <<~OUTPUT
        Identifier=com.example.Dependency
        CDHash=1111111111111111111111111111111111111111
        TeamIdentifier=OTHERTEAM1
        designated => identifier "com.example.Dependency" and anchor apple generic and certificate leaf[subject.OU] = OTHERTEAM1
      OUTPUT
      trusted_team = other_team
        .sub('TeamIdentifier=OTHERTEAM1', 'TeamIdentifier=M78L6FXD48')
        .sub('subject.OU] = OTHERTEAM1', 'subject.OU] = M78L6FXD48')
      sanevideo.define_singleton_method(:code_signature_details) do |path|
        [path.include?('Injected') ? other_team : trusted_team, success]
      end
      sanevideo.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| path }
      sanevideo.define_singleton_method(:nested_code_executable_signature_valid?) { |_path| true }

      error = nil
      begin
        Dir.mktmpdir('sane-test-other-team') do |dir|
          staged = File.join(dir, 'Injected.framework')
          fresh = File.join(dir, 'Fresh.framework')
          FileUtils.mkdir_p([staged, fresh])
          sanevideo.send(
            :validate_existing_nested_signature!,
            staged,
            trusted_path: fresh,
            relative_path: 'Frameworks/Injected.framework'
          )
        end
      rescue SaneTest::SigningValidationError => e
        error = e
      end

      assert(error, 'other-team nested code must never be adopted by the SaneApps signature')
      assert_includes(error.message, 'does not match fresh build')
      assert_includes(error.message, 'team')
      true
    end

    test('nested re-sign validation rejects a SaneApps-signed object that differs from the fresh build') do
      sanevideo = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      details = lambda do |cdhash|
        <<~OUTPUT
          Identifier=com.example.Dependency
          CDHash=#{cdhash}
          TeamIdentifier=M78L6FXD48
          designated => identifier "com.example.Dependency" and anchor apple generic and certificate leaf[subject.OU] = M78L6FXD48
        OUTPUT
      end
      sanevideo.define_singleton_method(:code_signature_details) do |path|
        hash = path.include?('Staged') ? '1' * 40 : '2' * 40
        [details.call(hash), success]
      end
      sanevideo.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| "#{path}/#{role}" }
      sanevideo.define_singleton_method(:nested_code_executable_signature_valid?) { |_path| true }

      Dir.mktmpdir('sane-test-signing-mismatch') do |dir|
        staged = File.join(dir, 'Staged.framework')
        fresh = File.join(dir, 'Fresh.framework')
        FileUtils.mkdir_p([staged, fresh])
        error = nil
        begin
          sanevideo.send(
            :validate_existing_nested_signature!,
            staged,
            trusted_path: fresh,
            relative_path: 'Frameworks/Dependency.framework'
          )
        rescue SaneTest::SigningValidationError => e
          error = e
        end

        assert(error, 'fresh-build content mismatch must block nested code adoption')
        assert_includes(error.message, 'cdhash')
      end
      true
    end

    test('nested re-sign validation preserves a matching SaneApps repair candidate') do
      sanevideo = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      valid_details = <<~OUTPUT
        Identifier=com.example.Dependency
        CDHash=1111111111111111111111111111111111111111
        TeamIdentifier=M78L6FXD48
        designated => identifier "com.example.Dependency" and anchor apple generic and certificate leaf[subject.OU] = M78L6FXD48
      OUTPUT
      sanevideo.define_singleton_method(:code_signature_details) { |_path| [valid_details, success] }
      sanevideo.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| "#{path}/#{role}" }
      sanevideo.define_singleton_method(:nested_code_executable_signature_valid?) { |_path| true }

      Dir.mktmpdir('sane-test-signing-match') do |dir|
        staged = File.join(dir, 'Staged.framework')
        fresh = File.join(dir, 'Fresh.framework')
        FileUtils.mkdir_p([staged, fresh])
        accepted = sanevideo.send(
          :validate_existing_nested_signature!,
          staged,
          trusted_path: fresh,
          relative_path: 'Frameworks/Dependency.framework'
        )

        assert_eq(accepted, true)
      end
      true
    end

    test('nested re-sign validation rejects modified code that retains stale SaneApps signature metadata') do
      sanevideo = SaneTest.allocate
      success = Object.new
      success.define_singleton_method(:success?) { true }
      stale_details = <<~OUTPUT
        Identifier=com.example.Dependency
        CDHash=1111111111111111111111111111111111111111
        TeamIdentifier=M78L6FXD48
        designated => identifier "com.example.Dependency" and anchor apple generic and certificate leaf[subject.OU] = M78L6FXD48
      OUTPUT
      sanevideo.define_singleton_method(:code_signature_details) { |_path| [stale_details, success] }
      sanevideo.define_singleton_method(:nested_code_executable_path!) { |path, _details, role:| "#{path}/#{role}" }
      sanevideo.define_singleton_method(:nested_code_executable_signature_valid?) do |path|
        !path.include?('/staged')
      end

      error = nil
      begin
        Dir.mktmpdir('sane-test-stale-metadata') do |dir|
          staged = File.join(dir, 'Staged.framework')
          fresh = File.join(dir, 'Fresh.framework')
          FileUtils.mkdir_p([staged, fresh])
          sanevideo.send(
            :validate_existing_nested_signature!,
            staged,
            trusted_path: fresh,
            relative_path: 'Frameworks/Dependency.framework'
          )
        end
      rescue SaneTest::SigningValidationError => e
        error = e
      end

      assert(error, 'stale signature metadata must not authenticate modified nested code')
      assert_includes(error.message, 'does not match fresh build')
      assert_includes(error.message, 'executable_valid')
      true
    end
  end

  test_category('SaneClip signed runtime path') do
    test('sane_test treats SaneClip as a signed Release runtime app') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclick = SaneTest.allocate
      saneclick.instance_variable_set(:@app_name, 'SaneClick')

      assert(saneclip.send(:signed_release_runtime_required?))
      assert(!saneclick.send(:signed_release_runtime_required?))
      true
    end

    test('SaneClip cleanup unregisters removed app paths without full database resets') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, '#{LSREGISTER} -u')
      assert_includes(source, '#{LSREGISTER} -gc')
      assert_includes(source, 'find #{remote_path} -depth -type d -name \'*.app\'')
      assert_includes(source, "Dir.glob(File.join(root, '**', '*.app'))")
      assert_includes(source, "system(LSREGISTER, '-u', bundle")
      assert_includes(source, "system(LSREGISTER, '-f', File.expand_path(path)")
      assert(!source.include?('lsregister -kill -r'),
             'removed lsregister reset flags must not return')
      true
    end

    test('Release builds keep the production bundle id') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')

      assert(!saneclip.send(:dev_bundle_override_for_build?, 'Release'))
      assert(saneclip.send(:dev_bundle_override_for_build?, 'ProdDebug'))
      true
    end

    test('Release builds never receive unsigned debug overrides') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')

      assert(!saneclip.send(:unsigned_debug_overrides_for_build?, 'Release', false))
      assert(saneclip.send(:unsigned_debug_overrides_for_build?, 'Debug', false))
      assert(!saneclip.send(:unsigned_debug_overrides_for_build?, 'Debug', true))
      true
    end

    test('direct executable launch keeps wrapper environment') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclip.instance_variable_set(:@hardware, false)
      saneclip.instance_variable_set(:@free_mode, false)

      env = saneclip.send(:launch_env_hash)
      assert_eq(env['SANEAPPS_SKIP_MOVE_TO_APPLICATIONS'], '1')
      assert_eq(env['SANEAPPS_PERMISSIONLESS_AUTOMATION'], '1')
      assert_eq(env['SANEVIDEO_ENABLE_HARDWARE_TESTS'], '0')
      true
    end

    test('direct executable launch suppresses app move prompts') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclip.instance_variable_set(:@allow_keychain, false)

      args = saneclip.send(:direct_launch_args)
      assert_includes(args, '--sane-skip-app-move')
      assert_includes(args, '--sane-no-keychain')

      saneclip.instance_variable_set(:@allow_keychain, true)
      assert_eq(saneclip.send(:direct_launch_args), ['--sane-skip-app-move'])
      true
    end

    test('sane_test direct-launches only quarantined local builds that LaunchServices would reject') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'launch_services_gatekeeper_rejected?(app_path)')
      assert_includes(source, 'return false unless quarantined?(app_path)')
      assert_includes(source, "Open3.capture3('xattr', '-p', 'com.apple.quarantine', app_path)")
      assert_includes(source, 'LaunchServices would show Gatekeeper')
      assert_includes(source, "spawn(launch_env_hash, executable, *direct_launch_args")
      true
    end

    test('sane_test does not SSH or rsync when already running on the Mini') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def running_on_mini_host?')
      assert_includes(source, 'Already running on Mac mini')
      assert_includes(source, "Socket.gethostname.to_s.downcase")
      assert_includes(source, "'/usr/sbin/scutil', '--get', 'ComputerName'")
      assert(
        source.index('running_on_mini_host?') < source.index('mini_reachable?'),
        'the Mini-local check must run before probing ssh mini'
      )
      assert(!source.include?("ENV.fetch('USER', '').downcase == 'stephansmac'"),
             'sane_test must not decide Mini identity from the shared account name')
      true
    end

    test('local pro-mode writes license fallback for the staged runtime bundle id') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def local_runtime_bundle_id')
      assert_includes(source, 'bundle_id_for_app(canonical_local_app_path)')
      assert_includes(source, 'bid = local_runtime_bundle_id')
      assert_includes(source, 'set_pro_fallback_local(bid)')
      assert(!source.include?('bid = @config[:dev]'),
             'local pro-mode must not write only the dev bundle id for signed release apps')
      true
    end
  end

  test_category('Canonical launch owner') do
    test('sane_test cleans the trashed destination from Launch Services') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      calls = []

      Dir.mktmpdir('sane-test-launch-services') do |dir|
        app = File.join(dir, 'SaneClip.app')
        FileUtils.mkdir_p(app)
        saneclip.define_singleton_method(:unregister_launch_services_local) { |_path| }
        saneclip.define_singleton_method(:system) do |*args, **_kwargs|
          calls << args
          true
        end

        saneclip.send(:trash_local_path, app)
      end

      hygiene_call = calls.find { |args| args.include?('--launch-services-only') }
      assert(hygiene_call, 'trash must be followed by scoped Launch Services hygiene')
      assert_includes(hygiene_call, 'SaneClip')
      true
    end

    test('sane_test removes Xcode index and Periphery app copies before launch') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(
        source,
        'Library/Developer/Xcode/DerivedData/#{@app_name}-*/Index.noindex/Build/Products/**/#{@app_name}.app'
      )
      assert_includes(
        source,
        'Library/Caches/com.github.peripheryapp/DerivedData*/Build/Products/**/#{@app_name}.app'
      )
      true
    end

    test('app_test_mode delegates Basic and Pro launches to sane_test') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'local launcher="$HOME/SaneApps/infra/SaneProcess/scripts/sane_test.rb"')
      assert_includes(source, 'launcher_args=("$app" "--local" "--release" "--no-logs")')
      assert_includes(source, 'launcher_args+=("--free-mode")')
      assert_includes(source, 'launcher_args+=("--pro-mode")')
      assert_includes(source, 'ruby "$launcher" "${launcher_args[@]}"')
      assert(!source.include?('launch_app_local()'), 'mode launch should not duplicate local app launching')
      assert(!source.include?('launch_app_remote()'), 'mode launch should not duplicate remote app launching')
      true
    end
  end

  test_category('Mini canonical workspace guard') do
    test('remote flow reuses the canonical Mini launcher and app checkout by default') do
      runner = SaneTest.allocate
      runner.instance_variable_set(:@app_dir, '/Users/sj/SaneApps/apps/SaneClip')
      runner.instance_variable_set(:@raw_args, [])
      runner.instance_variable_set(:@sync_workspace_to_mini, false)
      used = []
      runner.define_singleton_method(:step) { |_name, &block| block.call }
      runner.define_singleton_method(:assert_canonical_remote_repo!) { |path| used << path }
      runner.define_singleton_method(:sync_repo_to_mini) { |*| raise 'unexpected sync' }
      runner.define_singleton_method(:exec_remote_sane_test) { |path| used << [:exec, path] }

      runner.send(:run_remote)

      assert_includes(used, '/Users/stephansmac/SaneApps/apps/SaneClip')
      assert_includes(used, [:exec, '/Users/stephansmac/SaneApps/infra/SaneProcess'])
      true
    end

    test('explicit sync refuses dirty, divergent, or feature-branch Mini repos and accepts matching clean main') do
      cases = [
        ['main', ' M changed.swift', 'same-head'],
        ['codex/feature', '', 'same-head'],
        ['main', '', 'different-head']
      ]
      cases.each do |branch, dirty, remote_head|
        runner = SaneTest.allocate
        runner.define_singleton_method(:assert_canonical_remote_repo!) { |_repo| true }
        runner.define_singleton_method(:local_git_value) do |_repo, *args|
          args.first == 'rev-parse' ? 'same-head' : 'git@github.com:sane-apps/SaneClip.git'
        end
        runner.define_singleton_method(:remote_git_value) do |_repo, *args|
          {
            'branch' => branch,
            'status' => dirty,
            'head' => remote_head,
            'config' => 'https://github.com/sane-apps/SaneClip.git'
          }[args.first]
        end
        refused = false
        begin
          runner.send(:assert_remote_sync_safe!, '/air/SaneClip', '/mini/SaneClip')
        rescue SystemExit
          refused = true
        end
        assert(
          refused,
          "sync must refuse branch=#{branch.inspect} dirty=#{dirty.inspect} head=#{remote_head.inspect}"
        )
      end

      clean = SaneTest.allocate
      clean.define_singleton_method(:assert_canonical_remote_repo!) { |_repo| true }
      clean.define_singleton_method(:local_git_value) do |_repo, *args|
        args.first == 'rev-parse' ? 'same-head' : 'https://example-token@github.com/sane-apps/SaneClip.git'
      end
      clean.define_singleton_method(:remote_git_value) do |_repo, *args|
        {
          'branch' => 'main',
          'status' => '',
          'head' => 'same-head',
          'config' => 'https://github.com/sane-apps/SaneClip.git'
        }[args.first]
      end
      assert_eq(clean.send(:assert_remote_sync_safe!, '/air/SaneClip', '/mini/SaneClip'), nil)
      true
    end
  end

  test_category('Mini sync preserves tracked Xcode metadata') do
    test('sane_test keeps tracked project workspace metadata even when app .gitignore ignores it') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, "'--include', '*/project.xcworkspace/contents.xcworkspacedata'")
      assert(
        source.index("'--include', '*/project.xcworkspace/contents.xcworkspacedata'") <
          source.index("'--filter', ':- .gitignore'"),
        'tracked Xcode workspace metadata must be included before .gitignore filters can exclude it'
      )
      true
    end
  end
end)
