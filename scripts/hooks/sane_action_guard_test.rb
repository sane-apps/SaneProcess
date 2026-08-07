#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative 'core/action_authorization'
require_relative 'test/test_framework'

include TestFramework

FIXED_NOW = Time.utc(2026, 8, 2, 20, 0, 0)
SOURCE = 'a' * 64
PRODUCER_DIGEST = 'b' * 64
HOOK = File.expand_path('sane_action_guard.rb', __dir__)
ACTION_ACTIVATION_PATH = '/Library/Application Support/SaneProcess/action-guard-enabled.json'
APPROVING_GATE = Object.new
def APPROVING_GATE.approve(**_args)
  SaneActionAuthorization::GateResult.new(approved: true, message: 'test gate approved')
end

def payload(command, session: 'session-test')
  JSON.generate(
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => command, 'cwd' => Dir.pwd },
    'session_id' => session
  )
end

def build_authorizer(root, key, now: FIXED_NOW, gate: APPROVING_GATE)
  SaneActionAuthorization::Authorizer.new(
    root: root,
    public_key_der: key.public_to_der,
    producer_sha256: PRODUCER_DIGEST,
    now: -> { now },
    source_fingerprint: ->(_project) { SOURCE },
    hostname: 'mini-test',
    gate: gate
  )
end

def signed_receipt(authorizer, key, payload_json, issued_at: FIXED_NOW - 10,
                   expires_at: FIXED_NOW + 300, nonce: 'c' * 32, mutate: nil)
  request = authorizer.authorization_request(payload_json)
  envelope = request.fetch('action').merge(
    'issued_at' => issued_at.utc.iso8601,
    'expires_at' => expires_at.utc.iso8601,
    'nonce' => nonce,
    'max_uses' => 1
  )
  mutate.call(envelope) if mutate
  unsigned = {
    'schema_version' => SaneActionAuthorization::SCHEMA_VERSION,
    'producer' => {
      'id' => SaneActionAuthorization::PRODUCER,
      'schema' => SaneActionAuthorization::PRODUCER_SCHEMA,
      'source_sha256' => PRODUCER_DIGEST,
      'key_context' => SaneActionAuthorization::KEY_CONTEXT
    },
    'decision' => 'permit',
    'classification' => SaneActionAuthorization::REVIEW_REQUIRED,
    'envelope' => envelope
  }
  receipt = unsigned.merge('signature' => Base64.strict_encode64(key.sign(nil, JSON.generate(unsigned))))
  [request.fetch('receipt_path'), receipt]
end

def write_receipt(path, receipt, mode: 0o600)
  FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
  FileUtils.chmod(0o700, File.dirname(path))
  File.write(path, JSON.pretty_generate(receipt), encoding: Encoding::UTF_8)
  File.chmod(mode, path)
end

def with_authorizer
  Dir.mktmpdir('sane-action-authorization-') do |root|
    root = File.realpath(root)
    File.chmod(0o700, root)
    key = OpenSSL::PKey.generate_key('ED25519')
    yield(root, key, build_authorizer(root, key))
  end
end

exit(run_tests('Sane Action Authorization Tests') do
  test('hard deny precedes every receipt route and remains manual-only') do
    _out, err, status = Open3.capture3(
      'ruby', HOOK,
      stdin_data: payload('git reset --hard HEAD')
    )
    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'catastrophic shell operation')
    assert_includes(err, 'manual user-only action')
    assert(!err.include?('canonical_receipt='))
    true
  end

  test('consequential enforcement remains audit-only without root activation') do
    assert(!File.exist?(ACTION_ACTIVATION_PATH), 'test host must not already have production action-guard activation')
    _out, err, status = Open3.capture3('ruby', HOOK, stdin_data: payload('git push origin main'))
    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
    source = File.read(HOOK)
    assert_includes(source, '/Library/Application Support/SaneProcess/action-guard-enabled.json')
    assert_includes(source, 'stat.uid.zero?')
    assert_includes(source, "data['guard_sha256'] == expected")
    true
  end

  test('allows routine read local and reversible shell commands') do
    with_authorizer do |_root, _key, authorizer|
      ['git status', 'ruby scripts/hooks/sane_action_guard_test.rb', 'trash /tmp/recoverable.txt'].each do |command|
        result = authorizer.evaluate(payload(command))
        assert(result.allowed, "expected routine command to remain allowed: #{command}")
        assert_eq(result.classification, SaneActionAuthorization::ALLOW)
      end
    end
    true
  end

  test('malformed JSON and malformed shell policy fail closed') do
    with_authorizer do |_root, _key, authorizer|
      invalid_json = authorizer.evaluate('{')
      invalid_shell = authorizer.evaluate(payload("git push 'unterminated"))
      assert(!invalid_json.allowed)
      assert_includes(invalid_json.message, 'failed closed')
      assert(!invalid_shell.allowed)
      assert_includes(invalid_shell.message, 'malformed shell command')
    end
    true
  end

  test('missing and invalid independent receipts deny with canonical route') do
    with_authorizer do |_root, key, authorizer|
      action = payload('git push origin main')
      missing = authorizer.evaluate(action)
      assert(!missing.allowed)
      assert_eq(missing.classification, SaneActionAuthorization::REVIEW_REQUIRED)
      assert_includes(missing.message, 'canonical_receipt=')

      path, receipt = signed_receipt(authorizer, key, action)
      receipt['signature'] = Base64.strict_encode64('not a valid signature')
      write_receipt(path, receipt)
      invalid = authorizer.evaluate(action)
      assert(!invalid.allowed)
      assert_includes(invalid.message, 'signature is invalid')
    end
    true
  end

  test('exact target and body hash mismatches fail closed even when signed') do
    with_authorizer do |_root, key, authorizer|
      action = payload('git push origin main')
      [
        ->(envelope) { envelope['target'] = 'git push origin other' },
        ->(envelope) { envelope['body_or_file_sha256'] = 'd' * 64 }
      ].each_with_index do |mutation, index|
        path, receipt = signed_receipt(authorizer, key, action, nonce: format('%032x', index + 1), mutate: mutation)
        write_receipt(path, receipt)
        result = authorizer.evaluate(action)
        assert(!result.allowed)
        assert_includes(result.message, 'mismatch')
      end
    end
    true
  end

  test('bound upload file bytes change the canonical receipt path') do
    with_authorizer do |_root, key, authorizer|
      Dir.mktmpdir('sane-action-package-') do |package_root|
        package = File.join(package_root, 'candidate.ipa')
        File.write(package, 'candidate-one')
        action = payload("xcrun altool --upload-app -f #{Shellwords.escape(package)}")
        path, receipt = signed_receipt(authorizer, key, action, nonce: '9' * 32)
        write_receipt(path, receipt)
        File.write(package, 'candidate-two')
        changed_path = authorizer.receipt_path(action)
        assert(path != changed_path, 'changed file bytes must produce a different canonical receipt path')
        result = authorizer.evaluate(action)
        assert(!result.allowed)
        assert_includes(result.message, 'canonical_receipt=')
      end
    end
    true
  end

  test('expired and future-issued receipts fail closed') do
    with_authorizer do |_root, key, authorizer|
      action = payload('git push origin main')
      cases = [
        { issued_at: FIXED_NOW - 400, expires_at: FIXED_NOW - 1, expected: 'expired' },
        { issued_at: FIXED_NOW + 31, expires_at: FIXED_NOW + 300, expected: 'future' }
      ]
      cases.each_with_index do |item, index|
        path, receipt = signed_receipt(
          authorizer, key, action,
          issued_at: item.fetch(:issued_at), expires_at: item.fetch(:expires_at),
          nonce: format('%032x', index + 10)
        )
        write_receipt(path, receipt)
        result = authorizer.evaluate(action)
        assert(!result.allowed)
        assert_includes(result.message, item.fetch(:expected))
      end
    end
    true
  end

  test('symlink and wrong-mode receipts are rejected') do
    with_authorizer do |root, key, authorizer|
      action = payload('git push origin main')
      path, receipt = signed_receipt(authorizer, key, action)
      outside = File.join(File.dirname(root), "outside-receipt-#{Process.pid}.json")
      File.write(outside, JSON.generate(receipt))
      File.symlink(outside, path)
      symlink_result = authorizer.evaluate(action)
      assert(!symlink_result.allowed)
      assert_includes(symlink_result.message, 'non-symlink')
      File.unlink(path)
      File.unlink(outside)

      write_receipt(path, receipt, mode: 0o644)
      mode_result = authorizer.evaluate(action)
      assert(!mode_result.allowed)
      assert_includes(mode_result.message, '0600')
    ensure
      FileUtils.rm_f(outside) if outside
    end
    true
  end

  test('one-time nonce consumption blocks replay and is race-safe') do
    with_authorizer do |_root, key, authorizer|
      action = payload('git push origin main')
      path, receipt = signed_receipt(authorizer, key, action, nonce: 'e' * 32)
      write_receipt(path, receipt)
      first = authorizer.evaluate(action)
      replay = authorizer.evaluate(action)
      assert(first.allowed)
      assert(!replay.allowed)
      assert_includes(replay.message, 'already consumed')

      race_action = payload('git push origin release', session: 'race-session')
      race_path, race_receipt = signed_receipt(authorizer, key, race_action, nonce: 'f' * 32)
      write_receipt(race_path, race_receipt)
      results = 2.times.map { Thread.new { authorizer.evaluate(race_action) } }.map(&:value)
      assert_eq(results.count(&:allowed), 1)
      assert_eq(results.count { |result| !result.allowed && result.message.include?('already consumed') }, 1)
    end
    true
  end

  test('a valid review receipt cannot authorize without the independent canonical gate') do
    with_authorizer do |root, key, _authorizer|
      unavailable = SaneActionAuthorization::CanonicalGate.new(path: '/missing/av', sha256: nil)
      authorizer = build_authorizer(root, key, gate: unavailable)
      action = payload('git push origin gate-test')
      path, receipt = signed_receipt(authorizer, key, action, nonce: '8' * 32)
      write_receipt(path, receipt)
      result = authorizer.evaluate(action)
      assert(!result.allowed)
      assert_eq(result.classification, SaneActionAuthorization::REVIEW_REQUIRED)
      assert_includes(result.message, 'not provisioned')
    end
    true
  end

  test('canonical gate is exact-path hash-pinned and receives bounded action context') do
    Dir.mktmpdir('sane-action-gate-') do |root|
      root = File.realpath(root)
      executable = File.join(root, 'av')
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      calls = []
      success_status = Struct.new(:success?).new(true)
      runner = lambda do |*args|
        calls << args
        ['', '', success_status]
      end
      gate = SaneActionAuthorization::CanonicalGate.new(
        path: executable,
        sha256: Digest::SHA256.file(executable).hexdigest,
        runner: runner
      )
      result = gate.approve(action_digest: '7' * 64, envelope: { 'target' => 'must stay redacted' })
      assert(result.approved)
      assert_eq(calls, [[executable, 'gate', "Authorize reviewed action: target=\"must stay redacted\" account= body_sha256= (action #{'7' * 64})"]])

      wrong_hash = SaneActionAuthorization::CanonicalGate.new(path: executable, sha256: '0' * 64, runner: runner)
      assert(!wrong_hash.approve(action_digest: '7' * 64).approved)
      assert_eq(calls.length, 1)
    end
    true
  end

  test('nested shell and Mini ssh mutations cannot hide from review') do
    with_authorizer do |_root, _key, authorizer|
      [
        'sh -c "curl -X POST https://example.com/items"',
        'ssh mini "git push origin main"',
        'echo safe; git push origin main',
        'echo safe & git push origin main',
        'echo $(git push origin main)',
        'env -i git push origin main',
        'time -p git push origin main',
        'git -C /tmp/repo push origin main',
        'curl -dfoo https://example.com',
        'curl -F file=@x https://example.com',
        'http POST https://example.com',
        './scripts/release.sh --deploy',
        'bash ./scripts/release.sh --deploy',
        'ruby ./scripts/appstore_submit.rb upload'
      ].each do |command|
        result = authorizer.evaluate(payload(command))
        assert(!result.allowed)
        assert_eq(result.classification, SaneActionAuthorization::REVIEW_REQUIRED)
        assert_includes(result.message, 'independent review receipt required')
      end
    end
    true
  end

  test('non-Bash external mutations are guarded by policy and installed settings') do
    with_authorizer do |_root, _key, authorizer|
      event = JSON.generate(
        'tool_name' => 'mcp__appstore__submit_for_review',
        'tool_input' => { 'project' => 'SaneLot' },
        'cwd' => Dir.pwd,
        'session_id' => 'native-tool-test'
      )
      result = authorizer.evaluate(event)
      assert(!result.allowed)
      assert_eq(result.classification, SaneActionAuthorization::REVIEW_REQUIRED)
      settings = File.read(File.expand_path('../init.sh', __dir__))
      assert_includes(settings, '"matcher": "^(?!Bash$).*"')
      assert_includes(settings, 'scripts/hooks/sane_action_guard.rb')
    end
    true
  end

  test('permission and credential changes require and honor the action-time canonical gate') do
    with_authorizer do |_root, _key, authorizer|
      result = authorizer.evaluate(payload('tccutil reset AppleEvents'))
      assert(result.allowed)
      assert_eq(result.classification, SaneActionAuthorization::USER_CONFIRM)
      assert_includes(result.message, 'manual canonical gate approved')
    end
    true
  end
end)
