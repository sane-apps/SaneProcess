#!/usr/bin/env ruby
# frozen_string_literal: true

# Installs the repository-owned Cursor hook adapter and shared SaneProcess skills.
# Existing unrelated hooks/skills are retained; divergent owned files are backed
# up before replacement and no destination-only file is deleted.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require 'securerandom'
require 'time'

module SaneCursorInstall
  HOOK_FILES = %w[
    before_shell_guard.rb
    email_send_guard.rb
    gui_feedback_after_shell.rb
    gui_feedback_stop.rb
  ].freeze
  SUPPORT_FILES = %w[runtime_paths.rb].freeze
  OWNED_HOOK_COMMANDS = HOOK_FILES.map { |name| "./hooks/#{name}" }.freeze

  module_function

  def atomic_write(path, content, mode: 0o600)
    FileUtils.mkdir_p(File.dirname(path))
    temp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temp, path)
    FileUtils.chmod(mode, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp && File.exist?(temp)
  end

  def backup_existing(path, stamp)
    return nil unless File.exist?(path) || File.symlink?(path)

    backup = "#{path}.sane-backup-#{stamp}"
    suffix = 0
    while File.exist?(backup) || File.symlink?(backup)
      suffix += 1
      backup = "#{path}.sane-backup-#{stamp}-#{suffix}"
    end
    FileUtils.mv(path, backup)
    backup
  end

  def install_content(path, content, stamp:, mode: 0o600)
    if File.file?(path) && !File.symlink?(path) && File.binread(path) == content
      FileUtils.chmod(mode, path)
      return :current
    end

    FileUtils.mkdir_p(File.dirname(path))
    temp = File.join(File.dirname(path), ".#{File.basename(path)}.install.#{Process.pid}.#{SecureRandom.hex(6)}")
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
      file.binmode
      file.write(content)
      file.flush
      file.fsync
    end
    backup_existing(path, stamp)
    File.rename(temp, path)
    FileUtils.chmod(mode, path)
    :installed
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp && File.exist?(temp)
  end

  def merge_hooks(existing, canonical)
    merged = existing.is_a?(Hash) ? Marshal.load(Marshal.dump(existing)) : {}
    merged['version'] = canonical.fetch('version', 1)
    merged['hooks'] = {} unless merged['hooks'].is_a?(Hash)

    canonical.fetch('hooks').each do |event, desired_entries|
      current = Array(merged['hooks'][event]).reject do |entry|
        entry.is_a?(Hash) && OWNED_HOOK_COMMANDS.include?(entry['command'])
      end
      merged['hooks'][event] = current + desired_entries
    end
    merged
  end

  def install_hooks(home:, source_dir:, stamp:)
    cursor_dir = File.join(home, '.cursor')
    hooks_dir = File.join(cursor_dir, 'hooks')
    FileUtils.mkdir_p(hooks_dir, mode: 0o700)
    FileUtils.chmod(0o700, hooks_dir)

    (HOOK_FILES + SUPPORT_FILES).each do |name|
      source = File.join(source_dir, name)
      raise "missing Cursor hook source: #{source}" unless File.file?(source)

      install_content(File.join(hooks_dir, name), File.binread(source), stamp: stamp, mode: 0o755)
    end

    manifest_path = File.join(cursor_dir, 'hooks.json')
    template_path = File.join(source_dir, 'hooks.json.example')
    canonical = JSON.parse(File.read(template_path))
    existing = File.file?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}
    content = JSON.pretty_generate(merge_hooks(existing, canonical)) + "\n"
    install_content(manifest_path, content, stamp: stamp, mode: 0o600)
  rescue JSON::ParserError => e
    raise "refusing to replace invalid Cursor hooks JSON: #{e.message}"
  end

  def install_root_pointer(home:, root:, stamp:)
    cursor_dir = File.join(home, '.cursor')
    FileUtils.mkdir_p(cursor_dir)
    install_content(
      File.join(cursor_dir, 'saneprocess_root'),
      "#{File.expand_path(root)}\n",
      stamp: stamp,
      mode: 0o600
    )
  end

  def supported_skill_source?(path)
    return false unless path && File.directory?(path) && !File.symlink?(path)

    Dir.glob(File.join(path, '*', 'SKILL.md')).any? do |skill_file|
      File.file?(skill_file) && !File.symlink?(skill_file) && !File.symlink?(File.dirname(skill_file))
    end
  end

  def discover_skill_sources(home:, root:)
    repo_source = File.join(root, 'skills')
    return [repo_source] if supported_skill_source?(repo_source)

    [File.join(home, '.codex', 'skills'), File.join(home, '.agents', 'skills')]
      .select { |path| supported_skill_source?(path) }
  end

  def paths_overlap?(source, destination)
    source_path = File.realpath(source)
    destination_path = if File.exist?(destination) || File.symlink?(destination)
                         File.realpath(destination)
                       else
                         File.join(File.realpath(File.dirname(destination)), File.basename(destination))
                       end
    source_path == destination_path ||
      source_path.start_with?("#{destination_path}#{File::SEPARATOR}") ||
      destination_path.start_with?("#{source_path}#{File::SEPARATOR}")
  end

  def install_skills(home:, skills_sources:, stamp:)
    destination_root = File.join(home, '.cursor', 'skills')
    raise "Cursor skills destination must not be a symlink: #{destination_root}" if File.symlink?(destination_root)

    sources = skills_sources.select { |path| supported_skill_source?(path) }.uniq
    raise 'no supported skill source found' if sources.empty?

    sources.each do |source|
      if paths_overlap?(source, destination_root)
        raise "refusing destination-as-source skill recursion: #{source}"
      end
    end

    FileUtils.mkdir_p(destination_root, mode: 0o700)
    selected_files = {}
    sources.each do |skills_source|
      Dir.children(skills_source).sort.each do |skill_name|
        skill_root = File.join(skills_source, skill_name)
        skill_entry = File.join(skill_root, 'SKILL.md')
        next unless File.directory?(skill_root) && !File.symlink?(skill_root)
        next unless File.file?(skill_entry) && !File.symlink?(skill_entry)

        Find.find(skill_root) do |source|
          if File.symlink?(source)
            Find.prune if File.directory?(source)
            next
          end
          next unless File.file?(source)

          relative = source.delete_prefix("#{skills_source}/")
          selected_files[relative] = source
        end
      end
    end

    count = 0
    selected_files.sort.each do |relative, source|
      destination = File.join(destination_root, relative)
      mode = File.executable?(source) ? 0o755 : 0o644
      result = install_content(destination, File.binread(source), stamp: stamp, mode: mode)
      count += 1 if result == :installed
    end
    raise 'Cursor skills destination is empty after installation' unless supported_skill_source?(destination_root)

    [count, sources.length]
  end

  def run(argv)
    root = File.expand_path('../../..', __dir__)
    options = {
      home: Dir.home,
      skills_sources: []
    }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: install.rb [--home PATH] [--skills-source PATH]'
      opts.on('--home PATH') { |value| options[:home] = File.expand_path(value) }
      opts.on('--skills-source PATH', 'Skill source (repeatable; defaults to repo, then user Codex/agent skills)') do |value|
        options[:skills_sources] << File.expand_path(value)
      end
    end
    parser.parse!(argv)

    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    skills_sources = options[:skills_sources]
    skills_sources = discover_skill_sources(home: options[:home], root: root) if skills_sources.empty?
    install_root_pointer(home: options[:home], root: root, stamp: stamp)
    install_hooks(home: options[:home], source_dir: __dir__, stamp: stamp)
    changed_skills, source_count = install_skills(
      home: options[:home],
      skills_sources: skills_sources,
      stamp: stamp
    )
    puts "Cursor hooks installed and merged; #{changed_skills} skill file(s) updated from #{source_count} source(s) without deletion."
    0
  rescue OptionParser::ParseError, StandardError => e
    warn "Cursor install failed: #{e.message}"
    1
  end
end

exit SaneCursorInstall.run(ARGV) if $PROGRAM_NAME == __FILE__
