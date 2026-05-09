#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

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
  end

  test_category('Receipts') do
    test('dry-run writes a planned command receipt without requiring Peekaboo') do
      Dir.mktmpdir do |dir|
        options = subject.parse_visual_smoke_args(['--output', dir, '--dry-run'])
        result = subject.build_visual_smoke(options)
        receipt = JSON.parse(File.read(result[:receipt]))
        summary = File.read(result[:summary])

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

  test_category('Mini-first contract') do
    test('SaneMaster routes visual_smoke through Mini-first') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
      mini_first_block = source[/MINI_FIRST_COMMANDS = Set\.new\(%w\[(.*?)\]\)\.freeze/m, 1]

      assert(mini_first_block, 'expected MINI_FIRST_COMMANDS block')
      assert_includes(mini_first_block, 'visual_smoke')
      assert_includes(mini_first_block, 'visual-smoke')
      true
    end

    test('SaneMaster forwards Peekaboo override to the Mini') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
      env_block = source[/forwarded_env_keys = %w\[(.*?)\]/m, 1]

      assert(env_block, 'expected forwarded_env_keys block')
      assert_includes(env_block, 'PEEKABOO_BIN')
      true
    end

    test('dash alias resolves to detailed help') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
      alias_block = source[/aliases = \{(.*?)\n    \}/m, 1]

      assert(alias_block, 'expected help alias block')
      assert_includes(alias_block, "'visual-smoke' => 'visual_smoke'")
      true
    end
  end
end)
