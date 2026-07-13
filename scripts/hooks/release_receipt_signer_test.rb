#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'test/test_framework'
require_relative 'release_receipt_signer'

include TestFramework

def assert_raises(error_class = StandardError)
  begin
    yield
  rescue error_class => error
    return error
  end
  raise "Expected #{error_class} to be raised"
end

def signer_fixture_root
  Dir.mktmpdir('release-receipt-signer-') do |root|
    ReleaseReceiptSigner::PRODUCERS.each_value do |spec|
      path = File.join(root, spec.fetch(:path))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# canonical producer\n")
    end
    yield(root)
  end
end

def preflight_payload
  {
    'type' => 'release_preflight_status',
    'status' => 'passed',
    'issues' => [],
    'sourceFingerprint' => 'a' * 64
  }
end

def authority_for_mode(secret:, mode:, root:)
  authority_class = Class.new(ReleaseReceiptSigner::Signer) do
    define_method(:initialize) do |worker_secret, worker_mode, worker_root|
      seed = OpenSSL::HMAC.digest('SHA256', worker_secret, "#{ReleaseReceiptSigner::PRIVATE_KEY_CONTEXT}-#{worker_mode}")
      key = ReleaseReceiptSigner.ed25519_private_key(seed)
      initialize_authority(private_key: key, mode: worker_mode, root: worker_root)
    end
  end
  authority_class.new(secret, mode, root)
end

def fake_issuer_runner(root)
  path = File.join(root, 'fake_sanemaster.rb')
  File.write(path, <<~'RUBY')
    require 'json'

    exit Integer(ENV.fetch('FAKE_ISSUER_EXIT', '1')) if ENV['FAKE_ISSUER_NO_CANDIDATE'] == '1'

    command = ARGV.first
    payload = {
      'type' => command == 'appstore_preflight' ? 'appstore_preflight_status' : 'release_preflight_status',
      'status' => ENV.fetch('FAKE_ISSUER_STATUS', 'passed'),
      'issues' => [],
      'issueCount' => 0,
      'sourceFingerprint' => 'a' * 64,
      'observedCommand' => command,
      'observedArgs' => ARGV.drop(1)
    }
    envelope = {
      'producer' => ENV.fetch('SANEPROCESS_RELEASE_RECEIPT_PRODUCER'),
      'destination' => ENV.fetch('SANEPROCESS_RELEASE_RECEIPT_DESTINATION'),
      'token' => ENV.fetch('SANEPROCESS_RELEASE_RECEIPT_TOKEN'),
      'payload' => payload
    }
    io = IO.for_fd(Integer(ENV.fetch('SANEPROCESS_RELEASE_RECEIPT_FD')), 'w', autoclose: false)
    io.write(JSON.generate(envelope))
    io.flush
    exit Integer(ENV.fetch('FAKE_ISSUER_EXIT', '0'))
  RUBY
  path
end

exit(run_tests('Release Receipt Signer Security Tests') do
  test_category('production authorization boundary') do
    test('test-only dependency injection cannot authorize a production receipt') do
      signer_fixture_root do |root|
        path = File.join(root, 'receipt.json')
        test_signer = ReleaseReceiptSigner.test_signer(secret: 'shared-test-secret', root: root)
        production = authority_for_mode(secret: 'shared-test-secret', mode: 'production', root: root)

        test_signer.write(path, preflight_payload, producer: 'saneprocess.release_preflight.v1')
        assert(test_signer.read(path, producer: 'saneprocess.release_preflight.v1'))
        assert_eq(production.read(path, producer: 'saneprocess.release_preflight.v1'), nil)
      end
      true
    end

    test('caller-selected secret cannot forge a trusted production receipt') do
      signer_fixture_root do |root|
        path = File.join(root, 'receipt.json')
        attacker = authority_for_mode(secret: 'caller-env-secret', mode: 'production', root: root)
        trusted = authority_for_mode(secret: 'trusted-keychain-secret', mode: 'production', root: root)

        attacker.write(path, preflight_payload, producer: 'saneprocess.release_preflight.v1')
        assert_eq(trusted.read(path, producer: 'saneprocess.release_preflight.v1'), nil)
      end
      true
    end

    test('receipt binds the exact canonical producer digest') do
      signer_fixture_root do |root|
        path = File.join(root, 'receipt.json')
        signer = authority_for_mode(secret: 'trusted-secret', mode: 'production', root: root)
        signer.write(path, preflight_payload, producer: 'saneprocess.release_preflight.v1')
        assert(signer.read(path, producer: 'saneprocess.release_preflight.v1'))

        producer = File.join(root, ReleaseReceiptSigner::PRODUCERS.fetch('saneprocess.release_preflight.v1').fetch(:path))
        File.write(producer, "# replaced producer\n")
        assert_eq(signer.read(path, producer: 'saneprocess.release_preflight.v1'), nil)
      end
      true
    end

    test('producer and payload type cannot be interchanged') do
      signer_fixture_root do |root|
        path = File.join(root, 'receipt.json')
        signer = ReleaseReceiptSigner.test_signer(secret: 'test-secret', root: root)
        error = assert_raises(ArgumentError) do
          signer.write(path, preflight_payload, producer: 'saneprocess.upgrade_path_proof.v1')
        end
        assert_includes(error.message, 'upgrade_path_behavioral_proof')
      end
      true
    end

    test('imported production verifier exposes neither a signing API nor secret state') do
      verifier = ReleaseReceiptSigner.production
      assert(!verifier.respond_to?(:write))
      assert(!verifier.respond_to?(:signed_payload))
      assert(!verifier.instance_variables.include?(:@secret))
      assert(!ReleaseReceiptSigner.respond_to?(:production_secret, true))
      assert(!ReleaseReceiptSigner.respond_to?(:keychain_secret, true))
      assert(!ReleaseReceiptSigner.respond_to?(:legacy_file_secret, true))
      true
    end

    test('public authority construction rejects production mode') do
      error = assert_raises(ArgumentError) do
        ReleaseReceiptSigner::Signer.new(secret: 'attacker-secret', mode: 'production')
      end
      assert_includes(error.message, 'mode=test')
      true
    end

    test('issuer signs only a candidate emitted by its fixed canonical command') do
      signer_fixture_root do |root|
        project = File.join(root, 'project')
        FileUtils.mkdir_p(project)
        authority = ReleaseReceiptSigner.test_signer(secret: 'issuer-test-secret', root: root)
        issuer = ReleaseReceiptSigner::Issuer.new(
          authority: authority,
          root: root,
          workspace_root: root,
          runner: fake_issuer_runner(root),
          environment: { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home }
        )

        assert_eq(issuer.issue('saneprocess.release_preflight.v1', project), 0)
        receipt = File.join(project, 'outputs', 'release_preflight_status.json')
        payload = authority.read(receipt, producer: 'saneprocess.release_preflight.v1')
        assert(payload)
        assert_eq(payload['observedCommand'], 'release_preflight')
      end
      true
    end

    test('issuer rejects a passed candidate from a failed canonical producer') do
      signer_fixture_root do |root|
        project = File.join(root, 'project')
        FileUtils.mkdir_p(project)
        authority = ReleaseReceiptSigner.test_signer(secret: 'issuer-test-secret', root: root)
        issuer = ReleaseReceiptSigner::Issuer.new(
          authority: authority,
          root: root,
          workspace_root: root,
          runner: fake_issuer_runner(root),
          environment: {
            'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home,
            'FAKE_ISSUER_EXIT' => '1', 'FAKE_ISSUER_STATUS' => 'passed'
          }
        )

        error = assert_raises(RuntimeError) do
          issuer.issue('saneprocess.release_preflight.v1', project)
        end
        assert_includes(error.message, 'status does not match')
        assert(!File.exist?(File.join(project, 'outputs', 'release_preflight_status.json')))
      end
      true
    end

    test('issuer preserves only allowlisted App Store binding arguments') do
      signer_fixture_root do |root|
        project = File.join(root, 'project')
        package = File.join(project, 'build', 'Example.pkg')
        FileUtils.mkdir_p(File.dirname(package))
        File.write(package, 'fixture')
        authority = ReleaseReceiptSigner.test_signer(secret: 'issuer-test-secret', root: root)
        issuer = ReleaseReceiptSigner::Issuer.new(
          authority: authority,
          root: root,
          workspace_root: root,
          runner: fake_issuer_runner(root),
          environment: { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home }
        )

        args = ['--platform', 'macos', '--pkg', package]
        assert_eq(issuer.issue('saneprocess.appstore_preflight.v1', project, producer_args: args), 0)
        receipt = File.join(project, 'outputs', 'appstore_preflight_status.json')
        payload = authority.read(receipt, producer: 'saneprocess.appstore_preflight.v1')
        assert_eq(payload['observedCommand'], 'appstore_preflight')
        assert_eq(payload['observedArgs'], ['--platform', 'macos', '--pkg', File.realpath(package)])

        error = assert_raises(ArgumentError) do
          issuer.issue('saneprocess.appstore_preflight.v1', project, producer_args: ['--unsafe', 'passed'])
        end
        assert_includes(error.message, 'unsupported')
      end
      true
    end

    test('issuer invalidates an old passing receipt before a no-candidate producer failure') do
      signer_fixture_root do |root|
        project = File.join(root, 'project')
        receipt = File.join(project, 'outputs', 'release_preflight_status.json')
        FileUtils.mkdir_p(File.dirname(receipt))
        authority = ReleaseReceiptSigner.test_signer(secret: 'issuer-test-secret', root: root)
        authority.write(receipt, preflight_payload, producer: 'saneprocess.release_preflight.v1')
        assert(authority.read(receipt, producer: 'saneprocess.release_preflight.v1'))

        issuer = ReleaseReceiptSigner::Issuer.new(
          authority: authority,
          root: root,
          workspace_root: root,
          runner: fake_issuer_runner(root),
          environment: {
            'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home,
            'FAKE_ISSUER_EXIT' => '1', 'FAKE_ISSUER_NO_CANDIDATE' => '1'
          }
        )
        assert_eq(issuer.issue('saneprocess.release_preflight.v1', project), 1)
        assert(!File.exist?(receipt), 'stale passing receipt must be removed before the producer runs')
      end
      true
    end

    test('production verifier is public-key-only and requires no Keychain lookup') do
      verifier = ReleaseReceiptSigner::ProductionVerifier.new
      assert(!verifier.respond_to?(:write))
      assert(!verifier.instance_variables.include?(:@private_key))
      assert(!verifier.instance_variables.include?(:@secret))
      assert_eq(verifier.mode, 'production')
      true
    end

    test('production issuance host policy allows Mini and rejects Air') do
      assert(ReleaseReceiptSigner.signing_host?('Stephans-Mac-mini.local'))
      assert(ReleaseReceiptSigner.signing_host?('mini'))
      assert(!ReleaseReceiptSigner.signing_host?('Stephans-MacBook-Air.local'))
      true
    end
  end

  test_category('tool and CLI hardening') do
    test('production key lookup pins the system security binary and ignores caller key variables') do
      source = File.read(File.join(__dir__, 'release_receipt_signer.rb'))
      assert_eq(ReleaseReceiptSigner::SECURITY_BIN, '/usr/bin/security')
      assert(!source.include?("ENV['CLAUDE_HOOK_SECRET']"))
      assert(!source.include?("ENV.fetch('CLAUDE_HOOK_SECRET'"))
      true
    end

    test('StateSigner CLI has no arbitrary sign or migrate operation') do
      signer_path = File.join(__dir__, 'state_signer.rb')
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, signer_path, '--sign', '/tmp/forbidden.json')
      assert(!status.success?)
      assert(stderr.include?('invalid option') || stderr.include?('Unknown option'))

      source = File.read(signer_path)
      assert(!source.include?("opts.on('-s', '--sign'"))
      assert(!source.include?("opts.on('-m', '--migrate'"))
      true
    end

    test('release receipt worker has no caller-payload signing operation') do
      worker = File.join(__dir__, 'release_receipt_signer.rb')
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, worker,
        '--issue', 'saneprocess.release_preflight.v1', Dir.pwd, '{"status":"passed"}'
      )
      assert(!status.success?)
      assert_includes(stderr, 'unexpected release receipt worker arguments')

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, worker, '--sign', '/tmp/forbidden.json')
      assert(!status.success?)
      assert_includes(stderr, 'usage:')
      true
    end
  end
end)
