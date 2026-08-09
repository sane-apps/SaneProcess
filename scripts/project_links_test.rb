#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'project_links'
require_relative 'sync_check'
require_relative 'hooks/test/test_framework'

include TestFramework

exit(run_tests('Shared project links') do
  test('accepts only the relative shared lefthook target') do
    Dir.mktmpdir('sane-project-link-') do |project|
      assert_includes(SaneProjectLinks.lefthook_issue(project), 'missing')

      destination = File.join(project, 'lefthook.yml')
      FileUtils.cp(SaneProjectLinks::LEFTHOOK_TEMPLATE, destination)
      assert_includes(SaneProjectLinks.lefthook_issue(project), 'must be a symlink')

      File.unlink(destination)
      File.symlink('missing.yml', destination)
      assert_includes(SaneProjectLinks.lefthook_issue(project), 'broken')

      File.unlink(destination)
      File.symlink(SaneProjectLinks::LEFTHOOK_TEMPLATE, destination)
      assert_includes(SaneProjectLinks.lefthook_issue(project), 'must be relative')

      File.unlink(destination)
      wrong = File.join(project, 'wrong.yml')
      File.write(wrong, "pre-commit: {}\n")
      File.symlink('wrong.yml', destination)
      assert_includes(SaneProjectLinks.lefthook_issue(project), 'somewhere other')

      File.unlink(destination)
      relative = Pathname.new(SaneProjectLinks::LEFTHOOK_TEMPLATE)
        .relative_path_from(Pathname.new(project)).to_s
      File.symlink(relative, destination)
      assert_eq(SaneProjectLinks.lefthook_issue(project), nil)
    end
    true
  end

  test('installer replaces a copied config without changing the shared template') do
    Dir.mktmpdir('sane-project-link-install-') do |project|
      destination = File.join(project, 'lefthook.yml')
      File.write(destination, "copied: true\n")
      template_hash = Digest::SHA256.file(SaneProjectLinks::LEFTHOOK_TEMPLATE).hexdigest
      removed = []
      SaneProjectLinks.install_lefthook(
        project,
        remove_existing: lambda do |existing|
          removed << existing
          File.unlink(existing)
        end
      )
      assert_eq(removed, [File.join(File.realpath(project), 'lefthook.yml')])
      assert(File.symlink?(destination), 'installer must create a symlink')
      assert_eq(SaneProjectLinks.lefthook_issue(project), nil)
      assert_eq(Digest::SHA256.file(SaneProjectLinks::LEFTHOOK_TEMPLATE).hexdigest, template_hash)
    end
    true
  end

  test('sync check rejects copied, broken, and wrong-target lefthook configs') do
    Dir.mktmpdir('sane-project-link-sync-') do |project|
      destination = File.join(project, 'lefthook.yml')
      checker = SyncCheck.new([project])
      checker.send(:check_configs, project)
      assert(checker.instance_variable_get(:@diffs).any? { |row| row[:file] == 'lefthook.yml' }, 'missing link must drift')

      File.symlink('missing.yml', destination)
      checker = SyncCheck.new([project])
      checker.send(:check_configs, project)
      assert_includes(
        checker.instance_variable_get(:@diffs).find { |row| row[:file] == 'lefthook.yml' }[:reason],
        'broken'
      )

      File.unlink(destination)
      SaneProjectLinks.install_lefthook(project)
      checker = SyncCheck.new([project])
      checker.send(:check_configs, project)
      assert(!checker.instance_variable_get(:@diffs).any? { |row| row[:file] == 'lefthook.yml' }, 'valid shared link must pass')
    end
    true
  end

  test('scaffold creates the shared relative lefthook link') do
    Dir.mktmpdir('sane-project-link-scaffold-') do |apps_root|
      stdout, stderr, status = Open3.capture3(
        { 'SANEAPPS_SCAFFOLD_APPS_DIR' => apps_root },
        RbConfig.ruby, File.join(__dir__, 'scaffold.rb'), 'SaneLinkFixture', '--type', 'ios'
      )
      assert(status.success?, "#{stdout}\n#{stderr}")
      project = File.join(apps_root, 'SaneLinkFixture')
      destination = File.join(project, 'lefthook.yml')
      assert(File.symlink?(destination), 'scaffold must create a symlink')
      assert(!Pathname.new(File.readlink(destination)).absolute?, 'scaffold link must be relative')
      assert_eq(SaneProjectLinks.lefthook_issue(project), nil)
    end
    true
  end
end)
