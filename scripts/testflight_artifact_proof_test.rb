#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'testflight_artifact_proof'

class TestflightArtifactFixture
  attr_reader :root, :ipa, :archive, :export_options, :generated_project, :remote

  def initialize
    @root = Dir.mktmpdir('testflight-proof-project-')
    @remote = Dir.mktmpdir('testflight-proof-remote-')
    git(@remote, 'init', '--bare', '-q')
    git(@root, 'init', '-q', '-b', 'main')
    git(@root, 'config', 'user.email', 'proof@example.test')
    git(@root, 'config', 'user.name', 'Proof Test')
    File.write(File.join(@root, '.saneprocess'), "name: ProofApp\ntype: ios_app\n")
    File.write(File.join(@root, '.gitignore'), "outputs/\n")
    @generated_project = File.join(@root, 'ProofApp.xcodeproj')
    FileUtils.mkdir_p(@generated_project)
    File.write(File.join(@generated_project, 'project.pbxproj'), '// generated project fixture')
    git(@root, 'add', '.saneprocess', '.gitignore', 'ProofApp.xcodeproj/project.pbxproj')
    git(@root, 'commit', '-q', '-m', 'proof source')
    git(@root, 'remote', 'add', 'origin', @remote)
    git(@root, 'push', '-q', '-u', 'origin', 'main')

    artifact_root = File.join(@root, 'outputs', 'artifacts', '1133')
    @archive = File.join(artifact_root, 'archive', 'ProofApp.xcarchive')
    @ipa = File.join(artifact_root, 'export', 'ProofApp.ipa')
    @export_options = File.join(artifact_root, 'ExportOptions.plist')
    FileUtils.mkdir_p(File.dirname(@archive))
    FileUtils.mkdir_p(File.dirname(@ipa))
    rewrite_archive
    write_plist(@export_options, { 'method' => 'app-store-connect' })
    rewrite_ipa
  end

  def cleanup
    FileUtils.remove_entry_secure(@root) if Dir.exist?(@root)
    FileUtils.remove_entry_secure(@remote) if Dir.exist?(@remote)
  end

  def produce
    TestflightArtifactProof.produce!(
      project_dir: @root,
      ipa: @ipa,
      archive: @archive,
      export_options: @export_options,
      generated_project: @generated_project
    )
  end

  def validate(now: Time.now.utc)
    TestflightArtifactProof.validate(project_dir: @root, ipa: @ipa, now: now)
  end

  def rewrite_archive(bundle: 'com.saneapps.proof', version: '1.2.3', build: '1133')
    FileUtils.mkdir_p(File.join(@archive, 'Products', 'Applications', 'ProofApp.app'))
    write_plist(
      File.join(@archive, 'Info.plist'),
      {
        'ApplicationProperties' => {
          'CFBundleIdentifier' => bundle,
          'CFBundleShortVersionString' => version,
          'CFBundleVersion' => build
        }
      }
    )
    File.binwrite(File.join(@archive, 'Products', 'Applications', 'ProofApp.app', 'ProofApp'), 'archive-binary')
  end

  def rewrite_ipa(bundle: 'com.saneapps.proof', version: '1.2.3', build: '1133', executable: 'ipa-binary-0001')
    stage = Dir.mktmpdir('testflight-ipa-stage-')
    app = File.join(stage, 'Payload', 'ProofApp.app')
    FileUtils.mkdir_p(app)
    write_plist(
      File.join(app, 'Info.plist'),
      {
        'CFBundleIdentifier' => bundle,
        'CFBundleShortVersionString' => version,
        'CFBundleVersion' => build
      }
    )
    File.binwrite(File.join(app, 'ProofApp'), executable)
    Dir.glob(File.join(stage, '**/*'), File::FNM_DOTMATCH).each do |path|
      File.utime(Time.at(1_700_000_000), Time.at(1_700_000_000), path)
    end
    candidate = File.join(stage, 'candidate.ipa')
    Dir.chdir(stage) do
      raise 'zip fixture failed' unless system('/usr/bin/zip', '-X', '-0', '-q', '-r', candidate, 'Payload')
    end
    if File.exist?(@ipa)
      File.binwrite(@ipa, File.binread(candidate))
    else
      FileUtils.cp(candidate, @ipa)
    end
  ensure
    FileUtils.remove_entry_secure(stage) if stage && Dir.exist?(stage)
  end

  def replace_same_bytes(path)
    replacement = "#{path}.replacement"
    File.binwrite(replacement, File.binread(path))
    File.rename(replacement, path)
  end

  def advance_remote
    clone = Dir.mktmpdir('testflight-proof-clone-')
    system('git', 'clone', '-q', @remote, clone) || raise('clone failed')
    git(clone, 'config', 'user.email', 'remote@example.test')
    git(clone, 'config', 'user.name', 'Remote Test')
    File.write(File.join(clone, 'remote.txt'), 'advanced')
    git(clone, 'add', 'remote.txt')
    git(clone, 'commit', '-q', '-m', 'advance remote')
    git(clone, 'push', '-q', 'origin', 'main')
  ensure
    FileUtils.remove_entry_secure(clone) if clone && Dir.exist?(clone)
  end

  def git(path, *args)
    out, err, status = Open3.capture3('git', '-C', path, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def write_plist(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, plist_document(value))
  end

  def plist_document(value)
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">#{plist_node(value)}</plist>
    PLIST
  end

  def plist_node(value)
    case value
    when Hash
      "<dict>#{value.map { |key, child| "<key>#{key}</key>#{plist_node(child)}" }.join}</dict>"
    else
      "<string>#{value}</string>"
    end
  end
end

class TestflightArtifactProofTest < Minitest::Test
  GUARD = File.expand_path('hooks/sane_release_guard.rb', __dir__)

  def with_fixture
    fixture = TestflightArtifactFixture.new
    yield fixture
  ensure
    fixture&.cleanup
  end

  def run_guard(fixture, path = 'outputs/artifacts/1133/export/ProofApp.ipa')
    payload = {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{fixture.root} && xcrun altool --upload-app -f #{path} --apiKey KEY --apiIssuer ISSUER"
      }
    }
    Open3.capture3('ruby', GUARD, stdin_data: JSON.generate(payload))
  end

  def test_valid_exact_proof_is_private_and_allows_literal_and_variable_upload_paths
    with_fixture do |fixture|
      fixture.produce
      proof_path = TestflightArtifactProof.receipt_path(fixture.ipa)
      assert_equal 0, File.stat(proof_path).mode & 0o077
      assert_equal [true, 'exact TestFlight artifact proof is current'], fixture.validate
      _, err, status = run_guard(fixture)
      assert status.success?, err
      assert_includes err, 'exact source/archive/export/IPA proof'

      payload = {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "cd #{fixture.root} && ART=outputs/artifacts/1133 && xcrun altool --upload-app -f \"$ART/export/ProofApp.ipa\" --apiKey KEY --apiIssuer ISSUER"
        }
      }
      _, variable_err, variable_status = Open3.capture3('ruby', GUARD, stdin_data: JSON.generate(payload))
      assert variable_status.success?, variable_err
    end
  end

  def test_missing_ipa_and_unrelated_recent_verify_never_authorize_upload
    with_fixture do |fixture|
      FileUtils.mkdir_p(File.join(fixture.root, 'outputs', 'verify', 'recent'))
      File.write(File.join(fixture.root, 'outputs', 'verify', 'recent', 'receipt.json'), '{"ok":true}')
      File.delete(fixture.ipa)
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'does not exist'
      _, guard_err, guard_status = run_guard(fixture)
      assert_equal 2, guard_status.exitstatus
      assert_includes guard_err, 'exact adjacent mode-0600 proof'
    end
  end

  def test_detached_ahead_and_stale_live_remote_source_fail_closed
    with_fixture do |fixture|
      fixture.git(fixture.root, 'checkout', '-q', '--detach')
      assert_raises(RuntimeError) { fixture.produce }
    end
    with_fixture do |fixture|
      File.write(File.join(fixture.root, 'ahead.txt'), 'ahead')
      fixture.git(fixture.root, 'add', 'ahead.txt')
      fixture.git(fixture.root, 'commit', '-q', '-m', 'ahead')
      assert_raises(RuntimeError) { fixture.produce }
    end
    with_fixture do |fixture|
      fixture.produce
      fixture.advance_remote
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'HEAD to equal the live origin branch'
    end
  end

  def test_ipa_hash_bytes_and_inode_replacements_each_fail_closed
    with_fixture do |fixture|
      fixture.produce
      original = File.stat(fixture.ipa)
      fixture.rewrite_ipa(executable: 'ipa-binary-9999')
      assert_equal original.ino, File.stat(fixture.ipa).ino
      assert_equal original.size, File.size(fixture.ipa)
      refute fixture.validate.first, 'same-size hash mutation must invalidate proof'
    end
    with_fixture do |fixture|
      fixture.produce
      File.open(fixture.ipa, 'ab') { |file| file.write('extra-byte') }
      refute fixture.validate.first, 'byte-count mutation must invalidate proof'
    end
    with_fixture do |fixture|
      fixture.produce
      original_inode = File.stat(fixture.ipa).ino
      fixture.replace_same_bytes(fixture.ipa)
      refute_equal original_inode, File.stat(fixture.ipa).ino
      refute fixture.validate.first, 'same-byte inode replacement must invalidate proof'
    end
  end

  def test_archive_export_and_generated_project_replacements_fail_closed
    with_fixture do |fixture|
      fixture.produce
      fixture.rewrite_archive(version: '9.9.9')
      refute fixture.validate.first
    end
    with_fixture do |fixture|
      fixture.produce
      fixture.replace_same_bytes(fixture.export_options)
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'export options identity changed'
    end
    with_fixture do |fixture|
      fixture.produce
      File.write(File.join(fixture.generated_project, 'project.pbxproj'), '// changed')
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'clean worktree'
    end
  end

  def test_bundle_version_build_archive_and_ipa_mismatches_block_proof_creation
    %i[bundle version build].each do |field|
      with_fixture do |fixture|
        values = { bundle: 'com.saneapps.proof', version: '1.2.3', build: '1133' }
        values[field] = field == :build ? '9999' : 'wrong'
        fixture.rewrite_archive(**values)
        assert_raises(RuntimeError) { fixture.produce }
      end
    end
    with_fixture do |fixture|
      fixture.rewrite_ipa(bundle: 'com.saneapps.other')
      assert_raises(RuntimeError) { fixture.produce }
    end
    with_fixture do |fixture|
      wrong = File.join(fixture.root, 'outputs', 'artifacts', '1134', 'archive', 'ProofApp.xcarchive')
      FileUtils.mkdir_p(File.dirname(wrong))
      FileUtils.mv(fixture.archive, wrong)
      assert_raises(ArgumentError) do
        TestflightArtifactProof.produce!(
          project_dir: fixture.root,
          ipa: fixture.ipa,
          archive: wrong,
          export_options: fixture.export_options,
          generated_project: fixture.generated_project
        )
      end
    end
  end

  def test_artifact_directory_build_must_match_embedded_ipa_build
    with_fixture do |fixture|
      wrong_ipa = File.join(fixture.root, 'outputs', 'artifacts', '1134', 'export', 'ProofApp.ipa')
      FileUtils.mkdir_p(File.dirname(wrong_ipa))
      FileUtils.cp(fixture.ipa, wrong_ipa)
      assert_raises(ArgumentError) do
        TestflightArtifactProof.produce!(
          project_dir: fixture.root,
          ipa: wrong_ipa,
          archive: fixture.archive,
          export_options: fixture.export_options,
          generated_project: fixture.generated_project
        )
      end
    end
  end

  def test_export_options_must_share_the_numbered_artifact_root
    with_fixture do |fixture|
      outside = File.join(fixture.root, 'ExportOptions.plist')
      FileUtils.cp(fixture.export_options, outside)
      assert_raises(ArgumentError) do
        TestflightArtifactProof.produce!(
          project_dir: fixture.root,
          ipa: fixture.ipa,
          archive: fixture.archive,
          export_options: outside,
          generated_project: fixture.generated_project
        )
      end
    end
  end

  def test_bounded_capture_kills_a_noisy_child_without_waiting_for_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(RuntimeError) do
      TestflightArtifactProof.bounded_capture!(
        RbConfig.ruby,
        '-e',
        "STDOUT.write('x' * #{TestflightArtifactProof::MAX_COMMAND_BYTES + 1}); sleep 20",
        timeout_seconds: 10
      )
    end
    assert_includes error.message, 'output exceeded safe limit'
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_stale_world_readable_and_symlinked_receipts_fail_closed
    with_fixture do |fixture|
      fixture.produce
      path = TestflightArtifactProof.receipt_path(fixture.ipa)
      proof = JSON.parse(File.read(path))
      proof['generated_at'] = (Time.now.utc - 40 * 3600).iso8601
      proof['expires_at'] = (Time.now.utc - 4 * 3600).iso8601
      File.write(path, JSON.pretty_generate(proof))
      File.chmod(0o600, path)
      refute fixture.validate.first
    end
    with_fixture do |fixture|
      fixture.produce
      path = TestflightArtifactProof.receipt_path(fixture.ipa)
      File.chmod(0o644, path)
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'private mode 0600'
    end
    with_fixture do |fixture|
      fixture.produce
      path = TestflightArtifactProof.receipt_path(fixture.ipa)
      target = "#{path}.target"
      File.rename(path, target)
      File.symlink(target, path)
      valid, error = fixture.validate
      refute valid
      assert_includes error, 'nofollow'
    end
  end
end
