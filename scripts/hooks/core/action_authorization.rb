# frozen_string_literal: true
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'openssl'
require 'open3'
require 'shellwords'
require 'socket'
require 'time'
require_relative '../../sanemaster/source_fingerprint'
# Exact, short-lived authorization for consequential agent actions. This module
# verifies independently issued receipts; it intentionally exposes no signer.
module SaneActionAuthorization
  ALLOW = 'ALLOW'
  REVIEW_REQUIRED = 'REVIEW_REQUIRED'
  USER_CONFIRM = 'USER_CONFIRM'
  HARD_DENY = 'HARD_DENY'
  SCHEMA_VERSION = 1
  PRODUCER = 'saneprocess.independent_action_review.v1'
  PRODUCER_SCHEMA = 1
  PRODUCER_SHA256 = Digest::SHA256.hexdigest('saneprocess-independent-action-review-v1').freeze
  KEY_CONTEXT = 'saneprocess-action-authorization-v1-ed25519'
  # Independent action authority pin. Its private key is not present in the
  # executor environment. Until a separate constrained reviewer is provisioned
  # with its own replacement key/pin, REVIEW_REQUIRED deliberately fails closed.
  PUBLIC_KEY_DER_HEX =
    '302a300506032b65700321000a4646531cab8c46bf988da2ab8f56e494f9ab94069b837d05bdeab687243054'
  MAX_RECEIPT_BYTES = 128 * 1024
  MAX_LIFETIME_SECONDS = 15 * 60
  MAX_FUTURE_SKEW_SECONDS = 30
  MAX_DEPTH = 4
  SHELLS = %w[sh bash zsh].freeze
  WRAPPERS = %w[env sudo command builtin time].freeze
  WRAPPER_OPTIONS_WITH_VALUE = {
    'env' => %w[-u --unset -C --chdir -S --split-string],
    'sudo' => %w[-u --user -g --group -h --host -p --prompt -R --chroot -D --directory -C --close-from]
  }.freeze
  SSH_OPTIONS_WITH_VALUE = %w[-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w].freeze
  ENVELOPE_KEYS = %w[
    operation target tool method host account project body_or_file_sha256
    source_fingerprint session issued_at expires_at nonce max_uses
  ].freeze
  ACTION_KEYS = ENVELOPE_KEYS - %w[issued_at expires_at nonce max_uses]
  TOP_LEVEL_KEYS = %w[schema_version producer decision classification envelope signature].freeze
  PRODUCER_KEYS = %w[id schema source_sha256 key_context].freeze
  Decision = Struct.new(:classification, :operation, :method, :reason, keyword_init: true)
  Result = Struct.new(:allowed, :classification, :message, :envelope, keyword_init: true)
  GateResult = Struct.new(:approved, :message, keyword_init: true)
  class PolicyError < StandardError; end
  # Fixed provider adapter pinned to the SaneMaster-managed Mini/Air install.
  # The executor cannot select a gate via environment variables or tool input.
  class CanonicalGate
    AUTOMIC_VAULT_PATH = File.expand_path('~/.sanemaster/tools/automic-vault/1.18.2/av')
    AUTOMIC_VAULT_SHA256 = '8d71941dd49210e194e591a1fa1c5840b1b15c358113c2c99b7bb3a0c1009c02'
    def self.production
      new(path: AUTOMIC_VAULT_PATH, sha256: AUTOMIC_VAULT_SHA256)
    end
    def initialize(path:, sha256:, runner: Open3.method(:capture3))
      @path = path
      @sha256 = sha256
      @runner = runner
    end
    def approve(action_digest:, envelope: {})
      return GateResult.new(approved: false, message: 'canonical independent gate is not provisioned') unless @sha256.to_s.match?(/\A[0-9a-f]{64}\z/)
      stat = File.lstat(@path)
      return GateResult.new(approved: false, message: 'canonical gate executable is not a regular non-symlink file') unless stat.file? && !stat.symlink?
      return GateResult.new(approved: false, message: 'canonical gate executable path is not canonical') unless File.realpath(@path) == File.expand_path(@path)
      return GateResult.new(approved: false, message: 'canonical gate executable permissions are unsafe') unless (stat.mode & 0o022).zero? && File.executable?(@path)
      return GateResult.new(approved: false, message: 'canonical gate executable hash mismatch') unless Digest::SHA256.file(@path).hexdigest == @sha256
      summary = [envelope['operation'], envelope['tool'], envelope['method'], File.basename(envelope['project'].to_s)].compact.reject(&:empty?).join(' / ')
      summary = 'reviewed action' if summary.empty?
      target = envelope['target'].to_s
                       .gsub(/(?<=\s)(?:-w|--password|--token|--secret|--key)\s+\S+/i, '[REDACTED]')
                       .gsub(/--(?:password|token|secret|key)=\S+/i, '[REDACTED]')
                       .gsub(/[[:cntrl:]]/, ' ')[0, 240]
      context = "target=#{target.inspect} account=#{envelope['account']} body_sha256=#{envelope['body_or_file_sha256']}"
      _out, _err, status = @runner.call(@path, 'gate', "Authorize #{summary}: #{context} (action #{action_digest})")
      GateResult.new(approved: status.success?, message: status.success? ? 'canonical gate approved' : 'canonical gate denied')
    rescue Errno::ENOENT
      GateResult.new(approved: false, message: 'canonical independent gate is not installed')
    rescue StandardError => e
      GateResult.new(approved: false, message: "canonical gate failed closed: #{e.class}")
    end
  end
  class Authorizer
    def initialize(root: default_root, public_key_der: [PUBLIC_KEY_DER_HEX].pack('H*'),
                   producer_sha256: PRODUCER_SHA256, now: -> { Time.now.utc },
                   source_fingerprint: nil, hostname: Socket.gethostname,
                   gate: CanonicalGate.production)
      @root = File.expand_path(root)
      @public_key = OpenSSL::PKey.read(public_key_der)
      @producer_sha256 = producer_sha256
      @now = now
      @source_fingerprint = source_fingerprint
      @hostname = hostname
      @gate = gate
    end
    def evaluate(payload_json, hard_deny: false)
      payload = parse_payload(payload_json)
      return denied(HARD_DENY, 'manual user-only catastrophic boundary') if hard_deny
      decision = classify(payload)
      return Result.new(allowed: true, classification: ALLOW, message: 'routine action allowed') if decision.classification == ALLOW
      if decision.classification == USER_CONFIRM
        action = action_fields(payload, decision)
        action_digest = Digest::SHA256.hexdigest(JSON.generate(action))
        gate_result = @gate.approve(action_digest: action_digest, envelope: action)
        return denied(USER_CONFIRM, gate_result.message, action) unless gate_result.approved
        return Result.new(allowed: true, classification: USER_CONFIRM, message: 'manual canonical gate approved', envelope: action)
      end
      action = action_fields(payload, decision)
      receipt_path = receipt_path_for(action)
      receipt_record = read_secure_receipt(receipt_path)
      return denied(REVIEW_REQUIRED, review_route(action, receipt_path), action) unless receipt_record
      envelope = validate_receipt(receipt_record.fetch(:data), action)
      action_digest = Digest::SHA256.hexdigest(JSON.generate(action))
      gate_result = @gate.approve(action_digest: action_digest, envelope: envelope)
      return denied(REVIEW_REQUIRED, gate_result.message, envelope) unless gate_result.approved
      consume_nonce!(envelope.fetch('nonce'), receipt_record.fetch(:sha256), envelope)
      Result.new(allowed: true, classification: REVIEW_REQUIRED, message: 'independent one-time review accepted', envelope: envelope)
    rescue JSON::ParserError, PolicyError, KeyError, ArgumentError, TypeError, OpenSSL::PKey::PKeyError => e
      denied(REVIEW_REQUIRED, "authorization failed closed: #{e.message}")
    rescue StandardError => e
      denied(REVIEW_REQUIRED, "authorization failed closed: #{e.class}")
    end
    def classify(payload)
      tool = payload.fetch('tool_name')
      input = payload.fetch('tool_input')
      return classify_command(input.fetch('command').to_s) if tool == 'Bash'
      name = tool.to_s.downcase
      return Decision.new(classification: USER_CONFIRM, operation: 'permission_or_credential_change', method: tool, reason: name) if name.match?(/permission|credential|secret|token|role|owner/)
      return Decision.new(classification: REVIEW_REQUIRED, operation: 'external_mutation', method: tool, reason: name) if name.match?(/send|submit|publish|deploy|upload|merge|delete|destroy|update|create/)
      Decision.new(classification: ALLOW, operation: 'routine_tool', method: tool, reason: name)
    end
    def receipt_path(payload_json)
      authorization_request(payload_json).fetch('receipt_path')
    end
    def authorization_request(payload_json)
      payload = parse_payload(payload_json)
      decision = classify(payload)
      raise PolicyError, 'action does not use an independent review receipt' unless decision.classification == REVIEW_REQUIRED
      action = action_fields(payload, decision)
      { 'classification' => decision.classification, 'action' => action, 'receipt_path' => receipt_path_for(action) }
    end
    private
    def self.default_root
      File.expand_path('~/.config/saneprocess/action-authorizations')
    end
    def default_root
      self.class.default_root
    end
    def parse_payload(raw)
      data = JSON.parse(raw.to_s)
      raise PolicyError, 'hook payload must be an object' unless data.is_a?(Hash)
      raise PolicyError, 'tool_name is missing' if data['tool_name'].to_s.empty?
      raise PolicyError, 'tool_input must be an object' unless data['tool_input'].is_a?(Hash)

      data
    end
    def classify_command(command, depth = 0)
      raise PolicyError, 'shell nesting exceeds inspection limit' if depth > MAX_DEPTH
      return Decision.new(classification: ALLOW, operation: 'shell_noop', method: 'shell', reason: 'empty') if command.strip.empty?

      decisions = split_shell_segments(command).map do |segment|
        tokens = Shellwords.shellsplit(segment)
        raise PolicyError, 'shell command cannot be tokenized' if tokens.empty?

        classify_segment(tokens, depth)
      end
      decisions.max_by { |item| classification_rank(item.classification) }
    rescue ArgumentError => e
      raise PolicyError, "malformed shell command: #{e.message}"
    end
    def split_shell_segments(text)
      segments = []
      current = +''
      quote = nil
      escaped = false
      index = 0
      while index < text.length
        char = text[index]
        if escaped
          current << char
          escaped = false
        elsif char == '\\' && quote != "'"
          current << char
          escaped = true
        elsif quote
          current << char
          quote = nil if char == quote
        elsif char == "'" || char == '"'
          current << char
          quote = char
        elsif char == ';' || char == "\n" || %w[| & ( ) { } `].include?(char)
          segments << current.strip unless current.strip.empty?
          current = +''
          index += 1 if (char == '|' && text[index + 1] == '|') || (char == '&' && text[index + 1] == '&')
        else
          current << char
        end
        index += 1
      end
      segments << current.strip unless current.strip.empty?
      segments
    end

    def classify_segment(tokens, depth)
      index = command_index(tokens)
      base = File.basename(tokens[index].to_s)
      args = tokens[(index + 1)..] || []
      nested = nested_commands(base, args)
      nested_decision = nested.map { |command| classify_command(command, depth + 1) }
                              .max_by { |item| classification_rank(item.classification) }
      direct = direct_decision(base, args)
      [direct, nested_decision].compact.max_by { |item| classification_rank(item.classification) }
    end
    def command_index(tokens)
      index = 0
      while index < tokens.length
        token = tokens[index].to_s
        if token.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
          index += 1
          next
        end
        break unless WRAPPERS.include?(File.basename(token))
        wrapper = File.basename(token)
        index += 1
        while tokens[index].to_s.start_with?('-')
          option = tokens[index].to_s
          index += WRAPPER_OPTIONS_WITH_VALUE.fetch(wrapper, []).include?(option) ? 2 : 1
        end
      end
      raise PolicyError, 'shell command has no executable' if index >= tokens.length
      index
    end
    def nested_commands(base, args)
      if SHELLS.include?(base)
        index = args.index { |arg| arg == '-c' || arg.match?(/\A-[^-]*c/) }
        return [args[index + 1]] if index && args[index + 1]
        script = args.index { |arg| !arg.start_with?('-') }
        return script ? [args[script..].join(' ')] : []
      end
      if %w[ruby python python3 node].include?(base)
        script = args.index { |arg| !arg.start_with?('-') }
        return script ? [args[script..].join(' ')] : []
      end
      return [args.drop(1).join(' ')] if base == 'bundle' && args.first == 'exec' && args[1]
      return [] unless base == 'ssh'
      cursor = 0
      while args[cursor]&.start_with?('-')
        option = args[cursor]
        cursor += SSH_OPTIONS_WITH_VALUE.include?(option) ? 2 : 1
      end
      cursor += 1 # host
      args[cursor] ? [args[cursor..].join(' ')] : []
    end
    def direct_decision(base, args)
      joined = args.join(' ')
      user_confirm =
        base == 'tccutil' ||
        (base == 'security' && args.first.to_s.match?(/\A(?:add|delete|set)-/)) ||
        (base == 'profiles' && joined.match?(/\b(?:install|remove)\b/)) ||
        (base == 'launchctl' && %w[bootstrap bootout enable disable].include?(args.first)) ||
        (%w[chmod chown].include?(base) && joined.match?(/(?:777|a\+rwx|root(?::|\s))/))
      return Decision.new(classification: USER_CONFIRM, operation: 'permission_or_credential_change', method: "#{base}.#{args.first}", reason: joined) if user_confirm
      method = http_method(args) if %w[curl http wget].include?(base)
      git_operation = git_subcommand(args) if base == 'git'
      review_operation =
        if method && method != 'GET' && method != 'HEAD' then 'external_http_mutation'
        elsif base == 'git' && git_operation == 'push' then 'external_git_push'
        elsif base == 'gh' && joined.match?(/\b(?:merge|create|comment|edit|close|reopen|delete)\b/) then 'github_mutation'
        elsif base == 'wrangler' && joined.match?(/\b(?:deploy|publish|secret put|pages deploy|d1 execute)\b/) then 'cloud_mutation'
        elsif %w[aws gcloud].include?(base) && joined.match?(/\b(?:cp|sync|deploy|submit|upload|publish|put)\b/) then 'cloud_mutation'
        elsif %w[npm gem].include?(base) && args.first == 'publish' then 'package_publish'
        elsif base == 'xcrun' && joined.match?(/\b(?:altool|notarytool)\b.*\b(?:upload|submit)\b/) then 'store_upload'
        elsif %w[release.sh appstore_submit appstore_submit.rb].include?(base) && joined.match?(/(?:\A|\s)(?:--deploy|submit|upload)\b/) then 'release_or_store_mutation'
        end
      action_method = base == 'git' ? "git.#{git_operation}" : (method || "#{base}.#{args.first}")
      return Decision.new(classification: REVIEW_REQUIRED, operation: review_operation, method: action_method, reason: joined) if review_operation
      Decision.new(classification: ALLOW, operation: 'routine_shell', method: "#{base}.#{args.first}", reason: joined)
    end

    def http_method(args)
      verb = args.find { |arg| arg.match?(/\A(?:GET|HEAD|POST|PUT|PATCH|DELETE)\z/i) }
      return verb.upcase if verb
      args.each_with_index do |arg, index|
        return args[index + 1].to_s.upcase if %w[-X --request].include?(arg)
        return Regexp.last_match(1).upcase if arg.match?(/\A-X(\w+)\z/i)
        return Regexp.last_match(1).upcase if arg.match?(/\A--(?:request|method)=(\w+)\z/i)
      end
      return 'PUT' if args.any? { |arg| arg == '-T' || arg.start_with?('--upload-file') }
      args.any? { |arg| arg.match?(/\A-(?:d|F).+/) || %w[-d -F --form --post-data --post-file].include?(arg) || arg.match?(/\A--(?:data|form|post-data|post-file)/) } ? 'POST' : 'GET'
    end

    def git_subcommand(args)
      index = 0
      while args[index].to_s.start_with?('-')
        option = args[index].to_s
        index += %w[-C -c --git-dir --work-tree --namespace].include?(option) ? 2 : 1
      end
      args[index].to_s
    end

    def classification_rank(classification)
      { ALLOW => 0, REVIEW_REQUIRED => 1, USER_CONFIRM => 2, HARD_DENY => 3 }.fetch(classification)
    end

    def action_fields(payload, decision)
      input = payload.fetch('tool_input')
      cwd = input['cwd'] || payload['cwd'] || Dir.pwd
      project = File.realpath(cwd)
      source = @source_fingerprint ? @source_fingerprint.call(project) : SaneSourceFingerprint.release_status_source_fingerprint(project)
      raise PolicyError, 'source fingerprint unavailable' unless source.to_s.match?(/\A[0-9a-f]{64}\z/)

      target = payload['tool_name'] == 'Bash' ? input.fetch('command').to_s : JSON.generate(input)
      {
        'operation' => decision.operation,
        'target' => target,
        'tool' => payload.fetch('tool_name'),
        'method' => decision.method.to_s,
        'host' => @hostname.to_s,
        'account' => (input['account'] || input['account_id'] || '').to_s,
        'project' => project,
        'body_or_file_sha256' => body_or_file_sha256(input, project),
        'source_fingerprint' => source,
        'session' => session_id(payload)
      }
    rescue Errno::ENOENT
      raise PolicyError, 'project path does not exist'
    end

    def body_or_file_sha256(input, project)
      %w[file file_path body_file package pkg attachment].each do |key|
        next unless input[key]
        path = File.expand_path(input[key].to_s, project)
        stat = File.lstat(path)
        return Digest::SHA256.file(path).hexdigest if stat.file? && !stat.symlink?
      rescue Errno::ENOENT
        raise PolicyError, "bound file does not exist: #{key}"
      end
      return Digest::SHA256.hexdigest(input['body'].to_s) if input.key?('body')

      if input['command']
        paths = bound_file_paths(input['command'].to_s, project)
        unless paths.empty?
          digest = Digest::SHA256.new
          paths.sort.each do |path|
            stat = File.lstat(path)
            raise PolicyError, "bound file is not a regular non-symlink file: #{path}" unless stat.file? && !stat.symlink?

            digest.update(path)
            digest.update("\0")
            digest.update(Digest::SHA256.file(path).hexdigest)
            digest.update("\0")
          end
          return digest.hexdigest
        end
      end

      Digest::SHA256.hexdigest(JSON.generate(input))
    end

    def bound_file_paths(command, project)
      tokens = Shellwords.shellsplit(command)
      flags = %w[-f --file --body-file --package --pkg --attachment --data-binary]
      paths = []
      tokens.each_with_index do |token, index|
        candidate = if flags.include?(token)
                      tokens[index + 1]
                    elsif token.match?(/\A--(?:file|body-file|package|pkg|attachment|data-binary)=(.+)\z/)
                      Regexp.last_match(1)
                    end
        next unless candidate

        candidate = candidate.delete_prefix('@')
        path = File.expand_path(candidate, project)
        raise PolicyError, "bound file does not exist: #{candidate}" unless File.exist?(path) || File.symlink?(path)

        paths << path
      end
      paths.uniq
    rescue ArgumentError => e
      raise PolicyError, "malformed shell command: #{e.message}"
    end

    def session_id(payload)
      value = payload['session_id'] || ENV['CLAUDE_SESSION_ID'] || ENV['CODEX_THREAD_ID']
      value = "ppid:#{Process.ppid}" if value.to_s.empty?
      value.to_s
    end

    def receipt_path_for(action)
      File.join(@root, "#{Digest::SHA256.hexdigest(JSON.generate(action))}.json")
    end

    def read_secure_receipt(path)
      secure_directory!(@root, 0o700)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise PolicyError, 'receipt must be a regular non-symlink file' unless stat.file?
        raise PolicyError, 'receipt owner does not match executor uid' unless stat.uid == Process.uid
        raise PolicyError, 'receipt mode must be 0600' unless (stat.mode & 0o777) == 0o600
        raise PolicyError, 'receipt is too large' if stat.size > MAX_RECEIPT_BYTES

        raw = file.read(MAX_RECEIPT_BYTES + 1).to_s
        raise PolicyError, 'receipt is too large' if raw.bytesize > MAX_RECEIPT_BYTES

        { data: JSON.parse(raw), sha256: Digest::SHA256.hexdigest(raw) }
      end
    rescue Errno::ENOENT
      nil
    rescue Errno::ELOOP
      raise PolicyError, 'receipt must be a regular non-symlink file'
    end

    def secure_directory!(path, mode)
      stat = File.lstat(path)
      raise PolicyError, 'authorization directory must not be a symlink' if stat.symlink?
      raise PolicyError, 'authorization directory is not a directory' unless stat.directory?
      raise PolicyError, 'authorization directory owner mismatch' unless stat.uid == Process.uid
      raise PolicyError, format('authorization directory mode must be %04o', mode) unless (stat.mode & 0o777) == mode
      raise PolicyError, 'authorization directory path is not canonical' unless File.realpath(path) == File.expand_path(path)
    rescue Errno::ENOENT
      raise PolicyError, 'independent authorization directory is not installed'
    end

    def validate_receipt(receipt, action)
      raise PolicyError, 'receipt must be an object' unless receipt.is_a?(Hash)
      raise PolicyError, 'receipt schema keys mismatch' unless receipt.keys.sort == TOP_LEVEL_KEYS.sort
      raise PolicyError, 'receipt schema version mismatch' unless receipt['schema_version'] == SCHEMA_VERSION
      raise PolicyError, 'receipt decision must be permit' unless receipt['decision'] == 'permit'
      raise PolicyError, 'receipt classification mismatch' unless receipt['classification'] == REVIEW_REQUIRED
      validate_producer!(receipt.fetch('producer'))

      envelope = receipt.fetch('envelope')
      raise PolicyError, 'action envelope keys mismatch' unless envelope.is_a?(Hash) && envelope.keys.sort == ENVELOPE_KEYS.sort
      ACTION_KEYS.each { |key| raise PolicyError, "action envelope #{key} mismatch" unless envelope[key] == action[key] }
      validate_time_and_nonce!(envelope)
      verify_signature!(receipt)
      envelope
    end

    def validate_producer!(producer)
      expected = {
        'id' => PRODUCER, 'schema' => PRODUCER_SCHEMA,
        'source_sha256' => @producer_sha256, 'key_context' => KEY_CONTEXT
      }
      raise PolicyError, 'receipt producer is not trusted' unless producer.is_a?(Hash) && producer.keys.sort == PRODUCER_KEYS.sort && producer == expected
    end

    def validate_time_and_nonce!(envelope)
      issued = Time.iso8601(envelope.fetch('issued_at'))
      expires = Time.iso8601(envelope.fetch('expires_at'))
      now = @now.call.utc
      raise PolicyError, 'receipt issued in the future' if issued > now + MAX_FUTURE_SKEW_SECONDS
      raise PolicyError, 'receipt expired' if expires <= now
      raise PolicyError, 'receipt lifetime exceeds policy' if expires <= issued || expires - issued > MAX_LIFETIME_SECONDS
      raise PolicyError, 'receipt nonce is invalid' unless envelope['nonce'].to_s.match?(/\A[0-9a-f]{32,128}\z/)
      raise PolicyError, 'receipt max_uses must be one' unless envelope['max_uses'] == 1
    rescue ArgumentError
      raise PolicyError, 'receipt time is invalid'
    end

    def verify_signature!(receipt)
      signature = Base64.strict_decode64(receipt.fetch('signature'))
      unsigned = receipt.reject { |key, _value| key == 'signature' }
      raise PolicyError, 'receipt signature is invalid' unless @public_key.verify(nil, signature, JSON.generate(unsigned))
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      raise PolicyError, 'receipt signature is invalid'
    end

    def consume_nonce!(nonce, receipt_sha256, envelope)
      consumed = File.join(@root, 'consumed')
      Dir.mkdir(consumed, 0o700) unless File.exist?(consumed)
      secure_directory!(consumed, 0o700)
      path = File.join(consumed, nonce)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.chmod(0o600)
        file.write(JSON.generate('receipt_sha256' => receipt_sha256,
                                 'expires_at' => envelope.fetch('expires_at')))
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      raise PolicyError, 'receipt nonce already consumed'
    end

    def review_route(action, path)
      digest = Digest::SHA256.hexdigest(JSON.generate(action))
      "independent review receipt required; action_digest=#{digest}; canonical_receipt=#{path}"
    end

    def denied(classification, message, envelope = nil)
      Result.new(allowed: false, classification: classification, message: message, envelope: envelope)
    end
  end
end
