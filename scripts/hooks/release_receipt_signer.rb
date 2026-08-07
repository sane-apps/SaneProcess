# frozen_string_literal: true

require 'base64'
require 'digest'
require 'English'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'rbconfig'
require 'securerandom'
require 'socket'
require 'tempfile'
require 'time'
require 'uri'

# Domain-separated authentication for release-authorizing receipts.
#
# Imported production code receives only a verifier. Production signing lives
# in this file's one-shot worker entry point: it launches one fixed canonical
# SaneMaster producer, receives that producer's candidate over a private file
# descriptor, validates the child exit/result pairing, and signs the candidate.
module ReleaseReceiptSigner
  ROOT = File.realpath(File.expand_path('../..', __dir__))
  WORKSPACE_ROOT = File.realpath(File.expand_path('../..', ROOT))
  WORKER_PATH = File.realpath(__FILE__)
  SANEMASTER_PATH = File.realpath(File.join(ROOT, 'scripts', 'SaneMaster.rb'))
  SECURITY_BIN = '/usr/bin/security'
  SECURITY_ENV = { 'PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C', 'LANG' => 'C' }.freeze
  KEYCHAIN_SERVICE = 'claude_hook'
  KEYCHAIN_ACCOUNT = 'hmac_secret'
  LEGACY_SECRET_FILE = File.expand_path('~/.claude_hook_secret')
  KEY_CONTEXT = 'saneprocess-release-authorization-v2-ed25519'
  PRIVATE_KEY_CONTEXT = 'saneprocess-release-authorization-v1-ed25519'
  PUBLIC_KEY_DER_HEX = '302a300506032b65700321005da71566a34988f5c7f32a3db934f50bde4ea0366e854e9fbd3e40276ec3add4'
  AUTH_KEY = '__release_auth__'
  SIGNATURE_KEY = '__release_sig__'
  TIMESTAMP_KEY = '__ts__'
  CHILD_FD = 9
  CHILD_FD_ENV = 'SANEPROCESS_RELEASE_RECEIPT_FD'
  CHILD_TOKEN_ENV = 'SANEPROCESS_RELEASE_RECEIPT_TOKEN'
  CHILD_PRODUCER_ENV = 'SANEPROCESS_RELEASE_RECEIPT_PRODUCER'
  CHILD_DESTINATION_ENV = 'SANEPROCESS_RELEASE_RECEIPT_DESTINATION'
  INTERNAL_ENV_KEYS = [CHILD_FD_ENV, CHILD_TOKEN_ENV, CHILD_PRODUCER_ENV, CHILD_DESTINATION_ENV].freeze
  MAX_CANDIDATE_BYTES = 4 * 1024 * 1024

  PRODUCERS = {
    'saneprocess.release_preflight.v1' => {
      path: 'scripts/sanemaster/release.rb',
      payload_type: 'release_preflight_status',
      command: 'release_preflight',
      receipt: 'outputs/release_preflight_status.json'
    },
    'saneprocess.appstore_preflight.v1' => {
      path: 'scripts/sanemaster/release.rb',
      payload_type: 'appstore_preflight_status',
      command: 'appstore_preflight',
      receipt: 'outputs/appstore_preflight_status.json',
      option_flags: %w[--platform --pkg],
      receipt_optional_on_success: true
    },
    'saneprocess.webstore_preflight.v1' => {
      path: 'scripts/sanemaster/store_compliance.rb',
      payload_type: 'webstore_preflight_status',
      command: 'webstore_preflight',
      receipt: 'outputs/webstore_preflight_status.json',
      option_flags: %w[--package --listing --media-dir --privacy-url --review-instructions],
      file_flags: %w[--package --listing --review-instructions],
      directory_flags: %w[--media-dir],
      url_flags: %w[--privacy-url]
    },
    'saneprocess.upgrade_path_proof.v1' => {
      path: 'scripts/sanemaster/upgrade_path_proof.rb',
      payload_type: 'upgrade_path_behavioral_proof',
      command: 'upgrade_path_proof',
      receipt: 'outputs/upgrade_path_behavioral_receipt.json'
    }
  }.freeze

  class Verifier
    def initialize(public_key_der:, mode:, root: ROOT)
      @public_key = OpenSSL::PKey.read(public_key_der)
      @mode = mode.to_s
      @root = File.realpath(root)
    end

    attr_reader :mode

    def read(path, producer:)
      metadata = File.lstat(path)
      return nil unless metadata.file? && !metadata.symlink?

      data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      signature = data.delete(SIGNATURE_KEY)
      return nil if signature.to_s.empty?

      spec = producer_spec(producer)
      validate_payload_type!(data, spec)
      return nil unless valid_producer_identity?(data[AUTH_KEY], producer, spec)
      return nil unless valid_signature?(data, signature.to_s)

      data
    rescue Errno::ENOENT, JSON::ParserError, ArgumentError, TypeError
      nil
    end

    private

    def normalize_payload(payload)
      raise ArgumentError, 'release receipt payload must be a hash' unless payload.is_a?(Hash)

      JSON.parse(JSON.generate(payload))
    end

    def producer_spec(producer)
      PRODUCERS.fetch(producer.to_s)
    rescue KeyError
      raise ArgumentError, "unknown release receipt producer: #{producer}"
    end

    def validate_payload_type!(data, spec)
      expected = spec.fetch(:payload_type)
      actual = data['type'].to_s
      raise ArgumentError, "release receipt type must be #{expected}" unless actual == expected
    end

    def producer_identity(producer, spec)
      relative = spec.fetch(:path)
      real_path = File.realpath(File.join(@root, relative))
      raise ArgumentError, "release producer escapes SaneProcess: #{relative}" unless real_path.start_with?("#{@root}/")

      metadata = File.lstat(real_path)
      raise ArgumentError, "release producer is not a regular file: #{relative}" unless metadata.file? && !metadata.symlink?

      {
        'version' => 1,
        'mode' => @mode,
        'producer' => producer.to_s,
        'producerPath' => relative,
        'producerSha256' => Digest::SHA256.file(real_path).hexdigest,
        'keyContext' => KEY_CONTEXT
      }
    end

    def valid_producer_identity?(identity, producer, spec)
      identity.is_a?(Hash) && identity == producer_identity(producer, spec)
    rescue ArgumentError, Errno::ENOENT
      false
    end

    def valid_signature?(data, signature)
      decoded = Base64.strict_decode64(signature)
      @public_key.verify(nil, decoded, JSON.generate(data))
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      false
    end
  end

  # Test-only authority. Receipts created here are permanently bound to
  # mode=test and use a test-derived Ed25519 key.
  class Signer < Verifier
    def initialize(secret:, root: ROOT, mode: 'test')
      raise ArgumentError, 'release receipt signing secret is empty' if secret.to_s.empty?
      raise ArgumentError, 'public release receipt authorities must use mode=test' unless mode.to_s == 'test'

      key = ReleaseReceiptSigner.ed25519_private_key(OpenSSL::HMAC.digest('SHA256', secret.to_s, "#{PRIVATE_KEY_CONTEXT}-test"))
      initialize_authority(private_key: key, mode: 'test', root: root)
    end

    def signed_payload(payload, producer:)
      data = normalize_payload(payload)
      spec = producer_spec(producer)
      validate_payload_type!(data, spec)
      data[TIMESTAMP_KEY] = Time.now.utc.iso8601
      data[AUTH_KEY] = producer_identity(producer, spec)
      data.delete(SIGNATURE_KEY)
      data[SIGNATURE_KEY] = Base64.strict_encode64(@private_key.sign(nil, JSON.generate(data)))
      data
    end

    def write(path, payload, producer:)
      data = signed_payload(payload, producer: producer)
      File.write(path, JSON.pretty_generate(data), encoding: Encoding::UTF_8)
      data
    end

    protected

    def initialize_authority(private_key:, mode:, root:)
      @private_key = private_key
      @public_key = OpenSSL::PKey.read(private_key.public_to_der)
      @mode = mode.to_s
      @root = File.realpath(root)
    end
  end

  class ProductionVerifier < Verifier
    def initialize(root: ROOT)
      super(public_key_der: [PUBLIC_KEY_DER_HEX].pack('H*'), mode: 'production', root: root)
    end
  end

  # The issuer is safe to expose because it has no production authority unless
  # constructed inside the worker entry point. Its command and destination are
  # selected exclusively from PRODUCERS; callers cannot submit a payload.
  class Issuer
    def initialize(authority:, root: ROOT, workspace_root: WORKSPACE_ROOT, runner: SANEMASTER_PATH,
                   ruby: RbConfig.ruby, environment: ENV.to_h)
      @authority = authority
      @root = File.realpath(root)
      @workspace_root = File.realpath(workspace_root)
      @runner = File.realpath(runner)
      @ruby = File.realpath(ruby)
      @environment = environment.to_h
    end

    def issue(producer, project_root, producer_args: [])
      spec = PRODUCERS.fetch(producer.to_s)
      project = File.realpath(project_root)
      raise ArgumentError, 'release receipt project escapes the SaneApps workspace' unless beneath?(project, @workspace_root)
      canonical_args = validate_producer_args!(spec, producer_args, project)

      destination = File.join(project, spec.fetch(:receipt))
      prepare_destination!(destination, project)
      # A previous passing receipt must stop authorizing as soon as a fresh
      # canonical run begins. If the producer crashes before emitting a
      # candidate, absence is fail-closed instead of preserving stale success.
      File.delete(destination) if File.exist?(destination)
      token = SecureRandom.hex(32)
      candidate_file = Tempfile.new('saneprocess-release-candidate')
      candidate_file.chmod(0o600)
      File.unlink(candidate_file.path)

      status = run_producer(spec, producer.to_s, project, destination, token, candidate_file, canonical_args)
      candidate_file.flush
      candidate_file.rewind
      raw = candidate_file.read(MAX_CANDIDATE_BYTES + 1).to_s
      if raw.empty?
        return status if !status.zero? || spec[:receipt_optional_on_success]

        raise 'canonical release producer returned success without a receipt candidate'
      end
      raise 'canonical release producer receipt candidate is too large' if raw.bytesize > MAX_CANDIDATE_BYTES

      payload = validate_candidate!(raw, producer.to_s, destination, token, status, spec)
      write_signed_atomic!(destination, payload, producer.to_s)
      status
    ensure
      candidate_file&.close
    end

    private

    def run_producer(spec, producer, project, destination, token, candidate_file, producer_args)
      env = ReleaseReceiptSigner.sanitized_environment(@environment).merge(
        CHILD_FD_ENV => CHILD_FD.to_s,
        CHILD_TOKEN_ENV => token,
        CHILD_PRODUCER_ENV => producer,
        CHILD_DESTINATION_ENV => destination,
        'SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT' => '1'
      )
      system(
        env, @ruby, @runner, spec.fetch(:command), *producer_args,
        CHILD_FD => candidate_file,
        chdir: project,
        unsetenv_others: true
      )
      $CHILD_STATUS&.exitstatus || 1
    end

    def validate_producer_args!(spec, args, project)
      tokens = Array(args).map(&:to_s)
      allowed = Array(spec[:option_flags])
      raise ArgumentError, 'this canonical release producer accepts no arguments' if allowed.empty? && tokens.any?

      validated = []
      seen = {}
      until tokens.empty?
        flag = tokens.shift
        value = tokens.shift
        raise ArgumentError, "unsupported canonical producer option: #{flag}" unless allowed.include?(flag)
        raise ArgumentError, "missing value for canonical producer option: #{flag}" if value.to_s.empty? || value.include?("\0")
        raise ArgumentError, "duplicate canonical producer option: #{flag}" if seen[flag]
        raise ArgumentError, 'App Store platform must be macos or ios' if flag == '--platform' && !%w[macos ios].include?(value)
        if flag == '--pkg' || Array(spec[:file_flags]).include?(flag)
          expanded_package = File.expand_path(value, project)
          metadata = File.lstat(expanded_package)
          raise ArgumentError, "#{flag} must be a regular non-symlink file" unless metadata.file? && !metadata.symlink?
          package = File.realpath(expanded_package)
          raise ArgumentError, "#{flag} path escapes the project" unless beneath?(package, project)
          value = package
        elsif Array(spec[:directory_flags]).include?(flag)
          expanded_directory = File.expand_path(value, project)
          metadata = File.lstat(expanded_directory)
          raise ArgumentError, "#{flag} must be a non-symlink directory" unless metadata.directory? && !metadata.symlink?
          directory = File.realpath(expanded_directory)
          raise ArgumentError, "#{flag} path escapes the project" unless beneath?(directory, project)
          value = directory
        elsif Array(spec[:url_flags]).include?(flag)
          uri = URI.parse(value)
          raise ArgumentError, "#{flag} must be an HTTPS URL" unless uri.is_a?(URI::HTTPS) && uri.host
        elsif flag != '--platform' && !value.match?(/\A[A-Za-z0-9._-]+\z/)
          raise ArgumentError, "invalid value for canonical producer option: #{flag}"
        end

        seen[flag] = true
        validated.concat([flag, value])
      end
      validated
    rescue Errno::ENOENT, Errno::EACCES
      raise ArgumentError, 'canonical producer input path must exist and be readable'
    end

    def validate_candidate!(raw, producer, destination, token, status, spec)
      envelope = JSON.parse(raw)
      raise 'release receipt candidate envelope is invalid' unless envelope.is_a?(Hash)
      raise 'release receipt candidate producer mismatch' unless envelope['producer'] == producer
      raise 'release receipt candidate destination mismatch' unless envelope['destination'] == destination
      raise 'release receipt candidate token mismatch' unless envelope['token'] == token

      payload = envelope['payload']
      raise 'release receipt candidate payload is invalid' unless payload.is_a?(Hash)
      raise 'release receipt candidate contains reserved authentication fields' if [AUTH_KEY, SIGNATURE_KEY, TIMESTAMP_KEY].any? { |key| payload.key?(key) }
      raise 'release receipt candidate type mismatch' unless payload['type'] == spec.fetch(:payload_type)
      expected_status = status.zero? ? 'passed' : 'failed'
      raise 'release receipt candidate status does not match producer exit status' unless payload['status'] == expected_status
      raise 'release receipt candidate issues must be an array' unless payload['issues'].is_a?(Array)
      raise 'passed release receipt candidate still contains issues' if status.zero? && payload['issues'].any?
      if payload.key?('issueCount') && payload['issueCount'] != payload['issues'].length
        raise 'release receipt candidate issue count mismatch'
      end

      payload
    rescue JSON::ParserError => e
      raise "release receipt candidate is not valid JSON: #{e.message}"
    end

    def write_signed_atomic!(destination, payload, producer)
      directory = File.dirname(destination)
      temporary = File.join(directory, ".#{File.basename(destination)}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")
      data = @authority.signed_payload(payload, producer: producer)
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(data))
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def prepare_destination!(destination, project)
      directory = File.dirname(destination)
      FileUtils.mkdir_p(directory, mode: 0o700)
      real_directory = File.realpath(directory)
      raise 'release receipt output directory escapes the project' unless beneath?(real_directory, project)
      if File.exist?(destination) || File.symlink?(destination)
        metadata = File.lstat(destination)
        raise 'release receipt destination must be a regular non-symlink file' unless metadata.file? && !metadata.symlink?
      end
    end

    def beneath?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end
  end

  module_function

  def production
    @production_verifier ||= ProductionVerifier.new
  end

  def test_signer(secret:, root: ROOT)
    Signer.new(secret: secret, root: root)
  end

  def ed25519_private_key(seed)
    raise ArgumentError, 'Ed25519 seed must be exactly 32 bytes' unless seed.to_s.bytesize == 32

    algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId('ED25519')])
    wrapped_seed = OpenSSL::ASN1::OctetString(seed).to_der
    private_key_info = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(0),
      algorithm,
      OpenSSL::ASN1::OctetString(wrapped_seed)
    ])
    OpenSSL::PKey.read(private_key_info.to_der)
  end

  def canonical_producer_child?(producer)
    expected_destination = File.join(File.realpath(Dir.pwd), PRODUCERS.fetch(producer.to_s).fetch(:receipt))
    ENV[CHILD_FD_ENV].to_s == CHILD_FD.to_s &&
      ENV[CHILD_TOKEN_ENV].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      ENV[CHILD_PRODUCER_ENV].to_s == producer.to_s &&
      ENV[CHILD_DESTINATION_ENV].to_s == expected_destination
  rescue ArgumentError, KeyError, Errno::ENOENT
    false
  end

  def write_canonical_candidate!(destination, payload, producer:)
    raise 'release receipt candidate write is only available inside the canonical producer child' unless canonical_producer_child?(producer)
    raise 'release receipt candidate destination mismatch' unless File.expand_path(destination) == ENV.fetch(CHILD_DESTINATION_ENV)

    envelope = {
      'producer' => producer.to_s,
      'destination' => ENV.fetch(CHILD_DESTINATION_ENV),
      'token' => ENV.fetch(CHILD_TOKEN_ENV),
      'payload' => JSON.parse(JSON.generate(payload))
    }
    encoded = JSON.generate(envelope)
    raise 'release receipt candidate is too large' if encoded.bytesize > MAX_CANDIDATE_BYTES

    io = IO.for_fd(Integer(ENV.fetch(CHILD_FD_ENV)), 'w', autoclose: false)
    io.write(encoded)
    io.flush
    true
  end

  def run_canonical_producer(producer, project_root: Dir.pwd, args: [])
    PRODUCERS.fetch(producer.to_s)
    success = system(
      worker_environment,
      File.realpath(RbConfig.ruby), WORKER_PATH, '--issue', producer.to_s, File.realpath(project_root), '--', *Array(args),
      unsetenv_others: true
    )
    $CHILD_STATUS&.exitstatus || (success ? 0 : 1)
  end

  def worker_environment
    sanitized_environment(ENV.to_h)
  end

  def sanitized_environment(environment)
    environment.to_h.reject do |key, _value|
      INTERNAL_ENV_KEYS.include?(key) || %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE].include?(key)
    end
  end

  def signing_host?(hostname = Socket.gethostname)
    hostname.to_s.match?(/(?:\Amini(?:\.|\z)|mac-mini)/i)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    operation = ARGV.shift
    raise ArgumentError, 'usage: release_receipt_signer.rb --issue PRODUCER PROJECT -- [PRODUCER_ARGS]' unless operation == '--issue'
    producer = ARGV.shift
    target = ARGV.shift
    separator = ARGV.shift
    raise ArgumentError, 'unexpected release receipt worker arguments' unless producer && target && separator == '--'
    producer_args = ARGV.dup
    raise 'production release receipt issuance is Mini-only' unless ReleaseReceiptSigner.signing_host?

    keychain_secret = lambda do
      output, status = Open3.capture2(
        ReleaseReceiptSigner::SECURITY_ENV,
        ReleaseReceiptSigner::SECURITY_BIN, 'find-generic-password',
        '-s', ReleaseReceiptSigner::KEYCHAIN_SERVICE,
        '-a', ReleaseReceiptSigner::KEYCHAIN_ACCOUNT,
        '-w',
        err: File::NULL,
        unsetenv_others: true
      )
      value = output.to_s.strip
      status.success? && !value.empty? ? value : nil
    rescue StandardError
      nil
    end

    legacy_secret = lambda do
      metadata = File.lstat(ReleaseReceiptSigner::LEGACY_SECRET_FILE)
      next nil unless metadata.file? && !metadata.symlink?
      next nil unless metadata.uid == Process.uid && (metadata.mode & 0o077).zero?

      value = File.read(ReleaseReceiptSigner::LEGACY_SECRET_FILE, encoding: Encoding::UTF_8).strip
      value.empty? ? nil : value
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    base_secret = keychain_secret.call || legacy_secret.call
    raise 'release authorization key is unavailable' if base_secret.to_s.empty?

    seed = OpenSSL::HMAC.digest('SHA256', base_secret, ReleaseReceiptSigner::PRIVATE_KEY_CONTEXT)
    private_key = ReleaseReceiptSigner.ed25519_private_key(seed)
    unless private_key.public_to_der.unpack1('H*') == ReleaseReceiptSigner::PUBLIC_KEY_DER_HEX
      raise 'release authorization private key does not match the pinned verification key'
    end
    production_authority_class = Class.new(ReleaseReceiptSigner::Signer) do
      define_method(:initialize) do |worker_private_key, root|
        initialize_authority(private_key: worker_private_key, mode: 'production', root: root)
      end
    end
    authority = production_authority_class.new(private_key, ReleaseReceiptSigner::ROOT)

    issuer = ReleaseReceiptSigner::Issuer.new(authority: authority)
    exit issuer.issue(producer, target, producer_args: producer_args)
  rescue ArgumentError, KeyError, JSON::ParserError, RuntimeError, SystemCallError => e
    warn "Release receipt worker failed: #{e.message}"
    exit 2
  end
end
