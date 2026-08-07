#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class SaneCursorInstallTest < Minitest::Test
  ROOT = File.expand_path('../../..', __dir__)
  INSTALLER = File.join(__dir__, 'install.rb')
  INIT = File.join(ROOT, 'scripts', 'init.sh')
  BEFORE_GUARD = File.join(__dir__, 'before_shell_guard.rb')

  def run_installer(home, *skills)
    arguments = ['ruby', INSTALLER, '--home', home]
    skills.each { |source| arguments.concat(['--skills-source', source]) }
    Open3.capture3(
      { 'HOME' => home },
      *arguments
    )
  end

  def write_skill(root, name, content)
    skill_dir = File.join(root, name)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), content)
  end

  def test_merge_is_backup_first_idempotent_and_no_delete
    Dir.mktmpdir('cursor-install') do |dir|
      home = File.join(dir, 'home')
      skills = File.join(dir, 'skills')
      hooks_dir = File.join(home, '.cursor', 'hooks')
      FileUtils.mkdir_p([hooks_dir, File.join(skills, 'audit'), File.join(home, '.cursor', 'skills', 'audit')])
      File.write(File.join(skills, 'audit', 'SKILL.md'), "canonical audit\n")
      File.write(File.join(hooks_dir, 'before_shell_guard.rb'), "local divergent hook\n")
      File.write(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md'), "local divergent skill\n")
      File.write(File.join(home, '.cursor', 'skills', 'audit', 'local-note.md'), "keep me\n")
      File.write(File.join(home, '.cursor', 'hooks.json'), JSON.pretty_generate(
        'version' => 1,
        'hooks' => {
          'beforeShellExecution' => [
            { 'command' => './hooks/custom_guard.rb', 'matcher' => 'custom' },
            { 'command' => './hooks/email_send_guard.rb', 'matcher' => 'legacy' }
          ],
          'afterShellExecution' => [{ 'command' => './hooks/custom_after.rb', 'matcher' => 'custom' }]
        }
      ))

      stdout, stderr, status = run_installer(home, skills)
      assert status.success?, "#{stdout}\n#{stderr}"

      manifest = JSON.parse(File.read(File.join(home, '.cursor', 'hooks.json')))
      before_commands = manifest.dig('hooks', 'beforeShellExecution').map { |entry| entry['command'] }
      after_commands = manifest.dig('hooks', 'afterShellExecution').map { |entry| entry['command'] }
      assert_includes before_commands, './hooks/custom_guard.rb'
      assert_includes before_commands, './hooks/before_shell_guard.rb'
      refute_includes before_commands, './hooks/email_send_guard.rb'
      assert_includes after_commands, './hooks/custom_after.rb'
      assert_includes after_commands, './hooks/gui_feedback_after_shell.rb'
      assert_equal "canonical audit\n", File.read(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md'))
      assert File.file?(File.join(home, '.cursor', 'skills', 'audit', 'local-note.md'))
      assert_equal 0o600, File.stat(File.join(home, '.cursor', 'hooks.json')).mode & 0o777
      assert_equal 0o600, File.stat(File.join(home, '.cursor', 'saneprocess_root')).mode & 0o777
      assert_equal "#{ROOT}\n", File.read(File.join(home, '.cursor', 'saneprocess_root'))
      assert_equal 0o755, File.stat(File.join(hooks_dir, 'before_shell_guard.rb')).mode & 0o777

      installed_out, installed_err, installed_status = Open3.capture3(
        { 'HOME' => home },
        'ruby', File.join(hooks_dir, 'before_shell_guard.rb'),
        stdin_data: JSON.generate('command' => '/usr/bin/open -a "Google Chrome" https://example.com')
      )
      assert installed_status.success?, installed_err
      assert_equal 'deny', JSON.parse(installed_out)['permission']

      backups_before = Dir.glob(File.join(hooks_dir, 'before_shell_guard.rb.sane-backup-*')).length
      skill_backups_before = Dir.glob(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md.sane-backup-*')).length
      _stdout2, stderr2, status2 = run_installer(home, skills)
      assert status2.success?, stderr2
      assert_equal backups_before, Dir.glob(File.join(hooks_dir, 'before_shell_guard.rb.sane-backup-*')).length
      assert_equal skill_backups_before,
                   Dir.glob(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md.sane-backup-*')).length
    end
  end

  def test_before_shell_guard_denies_blocked_browser_and_invalid_payload
    denied_out, denied_err, denied_status = Open3.capture3(
      'ruby', BEFORE_GUARD,
      stdin_data: JSON.generate('command' => '/usr/bin/open -a "Google Chrome" https://example.com')
    )
    assert denied_status.success?, denied_err
    denied = JSON.parse(denied_out)
    assert_equal 'deny', denied['permission']
    assert_includes denied['agent_message'], 'Brave only'

    allowed_out, allowed_err, allowed_status = Open3.capture3(
      'ruby', BEFORE_GUARD,
      stdin_data: JSON.generate('command' => '/usr/bin/open -a "Brave Browser" https://example.com')
    )
    assert allowed_status.success?, allowed_err
    assert_equal 'allow', JSON.parse(allowed_out)['permission']

    invalid_out, invalid_err, invalid_status = Open3.capture3('ruby', BEFORE_GUARD, stdin_data: '{')
    assert invalid_status.success?, invalid_err
    assert_equal 'deny', JSON.parse(invalid_out)['permission']
  end

  def test_merges_user_codex_and_agent_skill_fallbacks_without_symlinks
    Dir.mktmpdir('cursor-user-skills') do |dir|
      home = File.join(dir, 'home')
      write_skill(File.join(home, '.codex', 'skills'), 'audit', "codex audit\n")
      write_skill(File.join(home, '.agents', 'skills'), 'social', "shared social\n")

      stdout, stderr, status = run_installer(home)
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "codex audit\n", File.read(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md'))
      assert_equal "shared social\n", File.read(File.join(home, '.cursor', 'skills', 'social', 'SKILL.md'))
      refute File.symlink?(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md'))
      refute File.symlink?(File.join(home, '.cursor', 'skills', 'social', 'SKILL.md'))
      assert_includes stdout, 'from 2 source(s) without deletion'
    end
  end

  def test_rejects_cursor_destination_as_an_explicit_skill_source
    Dir.mktmpdir('cursor-recursion') do |dir|
      home = File.join(dir, 'home')
      destination = File.join(home, '.cursor', 'skills')
      write_skill(destination, 'audit', "existing audit\n")

      stdout, stderr, status = run_installer(home, destination)
      refute status.success?, "#{stdout}\n#{stderr}"
      assert_includes stderr, 'refusing destination-as-source skill recursion'
    end
  end

  def test_cursor_init_matches_air_fallback_and_leaves_codex_and_cursor_skills_nonempty
    Dir.mktmpdir('cursor-init-air') do |dir|
      home = File.join(dir, 'home')
      project = File.join(dir, 'project')
      FileUtils.mkdir_p(project)
      write_skill(File.join(home, '.codex', 'skills'), 'audit', "codex audit\n")
      write_skill(File.join(home, '.agents', 'skills'), 'social', "shared social\n")
      refute File.directory?(File.join(ROOT, 'skills')), 'fixture requires the Air shape: no repo skills directory'

      stdout, stderr, status = Open3.capture3(
        { 'HOME' => home },
        'bash', INIT, '--client', 'cursor',
        chdir: project
      )
      assert status.success?, "#{stdout}\n#{stderr}"
      assert File.file?(File.join(home, '.agents', 'skills', 'audit', 'SKILL.md'))
      assert File.file?(File.join(home, '.agents', 'skills', 'social', 'SKILL.md'))
      assert File.file?(File.join(home, '.cursor', 'skills', 'audit', 'SKILL.md'))
      assert File.file?(File.join(home, '.cursor', 'skills', 'social', 'SKILL.md'))
      assert_includes stdout, '~/.agents/skills present and nonempty'
      assert_includes stdout, 'Cursor hook registration and skills present'
    end
  end

  def test_generic_public_install_does_not_require_private_skill_sources
    Dir.mktmpdir('generic-no-skills') do |dir|
      home = File.join(dir, 'home')
      project = File.join(dir, 'project')
      FileUtils.mkdir_p(project)
      stdout, stderr, status = Open3.capture3(
        { 'HOME' => home },
        'bash', INIT, '--client', 'generic',
        chdir: project
      )
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes stdout, 'Installation complete'
      refute File.exist?(File.join(home, '.agents', 'skills'))
    end
  end

  def test_init_exposes_cursor_without_destructive_skill_sync
    source = File.read(File.join(ROOT, 'scripts', 'init.sh'))
    assert_includes source, '--client cursor'
    assert_includes source, 'scripts/hooks/cursor/install.rb'
    refute_includes File.read(INSTALLER), '--delete'
  end
end
