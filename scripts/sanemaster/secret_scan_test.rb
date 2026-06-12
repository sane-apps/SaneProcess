#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

require_relative '../hooks/test/test_framework'

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
end)
