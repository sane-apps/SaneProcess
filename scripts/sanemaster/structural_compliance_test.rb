#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'structural_compliance'

include TestFramework

def with_global_settings(path)
  mod = SaneMasterModules::StructuralCompliance
  original = mod.const_get(:GLOBAL_SETTINGS)
  mod.send(:remove_const, :GLOBAL_SETTINGS)
  mod.const_set(:GLOBAL_SETTINGS, path)
  yield
ensure
  mod.send(:remove_const, :GLOBAL_SETTINGS)
  mod.const_set(:GLOBAL_SETTINGS, original)
end

def write_settings(path, commands)
  hooks = commands.transform_values do |command|
    [
      {
        'hooks' => [
          {
            'type' => 'command',
            'command' => command
          }
        ]
      }
    ]
  end
  File.write(path, JSON.pretty_generate('hooks' => hooks))
end

def blocking_hook_commands(masked: false, include_task_completed: true)
  suffix = masked ? ' || true' : ''
  commands = {
    'SessionStart' => '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh session_start.rb',
    'UserPromptSubmit' => '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh saneprompt.rb',
    'PreToolUse' => '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh sanetools.rb',
    'PostToolUse' => '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh sanetrack.rb',
    'Stop' => '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh sanestop.rb'
  }
  commands['TaskCompleted'] = '~/SaneApps/infra/SaneProcess/scripts/hooks/run_hook.sh task_completed_gate.rb' if include_task_completed
  commands.transform_values { |command| "#{command}#{suffix}" }
end

exit(run_tests('SaneMaster Structural Compliance Tests') do
  test_category('Documentation contract') do
    test('uses AGENTS as the portable required doc and does not require CLAUDE by default') do
      Dir.mktmpdir('structural-docs-') do |dir|
        File.write(File.join(dir, '.saneprocess'), <<~YAML)
          name: GenericProject
          type: generic
          commands:
            verify: ruby -e true
          docs:
            - AGENTS.md
            - README.md
            - DEVELOPMENT.md
            - ARCHITECTURE.md
            - SESSION_HANDOFF.md
        YAML
        %w[AGENTS.md README.md DEVELOPMENT.md ARCHITECTURE.md SESSION_HANDOFF.md].each do |doc|
          File.write(File.join(dir, doc), "#{doc}\n")
        end

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_manifest)
        checker.send(:check_required_docs)
        result = checker.results[:critical].last

        assert_eq(result.pass, true)
        assert_includes(result.detail, '5/5')
      end
      true
    end

    test('flags private SaneApps tokens in public docs before an internal overlay') do
      Dir.mktmpdir('structural-public-docs-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'templates', 'boilerplate'))
        File.write(File.join(dir, 'README.md'), "Use ssh mini for every build.\n")

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_public_docs_separation)
        result = checker.results[:practice].last

        assert_eq(result.pass, false)
        assert_includes(result.detail, 'README.md:1 ssh mini')
      end
      true
    end

    test('allows private SaneApps tokens inside explicitly internal doc sections') do
      Dir.mktmpdir('structural-public-docs-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'templates', 'boilerplate'))
        File.write(File.join(dir, 'DEVELOPMENT.md'), <<~MD)
          # Development

          Portable users run local verification.

          ## SaneApps Operator Overlay

          SaneApps operators use ssh mini and ~/SaneApps paths.
        MD

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_public_docs_separation)
        result = checker.results[:practice].last

        assert_eq(result.pass, true)
      end
      true
    end
  end

  test_category('Hook registration') do
    test('requires the TaskCompleted completion gate hook') do
      Dir.mktmpdir('structural-hooks-') do |dir|
        settings_path = File.join(dir, 'settings.json')
        write_settings(settings_path, blocking_hook_commands(include_task_completed: false))

        with_global_settings(settings_path) do
          checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
          checker.send(:check_hook_registration)
          result = checker.results[:critical].last

          assert_eq(result.pass, false)
          assert_includes(result.detail, 'task_completed_gate.rb')
        end
      end
      true
    end

    test('blocks masking blocking hook exits with || true') do
      Dir.mktmpdir('structural-hooks-') do |dir|
        settings_path = File.join(dir, 'settings.json')
        write_settings(settings_path, blocking_hook_commands(masked: true))

        with_global_settings(settings_path) do
          checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
          checker.send(:check_hook_registration)
          result = checker.results[:critical].last

          assert_eq(result.pass, false)
          assert_includes(result.detail, 'masked exits')
          assert_includes(result.detail, 'session_start.rb')
          assert_includes(result.fix, 'if/then guard')
        end
      end
      true
    end

    test('accepts guarded blocking hooks that preserve exit status') do
      Dir.mktmpdir('structural-hooks-') do |dir|
        settings_path = File.join(dir, 'settings.json')
        write_settings(settings_path, blocking_hook_commands)

        with_global_settings(settings_path) do
          checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
          checker.send(:check_hook_registration)
          result = checker.results[:critical].last

          assert_eq(result.pass, true)
          assert_includes(result.detail, '6/6')
        end
      end
      true
    end
  end

  test_category('Project settings cleanup') do
    test('does not flag project settings when they are the global symlink target') do
      Dir.mktmpdir('structural-settings-') do |dir|
        settings_dir = File.join(dir, '.claude')
        FileUtils.mkdir_p(settings_dir)
        settings_path = File.join(settings_dir, 'settings.json')
        write_settings(settings_path, blocking_hook_commands)

        with_global_settings(settings_path) do
          checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
          checker.send(:check_clean_project_settings)
          result = checker.results[:config].last

          assert_eq(result.pass, true)
          assert_includes(result.detail, 'global symlink target')
        end
      end
      true
    end
  end

  test_category('Component owner size') do
    test('counts Swift extensions against the same component owner') do
      Dir.mktmpdir('structural-component-size-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Core'))
        File.write(File.join(dir, 'Core', 'LargeManager.swift'), (["final class LargeManager {}\n"] * 300).join)
        File.write(File.join(dir, 'Core', 'LargeManager+Moves.swift'), (["extension LargeManager {}\n"] * 300).join)
        File.write(File.join(dir, 'Core', 'LargeManager+Recovery.swift'), (["extension LargeManager {}\n"] * 250).join)

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_component_owner_size)
        result = checker.results[:practice].last

        assert_eq(result.pass, false)
        assert_includes(result.detail, 'LargeManager=850 lines/3 files')
        assert_includes(result.fix, 'extensions to hide a component')
      end
      true
    end

    test('does not count generated build directories as component owners') do
      Dir.mktmpdir('structural-component-build-') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.build', 'checkouts'))
        File.write(File.join(dir, '.build', 'checkouts', 'Generated.swift'), (["struct Generated {}\n"] * 900).join)
        File.write(File.join(dir, 'SmallView.swift'), "struct SmallView {}\n")

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_component_owner_size)
        result = checker.results[:practice].last

        assert_eq(result.pass, true)
      end
      true
    end

    test('flags oversized release scripts as audit liabilities') do
      Dir.mktmpdir('structural-release-script-size-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'Scripts'))
        File.write(File.join(dir, 'Scripts', 'huge_release_tool.rb'), (["puts 'ship'\n"] * 850).join)

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_release_script_size)
        result = checker.results[:practice].last

        assert_eq(result.pass, false)
        assert_includes(result.detail, 'Scripts/huge_release_tool.rb=850 lines')
        assert_eq(result.detail.scan('huge_release_tool.rb').count, 1)
        assert_includes(result.fix, 'Rule #10 applies to release tooling')
      end
      true
    end

    test('does not count generated build scripts as release tooling') do
      Dir.mktmpdir('structural-release-build-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'build', 'Scripts'))
        FileUtils.mkdir_p(File.join(dir, 'Scripts'))
        File.write(File.join(dir, 'build', 'Scripts', 'Generated.rb'), (["puts 'generated'\n"] * 900).join)
        File.write(File.join(dir, 'Scripts', 'small_release_tool.rb'), "puts 'ok'\n")

        checker = SaneMasterModules::StructuralCompliance::ComplianceChecker.new(dir)
        checker.send(:check_release_script_size)
        result = checker.results[:practice].last

        assert_eq(result.pass, true)
      end
      true
    end
  end
end)
