#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'rubygems/package'
require 'set'
require 'tmpdir'
require 'time'
require 'zlib'

File.umask(0o077)

EXCLUDED_DIRECTORIES = %w[
  .build .cache .git .hg .mypy_cache .nyc_output .pytest_cache .ruff_cache
  .svn .swiftpm .venv .wrangler DerivedData __pycache__ build coverage dist
  logs node_modules outputs secrets tmp venv xcuserdata
].freeze

EXCLUDED_EXACT_FILES = %w[
  .DS_Store .dev.vars .env .netrc .npmrc .pypirc credentials credentials.json
  cookies.json service-account.json secrets.json tokens.json
].freeze

EXCLUDED_SUFFIXES = %w[
  .bak .jks .key .keystore .log .mobileprovision .orig .p8 .pem .pid .rej .swp
].freeze

class CustodyError < StandardError; end

def run!(*command, chdir: nil)
  stdout, stderr, status = if chdir
                             Open3.capture3(*command, chdir: chdir)
                           else
                             Open3.capture3(*command)
                           end
  return stdout if status.success?

  detail = stderr.lines.first.to_s.strip
  raise CustodyError, "command failed: #{command.first}#{detail.empty? ? '' : ": #{detail}"}"
end

def inside?(path, root)
  path == root || path.start_with?("#{root}#{File::SEPARATOR}")
end

def excluded_file?(basename)
  lower = basename.downcase
  return true if EXCLUDED_EXACT_FILES.any? { |excluded| lower == excluded.downcase }
  return true if lower.start_with?('.env.', '.dev.vars.')

  EXCLUDED_SUFFIXES.any? { |suffix| lower.end_with?(suffix) }
end

def validate_relative_path!(path)
  raise CustodyError, "unsafe archive path: #{path}" if path.empty? || Pathname.new(path).absolute?

  parts = Pathname.new(path).each_filename.to_a
  raise CustodyError, "unsafe archive path: #{path}" if parts.include?('..') || parts.include?('.')
end

def excluded_relative_path?(relative)
  parts = Pathname.new(relative).each_filename.to_a
  parts[0...-1].any? do |part|
    EXCLUDED_DIRECTORIES.any? { |excluded| part.casecmp?(excluded) }
  end || excluded_file?(parts.last.to_s)
end

def external_symlink_record(source, root, relative)
  validate_relative_path!(relative)
  absolute = File.join(source, relative)
  raise CustodyError, "declared manifest symlink is not a symlink: #{relative}" unless File.symlink?(absolute)

  raw_target = File.readlink(absolute)
  raise CustodyError, "absolute symlink rejected: #{relative}" if Pathname.new(raw_target).absolute?

  resolved = File.realpath(absolute)
  raise CustodyError, "declared manifest symlink must resolve outside source: #{relative}" if inside?(resolved, source)
  raise CustodyError, "escaping symlink leaves SaneApps root: #{relative}" unless inside?(resolved, root)

  resolved_relative = resolved.delete_prefix("#{root}/")
  if excluded_relative_path?(resolved_relative)
    raise CustodyError, "declared manifest symlink targets an excluded path: #{relative}"
  end

  target_stat = File.lstat(resolved)
  raise CustodyError, "declared manifest symlink target must be a regular file: #{relative}" unless target_stat.file?

  {
    'path' => relative,
    'rawTarget' => raw_target,
    'resolvedTargetRelativeToRoot' => resolved_relative,
    'targetType' => 'file',
    'targetSize' => target_stat.size,
    'targetSha256' => Digest::SHA256.file(resolved).hexdigest,
    'archiveDisposition' => 'manifest-only-not-archived',
    'restoreRequirement' => 'Restore and verify this declared SaneApps dependency before using the symlink.'
  }
rescue Errno::ENOENT, Errno::EACCES => e
  raise CustodyError, "unreadable or dangling declared manifest symlink rejected: #{relative} (#{e.class})"
end

def source_entries(source, root: source, manifest_symlinks: [])
  source = File.realpath(source)
  root = File.realpath(root)
  declared = Set.new
  manifest_symlinks.each do |relative|
    validate_relative_path!(relative)
    clean = Pathname.new(relative).cleanpath.to_s
    raise CustodyError, "manifest symlink path must be normalized: #{relative}" unless clean == relative
    raise CustodyError, "duplicate manifest symlink declaration: #{relative}" unless declared.add?(relative)
  end
  entries = []
  external_symlinks = []
  observed_external = Set.new
  excluded = Hash.new(0)

  Find.find(source) do |absolute|
    next if absolute == source

    relative = absolute.delete_prefix("#{source}/")
    validate_relative_path!(relative)
    stat = File.lstat(absolute)
    basename = File.basename(absolute)

    if stat.directory? && EXCLUDED_DIRECTORIES.any? { |excluded_name| basename.casecmp?(excluded_name) }
      excluded['directory'] += 1
      Find.prune
    end

    if !stat.directory? && excluded_file?(basename)
      excluded['file'] += 1
      next
    end

    mode = format('%04o', stat.mode & 0o7777)
    case stat.ftype
    when 'directory'
      entries << { 'path' => relative, 'type' => 'directory', 'mode' => mode }
    when 'file'
      entries << {
        'path' => relative,
        'type' => 'file',
        'mode' => mode,
        'size' => stat.size,
        'sha256' => Digest::SHA256.file(absolute).hexdigest
      }
    when 'link'
      target = File.readlink(absolute)
      raise CustodyError, "absolute symlink rejected: #{relative}" if Pathname.new(target).absolute?

      resolved = File.realpath(absolute)
      unless inside?(resolved, source)
        raise CustodyError, "escaping symlink rejected: #{relative}" unless declared.include?(relative)

        external_symlinks << external_symlink_record(source, root, relative)
        observed_external << relative
        next
      end

      # Symlink permission bits are not portable and macOS does not provide a
      # safe way to restore them independently of the target. Preserve and
      # verify the link path and relative target instead.
      entries << { 'path' => relative, 'type' => 'symlink', 'target' => target }
    else
      raise CustodyError, "unsupported source entry rejected: #{relative} (#{stat.ftype})"
    end
  rescue Errno::ENOENT, Errno::EACCES => e
    raise CustodyError, "unreadable or dangling source entry rejected: #{relative} (#{e.class})"
  end

  missing = declared - observed_external
  unless missing.empty?
    raise CustodyError, "declared manifest symlink was not an external link: #{missing.to_a.sort.first}"
  end

  [entries.sort_by { |entry| entry['path'] }, excluded, external_symlinks.sort_by { |entry| entry['path'] }]
end

def inventory_difference(expected, actual)
  expected_by_path = expected.to_h { |entry| [entry.fetch('path'), entry] }
  actual_by_path = actual.to_h { |entry| [entry.fetch('path'), entry] }
  path = (expected_by_path.keys | actual_by_path.keys).sort.find do |candidate|
    expected_by_path[candidate] != actual_by_path[candidate]
  end
  return 'unknown entry' unless path

  expected_entry = expected_by_path[path]
  actual_entry = actual_by_path[path]
  fields = ((expected_entry || {}).keys | (actual_entry || {}).keys) - %w[path sha256]
  changed = fields.select { |field| expected_entry&.[](field) != actual_entry&.[](field) }
  "#{path} fields=#{changed.join(',')}"
end

def write_archive(source, entries, destination)
  Zlib::GzipWriter.open(destination) do |gzip|
    Gem::Package::TarWriter.new(gzip) do |tar|
      entries.each do |entry|
        absolute = File.join(source, entry.fetch('path'))
        case entry.fetch('type')
        when 'directory'
          tar.mkdir(entry.fetch('path'), entry.fetch('mode').to_i(8))
        when 'file'
          tar.add_file_simple(entry.fetch('path'), entry.fetch('mode').to_i(8), entry.fetch('size')) do |io|
            File.open(absolute, 'rb') { |file| IO.copy_stream(file, io) }
          end
        when 'symlink'
          tar.add_symlink(entry.fetch('path'), entry.fetch('target'), 0o777)
        end
      end
    end
  end
  File.chmod(0o600, destination)
end

def restore_archive(archive, destination)
  directory_modes = []
  FileUtils.mkdir_p(destination, mode: 0o700)

  Zlib::GzipReader.open(archive) do |gzip|
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        relative = entry.full_name
        validate_relative_path!(relative)
        target = File.expand_path(relative, destination)
        raise CustodyError, "archive entry escapes restore root: #{relative}" unless inside?(target, destination)

        if entry.directory?
          FileUtils.mkdir_p(target)
          directory_modes << [target, entry.header.mode]
        elsif entry.file?
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, 'wb', entry.header.mode) { |file| IO.copy_stream(entry, file) }
          File.chmod(entry.header.mode, target)
        elsif entry.symlink?
          link_target = entry.header.linkname
          raise CustodyError, "absolute restored symlink rejected: #{relative}" if Pathname.new(link_target).absolute?

          resolved = File.expand_path(link_target, File.dirname(target))
          raise CustodyError, "restored symlink escapes restore root: #{relative}" unless inside?(resolved, destination)

          FileUtils.mkdir_p(File.dirname(target))
          File.symlink(link_target, target)
        else
          raise CustodyError, "unsupported archive entry rejected: #{relative}"
        end
      end
    end
  end
  directory_modes.reverse_each { |path, mode| File.chmod(mode, path) }
end

def git_repo?(source)
  _out, _err, status = Open3.capture3('git', '-C', source, 'rev-parse', '--is-inside-work-tree')
  status.success?
end

options = { manifest_symlinks: [] }
OptionParser.new do |parser|
  parser.on('--root PATH') { |value| options[:root] = value }
  parser.on('--source PATH') { |value| options[:source] = value }
  parser.on('--output-root PATH') { |value| options[:output_root] = value }
  parser.on('--run-tag TAG') { |value| options[:run_tag] = value }
  parser.on('--host TAG') { |value| options[:host] = value }
  parser.on('--custody-manifest-symlink PATH') { |value| options[:manifest_symlinks] << value }
end.parse!

begin
  %i[root source output_root run_tag host].each do |key|
    raise CustodyError, "missing --#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
  end

  root = File.realpath(options.fetch(:root))
  source_input = options.fetch(:source)
  source_candidate = Pathname.new(source_input).absolute? ? source_input : File.join(root, source_input)
  raise CustodyError, "source must be a directory: #{source_input}" unless File.directory?(source_candidate)
  raise CustodyError, "source root cannot be a symlink: #{source_input}" if File.symlink?(source_candidate)

  source = File.realpath(source_candidate)
  raise CustodyError, "source escapes SaneApps root: #{source_input}" unless inside?(source, root)

  relative_source = source.delete_prefix("#{root}/")
  label = relative_source.gsub(%r{[^A-Za-z0-9._-]+}, '__')
  entries, excluded_counts, external_symlinks = source_entries(
    source,
    root: root,
    manifest_symlinks: options.fetch(:manifest_symlinks)
  )
  raise CustodyError, "no source files remained after exclusions: #{relative_source}" if entries.none? { |entry| entry['type'] == 'file' }

  repo = git_repo?(source)
  git_data = nil
  status_sha = nil
  if repo
    head = run!('git', '-C', source, 'rev-parse', 'HEAD').strip
    branch = run!('git', '-C', source, 'branch', '--show-current').strip
    status = run!('git', '-C', source, 'status', '--porcelain=v1', '-z')
    status_sha = Digest::SHA256.hexdigest(status)
    git_data = { 'head' => head, 'branch' => branch, 'dirty' => !status.empty?, 'statusSha256' => status_sha }
  end

  fingerprint_input = JSON.generate('source' => relative_source, 'entries' => entries,
                                    'externalSymlinks' => external_symlinks,
                                    'gitHead' => git_data&.fetch('head', nil), 'gitStatusSha256' => status_sha)
  fingerprint = Digest::SHA256.hexdigest(fingerprint_input)
  receipt_name = "#{options.fetch(:run_tag)}-#{options.fetch(:host)}-#{fingerprint[0, 16]}"
  label_root = File.join(options.fetch(:output_root), label)
  final_dir = File.join(label_root, receipt_name)
  FileUtils.mkdir_p(label_root, mode: 0o700)
  raise CustodyError, "custody receipt already exists: #{final_dir}" if File.exist?(final_dir)

  working_dir = Dir.mktmpdir('.source-custody-', label_root)
  begin
    File.chmod(0o700, working_dir)
    archive = File.join(working_dir, 'source.tar.gz')
    write_archive(source, entries, archive)
    archive_sha = Digest::SHA256.file(archive).hexdigest

    bundle_data = nil
    if repo
      bundle = File.join(working_dir, 'history.bundle')
      run!('git', '-C', source, 'bundle', 'create', bundle, '--all')
      File.chmod(0o600, bundle)
      run!('git', '-C', source, 'bundle', 'verify', bundle)
      bundle_data = { 'sha256' => Digest::SHA256.file(bundle).hexdigest, 'verified' => true }
    end

    Dir.mktmpdir('source-custody-restore-') do |restore_root|
      raise CustodyError, 'source archive hash changed before restore' unless Digest::SHA256.file(archive).hexdigest == archive_sha

      restored_source = File.join(restore_root, 'source')
      restore_archive(archive, restored_source)
      restored_entries, = source_entries(restored_source)
      unless restored_entries == entries
        raise CustodyError, "restored source inventory mismatch: #{inventory_difference(entries, restored_entries)}"
      end

      if repo
        bundle = File.join(working_dir, 'history.bundle')
        raise CustodyError, 'Git bundle hash changed before restore' unless Digest::SHA256.file(bundle).hexdigest == bundle_data.fetch('sha256')

        clone = File.join(restore_root, 'history')
        run!('git', 'clone', '--quiet', '--no-checkout', bundle, clone)
        run!('git', '-C', clone, 'cat-file', '-e', "#{git_data.fetch('head')}^{commit}")
        run!('git', '-C', clone, 'fsck', '--full', '--no-dangling')
      end
    end

    revalidated_external_symlinks = options.fetch(:manifest_symlinks).map do |relative|
      external_symlink_record(source, root, relative)
    end.sort_by { |entry| entry['path'] }
    unless revalidated_external_symlinks == external_symlinks
      raise CustodyError, 'declared external symlink metadata changed before finalization'
    end

    manifest = {
      'schemaVersion' => 1,
      'createdAt' => Time.now.utc.iso8601,
      'host' => options.fetch(:host),
      'sourceRelativePath' => relative_source,
      'sourceKind' => repo ? 'git' : 'directory',
      'fingerprint' => fingerprint,
      'exclusionPolicy' => {
        'directories' => EXCLUDED_DIRECTORIES.sort,
        'exactFiles' => EXCLUDED_EXACT_FILES.sort,
        'suffixes' => EXCLUDED_SUFFIXES.sort,
        'excludedCounts' => excluded_counts.sort.to_h
      },
      'entries' => entries,
      'externalSymlinks' => external_symlinks,
      'archive' => { 'file' => 'source.tar.gz', 'sha256' => archive_sha, 'verified' => true },
      'git' => git_data&.merge('bundle' => bundle_data),
      'verification' => {
        'restoredInventoryMatches' => true,
        'gitBundleRestores' => repo,
        'externalSymlinksRevalidated' => true,
        'externalSymlinksArchived' => false
      }
    }
    manifest_path = File.join(working_dir, 'manifest.json')
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
    File.chmod(0o600, manifest_path)

    File.rename(working_dir, final_dir)
  ensure
    FileUtils.remove_entry(working_dir) if File.exist?(working_dir)
  end

  latest = File.join(label_root, 'latest.txt')
  File.write(latest, "#{final_dir}\n")
  File.chmod(0o600, latest)
  puts "CUSTODY_RECEIPT=#{final_dir}"
rescue CustodyError, SystemCallError, Gem::Package::TarInvalidError => e
  warn "ERROR: #{e.message}"
  exit 1
end
