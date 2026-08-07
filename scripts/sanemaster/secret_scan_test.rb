#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

require_relative '../hooks/test/test_framework'
require_relative 'secret_scan'
require_relative '../../outputs/secret-remediation/execute-20260803-air-derived-trash'

include TestFramework

ROOT = File.expand_path('../..', __dir__)
SANEMASTER = File.join(ROOT, 'scripts', 'SaneMaster.rb')

def write_fake_av(path)
  File.write(path, <<~'RUBY')
    #!/usr/bin/env ruby
    require 'json'

    if ARGV.include?('--version')
      puts 'Automic Vault 1.18.2'
      exit 0
    end

    unless ARGV.first == 'scan'
      warn 'unexpected command'
      exit 2
    end

    puts ENV.fetch('FAKE_AUTOMIC_FINDINGS_JSON')
  RUBY
  File.chmod(0o755, path)
end

def run_secret_scan(root, scanner, findings, *extra_args)
  out_dir = File.join(root, 'outputs', 'secret-scan')
  env = {
    'FAKE_AUTOMIC_FINDINGS_JSON' => JSON.generate('findings' => findings),
    'SANEMASTER_DISABLE_MINI_ROUTING' => '1'
  }
  Open3.capture3(
    env,
    'ruby', SANEMASTER, 'secret_scan',
    '--path', root,
    '--scanner', scanner,
    '--output-dir', out_dir,
    '--json',
    *extra_args,
    chdir: ROOT
  ).then do |stdout, stderr, status|
    receipt = Dir.glob(File.join(out_dir, '*.json')).max_by { |candidate| File.mtime(candidate) }
    [stdout, stderr, status, receipt ? JSON.parse(File.read(receipt)) : nil]
  end
end

exit(run_tests('SaneMaster Secret Scan Tests') do
  test_category('Automic Vault policy wrapper') do
    test('preserves exact private Grok and Gemini credential stores') do
      Dir.mktmpdir('secret-scan-canonical-store-') do |temporary_home|
        home = File.realpath(temporary_home)
        policy = Object.new.extend(SaneMasterModules::SecretScan)

        %w[.grok/auth.json .gemini/oauth_creds.json].each do |relative_path|
          path = File.join(home, relative_path)
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          File.write(path, '{}', mode: 'w', perm: 0o600)

          assert(
            policy.send(:secure_canonical_active_access_file?, path, home: home),
            "expected secure canonical store: #{relative_path}"
          )
        end
      end
      true
    end

    test('rejects canonical store symlinks unsafe modes owners parents and other paths') do
      Dir.mktmpdir('secret-scan-canonical-negative-') do |temporary_home|
        home = File.realpath(temporary_home)
        policy = Object.new.extend(SaneMasterModules::SecretScan)
        grok_dir = File.join(home, '.grok')
        FileUtils.mkdir_p(grok_dir, mode: 0o700)
        store = File.join(grok_dir, 'auth.json')
        File.write(store, '{}', mode: 'w', perm: 0o600)

        assert(!policy.send(:secure_canonical_active_access_file?, store, home: home, owner_uid: Process.uid + 1), 'wrong owner must fail')

        File.chmod(0o640, store)
        assert(!policy.send(:secure_canonical_active_access_file?, store, home: home), 'wrong file mode must fail')
        File.chmod(0o600, store)

        File.chmod(0o777, grok_dir)
        assert(!policy.send(:secure_canonical_active_access_file?, store, home: home), 'unsafe parent must fail')
        File.chmod(0o700, grok_dir)

        other = File.join(home, '.other', 'auth.json')
        FileUtils.mkdir_p(File.dirname(other), mode: 0o700)
        File.write(other, '{}', mode: 'w', perm: 0o600)
        assert(!policy.send(:secure_canonical_active_access_file?, other, home: home), 'noncanonical path must fail')

        target = File.join(home, 'target.json')
        File.write(target, '{}', mode: 'w', perm: 0o600)
        FileUtils.rm_f(store)
        File.symlink(target, store)
        assert(!policy.send(:secure_canonical_active_access_file?, store, home: home), 'symlink must fail')
      end
      true
    end

    test('fails on plaintext shell startup secret and redacts receipt payload') do
      Dir.mktmpdir('secret-scan-actionable-') do |dir|
        scanner = File.join(dir, 'av')
        write_fake_av(scanner)
        zshenv = File.join(dir, '.zshenv')
        ssh_key = File.join(Dir.home, '.ssh', 'id_ed25519')
        secret_name = ['CLOUDFLARE_API', 'TOKEN'].join('_')
        fake_secret = ['fake-regression', 'secret'].join('-')
        findings = [
          {
            'severity' => 'high',
            'kind' => 'secret-assignment',
            'path' => zshenv,
            'message' => "Plaintext-looking credential assigned to #{secret_name}",
            'secret' => fake_secret,
            'line' => "export #{secret_name}=#{fake_secret}"
          },
          {
            'severity' => 'critical',
            'kind' => 'private-key',
            'path' => ssh_key,
            'message' => 'Private key material',
            'raw' => 'fake-private-key-material'
          }
        ]

        _stdout, stderr, status, receipt = run_secret_scan(dir, scanner, findings)

        assert_eq(status.exitstatus, 1, stderr)
        assert_eq(receipt['status'], 'fail')
        assert_eq(receipt['actionable_count'], 1)
        assert_eq(receipt['preserved_count'], 1)
        assert_includes(receipt['actionable_findings'].first['path'], '.zshenv')
        serialized = JSON.generate(receipt)
        assert(!serialized.include?(fake_secret), 'receipt leaked fake secret value')
        assert(!serialized.include?("export #{secret_name}"), 'receipt leaked source line')
      end
      true
    end

    test('passes when findings are preserved active access or third-party packages') do
      Dir.mktmpdir('secret-scan-preserved-') do |dir|
        scanner = File.join(dir, 'av')
        write_fake_av(scanner)
        findings = [
          {
            'severity' => 'critical',
            'kind' => 'private-key',
            'path' => File.join(Dir.home, '.private_keys', 'AuthKey_S34998ZCRT.p8'),
            'message' => 'Active Apple API key'
          },
          {
            'severity' => 'high',
            'kind' => 'test-token',
            'path' => File.join(dir, '.venv', 'lib', 'python3.14', 'site-packages', 'pyjwt-2.13.0.dist-info', 'METADATA'),
            'message' => 'Third-party package test vector'
          }
        ]

        _stdout, stderr, status, receipt = run_secret_scan(dir, scanner, findings)

        assert_eq(status.exitstatus, 0, stderr)
        assert_eq(receipt['status'], 'pass')
        assert_eq(receipt['actionable_count'], 0)
        assert_eq(receipt['preserved_count'], 1)
        assert_eq(receipt['ignored_count'], 1)
      end
      true
    end

    test('preserves known active CLI credential stores') do
      Dir.mktmpdir('secret-scan-active-cli-') do |dir|
        scanner = File.join(dir, 'av')
        write_fake_av(scanner)
        home = Dir.home
        findings = [
          File.join(home, '.config', 'nv', 'env'),
          File.join(home, '.config', 'gh', 'hosts.yml'),
          File.join(home, '.config', 'saneprocess', 'secrets.env'),
          File.join(home, '.codex', 'secrets', 'github_token'),
          File.join(home, '.peekaboo', 'credentials'),
          File.join(home, '.appstoreconnect', 'private_keys', 'AuthKey_FIXTURE.p8')
        ].map do |path|
          {
            'severity' => 'high',
            'kind' => 'secret-assignment',
            'path' => path,
            'message' => 'Active credential store'
          }
        end

        _stdout, stderr, status, receipt = run_secret_scan(dir, scanner, findings)

        assert_eq(status.exitstatus, 0, stderr)
        assert_eq(receipt['status'], 'pass')
        assert_eq(receipt['actionable_count'], 0)
        assert_eq(receipt['preserved_count'], 6)
      end
      true
    end

    test('ignores known scanner prompt and test fixture examples') do
      Dir.mktmpdir('secret-scan-fixtures-') do |dir|
        scanner = File.join(dir, 'av')
        write_fake_av(scanner)
        findings = [
          File.join(dir, 'apps', 'SaneClip', 'Tests', 'SaneClipTests.swift'),
          File.join(dir, '.nvm', '.github', 'workflows', 'windows-npm.yml'),
          File.join(Dir.home, '.grok', 'marketplace-cache', 'fixture', 'src', 'services', 'telemetry', 'common.ts'),
          File.join(Dir.home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'memory-conflicts', '20260803T011209Z', 'codex-memories', 'local', 'manifest.tsv')
        ].map do |path|
          {
            'severity' => 'critical',
            'kind' => 'private-key',
            'path' => path,
            'message' => 'Fixture private-key pattern'
          }
        end

        _stdout, stderr, status, receipt = run_secret_scan(dir, scanner, findings)

        assert_eq(status.exitstatus, 0, stderr)
        assert_eq(receipt['status'], 'pass')
        assert_eq(receipt['actionable_count'], 0)
        assert_eq(receipt['ignored_count'], 4)
      end
      true
    end

    test('does not ignore live configs session history or private dirty patches') do
      Dir.mktmpdir('secret-scan-negative-policy-') do |dir|
        scanner = File.join(dir, 'av')
        write_fake_av(scanner)
        findings = [
          File.join(Dir.home, 'SaneApps', 'sanelot', '.dev.vars'),
          File.join(Dir.home, '.codex', 'sessions', '2026', '08', '03', 'rollout.jsonl'),
          File.join(Dir.home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'peer-dirty-backups', 'host', 'SaneProcess', 'snapshot', 'worktree.patch')
        ].map do |path|
          {
            'severity' => 'high',
            'kind' => 'token-literal',
            'path' => path,
            'message' => 'Must remain actionable'
          }
        end

        _stdout, stderr, status, receipt = run_secret_scan(dir, scanner, findings)

        assert_eq(status.exitstatus, 1, stderr)
        assert_eq(receipt['actionable_count'], 3)
        assert_eq(receipt['ignored_count'], 0)
      end
      true
    end

    test('reports missing scanner with install guidance') do
      Dir.mktmpdir('secret-scan-missing-') do |dir|
        missing = File.join(dir, 'missing-av')
        _stdout, stderr, status, receipt = run_secret_scan(dir, missing, [])

        assert_eq(status.exitstatus, 2, stderr)
        assert_eq(receipt['status'], 'scanner_missing')
        assert_includes(receipt.dig('scanner', 'install'), 'automic-vault')
      end
      true
    end
  end

  test_category('Exact recoverable-trash plan') do
    test('validates a private NUL-safe manifest and refuses changed content') do
      Dir.mktmpdir('secret-trash-plan-') do |dir|
        file_target = File.join(dir, "generated\nartifact.txt")
        directory_target = File.join(dir, 'derived-cache')
        File.write(file_target, 'fixture only')
        FileUtils.mkdir_p(directory_target)
        File.write(File.join(directory_target, 'entry.json'), '{}')
        File.chmod(0o600, file_target)
        File.chmod(0o700, directory_target)

        paths = [file_target, directory_target]
        manifest = File.join(dir, 'plan.paths0')
        metadata = File.join(dir, 'plan.metadata.json')
        File.binwrite(manifest, paths.join("\0") + "\0")
        entries = paths.each_with_index.map do |path, index|
          type = File.directory?(path) ? 'directory' : 'file'
          {
            index: index,
            path_sha256: SaneSecretTrashPlan.path_hash(path),
            type: type,
            mode: SaneSecretTrashPlan.file_mode(path),
            sha256: type == 'directory' ? SaneSecretTrashPlan.directory_digest(path) : Digest::SHA256.file(path).hexdigest,
            precondition: 'fixture'
          }
        end
        File.write(metadata, JSON.pretty_generate(
          schema_version: 1,
          manifest_sha256: Digest::SHA256.file(manifest).hexdigest,
          entries: entries
        ))
        File.chmod(0o600, manifest)
        File.chmod(0o600, metadata)

        validated = SaneSecretTrashPlan.validate(manifest_path: manifest, metadata_path: metadata)
        assert_eq(validated, paths)
        assert_eq(SaneSecretTrashPlan.run([], manifest_path: manifest, metadata_path: metadata), 0)
        assert(File.exist?(file_target), 'dry run changed a file')
        assert(File.exist?(directory_target), 'dry run changed a directory')

        File.write(file_target, 'changed fixture')
        begin
          SaneSecretTrashPlan.validate(manifest_path: manifest, metadata_path: metadata)
          assert(false, 'changed content must fail validation')
        rescue StandardError => e
          assert_includes(e.message, 'content digest mismatch')
        end
      end
      true
    end

    test('executor is dry-run by default and applies only through usr bin trash') do
      source = File.read(File.join(ROOT, 'outputs', 'secret-remediation', 'execute-20260803-air-derived-trash.rb'))
      assert_includes(source, "apply = argv.delete('--apply')")
      assert_includes(source, "TRASH = '/usr/bin/trash'")
      assert_includes(source, "Open3.capture3(TRASH, '--stopOnError', *paths)")
      assert(!source.include?('rm -'), 'executor must never use rm')
      true
    end
  end
end)
