#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'tempfile'
require 'time'

# Produces and revalidates the exact local package proof required by the
# intentionally narrow direct-altool TestFlight lane.
module TestflightArtifactProof
  SCHEMA = 'saneprocess.testflight_artifact_proof.v1'
  SUFFIX = '.testflight-proof.json'
  DEFAULT_MAX_AGE = 36 * 3600
  MAX_RECEIPT_BYTES = 128 * 1024
  MAX_COMMAND_BYTES = 4 * 1024 * 1024
  MAX_ARCHIVE_FILES = 50_000
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024 * 1024
  module_function

  def receipt_path(ipa_path)
    "#{File.expand_path(ipa_path)}#{SUFFIX}"
  end

  def upload_ipa_path(command)
    text = command.to_s
    return nil unless text.match?(/\baltool\b/) && text.match?(/--upload-(?:app|package)\b/)

    tokens = Shellwords.split(text)
    index = tokens.index('-f') || tokens.index('--file')
    value = index ? tokens[index + 1] : nil
    value ||= tokens.find { |token| token.start_with?('--file=') }.to_s.delete_prefix('--file=')
    return nil if value.to_s.empty?

    assignments = {}
    text.scan(/(?:^|[\s;|&])(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=([^\s;|&]+)/) do |key, raw|
      assignments[key] ||= shell_unquote(raw)
    end
    shell_unquote(value).gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
      key = Regexp.last_match(1) || Regexp.last_match(2)
      assignments[key] || Regexp.last_match(0)
    end
  rescue ArgumentError
    nil
  end

  def shell_unquote(value)
    text = value.to_s.strip
    quoted = (text.start_with?('"') && text.end_with?('"')) ||
             (text.start_with?("'") && text.end_with?("'"))
    quoted ? text[1..-2] : text
  end

  def produce!(project_dir:, ipa:, archive:, export_options:, generated_project:, max_age: DEFAULT_MAX_AGE)
    lexical_root = File.expand_path(project_dir)
    root = File.realpath(lexical_root)
    ipa_path = secure_path!(root, canonical_project_path(lexical_root, root, ipa), :file)
    archive_path = secure_path!(root, canonical_project_path(lexical_root, root, archive), :directory)
    export_path = secure_path!(root, canonical_project_path(lexical_root, root, export_options), :file)
    project_path = generated_project_path!(root, canonical_project_path(lexical_root, root, generated_project))
    build, artifact_root = artifact_context!(root, ipa_path)
    unless archive_path.start_with?("#{artifact_root}/") && archive_path.end_with?('.xcarchive')
      raise ArgumentError, 'archive must be the .xcarchive under the same outputs/artifacts/<build> root as the IPA'
    end
    unless export_path.start_with?("#{artifact_root}/")
      raise ArgumentError, 'export options must be under the same outputs/artifacts/<build> root as the IPA'
    end

    source = live_source_identity!(root)
    project_identity = path_identity(root, project_path)
    archive_identity = directory_identity(root, archive_path)
    archive_app = archive_app_identity!(archive_path)
    export_method = export_method!(export_path)
    export_identity = file_identity(root, export_path).merge('method' => export_method)
    ipa_identity = file_identity(root, ipa_path).merge(ipa_app_identity!(ipa_path))
    matching_app_identity!(build, archive_app, ipa_identity)

    now = Time.now.utc
    payload = {
      'schema' => SCHEMA,
      'generated_at' => now.iso8601,
      'expires_at' => (now + Integer(max_age)).iso8601,
      'project_root' => root,
      'source' => source,
      'generated_project' => project_identity,
      'archive' => archive_identity.merge('app' => archive_app),
      'export_options' => export_identity,
      'ipa' => ipa_identity,
      'artifact_build' => build
    }
    write_private_json!(receipt_path(ipa_path), payload)
    payload
  end

  def validate(project_dir:, ipa:, now: Time.now.utc)
    lexical_root = File.expand_path(project_dir)
    root = File.realpath(lexical_root)
    ipa_path = secure_path!(root, canonical_project_path(lexical_root, root, ipa), :file)
    build, artifact_root = artifact_context!(root, ipa_path)
    proof = read_private_json!(receipt_path(ipa_path))
    return [false, 'TestFlight proof schema is invalid'] unless proof['schema'] == SCHEMA
    return [false, 'TestFlight proof project root does not match'] unless proof['project_root'] == root
    return [false, 'TestFlight proof artifact build does not match the IPA path'] unless proof['artifact_build'].to_s == build
    return [false, 'TestFlight proof is stale; regenerate it immediately before upload'] unless fresh?(proof, now)

    expected_source = live_source_identity!(root)
    return [false, 'TestFlight proof source no longer matches live origin'] unless proof['source'] == expected_source

    project_path = identity_path!(root, proof['generated_project'], 'generated project')
    archive_path = identity_path!(root, proof['archive'], 'archive')
    export_path = identity_path!(root, proof['export_options'], 'export options')
    generated_project_path!(root, project_path)
    unless archive_path.start_with?("#{artifact_root}/") && archive_path.end_with?('.xcarchive')
      return [false, 'TestFlight proof archive escaped its artifact build root']
    end

    expected_project = path_identity(root, project_path)
    expected_archive = directory_identity(root, archive_path).merge('app' => archive_app_identity!(archive_path))
    expected_export = file_identity(root, export_path).merge('method' => export_method!(export_path))
    expected_ipa = file_identity(root, ipa_path).merge(ipa_app_identity!(ipa_path))
    matching_app_identity!(build, expected_archive.fetch('app'), expected_ipa)

    comparisons = {
      'generated project' => [proof['generated_project'], expected_project],
      'archive' => [proof['archive'], expected_archive],
      'export options' => [proof['export_options'], expected_export],
      'IPA' => [proof['ipa'], expected_ipa]
    }
    mismatch = comparisons.find { |_label, pair| pair[0] != pair[1] }
    return [false, "TestFlight proof #{mismatch[0]} identity changed"] if mismatch

    [true, 'exact TestFlight artifact proof is current']
  rescue StandardError => e
    [false, e.message]
  end

  def fresh?(proof, now)
    generated = Time.iso8601(proof.fetch('generated_at'))
    expires = Time.iso8601(proof.fetch('expires_at'))
    generated <= now + 60 && expires > now && expires <= generated + DEFAULT_MAX_AGE
  rescue KeyError, ArgumentError
    false
  end

  def live_source_identity!(root)
    branch = git!(root, 'branch', '--show-current').strip
    raise 'TestFlight proof requires a named branch; detached HEAD is not allowed' if branch.empty?

    commit = git!(root, 'rev-parse', 'HEAD').strip
    tree = git!(root, 'rev-parse', 'HEAD^{tree}').strip
    status = git!(root, 'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none')
    raise 'TestFlight proof requires a clean worktree' unless status.empty?

    upstream = git!(root, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}').strip
    expected_upstream = "origin/#{branch}"
    raise "TestFlight proof requires upstream #{expected_upstream}" unless upstream == expected_upstream

    remote_ref = "refs/heads/#{branch}"
    remote_line = git!(root, 'ls-remote', '--exit-code', 'origin', remote_ref).lines.map(&:strip)
      .find { |line| line.split(/\s+/, 2)[1] == remote_ref }
    remote_commit = remote_line.to_s.split(/\s+/, 2).first.to_s
    raise "TestFlight proof could not resolve live origin #{remote_ref}" unless remote_commit.match?(/\A[0-9a-f]{40,64}\z/i)
    raise 'TestFlight proof requires HEAD to equal the live origin branch' unless remote_commit == commit

    {
      'branch' => branch,
      'commit' => commit,
      'tree_sha' => tree,
      'clean' => true,
      'remote' => 'origin',
      'remote_ref' => remote_ref,
      'remote_commit' => remote_commit,
      'upstream' => upstream,
      'pushed' => true
    }
  end

  def git!(root, *args)
    out, err, status = bounded_capture!('git', '-C', root, *args)
    raise "git #{args.first} failed: #{err.strip}" unless status.success?

    out
  end

  def artifact_context!(root, ipa_path)
    relative = relative_path(root, ipa_path)
    match = relative.match(%r{\Aoutputs/artifacts/(\d+)/export/[^/]+\.ipa\z}i)
    raise ArgumentError, 'IPA must be outputs/artifacts/<build>/export/<name>.ipa' unless match

    [match[1], File.join(root, 'outputs', 'artifacts', match[1])]
  end

  def generated_project_path!(root, path)
    project_path = secure_path!(root, path, :directory)
    relative = relative_path(root, project_path)
    unless relative.match?(/\A(?!outputs\/).+\.(?:xcodeproj|xcworkspace)\z/)
      raise ArgumentError, 'generated project must be an .xcodeproj or .xcworkspace outside outputs'
    end

    project_path
  end

  def export_method!(path)
    method = plist_value!(path, 'method')
    unless %w[app-store app-store-connect].include?(method)
      raise ArgumentError, 'export options method must be app-store or app-store-connect'
    end

    method
  end

  def matching_app_identity!(artifact_build, archive_app, ipa)
    fields = %w[bundle_id version build]
    mismatch = fields.find { |field| archive_app[field].to_s != ipa[field].to_s }
    raise "archive and IPA #{mismatch} do not match" if mismatch
    raise 'IPA build does not match outputs/artifacts/<build>' unless ipa['build'].to_s == artifact_build.to_s

    true
  end

  def archive_app_identity!(archive_path)
    info = secure_child!(archive_path, 'Info.plist', :file)
    app = {
      'bundle_id' => plist_value!(info, 'ApplicationProperties.CFBundleIdentifier'),
      'version' => plist_value!(info, 'ApplicationProperties.CFBundleShortVersionString'),
      'build' => plist_value!(info, 'ApplicationProperties.CFBundleVersion')
    }
    raise 'archive application identity is incomplete' if app.values.any?(&:empty?)

    app
  end

  def ipa_app_identity!(ipa_path)
    listing, err, status = bounded_capture!('/usr/bin/unzip', '-Z1', ipa_path)
    raise "could not inspect IPA: #{err.strip}" unless status.success?
    entries = listing.lines.map(&:strip).grep(%r{\APayload/[^/]+\.app/Info\.plist\z})
    raise 'IPA must contain exactly one top-level app Info.plist' unless entries.length == 1

    bytes, extract_err, extract_status = bounded_capture!('/usr/bin/unzip', '-p', ipa_path, entries.first)
    raise "could not read IPA Info.plist: #{extract_err.strip}" unless extract_status.success?
    Tempfile.create(['testflight-info-', '.plist']) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      return {
        'bundle_id' => plist_value!(file.path, 'CFBundleIdentifier'),
        'version' => plist_value!(file.path, 'CFBundleShortVersionString'),
        'build' => plist_value!(file.path, 'CFBundleVersion')
      }
    end
  end

  def plist_value!(path, key)
    out, err, status = bounded_capture!('/usr/bin/plutil', '-extract', key, 'raw', '-o', '-', path)
    raise "plist is missing #{key}: #{err.strip}" unless status.success?

    out.strip
  end

  def path_identity(root, path)
    File.directory?(path) ? directory_identity(root, path) : file_identity(root, path)
  end

  def file_identity(root, path)
    secure_path!(root, path, :file)
    stat = File.lstat(path)
    {
      'path' => relative_path(root, path),
      'sha256' => opened_file_sha256!(path, stat),
      'bytes' => stat.size,
      'inode' => stat.ino,
      'device' => stat.dev
    }
  end

  def directory_identity(root, path)
    secure_path!(root, path, :directory)
    stat = File.lstat(path)
    rows = []
    file_count = 0
    total_bytes = 0
    Find.find(path) do |entry|
      metadata = File.lstat(entry)
      raise "artifact tree contains symlink: #{entry}" if metadata.symlink?
      relative = entry.delete_prefix("#{path}/")
      next if entry == path
      if metadata.directory?
        rows << "D\0#{relative}\0#{metadata.mode & 0o7777}"
      elsif metadata.file?
        file_count += 1
        total_bytes += metadata.size
        raise 'artifact tree exceeds safe file limit' if file_count > MAX_ARCHIVE_FILES
        raise 'artifact tree exceeds safe byte limit' if total_bytes > MAX_ARCHIVE_BYTES
        rows << "F\0#{relative}\0#{metadata.mode & 0o7777}\0#{metadata.size}\0#{opened_file_sha256!(entry, metadata)}"
      else
        raise "artifact tree contains unsupported entry: #{entry}"
      end
    end
    {
      'path' => relative_path(root, path),
      'manifest_sha256' => Digest::SHA256.hexdigest(rows.sort.join("\n")),
      'files' => file_count,
      'bytes' => total_bytes,
      'inode' => stat.ino,
      'device' => stat.dev
    }
  end

  def identity_path!(root, identity, label)
    raise "TestFlight proof is missing #{label} identity" unless identity.is_a?(Hash)
    relative = identity['path'].to_s
    raise "TestFlight proof is missing #{label} path" if relative.empty?

    File.expand_path(relative, root)
  end

  def secure_path!(root, path, kind)
    absolute = File.expand_path(path, root)
    raise ArgumentError, 'artifact path escapes project root' unless absolute.start_with?("#{root}/")
    cursor = root
    absolute.delete_prefix("#{root}/").split('/').each do |part|
      cursor = File.join(cursor, part)
      metadata = File.lstat(cursor)
      raise "artifact path contains symlink: #{cursor}" if metadata.symlink?
    end
    metadata = File.lstat(absolute)
    valid = kind == :file ? metadata.file? : metadata.directory?
    raise "artifact path is not a regular #{kind}: #{absolute}" unless valid

    absolute
  rescue Errno::ENOENT
    raise "artifact path does not exist: #{absolute}"
  end

  def canonical_project_path(lexical_root, real_root, path)
    absolute = File.expand_path(path, lexical_root)
    return real_root if absolute == lexical_root
    return absolute unless absolute.start_with?("#{lexical_root}/")

    File.join(real_root, absolute.delete_prefix("#{lexical_root}/"))
  end

  def secure_child!(parent, relative, kind)
    root = File.realpath(parent)
    secure_path!(root, File.join(root, relative), kind)
  end

  def relative_path(root, path)
    File.expand_path(path).delete_prefix("#{root}/")
  end

  def read_private_json!(path)
    metadata = File.lstat(path)
    raise 'TestFlight proof must be a regular nofollow file' unless metadata.file? && !metadata.symlink?
    raise 'TestFlight proof must be private mode 0600' unless (metadata.mode & 0o077).zero?
    raise 'TestFlight proof is too large' if metadata.size > MAX_RECEIPT_BYTES

    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags) do |file|
      opened = file.stat
      raise 'TestFlight proof changed while opening' unless opened.dev == metadata.dev && opened.ino == metadata.ino
      JSON.parse(file.read(MAX_RECEIPT_BYTES + 1))
    end
  rescue Errno::ENOENT, JSON::ParserError
    raise 'exact adjacent TestFlight proof is missing or invalid'
  end

  def opened_file_sha256!(path, expected)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags) do |file|
      opened = file.stat
      unless opened.file? && opened.dev == expected.dev && opened.ino == expected.ino && opened.size == expected.size
        raise "artifact file changed while opening: #{path}"
      end
      digest = Digest::SHA256.new
      loop do
        chunk = file.read(64 * 1024)
        break unless chunk

        digest << chunk
      end
      final = file.stat
      unless final.dev == opened.dev && final.ino == opened.ino && final.size == opened.size &&
             final.mtime == opened.mtime && final.ctime == opened.ctime
        raise "artifact file changed while hashing: #{path}"
      end
      digest.hexdigest
    end
  rescue Errno::ELOOP
    raise "artifact file became a symlink: #{path}"
  end

  def write_private_json!(path, payload)
    dir = File.dirname(path)
    if File.exist?(path) || File.symlink?(path)
      metadata = File.lstat(path)
      raise 'refusing to replace a symlinked TestFlight proof' if metadata.symlink?
      raise 'refusing to replace a non-file TestFlight proof' unless metadata.file?
    end
    Tempfile.create(['.testflight-proof-', '.tmp'], dir, mode: 0o600) do |file|
      file.write(JSON.pretty_generate(payload))
      file.write("\n")
      file.flush
      file.fsync
      File.chmod(0o600, file.path)
      File.rename(file.path, path)
    end
    File.chmod(0o600, path)
    path
  end

  def bounded_capture!(*command, timeout_seconds: 30)
    stdout_data = +''
    stderr_data = +''
    status = nil
    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      readers = [[stdout, stdout_data], [stderr, stderr_data]].map do |io, target|
        Thread.new do
          loop do
            chunk = io.readpartial(16 * 1024)
            target << chunk
            if target.bytesize > MAX_COMMAND_BYTES
              Process.kill('KILL', wait_thr.pid) rescue nil
              raise 'command output exceeded safe limit'
            end
          rescue EOFError
            break
          end
        end.tap { |thread| thread.report_on_exception = false }
      end
      unless wait_thr.join(timeout_seconds)
        Process.kill('TERM', wait_thr.pid) rescue nil
        wait_thr.join(2) || (Process.kill('KILL', wait_thr.pid) rescue nil)
        raise "command timed out: #{command.first}"
      end
      readers.each(&:value)
      status = wait_thr.value
    end
    [stdout_data, stderr_data, status]
  end

  def cli!(argv)
    options = { project_dir: Dir.pwd, max_age: DEFAULT_MAX_AGE }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: testflight_artifact_proof.rb --ipa PATH --archive PATH --export-options PATH --generated-project PATH'
      opts.on('--project PATH') { |value| options[:project_dir] = value }
      opts.on('--ipa PATH') { |value| options[:ipa] = value }
      opts.on('--archive PATH') { |value| options[:archive] = value }
      opts.on('--export-options PATH') { |value| options[:export_options] = value }
      opts.on('--generated-project PATH') { |value| options[:generated_project] = value }
      opts.on('--max-age-hours HOURS', Float) { |value| options[:max_age] = Integer(value * 3600) }
    end
    parser.parse!(argv)
    missing = %i[ipa archive export_options generated_project].reject { |key| options[key] }
    raise OptionParser::MissingArgument, missing.join(', ') unless missing.empty?
    raise OptionParser::InvalidArgument, 'max age must be within 36 hours' unless options[:max_age].positive? && options[:max_age] <= DEFAULT_MAX_AGE

    payload = produce!(**options)
    puts JSON.generate('status' => 'passed', 'receipt' => receipt_path(File.expand_path(options[:ipa], options[:project_dir])), 'proof' => payload)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    TestflightArtifactProof.cli!(ARGV)
  rescue StandardError => e
    warn "TestFlight artifact proof failed: #{e.message}"
    exit 2
  end
end
