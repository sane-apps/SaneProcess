# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'shellwords'
require 'time'
require 'tmpdir'

module MandatoryWorkflows
  CANONICAL_GPT_AUDIT = File.expand_path('../../automation/gpt_audit.py', __dir__).freeze
  TRUSTED_PYTHON_LAUNCHER = '/Applications/Xcode.app/Contents/Developer/usr/bin/python3'
  CODEX_REQUIREMENT = '=identifier "codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'
  WORKFLOWS = {
    sane_audit: {
      patterns: [
        /\bsaneapps\s+audit\b/i,
        /\bfull\s+saneapps\s+audit\b/i,
        /\baudit\s+the\s+app\b/i,
        /\baudit\b.*\b(?:past|historical)\b.*\b(?:issues?|github|support)\b/i,
        /\broot[- ]cause\b.*\brecurring\s+issues?\b/i,
        /\brecurring\s+issues?\b.*\baudit\b/i
      ],
      requires_subagents: true,
      min_subagents: 9,
      description: 'SaneApps audit using completed native Task reviews or authoritative read-only Codex fan-out receipts'
    },
    docs_audit: {
      patterns: [
        /\b(docs[- ]?audit|\/docs-audit)\b/i,
        /\baudit\b.*\b(docs|documentation)\b/i,
        /\bdocumentation\s+audit\b/i,
        /\b14[- ]?perspective\b/i,
        /\bfull\s+audit\b/i
      ],
      requires_subagents: true,
      min_subagents: 5,
      description: 'Documentation audit using completed native Task reviews or authoritative read-only Codex fan-out receipts'
    },
    evolve: {
      patterns: [
        /\b(evolve|\/evolve)\b/i,
        /\bupdate\s+(tools|dependencies|mcps?)\b/i,
        /\bcheck\s+for\s+updates\b/i,
        /\b(missing|lack|need)\s+(a\s+)?tool\b/i,
        /\bhunting\s+around\s+for\s+tools?\b/i,
        /\bbest\s+tools?\b/i,
        /\b(part\s+of\s+(our\s+)?)?sop\b.*\b(tools?|tooling)\b/i,
        /\b(tools?|tooling)\b.*\b(enforced|enforce)\b/i,
        /\bcanonical\s+tool\b/i,
        /\bstandard\s+tool\s+path\b/i,
        /\bdo\s+we\s+already\s+have\b/i,
        /\binstall\s+(the\s+)?tool\b/i
      ],
      requires_runner: true,
      description: 'Tool discovery, upgrade, and gap check',
      runner_command: 'ruby scripts/SaneMaster.rb tool_discovery --query "..."',
      runner_patterns: [
        %r{SaneMaster\.rb\s+(?:tool_discovery|tool_receipt)\b}i,
        %r{scripts/automation/tool_discovery_receipt\.rb}i
      ]
    },
    status: {
      patterns: [
        %r{(?:^|\s)/status\b}i,
        /\b(run|check|project)\s+status\b/i,
        /\bwhat(?:'s| is)\s+the\s+status\b/i,
        /\bhealth\s+check\b/i
      ],
      requires_runner: true,
      description: 'Live status cross-reference workflow',
      runner_command: 'ruby scripts/SaneMaster.rb status',
      runner_patterns: [
        %r{SaneMaster\.rb\s+status\b}i
      ]
    },
    verify: {
      patterns: [
        %r{(?:^|\s)/verify\b}i,
        /\bverify(?:\s+(?:this|the|that|current))?(?:\s+(?:project|app|repo|changes|build))?\b/i,
        /\bdoes\s+it\s+build\b/i,
        /\brun\s+(?:the\s+)?(?:verify|verification|checks?)\b/i
      ],
      requires_runner: true,
      description: 'Canonical build and test workflow',
      runner_command: 'ruby scripts/SaneMaster.rb verify',
      runner_patterns: [
        %r{SaneMaster\.rb\s+verify\b}i
      ]
    },
    ship: {
      patterns: [
        %r{(?:^|\s)/ship\b}i,
        /\bship\s+it\b/i,
        /\bprepare\s+for\s+release\b/i,
        /\bready\s+to\s+ship\b/i,
        /\brelease\s+(?:readiness|preflight|check)\b/i
      ],
      requires_runner: true,
      description: 'Release-readiness workflow',
      runner_command: 'ruby scripts/SaneMaster.rb release_preflight',
      runner_patterns: [
        %r{SaneMaster\.rb\s+release_preflight\b}i
      ]
    },
    check_inbox: {
      patterns: [
        %r{(?:^|\s)/(?:check-inbox|check_inbox)\b}i,
        /\bcheck\s+(?:the\s+)?inbox\b/i,
        /\bsupport\s+inbox\b/i,
        /\bcustomer\s+emails?\b/i,
        /\breply\s+to\s+customer\b/i
      ],
      requires_runner: true,
      description: 'Support inbox workflow',
      runner_command: 'ruby scripts/SaneMaster.rb check_inbox',
      runner_patterns: [
        %r{SaneMaster\.rb\s+check_inbox\b}i
      ]
    },
    outreach: {
      patterns: [
        /\b(outreach|\/outreach)\b/i,
        /\bcompetitor\s+(monitoring|analysis)\b/i,
        /\bgithub\s+opportunities\b/i
      ],
      description: 'GitHub competitor monitoring'
    }
  }.freeze

  def self.skill_triggers
    WORKFLOWS.transform_values do |config|
      {
        patterns: config[:patterns],
        requires_subagents: config[:requires_subagents],
        min_subagents: config[:min_subagents] || 0,
        description: config[:description]
      }
    end
  end

  def self.skill_requirements
    WORKFLOWS.transform_values do |config|
      {
        min_subagents: config[:min_subagents] || 0,
        requires_runner: config[:requires_runner] || false,
        description: config[:description],
        runner_command: config[:runner_command]
      }
    end
  end

  def self.runner_patterns_for(name)
    Array(WORKFLOWS.dig(name.to_sym, :runner_patterns))
  end

  def self.runner_command_for(name)
    WORKFLOWS.dig(name.to_sym, :runner_command)
  end

  def self.codex_review_evidence(command, response, since: nil)
    return [] unless successful_bash_response?(response)
    normalized_command = normalized_shell_command(command)
    return [] unless normalized_command

    gpt_audit_manifest_evidence(normalized_command, response, since: since)
  rescue ArgumentError, TypeError, JSON::ParserError, Errno::ENOENT, Errno::EACCES
    []
  end

  def self.successful_bash_response?(response)
    return false unless response.is_a?(Hash)
    return false unless (response['error'] || response[:error]).to_s.strip.empty?
    return false if response['interrupted'] == true || response[:interrupted] == true

    status = (response['status'] || response[:status]).to_s.downcase
    return false if %w[started running pending queued].include?(status)
    return false unless response.key?('exit_code') || response.key?(:exit_code)

    (response['exit_code'] || response[:exit_code]).to_i.zero?
  end

  def self.gpt_audit_manifest_evidence(command, response, since: nil)
    tokens = Shellwords.shellsplit(command.to_s)
    return [] unless canonical_gpt_audit_command?(tokens)

    output = response['output'] || response[:output] || response['stdout'] || response[:stdout]
    receipt_match = output.to_s.lines.map do |line|
      line.match(/\ACODEX_FANOUT_RECEIPT=(\S+) CODEX_FANOUT_NONCE=([0-9a-f]{32}) CODEX_FANOUT_COMMAND_SHA256=([0-9a-f]{64})\s*\z/)
    end.compact.last
    return [] unless receipt_match
    receipt, receipt_nonce, receipt_command_digest = receipt_match.captures
    return [] unless nonempty_file?(receipt, since: since)

    manifest = JSON.parse(File.read(receipt))
    runner = manifest['runner'] || {}
    execution = manifest['execution'] || {}
    summary = manifest['summary'] || {}
    results = Array(manifest['results'])
    return [] unless canonical_realpath?(runner['path']) && runner['schema_version'] == 4
    return [] unless valid_invocation_binding?(manifest['invocation'], tokens, receipt_nonce, receipt_command_digest)
    return [] unless manifest['backend'] == 'codex-exec'
    return [] unless execution['command_mode'] == 'codex exec --ephemeral'
    return [] unless execution['read_only'] == true && execution['isolated_user_config'] == true
    return [] unless execution['allow_partial'] == false && execution['codex_bin_override'] == false
    return [] unless execution['testing_mode'] == false
    return [] unless authoritative_summary?(summary, results)
    return [] unless manifest.dig('synthesis', 'status') == 'succeeded'
    return [] unless fresh_manifest?(manifest, receipt, since)
    return [] unless valid_manifest_inputs?(manifest, results)
    return [] unless valid_codex_binary?(execution['codex_binary'])
    return [] unless valid_report?(manifest, receipt)

    names = results.map { |result| result['name'].to_s }
    return [] if names.any?(&:empty?) || names.uniq.length != names.length

    artifacts = results.map { |result| artifact_realpath(result['output_path']) }
    return [] if artifacts.any?(&:nil?) || artifacts.uniq.length != artifacts.length

    source_fingerprint = manifest.dig('inputs', 'repo_source', 'sha256').to_s
    results.each_with_index.map do |result, index|
      next unless result['ok'] == true && result['read_only'] == true
      next unless result['isolated_user_config'] == true
      next unless result['command_mode'] == 'codex exec --ephemeral' && result['output_nonempty'] == true
      next unless nonempty_file?(result['output_path'], since: since)
      next unless File.dirname(artifacts[index]) == File.dirname(File.realpath(receipt))
      next unless artifact_fresh_for_manifest?(artifacts[index], manifest)
      next unless valid_artifact_digest?(artifacts[index], result['output_sha256'])

      artifact = artifacts[index]
      identity = [File.realpath(receipt), source_fingerprint, result['name'], artifact].join("\0")
      {
        fingerprint: Digest::SHA256.hexdigest("manifest\0#{identity}"),
        source: 'gpt_audit_manifest', command: command.strip[0, 500], artifact: artifact,
        perspective: result['name'].to_s[0, 120], source_fingerprint: source_fingerprint
      }
    end.compact
  end

  def self.canonical_gpt_audit_command?(tokens)
    return false if tokens.any? { |token| token == '--codex-bin' || token.start_with?('--codex-bin=') }
    tokens.length >= 2 && trusted_python_realpath?(tokens[0]) && canonical_realpath?(tokens[1])
  end

  def self.unsafe_shell_command?(command)
    normalized_shell_command(command).nil?
  end

  def self.normalized_shell_command(command)
    text = command.to_s
    return nil if text.empty?

    text = text.gsub(/\\\r?\n[ \t]*/, ' ')
    return nil if text.match?(/[;\n\r|&`<>]/) || text.include?('$(') || text.include?('${')

    text.strip
  end

  def self.valid_invocation_binding?(invocation, tokens, nonce, digest)
    return false unless invocation.is_a?(Hash) && invocation['nonce'] == nonce
    interpreter = invocation['python_interpreter']
    return false unless valid_python_interpreter?(interpreter, tokens[0])
    normalized = [File.realpath(interpreter['realpath']), File.realpath(CANONICAL_GPT_AUDIT), *(tokens[2..] || [])]
    payload = JSON.generate(normalized)
    expected = Digest::SHA256.hexdigest(payload)
    invocation['normalized_command'] == payload && invocation['command_sha256'] == expected && digest == expected
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.trusted_python_realpath?(path)
    File.realpath(path.to_s) == File.realpath(TRUSTED_PYTHON_LAUNCHER)
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.valid_python_interpreter?(evidence, invoked)
    return false unless evidence.is_a?(Hash) && trusted_python_realpath?(invoked)
    path = File.realpath(evidence['realpath'].to_s)
    info = File.stat(path)
    path == File.realpath(TRUSTED_PYTHON_LAUNCHER) && info.uid.zero? && (info.mode & 0o022).zero? &&
      valid_artifact_digest?(path, evidence['sha256'])
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.canonical_realpath?(path)
    !path.to_s.empty? && File.realpath(path) == File.realpath(CANONICAL_GPT_AUDIT)
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.authoritative_summary?(summary, results)
    total = results.length
    succeeded = results.count { |result| result['ok'] == true }
    total.positive? && summary['total'] == total && summary['succeeded'] == succeeded &&
      summary['failed'] == total - succeeded && summary['required_success'] == total &&
      succeeded == total && summary['minimum_met'] == true && summary['authoritative'] == true
  end

  def self.fresh_manifest?(manifest, receipt, since)
    started = Float(manifest['started_at'])
    completed = Float(manifest['completed_at'])
    now = Time.now.to_f
    return false unless started <= completed && completed <= now + 5 && now - completed <= 3600
    return false if since && started < Time.iso8601(since.to_s).to_f - 1

    receipt_mtime = File.mtime(File.realpath(receipt)).to_f
    receipt_mtime >= completed - 1 && receipt_mtime <= now + 5
  rescue ArgumentError, TypeError, Errno::ENOENT, Errno::EACCES
    false
  end

  def self.artifact_realpath(path)
    File.realpath(path)
  rescue TypeError, Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.artifact_fresh_for_manifest?(path, manifest)
    modified = File.mtime(path).to_f
    modified >= Float(manifest['started_at']) - 1 && modified <= Float(manifest['completed_at']) + 1
  rescue ArgumentError, TypeError, Errno::ENOENT, Errno::EACCES
    false
  end

  def self.valid_artifact_digest?(path, expected)
    expected.to_s.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(path).hexdigest == expected
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.valid_manifest_inputs?(manifest, results)
    repo = File.realpath(manifest['repo'].to_s)
    workspace = File.realpath(ENV.fetch('SANEAPPS_ROOT', File.join(Dir.home, 'SaneApps')))
    return false unless path_beneath?(repo, workspace) && File.directory?(repo)
    target_root = ENV['CLAUDE_PROJECT_DIR'].to_s.strip
    target_root = Dir.pwd if target_root.empty?
    return false unless repo == File.realpath(target_root)

    inputs = manifest['inputs'] || {}
    source = inputs['repo_source'] || {}
    current_source = repo_source_snapshot(repo)
    return false unless current_source
    return false unless source['algorithm'] == 'git-ls-files-content-v1' && source['stable'] == true
    return false unless source['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
    return false unless source['sha256'] == source['completed_sha256']
    return false unless source['file_count'] == source['completed_file_count']
    return false unless current_source['sha256'] == source['sha256'] && current_source['file_count'] == source['file_count']

    bundle = inputs['bundle'] || {}
    trusted_input = File.realpath(File.join(Dir.tmpdir, 'saneprocess-gpt-audit-inputs'))
    bundle_path = File.realpath(bundle['path'].to_s)
    return false unless path_beneath?(bundle_path, repo) || path_beneath?(bundle_path, trusted_input)
    return false unless valid_owned_input?(bundle_path, bundle, 8 * 1024 * 1024)

    prompts = Array(inputs['prompts'])
    return false if prompts.empty? || prompts.length > 64
    roots = %w[audit critic].map { |name| File.realpath(File.join(Dir.home, '.codex', 'skills', name, 'prompts')) rescue nil }.compact
    names = prompts.map { |item| item['name'].to_s }
    hashes = prompts.map { |item| item['sha256'].to_s }
    return false unless names.uniq.length == names.length && hashes.uniq.length == hashes.length
    return false unless names.sort == results.map { |result| result['name'].to_s }.sort
    prompts.all? do |item|
      path = File.realpath(item['path'].to_s)
      roots.include?(File.dirname(path)) && valid_owned_input?(path, item, 256 * 1024)
    end
  rescue ArgumentError, TypeError, Errno::ENOENT, Errno::EACCES
    false
  end

  def self.repo_source_snapshot(repo)
    stdout, _stderr, status = Open3.capture3(
      'git', '-C', repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard',
      '--', '.', ':(exclude)outputs/**', ':(exclude).claude/state.json',
      ':(exclude).claude/state.json.lock', ':(exclude).claude/sanetrack.log',
      ':(exclude).claude/gate-hits.json', ':(exclude).claude/gate-overrides.json',
      ':(exclude).sanemaster/process_metrics.jsonl', binmode: true
    )
    return nil unless status.success?

    paths = stdout.force_encoding(Encoding::BINARY).split("\0".b).reject(&:empty?).uniq.sort
    digest = Digest::SHA256.new.update("saneprocess-gpt-audit-source-v1\0")
    paths.each do |relative|
      return nil if relative.start_with?('/'.b) || relative.split('/'.b).any? { |part| part.empty? || %w[. ..].include?(part) }

      path = File.join(repo, relative)
      metadata = File.lstat(path)
      if metadata.symlink?
        payload = File.readlink(path).b
        update_source_entry(digest, relative, 'L', false, payload.bytesize)
        digest.update(payload)
      elsif metadata.file?
        descriptor = IO.sysopen(path, File::RDONLY | File::NOFOLLOW)
        io = IO.new(descriptor, 'rb')
        begin
          before = io.stat
          identity = [before.dev, before.ino, before.mode, before.size, before.mtime.to_r, before.ctime.to_r]
          update_source_entry(digest, relative, 'F', (before.mode & 0o111).positive?, before.size)
          remaining = before.size
          while remaining.positive?
            chunk = io.read([remaining, 65_536].min)
            return nil unless chunk
            digest.update(chunk)
            remaining -= chunk.bytesize
          end
          return nil unless io.read(1).nil?
          after = io.stat
          current = [after.dev, after.ino, after.mode, after.size, after.mtime.to_r, after.ctime.to_r]
          return nil unless current == identity
        ensure
          io.close
        end
      else
        return nil
      end
    rescue Errno::ENOENT
      update_source_entry(digest, relative, 'D', false, 0)
    end
    { 'algorithm' => 'git-ls-files-content-v1', 'sha256' => digest.hexdigest, 'file_count' => paths.length }
  rescue StandardError
    nil
  end

  def self.update_source_entry(digest, relative, kind, executable, size)
    digest.update([relative.bytesize].pack('Q>')).update(relative)
    digest.update(kind).update(executable ? "\x01" : "\x00").update([size].pack('Q>'))
  end

  def self.valid_owned_input?(path, evidence, cap)
    info = File.lstat(path)
    info.file? && !info.symlink? && info.uid == Process.uid && info.size.positive? && info.size <= cap &&
      evidence['size'] == info.size && valid_artifact_digest?(path, evidence['sha256'])
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.valid_codex_binary?(evidence)
    return false unless evidence.is_a?(Hash)

    path = File.realpath(evidence['realpath'].to_s)
    trusted = trusted_codex_realpaths
    info = File.stat(path)
    trusted.include?(path) && File.file?(path) && File.executable?(path) &&
      [0, Process.uid].include?(info.uid) && (info.mode & 0o022).zero? && valid_codex_signature?(path) &&
      valid_artifact_digest?(path, evidence['sha256'])
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.valid_codex_signature?(path)
    system('/usr/bin/codesign', '--verify', '--strict', '--requirement', CODEX_REQUIREMENT, path,
           out: File::NULL, err: File::NULL)
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.trusted_codex_realpaths
    candidates = [
      File.join(Dir.home, '.codex', 'packages', 'standalone', 'current', 'bin', 'codex'),
      File.join(Dir.home, '.codex', 'packages', 'standalone', 'current', 'codex'),
      '/Applications/ChatGPT.app/Contents/Resources/codex'
    ]
    candidates.each_with_object([]) do |candidate, paths|
      path = File.realpath(candidate)
      paths << path if File.file?(path) && File.executable?(path) && !paths.include?(path)
    rescue Errno::ENOENT, Errno::EACCES
      next
    end
  end

  def self.valid_report?(manifest, receipt)
    report = File.realpath(manifest['report'].to_s)
    receipt_dir = File.dirname(File.realpath(receipt))
    return false unless File.dirname(report) == receipt_dir && nonempty_file?(report)
    return false unless valid_artifact_digest?(report, manifest['report_sha256'])
    return false unless artifact_fresh_for_manifest?(report, manifest)

    repo_outputs = File.join(File.realpath(manifest['repo'].to_s), 'outputs')
    temp_receipts = File.realpath(ENV.fetch('SANEPROCESS_GPT_AUDIT_RECEIPT_ROOT', File.join(Dir.tmpdir, 'saneprocess-gpt-audit-receipts')))
    return false unless path_beneath?(receipt_dir, repo_outputs) || path_beneath?(receipt_dir, temp_receipts)
    receipt_info = File.lstat(receipt)
    mode = File.stat(receipt_dir).mode & 0o777
    mode == 0o700 && receipt_info.file? && !receipt_info.symlink? && receipt_info.uid == Process.uid
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.path_beneath?(path, root)
    path == root || path.start_with?("#{root}#{File::SEPARATOR}")
  end

  def self.nonempty_file?(path, since: nil)
    return false if path.to_s.strip.empty?

    expanded = File.expand_path(path)
    return false unless File.file?(expanded)
    return false if since && File.mtime(expanded) < Time.iso8601(since.to_s)

    File.open(expanded, 'r') { |file| file.read(4096).to_s.match?(/\S/) }
  rescue Errno::ENOENT, Errno::EACCES
    false
  end
end
