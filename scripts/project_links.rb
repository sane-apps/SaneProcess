# frozen_string_literal: true

require 'pathname'

module SaneProjectLinks
  module_function

  SANEPROCESS_ROOT = File.expand_path('..', __dir__)
  LEFTHOOK_TEMPLATE = File.join(SANEPROCESS_ROOT, 'templates', 'lefthook.yml')

  def lefthook_path(project_dir)
    File.join(File.expand_path(project_dir), 'lefthook.yml')
  end

  def lefthook_issue(project_dir)
    destination = lefthook_path(project_dir)
    metadata = File.lstat(destination)
    return 'lefthook.yml must be a symlink to the shared template' unless metadata.symlink?

    target = File.readlink(destination)
    return 'lefthook.yml target must be relative' if Pathname.new(target).absolute?

    resolved = File.realpath(File.expand_path(target, File.dirname(destination)))
    expected = File.realpath(LEFTHOOK_TEMPLATE)
    return nil if resolved == expected

    'lefthook.yml points somewhere other than the shared template'
  rescue Errno::ENOENT
    File.symlink?(destination) ? 'lefthook.yml symlink is broken' : 'lefthook.yml is missing'
  rescue Errno::EACCES => error
    "lefthook.yml cannot be inspected: #{error.message}"
  end

  def install_lefthook(project_dir, remove_existing: method(:trash_existing_link))
    project_root = File.realpath(project_dir)
    template = File.realpath(LEFTHOOK_TEMPLATE)
    raise 'shared lefthook template is not a regular file' unless File.file?(template) && !File.symlink?(template)

    destination = File.join(project_root, 'lefthook.yml')
    return destination unless lefthook_issue(project_root)

    remove_existing.call(destination) if File.exist?(destination) || File.symlink?(destination)
    relative = Pathname.new(template).relative_path_from(Pathname.new(project_root)).to_s
    File.symlink(relative, destination)
    issue = lefthook_issue(project_root)
    raise issue if issue

    destination
  end

  def trash_existing_link(path)
    ok = system('/usr/bin/trash', path, out: File::NULL, err: File::NULL)
    raise "could not move existing lefthook.yml to Trash: #{path}" unless ok
  end
end
