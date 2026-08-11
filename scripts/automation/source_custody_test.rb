#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'pathname'
require 'rubygems/package'
require 'tmpdir'
require 'zlib'

ROOT = File.expand_path('..', __dir__)
WRAPPER = File.join(ROOT, 'automation', 'git-sync-safe.sh')

def assert(condition, message)
  raise message unless condition
end

def run(env, *command)
  Open3.capture3(env, *command)
end

def run!(env, *command)
  stdout, stderr, status = run(env, *command)
  raise "command failed: #{command.join(' ')}\n#{stdout}\n#{stderr}" unless status.success?

  stdout
end

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

def receipt_for(home, relative)
  label = relative.gsub(%r{[^A-Za-z0-9._-]+}, '__')
  latest = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'source-custody', label, 'latest.txt')
  File.read(latest).strip
end

def archive_listing(path)
  run!({}, '/usr/bin/tar', '-tzf', path).lines.map(&:chomp)
end

def archived_file_bytes(path)
  bytes = +''
  Zlib::GzipReader.open(path) do |gzip|
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each { |entry| bytes << entry.read if entry.file? }
    end
  end
  bytes
end

def custody_command(relative, *manifest_symlinks)
  command = ['/bin/bash', WRAPPER, '--custody-path', relative]
  manifest_symlinks.each do |path|
    command << '--custody-manifest-symlink' << path
  end
  command
end

tests = []

tests << lambda do
  Dir.mktmpdir('source-custody-git-test') do |tmp|
    home = File.join(tmp, 'home')
    relative = 'clients/fixture/extension'
    repo = File.join(home, 'SaneApps', relative)
    FileUtils.mkdir_p(repo)
    run!({}, 'git', '-C', repo, 'init', '-b', 'main')
    run!({}, 'git', '-C', repo, 'config', 'user.email', 'fixture@example.com')
    run!({}, 'git', '-C', repo, 'config', 'user.name', 'Fixture')
    write(File.join(repo, 'src', 'main.js'), "export const value = 1;\n")
    write(File.join(repo, 'README.md'), "fixture\n")
    run!({}, 'git', '-C', repo, 'add', '.')
    run!({}, 'git', '-C', repo, 'commit', '-m', 'fixture')
    write(File.join(repo, 'src', 'main.js'), "export const value = 2;\n")
    write(File.join(repo, 'untracked.js'), "export const dirty = true;\n")
    write(File.join(repo, '.env'), "DO_NOT_CAPTURE=fixture\n")
    write(File.join(repo, '.ENV'), "DO_NOT_CAPTURE_UPPER_ENV\n")
    write(File.join(repo, 'Credentials.JSON'), "DO_NOT_CAPTURE_UPPER_CREDENTIALS\n")
    write(File.join(repo, 'debug.log'), "DO_NOT_CAPTURE_LOG\n")
    write(File.join(repo, 'node_modules', 'module.js'), "DO_NOT_CAPTURE_CACHE\n")
    write(File.join(repo, 'NODE_MODULES', 'upper-module.js'), "DO_NOT_CAPTURE_UPPER_CACHE\n")
    write(File.join(repo, 'safe-target.txt'), "safe link target\n")
    File.symlink('safe-target.txt', File.join(repo, 'safe-link.txt'))
    File.symlink('../../../outside.txt', File.join(repo, 'escape-link.txt'))
    File.symlink('../../../outside-two.txt', File.join(repo, 'escape-link-two.txt'))
    external_target = File.join(home, 'SaneApps', 'outside.txt')
    external_target_two = File.join(home, 'SaneApps', 'outside-two.txt')
    write(external_target, "EXTERNAL_TARGET_MUST_NOT_BE_ARCHIVED\n")
    write(external_target_two, "SECOND_EXTERNAL_TARGET_MUST_NOT_BE_ARCHIVED\n")

    before_head = run!({}, 'git', '-C', repo, 'rev-parse', 'HEAD')
    before_status = run!({}, 'git', '-C', repo, 'status', '--porcelain=v1', '-z')
    stdout, stderr, status = run({ 'HOME' => home }, *custody_command(relative))
    assert(!status.success?, 'an escaping symlink must fail custody capture')
    assert("#{stdout}\n#{stderr}".include?('escaping symlink rejected'), 'symlink failure must name the safety gate')

    declared_links = %w[escape-link.txt escape-link-two.txt]
    stdout, stderr, status = run({ 'HOME' => home }, *custody_command(relative, *declared_links))
    assert(status.success?, "Git custody failed\n#{stdout}\n#{stderr}")
    receipt = receipt_for(home, relative)
    manifest_path = File.join(receipt, 'manifest.json')
    manifest = JSON.parse(File.read(manifest_path))
    listing = archive_listing(File.join(receipt, 'source.tar.gz'))
    archived_bytes = archived_file_bytes(File.join(receipt, 'source.tar.gz'))
    external = manifest.fetch('externalSymlinks')

    assert((File.stat(manifest_path).mode & 0o777) == 0o600, 'manifest must be mode 0600')
    assert((File.stat(File.join(receipt, 'source.tar.gz')).mode & 0o777) == 0o600, 'archive must be mode 0600')
    assert((File.stat(File.join(receipt, 'history.bundle')).mode & 0o777) == 0o600, 'bundle must be mode 0600')
    assert(manifest.dig('archive', 'verified') == true, 'archive hash verification missing')
    assert(manifest.dig('git', 'bundle', 'verified') == true, 'Git bundle verification missing')
    assert(manifest.dig('verification', 'restoredInventoryMatches') == true, 'restore verification missing')
    assert(manifest.dig('verification', 'gitBundleRestores') == true, 'Git bundle restore verification missing')
    assert(manifest.dig('verification', 'externalSymlinksRevalidated') == true, 'external symlink revalidation missing')
    assert(manifest.dig('verification', 'externalSymlinksArchived') == false, 'external symlinks must not be archived')
    assert(listing.include?('src/main.js') && listing.include?('untracked.js'), 'dirty and untracked source missing')
    assert(listing.include?('safe-link.txt'), 'safe internal symlink missing')
    assert((listing & declared_links).empty?, 'manifest-only symlinks must not enter the source archive')
    assert(!archived_bytes.include?('EXTERNAL_TARGET_MUST_NOT_BE_ARCHIVED'), 'external target bytes entered archive')
    assert(!archived_bytes.include?('DO_NOT_CAPTURE_UPPER_ENV'), 'case-variant env file entered archive')
    assert(!archived_bytes.include?('DO_NOT_CAPTURE_UPPER_CREDENTIALS'),
           'case-variant credential file entered archive')
    assert(!archived_bytes.include?('DO_NOT_CAPTURE_UPPER_CACHE'),
           'case-variant dependency cache entered archive')
    assert(external.map { |entry| entry.fetch('path') } == declared_links.sort, 'repeated external declarations missing')
    first_external = external.find { |entry| entry.fetch('path') == 'escape-link.txt' }
    assert(first_external.fetch('rawTarget') == '../../../outside.txt', 'raw external target missing')
    assert(first_external.fetch('resolvedTargetRelativeToRoot') == 'outside.txt', 'root-relative target missing')
    assert(first_external.fetch('targetType') == 'file', 'external target type missing')
    assert(first_external.fetch('targetSize') == File.size(external_target), 'external target size mismatch')
    assert(first_external.fetch('targetSha256') == Digest::SHA256.file(external_target).hexdigest,
           'external target hash mismatch')
    assert(first_external.fetch('archiveDisposition') == 'manifest-only-not-archived', 'archive disposition missing')
    assert(!first_external.fetch('restoreRequirement').empty?, 'restore requirement missing')
    assert(listing.none? { |path| path.include?('.env') || path.include?('node_modules') || path.end_with?('.log') },
           "secret/cache/log exclusion failed: #{listing}")
    assert(run!({}, 'git', '-C', repo, 'rev-parse', 'HEAD') == before_head, 'custody changed Git HEAD')
    after_status = run!({}, 'git', '-C', repo, 'status', '--porcelain=v1', '-z')
    assert(after_status == before_status, 'custody changed the Git worktree')

    outside_root = File.join(tmp, 'outside-root.txt')
    write(outside_root, "outside root\n")
    outside_link = File.join(repo, 'outside-root-link.txt')
    File.symlink(Pathname.new(outside_root).relative_path_from(Pathname.new(repo)).to_s, outside_link)
    out, err, failed = run({ 'HOME' => home }, *custody_command(relative, *declared_links, 'outside-root-link.txt'))
    assert(!failed.success? && "#{out}\n#{err}".include?('leaves SaneApps root'),
           'outside-root manifest symlink must fail')
    FileUtils.rm(outside_link)

    absolute_link = File.join(repo, 'absolute-link.txt')
    File.symlink(external_target, absolute_link)
    out, err, failed = run({ 'HOME' => home }, *custody_command(relative, *declared_links, 'absolute-link.txt'))
    assert(!failed.success? && "#{out}\n#{err}".include?('absolute symlink rejected'), 'absolute link must fail')
    FileUtils.rm(absolute_link)

    secret_target = File.join(home, 'SaneApps', '.env')
    write(secret_target, "DO_NOT_CAPTURE_SECRET_TARGET\n")
    secret_link = File.join(repo, 'secret-link.txt')
    File.symlink('../../../.env', secret_link)
    out, err, failed = run({ 'HOME' => home }, *custody_command(relative, *declared_links, 'secret-link.txt'))
    assert(!failed.success? && "#{out}\n#{err}".include?('targets an excluded path'), 'secret target must fail')
    FileUtils.rm(secret_link)

    out, err, failed = run({ 'HOME' => home }, *custody_command(relative, *declared_links, 'missing-link.txt'))
    assert(!failed.success? && "#{out}\n#{err}".include?('not an external link'), 'missing declaration must fail')

    fake_bin = File.join(tmp, 'fake-bin')
    fake_git = File.join(fake_bin, 'git')
    write(fake_git, <<~'BASH')
      #!/bin/bash
      if [[ "$*" == *"bundle verify"* ]]; then
        /usr/bin/git "$@" || exit $?
        printf 'mutated during capture\n' > "$MUTATE_TARGET"
        exit 0
      fi
      exec /usr/bin/git "$@"
    BASH
    FileUtils.chmod(0o755, fake_git)
    write(external_target, "race baseline\n")
    env = { 'HOME' => home, 'PATH' => "#{fake_bin}:/usr/bin:/bin", 'MUTATE_TARGET' => external_target }
    out, err, failed = run(env, *custody_command(relative, *declared_links))
    assert(!failed.success? && "#{out}\n#{err}".include?('changed before finalization'),
           'external target mutation must fail finalization')
  end
end

tests << lambda do
  Dir.mktmpdir('source-custody-directory-test') do |tmp|
    home = File.join(tmp, 'home')
    relative = 'clients/fixture/valuation-api'
    source = File.join(home, 'SaneApps', relative)
    write(File.join(source, 'src', 'server.py'), "print('safe')\n")
    write(File.join(source, 'tests', 'test_server.py'), "assert True\n")
    write(File.join(source, '.venv', 'bin', 'python'), "DO_NOT_CAPTURE_VENV\n")
    write(File.join(source, 'outputs', 'receipt.json'), "DO_NOT_CAPTURE_OUTPUT\n")
    write(File.join(source, '.dev.vars'), "DO_NOT_CAPTURE_SECRET\n")

    stdout, stderr, status = run({ 'HOME' => home }, '/bin/bash', WRAPPER, '--custody-path', relative)
    assert(status.success?, "directory custody failed\n#{stdout}\n#{stderr}")
    receipt = receipt_for(home, relative)
    manifest = JSON.parse(File.read(File.join(receipt, 'manifest.json')))
    listing = archive_listing(File.join(receipt, 'source.tar.gz'))

    assert(manifest.fetch('sourceKind') == 'directory', 'non-Git source must be identified as a directory')
    assert(manifest['git'].nil?, 'non-Git source must not claim Git history')
    assert(!File.exist?(File.join(receipt, 'history.bundle')), 'non-Git source must not emit a fake bundle')
    assert(manifest.dig('verification', 'restoredInventoryMatches') == true, 'directory restore verification missing')
    assert(listing.include?('src/server.py') && listing.include?('tests/test_server.py'), 'source/test files missing')
    assert(listing.none? { |path| path.include?('.venv') || path.include?('outputs') || path.include?('.dev.vars') },
           "non-Git exclusions failed: #{listing}")
  end
end

tests.each(&:call)
puts "PASS #{tests.length}/#{tests.length}"
