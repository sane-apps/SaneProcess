#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'open3'

require_relative '../hooks/test/test_framework'
require_relative 'visual_smoke'

class VisualSmokeHarness
  include SaneMasterModules::VisualSmoke

  def initialize
    @bundle_id = 'com.example.VisualSmoke'
  end

  def project_name
    'VisualSmokeTest'
  end
end

include TestFramework

exit(run_tests('SaneMaster Visual Smoke Tests') do
  subject = VisualSmokeHarness.new

  test_category('Argument parsing') do
    test('parses app bundle output and strict mode') do
      Dir.mktmpdir do |dir|
        options = subject.parse_visual_smoke_args(
          [
            '--app', 'SaneBar',
            '--bundle-id', 'com.sanebar.app',
            '--output', dir,
            '--peekaboo', '/tmp/peekaboo',
            '--timeout', '9',
            '--require-peekaboo',
            '--no-menu',
            '--json'
          ]
        )

        assert_eq(options.app_name, 'SaneBar')
        assert_eq(options.bundle_id, 'com.sanebar.app')
        assert_eq(options.output_root, dir)
        assert_eq(options.peekaboo_bin, '/tmp/peekaboo')
        assert_eq(options.timeout, 9)
        assert_eq(options.require_peekaboo, true)
        assert_eq(options.terminal_host, true)
        assert_eq(options.capture_menu, false)
        assert_eq(options.json, true)
      end
      true
    end

    test('enforces a minimum timeout') do
      options = subject.parse_visual_smoke_args(%w[--timeout 1])
      assert_eq(options.timeout, 5)
      true
    end

    test('searches non-login Homebrew paths used by Mini routes') do
      search_path = subject.visual_smoke_search_path
      assert_includes(search_path, '/opt/homebrew/bin')
      assert_includes(search_path, '/usr/local/bin')
      true
    end

    test('supports direct mode override') do
      options = subject.parse_visual_smoke_args(%w[--direct])
      assert_eq(options.terminal_host, false)
      true
    end

    test('no-app visual precheck does not require target app windows') do
      Dir.mktmpdir do |dir|
        options = subject.parse_visual_smoke_args(['--output', dir, '--dry-run', '--no-app'])
        result = subject.build_visual_smoke(options)
        names = result[:commands].map { |command| command[:name] }

        assert(!names.include?('windows'), 'precheck should not fail because the target app is not already running')
        assert(!names.include?('app-see'), 'precheck should not capture a target app image')
        assert(!names.include?('apps'), 'precheck should not require app-list APIs when app capture is disabled')
        assert_includes(names, 'screen-image')
        assert_includes(names, 'menu-image')
      end
      true
    end

    test('known menu-bar-only apps use screen and menu evidence without app windows') do
      Dir.mktmpdir do |dir|
        options = subject.parse_visual_smoke_args(['--output', dir, '--dry-run', '--app', 'SaneBar'])
        result = subject.build_visual_smoke(options)
        names = result[:commands].map { |command| command[:name] }

        assert(!names.include?('windows'), 'SaneBar visual smoke should not require normal app windows')
        assert(!names.include?('app-see'), 'SaneBar visual smoke should not run app-see against a windowless menu-bar app')
        assert(!names.include?('apps'), 'SaneBar visual smoke should not require app-list APIs for menu-bar-only evidence')
        assert_includes(names, 'screen-image')
        assert_includes(names, 'menu-image')
      end
      true
    end
  end

  test_category('Receipts') do
    test('dry-run writes a planned command receipt without requiring Peekaboo') do
      Dir.mktmpdir do |dir|
        options = subject.parse_visual_smoke_args(['--output', dir, '--dry-run'])
        result = subject.build_visual_smoke(options)
        receipt = JSON.parse(File.read(result[:receipt], encoding: Encoding::UTF_8))
        summary = File.read(result[:summary], encoding: Encoding::UTF_8)

        assert(result[:ok], 'dry-run should be successful')
        assert_eq(result[:status], 'planned')
        assert_eq(receipt['commands'].first['name'], 'permissions')
        assert_eq(receipt['runner'], 'terminal-host')
        assert_includes(summary, 'peekaboo image --mode screen --retina --path')
        assert_includes(summary, 'peekaboo image --app menubar --retina --path')
        assert_includes(summary, 'peekaboo see --app VisualSmokeTest --json --annotate --path')
      end
      true
    end

    test('missing Peekaboo skips by default and fails when required') do
      Dir.mktmpdir do |dir|
        optional = subject.parse_visual_smoke_args(['--output', dir, '--peekaboo', '/no/such/peekaboo'])
        optional_result = subject.build_visual_smoke(optional)
        assert(optional_result[:ok], 'missing optional Peekaboo should not fail release workflows')
        assert_eq(optional_result[:status], 'skipped')

        required = subject.parse_visual_smoke_args(
          ['--output', dir, '--peekaboo', '/no/such/peekaboo', '--require-peekaboo']
        )
        required_result = subject.build_visual_smoke(required)
        assert_eq(required_result[:ok], false)
        assert_eq(required_result[:status], 'failed')
      end
      true
    end

    test('dirty GUI state fails before capture commands run') do
      Dir.mktmpdir do |dir|
        fake_peekaboo = File.join(dir, 'peekaboo')
        File.write(fake_peekaboo, "#!/bin/sh\nexit 0\n")
        File.chmod(0o700, fake_peekaboo)

        subject.define_singleton_method(:visual_smoke_cleanliness_issues) do |_options|
          ['Terminal has 3 open window(s); close them before visual capture']
        end

        options = subject.parse_visual_smoke_args(['--output', dir, '--peekaboo', fake_peekaboo])
        result = subject.build_visual_smoke(options)

        assert_eq(result[:ok], false)
        assert_eq(result[:status], 'failed')
        assert_includes(result[:reason], 'Mini visual workspace is dirty')
        assert(result[:commands].none? { |command| command.key?(:success) }, 'commands must not run after dirty GUI preflight')
      end
      true
    ensure
      subject.singleton_class.remove_method(:visual_smoke_cleanliness_issues) rescue nil
    end

    test('windowless menu-bar apps skip app capture without failing visual smoke') do
      Dir.mktmpdir do |dir|
        fake_peekaboo = File.join(dir, 'peekaboo')
        log_path = File.join(dir, 'peekaboo.log')
        File.write(
          fake_peekaboo,
          <<~SH
            #!/bin/sh
            echo "$@" >> #{log_path}
            if [ "$1" = "permissions" ]; then
              echo '{"data":{"screen_recording":true,"accessibility":true}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "apps" ]; then
              echo '{"data":{"apps":[{"name":"VisualSmokeTest"}]}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "windows" ]; then
              echo '{"data":{"windows":[]},"summary":{"counts":{"windows":0}}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "menubar" ]; then
              echo '{"data":{"items":[]}}'
              exit 0
            fi
            if [ "$1" = "image" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--path" ]; then
                  shift
                  : > "$1"
                  echo '{"data":{"path":"'"$1"'"}}'
                  exit 0
                fi
                shift
              done
            fi
            if [ "$1" = "see" ]; then
              exit 12
            fi
            exit 1
          SH
        )
        File.chmod(0o700, fake_peekaboo)

        subject.define_singleton_method(:visual_smoke_cleanliness_issues) { |_options| [] }

        options = subject.parse_visual_smoke_args(['--output', dir, '--peekaboo', fake_peekaboo, '--direct'])
        result = subject.build_visual_smoke(options)
        app_see = result[:commands].find { |command| command[:name] == 'app-see' }
        app_see_receipt = JSON.parse(File.read(app_see[:output], encoding: Encoding::UTF_8))
        invocation_log = File.read(log_path, encoding: Encoding::UTF_8)

        assert(result[:ok], 'windowless menu-bar app should not fail visual smoke')
        assert_eq(result[:status], 'passed')
        assert_eq(app_see[:success], true)
        assert_eq(app_see[:skipped], true)
        assert_includes(app_see[:reason], 'target app has no windows')
        assert_eq(app_see_receipt['skipped'], true)
        assert(!invocation_log.include?('see --app'), 'app-see command should not run for a windowless app')
      end
      true
    ensure
      subject.singleton_class.remove_method(:visual_smoke_cleanliness_issues) rescue nil
    end

    test('no-app visual precheck passes when app-list API fails') do
      Dir.mktmpdir do |dir|
        fake_peekaboo = File.join(dir, 'peekaboo')
        log_path = File.join(dir, 'peekaboo.log')
        File.write(
          fake_peekaboo,
          <<~SH
            #!/bin/sh
            echo "$@" >> #{log_path}
            if [ "$1" = "permissions" ]; then
              echo '{"data":{"screen_recording":true,"accessibility":true}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "apps" ]; then
              echo '{"error":{"code":"PERMISSION_ERROR_SCREEN_RECORDING"}}'
              exit 4
            fi
            if [ "$1" = "list" ] && [ "$2" = "menubar" ]; then
              echo '{"data":{"items":[]}}'
              exit 0
            fi
            if [ "$1" = "image" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--path" ]; then
                  shift
                  : > "$1"
                  echo '{"data":{"path":"'"$1"'"}}'
                  exit 0
                fi
                shift
              done
            fi
            exit 1
          SH
        )
        File.chmod(0o700, fake_peekaboo)

        subject.define_singleton_method(:visual_smoke_cleanliness_issues) { |_options| [] }

        options = subject.parse_visual_smoke_args(['--output', dir, '--peekaboo', fake_peekaboo, '--direct', '--no-app'])
        result = subject.build_visual_smoke(options)
        invocation_log = File.read(log_path, encoding: Encoding::UTF_8)

        assert(result[:ok], 'no-app visual precheck should not fail on an unused app-list API')
        assert_eq(result[:status], 'passed')
        assert(!invocation_log.include?('list apps'), 'no-app precheck should not call app-list')
      end
      true
    ensure
      subject.singleton_class.remove_method(:visual_smoke_cleanliness_issues) rescue nil
    end

    test('app-see post-capture element detection failure is accepted when screenshot and window list exist') do
      Dir.mktmpdir do |dir|
        fake_peekaboo = File.join(dir, 'peekaboo')
        File.write(
          fake_peekaboo,
          <<~SH
            #!/bin/sh
            if [ "$1" = "permissions" ]; then
              echo '{"data":{"screen_recording":true,"accessibility":true}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "apps" ]; then
              echo '{"data":{"apps":[{"name":"VisualSmokeTest"}]}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "windows" ]; then
              echo '{"data":{"windows":[{"title":"VisualSmokeTest","bounds":[[0,0],[320,240]]}]},"summary":{"counts":{"windows":1}}}'
              exit 0
            fi
            if [ "$1" = "list" ] && [ "$2" = "menubar" ]; then
              echo '{"data":{"items":[]}}'
              exit 0
            fi
            if [ "$1" = "image" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--path" ]; then
                  shift
                  printf 'png' > "$1"
                  echo '{"data":{"path":"'"$1"'"}}'
                  exit 0
                fi
                shift
              done
            fi
            if [ "$1" = "see" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--path" ]; then
                  shift
                  printf 'png' > "$1"
                  echo '{"success":false,"error":{"code":"WINDOW_NOT_FOUND","message":"post-capture failure"}}'
                  exit 1
                fi
                shift
              done
            fi
            exit 1
          SH
        )
        File.chmod(0o700, fake_peekaboo)

        subject.define_singleton_method(:visual_smoke_cleanliness_issues) { |_options| [] }

        options = subject.parse_visual_smoke_args(['--output', dir, '--peekaboo', fake_peekaboo, '--direct'])
        result = subject.build_visual_smoke(options)
        app_see = result[:commands].find { |command| command[:name] == 'app-see' }

        assert(result[:ok], 'captured app screenshot with valid window list should satisfy visual smoke')
        assert_eq(result[:status], 'passed')
        assert_eq(app_see[:success], true)
        assert_eq(app_see[:fallback_success], true)
        assert_includes(app_see[:reason], 'screenshot artifact was captured')
      end
      true
    ensure
      subject.singleton_class.remove_method(:visual_smoke_cleanliness_issues) rescue nil
    end

    test('cleanliness check rejects visible stale apps and helper apps') do
      subject.define_singleton_method(:visual_smoke_terminal_window_count) { 0 }
      subject.define_singleton_method(:visual_smoke_permission_prompt_hits) { |_app| [] }
      subject.define_singleton_method(:visual_smoke_visible_process_names) do
        ['Finder', 'SaneSales', 'Preview', 'SaneClip']
      end
      subject.define_singleton_method(:visual_smoke_running_sane_process_lines) { [] }

      options = subject.parse_visual_smoke_args(%w[--app SaneClip])
      issues = subject.visual_smoke_cleanliness_issues(options)

      assert_includes(issues, 'Visible stale SaneApps window: SaneSales while testing SaneClip')
      assert_includes(issues, 'Visible helper app can contaminate screenshot: Preview')
      assert(!issues.any? { |issue| issue.include?('SaneClip while testing SaneClip') },
             'target app should remain allowed while capturing it')
      true
    ensure
      %i[
        visual_smoke_terminal_window_count
        visual_smoke_permission_prompt_hits
        visual_smoke_visible_process_names
        visual_smoke_running_sane_process_lines
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('cleanliness check rejects stale helper processes from prior app tests') do
      subject.define_singleton_method(:visual_smoke_terminal_window_count) { 0 }
      subject.define_singleton_method(:visual_smoke_permission_prompt_hits) { |_app| [] }
      subject.define_singleton_method(:visual_smoke_visible_process_names) { ['Finder', 'SaneVideo'] }
      subject.define_singleton_method(:visual_smoke_running_sane_process_lines) do
        [
          '61317 /Applications/SaneClick.app/Contents/PlugIns/SaneClickExtension.appex/Contents/MacOS/SaneClickExtension',
          '16441 /opt/homebrew/bin/python3 /Users/stephansmac/SaneApps/apps/SaneSync/scripts/inference_server.py',
          '62999 ruby ./scripts/SaneMaster.rb visual_smoke --app SaneVideo',
          '62849 tee -a /Users/stephansmac/SaneApps/outputs/customer-ui-audit/SaneVideo.run.log'
        ]
      end

      options = subject.parse_visual_smoke_args(%w[--app SaneVideo])
      issues = subject.visual_smoke_cleanliness_issues(options)

      assert_includes(issues, 'Stale SaneClickExtension helper is still running')
      assert_includes(issues, 'Stale SaneSync inference server is still running')
      assert(!issues.any? { |issue| issue.include?('visual_smoke --app') },
             'the visual_smoke command itself should not block its own capture')
      assert(!issues.any? { |issue| issue.include?('tee -a') },
             'background harness/log commands should not be treated as app UI pollution')
      true
    ensure
      %i[
        visual_smoke_terminal_window_count
        visual_smoke_permission_prompt_hits
        visual_smoke_visible_process_names
        visual_smoke_running_sane_process_lines
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('cleanliness check allows target app Sparkle updater helper without prompt') do
      subject.define_singleton_method(:visual_smoke_terminal_window_count) { 0 }
      subject.define_singleton_method(:visual_smoke_permission_prompt_hits) { |_app| [] }
      subject.define_singleton_method(:visual_smoke_visible_process_names) { ['Finder', 'SaneClick'] }
      subject.define_singleton_method(:visual_smoke_running_sane_process_lines) do
        [
          '21300 /Users/stephansmac/Library/Caches/com.saneclick.SaneClick/org.sparkle-project.Sparkle/Launcher/6OztUMoie/Updater.app/Contents/MacOS/Updater /Applications/SaneClick.app 0'
        ]
      end

      options = subject.parse_visual_smoke_args(%w[--app SaneClick])
      issues = subject.visual_smoke_cleanliness_issues(options)

      assert(!issues.any? { |issue| issue.include?('Stale SaneApps process') },
             "target app Sparkle updater helper should not block when no prompt is visible: #{issues.inspect}")
      true
    ensure
      %i[
        visual_smoke_terminal_window_count
        visual_smoke_permission_prompt_hits
        visual_smoke_visible_process_names
        visual_smoke_running_sane_process_lines
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('cleanliness check blocks unresolved macOS prompts before visual proof') do
      subject.define_singleton_method(:visual_smoke_terminal_window_count) { 0 }
      subject.define_singleton_method(:visual_smoke_permission_prompt_hits) do |_app|
        ['SaneVideo has an unresolved macOS permission/security prompt']
      end
      subject.define_singleton_method(:visual_smoke_visible_process_names) { ['Finder', 'SaneVideo'] }
      subject.define_singleton_method(:visual_smoke_running_sane_process_lines) { [] }

      options = subject.parse_visual_smoke_args(%w[--app SaneVideo])
      issues = subject.visual_smoke_cleanliness_issues(options)

      assert_includes(issues, 'SaneVideo has an unresolved macOS permission/security prompt')
      true
    ensure
      %i[
        visual_smoke_terminal_window_count
        visual_smoke_permission_prompt_hits
        visual_smoke_visible_process_names
        visual_smoke_running_sane_process_lines
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('prompt scan treats app-owned Move to Applications dialogs as visual blockers') do
      source = File.read(File.expand_path('visual_smoke.rb', __dir__), encoding: Encoding::UTF_8)

      assert_includes(source, "hasn't restarted")
      assert_includes(source, 'hasn’t restarted')
      assert_includes(source, 'failed to quit')
      assert_includes(source, 'has an unresolved macOS restart/shutdown prompt')
      assert_includes(source, 'Move to Applications')
      assert_includes(source, 'Could Not Move')
      assert_includes(source, 'works best from your Applications folder')
      assert_includes(source, 'move it there manually')
      assert_includes(source, 'You may be asked for your password')
      assert_includes(source, 'has an unresolved app install/move prompt')
      true
    end

    test('cleanliness check rejects known desktop test artifacts') do
      subject.define_singleton_method(:visual_smoke_terminal_window_count) { 0 }
      subject.define_singleton_method(:visual_smoke_permission_prompt_hits) { |_app| [] }
      subject.define_singleton_method(:visual_smoke_visible_process_names) { ['Finder'] }
      subject.define_singleton_method(:visual_smoke_running_sane_process_lines) { [] }
      subject.define_singleton_method(:visual_smoke_desktop_artifacts) do
        ['SaneProcess-rsync-misfire-20260509-110236', 'Screenshots']
      end

      options = subject.parse_visual_smoke_args(%w[--app SaneClip])
      issues = subject.visual_smoke_cleanliness_issues(options)
      joined = issues.join("\n")

      assert_includes(joined, 'Desktop contains leftover test artifact: SaneProcess-rsync-misfire')
      assert(!joined.include?('Screenshots'), 'normal desktop folders should not be rejected by artifact-pattern guard')
      true
    ensure
      %i[
        visual_smoke_terminal_window_count
        visual_smoke_permission_prompt_hits
        visual_smoke_visible_process_names
        visual_smoke_running_sane_process_lines
        visual_smoke_desktop_artifacts
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('visual smoke refuses overlapping runs instead of opening parallel Terminal windows') do
      Dir.mktmpdir do |dir|
        lock_path = File.join(Dir.tmpdir, 'sanemaster-visual-smoke.lock')
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX | File::LOCK_NB)

          options = subject.parse_visual_smoke_args(['--output', dir, '--dry-run'])
          result = subject.build_visual_smoke(options)

          assert_eq(result[:ok], false)
          assert_eq(result[:status], 'failed')
          assert_includes(result[:reason], 'another visual_smoke run is active')
        end
      end
      true
    end
  end

  test_category('macOS automation safety') do
    test('terminal-host command failure falls back to direct execution') do
      subject.define_singleton_method(:visual_smoke_terminal_host_available) { true }
      subject.define_singleton_method(:run_visual_smoke_command_via_terminal) do |_command, timeout:|
        { success: false, timed_out: true, runner: 'terminal-host', timeout: timeout }
      end
      subject.define_singleton_method(:run_visual_smoke_command_direct) do |_command, timeout:|
        { success: true, exit_status: 0, timed_out: false, runner: 'direct', timeout: timeout }
      end

      result = subject.run_visual_smoke_command({ argv: %w[peekaboo permissions status] }, timeout: 7, terminal_host: true)

      assert_eq(result[:success], true)
      assert_eq(result[:runner], 'direct-fallback')
      assert_eq(result[:fallback_from][:runner], 'terminal-host')
      true
    ensure
      %i[
        visual_smoke_terminal_host_available
        run_visual_smoke_command_via_terminal
        run_visual_smoke_command_direct
      ].each { |method| subject.singleton_class.remove_method(method) rescue nil }
    end

    test('osascript helper times out instead of hanging visual gates') do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _stdout, status = subject.send(:visual_smoke_capture_osascript, 'delay 10', timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert(status.nil?, 'timed-out osascript should not return a successful status')
      assert(elapsed < 4, "osascript timeout took too long: #{elapsed.round(2)}s")
      true
    end
  end

  test_category('Mini-first contract') do
    test('SaneMaster routes visual_smoke through Mini-first') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__), encoding: Encoding::UTF_8)
      mini_first_block = source[/MINI_FIRST_COMMANDS = Set\.new\(%w\[(.*?)\]\)\.freeze/m, 1]

      assert(mini_first_block, 'expected MINI_FIRST_COMMANDS block')
      assert_includes(mini_first_block, 'visual_smoke')
      assert_includes(mini_first_block, 'visual-smoke')
      true
    end

    test('visual smoke Mini host detection does not use the shared username') do
      source = File.read(File.expand_path('visual_smoke.rb', __dir__), encoding: Encoding::UTF_8)

      assert_includes(source, "Socket.gethostname.to_s.downcase")
      assert_includes(source, "'/usr/sbin/scutil', '--get', 'ComputerName'")
      assert(!source.include?("ENV.fetch('USER', '').downcase == 'stephansmac'"),
             'visual smoke must route by host identity, not account name')
      true
    end

    test('SaneMaster forwards visual runtime overrides to the Mini') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__), encoding: Encoding::UTF_8)
      env_block = source[/forwarded_env_keys = %w\[(.*?)\]/m, 1]

      assert(env_block, 'expected forwarded_env_keys block')
      assert_includes(env_block, 'PEEKABOO_BIN')
      assert_includes(env_block, 'SANEAPPS_FORCE_LICENSE_CHECK')
      true
    end

    test('dash alias resolves to detailed help') do
      registry_source = File.read(File.expand_path('command_registry.rb', __dir__), encoding: Encoding::UTF_8)
      stdout, stderr, status = Open3.capture3(
        'ruby',
        File.expand_path('../SaneMaster.rb', __dir__),
        'help',
        'visual-smoke'
      )

      assert_includes(registry_source, "'visual-smoke' => 'visual_smoke'")
      assert_eq(status.exitstatus, 0)
      assert_eq(stderr, '')
      assert_includes(stdout, 'VISUAL_SMOKE')
      assert_includes(stdout, '--require-peekaboo')
      true
    end
  end
end)
