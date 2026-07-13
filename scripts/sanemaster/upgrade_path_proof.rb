# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'pathname'
require 'rbconfig'
require 'securerandom'
require 'socket'
require 'time'
require_relative '../hooks/release_receipt_signer'
require_relative 'process_tree_cleanup'

module SaneMasterModules
  # Runs one selected upgrade test through the canonical SaneMaster
  # monitor_tests lane, independently re-parses its xcresult, and records a
  # producer-bound release authorization receipt.
  module UpgradePathProof
    include ProcessTreeCleanup

    UPGRADE_RESULT_MAX_BYTES = 2 * 1024 * 1024
    UPGRADE_RUNTIME_MAX_BYTES = 2 * 1024 * 1024
    UPGRADE_LOG_MAX_BYTES = 16 * 1024 * 1024
    UPGRADE_RESULT_BUNDLE_MAX_BYTES = 2 * 1024 * 1024 * 1024
    UPGRADE_RESULT_BUNDLE_MAX_ENTRIES = 100_000
    UPGRADE_MONITOR_CLOCK_SKEW_SECONDS = 1
    UPGRADE_PRODUCER = 'saneprocess.upgrade_path_proof.v1'
    RELEASE_PREFLIGHT_PRODUCER = 'saneprocess.release_preflight.v1'
    UPGRADE_SPAWN_GATE = <<~'RUBY'.freeze
      gate = IO.for_fd(Integer(ENV.fetch('SANEMASTER_UPGRADE_GATE_FD')))
      token = gate.read(1)
      gate.close
      exit 125 unless token == 'G'
      exec(*ARGV)
    RUBY

    def upgrade_path_proof(args = [])
      abort 'Usage: SaneMaster.rb upgrade_path_proof' unless args.empty?
      abort 'Upgrade-path proof must run on the Mac Mini.' unless release_status_mini_runtime?

      config = saneprocess_value('release', 'upgrade_path_test')
      abort 'Missing release.upgrade_path_test configuration in .saneprocess.' unless config.is_a?(Hash)
      if config.key?('command')
        abort 'release.upgrade_path_test.command is not trusted; configure scheme and test_selector for the canonical monitor_tests runner.'
      end

      scheme = config['scheme'].to_s.strip
      test_selector = config['test_selector'].to_s.strip
      abort 'release.upgrade_path_test.scheme is required.' if scheme.empty?
      abort 'release.upgrade_path_test.test_selector is required.' if test_selector.empty?

      from_version = config['from_version'].to_s.strip
      abort 'release.upgrade_path_test.from_version is required.' if from_version.empty?

      timeout_seconds = Integer(config.fetch('timeout_seconds', 900))
      abort 'release.upgrade_path_test.timeout_seconds must be positive.' unless timeout_seconds.positive?

      project_root = File.realpath(Dir.pwd)
      app_name = saneprocess_value('name').to_s.strip
      app_name = File.basename(project_root) if app_name.empty?
      to_version = release_current_project_version[:version].to_s.strip
      abort 'Unable to determine the current project version.' if to_version.empty?
      abort 'Upgrade proof requires different from_version and current versions.' if from_version == to_version

      source_fingerprint = release_status_source_fingerprint(project_root).to_s
      abort 'Unable to calculate the pre-test source fingerprint.' if source_fingerprint.empty?

      run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(12)}"
      challenge = SecureRandom.hex(32)
      challenge_root = File.expand_path(ENV.fetch('SANEMASTER_UPGRADE_CHALLENGE_ROOT', '~/.sanemaster/upgrade-path-runs'))
      run_root = File.join(challenge_root, app_name.gsub(/[^A-Za-z0-9_.-]/, '_'), run_id)
      upgrade_path_secure_directory!(run_root)
      raw_log_path = File.join(run_root, 'command.log')
      result_path = File.join(run_root, 'result.json')
      runtime_path = File.join(run_root, 'runtime.json')
      started_at = Time.now.utc

      argv = upgrade_path_runner_argv(scheme: scheme, test_selector: test_selector, timeout_seconds: timeout_seconds)
      status = upgrade_path_spawn(
        argv,
        upgrade_path_runner_env(run_id, challenge),
        project_root,
        raw_log_path,
        timeout_seconds + 30
      )
      finished_at = Time.now.utc
      abort "Canonical upgrade test failed (exit #{status[:exit_status] || 'timeout'}); see #{raw_log_path}." unless status[:success]

      monitor_receipt_path = upgrade_path_monitor_receipt_path!(raw_log_path, project_root)
      monitor_receipt, result_summary = upgrade_path_validate_monitor_receipt!(
        monitor_receipt_path,
        project_root: project_root,
        scheme: scheme,
        test_selector: test_selector,
        started_at: started_at,
        finished_at: finished_at,
        run_id: run_id,
        nonce: challenge
      )
      result_bundle = File.realpath(monitor_receipt.fetch('result_bundle_path'))
      bundle_manifest = upgrade_path_result_bundle_manifest!(result_bundle, project_root)
      result_payload = {
        'type' => 'upgrade_path_monitor_result',
        'source' => monitor_receipt.fetch('source'),
        'status' => monitor_receipt.fetch('status'),
        'scheme' => scheme,
        'testSelector' => test_selector,
        'runId' => monitor_receipt.fetch('upgrade_run_id'),
        'monitorRunId' => monitor_receipt.fetch('run_id'),
        'nonceDigest' => Digest::SHA256.hexdigest(monitor_receipt.fetch('upgrade_nonce')),
        'testsRun' => result_summary.fetch(:matched_test_count),
        'monitorReceiptSha256' => Digest::SHA256.file(monitor_receipt_path).hexdigest,
        'resultBundleManifestSha256' => bundle_manifest.fetch('sha256')
      }
      runtime_payload = {
        'type' => 'upgrade_path_runtime_observation',
        'status' => 'passed',
        'runId' => monitor_receipt.fetch('upgrade_run_id'),
        'monitorRunId' => monitor_receipt.fetch('run_id'),
        'challengeDigest' => Digest::SHA256.hexdigest(monitor_receipt.fetch('upgrade_nonce')),
        'app' => app_name,
        'fromVersion' => from_version,
        'toVersion' => to_version,
        'sourceFingerprint' => source_fingerprint,
        'scheme' => scheme,
        'testSelector' => test_selector,
        'discoveredTests' => result_summary.fetch(:discovered_test_count),
        'passedTests' => result_summary.fetch(:passed_test_count),
        'matchedUpgradeTests' => result_summary.fetch(:matched_test_count),
        'resultBundle' => bundle_manifest
      }
      upgrade_path_write_json_artifact!(result_path, result_payload, UPGRADE_RESULT_MAX_BYTES)
      upgrade_path_write_json_artifact!(runtime_path, runtime_payload, UPGRADE_RUNTIME_MAX_BYTES)
      upgrade_path_validate_artifact!(raw_log_path, UPGRADE_LOG_MAX_BYTES, 'command log', allow_empty: true)
      current_fingerprint = release_status_source_fingerprint(project_root).to_s
      abort 'Source changed while the upgrade test ran; discard this proof and rerun.' unless current_fingerprint == source_fingerprint

      evidence_dir = File.join(project_root, 'outputs', 'upgrade-path-proof', run_id)
      upgrade_path_secure_directory!(evidence_dir, project_root: project_root)
      evidence_paths = {
        'result' => File.join(evidence_dir, 'result.json'),
        'runtime' => File.join(evidence_dir, 'runtime.json'),
        'log' => File.join(evidence_dir, 'command.log')
      }
      { 'result' => result_path, 'runtime' => runtime_path, 'log' => raw_log_path }.each do |role, source|
        FileUtils.cp(source, evidence_paths.fetch(role), preserve: false)
      end
      evidence_paths.each_value { |path| File.chmod(0o600, path) }

      payload = {
        'schemaVersion' => 2,
        'type' => 'upgrade_path_behavioral_proof',
        'status' => 'passed',
        'behavioral' => true,
        'app' => app_name,
        'fromVersion' => from_version,
        'toVersion' => to_version,
        'testsRun' => result_summary.fetch(:matched_test_count),
        'miniRuntime' => true,
        'host' => Socket.gethostname,
        'generatedAt' => finished_at.iso8601,
        'startedAt' => started_at.iso8601,
        'finishedAt' => finished_at.iso8601,
        'sourceFingerprint' => source_fingerprint,
        'runId' => run_id,
        'challengeDigest' => Digest::SHA256.hexdigest(challenge),
        'process' => upgrade_path_process_identity(argv, status),
        'testEvidence' => result_payload,
        'artifacts' => upgrade_path_evidence_manifest(evidence_paths, project_root)
      }
      receipt_path = File.join(project_root, 'outputs', 'upgrade_path_behavioral_receipt.json')
      upgrade_path_write_signed_atomic!(
        receipt_path,
        payload,
        producer: UPGRADE_PRODUCER,
        project_root: project_root
      )
      puts "Upgrade-path behavioral proof passed: #{receipt_path}"
      receipt_path
    rescue ArgumentError => e
      abort "Invalid upgrade-path proof configuration: #{e.message}"
    ensure
      FileUtils.remove_entry_secure(run_root) if defined?(run_root) && run_root && File.directory?(run_root)
    end

    def release_receipt_signer
      ReleaseReceiptSigner.production
    end

    def upgrade_path_write_signed_atomic!(path, payload, producer:, project_root: nil)
      if ReleaseReceiptSigner.canonical_producer_child?(producer)
        ReleaseReceiptSigner.write_canonical_candidate!(path, payload, producer: producer)
        return path
      end

      directory = File.dirname(path)
      upgrade_path_secure_directory!(directory, project_root: project_root)
      if File.exist?(path) || File.symlink?(path)
        metadata = File.lstat(path)
        raise "Refusing non-regular signed receipt target: #{path}" unless metadata.file? && !metadata.symlink?
      end
      temporary = File.join(directory, ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      release_receipt_signer.write(temporary, payload, producer: producer)
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
      path
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def upgrade_path_read_signed(path, producer:)
      release_receipt_signer.read(path, producer: producer)
    end

    def upgrade_path_verify_artifacts(receipt, project_path)
      root = File.realpath(project_path)
      artifacts = receipt['artifacts']
      return 'receipt artifacts are missing' unless artifacts.is_a?(Array)
      roles = artifacts.map { |item| item.is_a?(Hash) ? item['role'].to_s : '' }
      return 'receipt must bind result, runtime, and log artifacts' unless %w[log result runtime].all? { |role| roles.include?(role) }

      artifacts.each do |artifact|
        return 'receipt artifact entry is malformed' unless artifact.is_a?(Hash)
        relative = artifact['path'].to_s
        return 'receipt artifact path is unsafe' if relative.empty? || Pathname.new(relative).absolute? || relative.split('/').include?('..')
        path = File.join(root, relative)
        return "receipt artifact is missing or unsafe: #{relative}" unless release_regular_file_without_symlinked_parent?(path)
        real_path = File.realpath(path)
        return "receipt artifact escapes project: #{relative}" unless real_path.start_with?("#{root}/")
        return "receipt artifact size changed: #{relative}" unless File.size(real_path) == artifact['size'].to_i
        return "receipt artifact digest changed: #{relative}" unless Digest::SHA256.file(real_path).hexdigest == artifact['sha256'].to_s
      end
      nil
    rescue StandardError => e
      "receipt artifact validation failed: #{e.message}"
    end

    private

    def upgrade_path_runner_argv(scheme:, test_selector:, timeout_seconds:)
      runner = File.realpath(File.join(__dir__, '..', 'SaneMaster.rb'))
      ruby = File.realpath(RbConfig.ruby)
      [ruby, runner, 'monitor_tests', '--scheme', scheme, '--test', test_selector, '--timeout', timeout_seconds.to_s]
    end

    def upgrade_path_runner_env(run_id, nonce)
      {
        'PATH' => '/usr/bin:/bin',
        'HOME' => Dir.home,
        'TMPDIR' => ENV.fetch('TMPDIR', '/tmp'),
        'LANG' => 'en_US.UTF-8',
        'LC_ALL' => 'en_US.UTF-8',
        'SANEMASTER_UPGRADE_RUN_ID' => run_id,
        'SANEMASTER_UPGRADE_NONCE' => nonce
      }
    end

    def upgrade_path_spawn(argv, env, project_root, log_path, timeout_seconds)
      gate_reader, gate_writer = IO.pipe
      gate_reader.close_on_exec = false
      gated_env = env.merge('SANEMASTER_UPGRADE_GATE_FD' => gate_reader.fileno.to_s)
      pid = Process.spawn(
        gated_env,
        File.realpath(RbConfig.ruby), '-e', UPGRADE_SPAWN_GATE, *argv,
        gate_reader => gate_reader,
        chdir: project_root,
        out: log_path,
        err: [:child, :out],
        pgroup: true,
        unsetenv_others: true
      )
      gate_reader.close
      root_identity = upgrade_path_bind_spawned_runner(pid)
      unless root_identity
        gate_writer.close
        upgrade_path_cleanup_unbound_spawn!(pid)
        raise "Could not bind canonical upgrade runner identity for pid #{pid}"
      end

      tracked_identities = {}
      gate_writer.write('G')
      gate_writer.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      process_status = nil
      timed_out = false
      loop do
        monitor_test_track_descendant_identities(root_identity, tracked_identities)
        waited = Process.waitpid2(pid, Process::WNOHANG)
        process_status = waited && waited[1]
        break if process_status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          timed_out = true
          terminate_monitor_test_process_group(
            pid,
            root_identity: root_identity,
            tracked_identities: tracked_identities,
            tracked_descendants: tracked_identities.keys
          )
          _, process_status = Process.waitpid2(pid) rescue [nil, nil]
          break
        end
        sleep 0.05
      end

      survivors = monitor_test_termination_survivors(root_identity, tracked_identities)
      unless monitor_test_survivors_empty?(survivors)
        terminate_monitor_test_process_group(
          pid,
          root_identity: root_identity,
          tracked_identities: tracked_identities,
          tracked_descendants: tracked_identities.keys
        )
      end
      {
        success: !timed_out && process_status&.success? == true,
        pid: pid,
        exit_status: process_status&.exitstatus,
        timed_out: timed_out
      }
    rescue StandardError
      gate_writer.close if defined?(gate_writer) && gate_writer && !gate_writer.closed?
      gate_reader.close if defined?(gate_reader) && gate_reader && !gate_reader.closed?
      if defined?(root_identity) && root_identity
        terminate_monitor_test_process_group(
          pid,
          root_identity: root_identity,
          tracked_identities: defined?(tracked_identities) ? tracked_identities : {},
          tracked_descendants: defined?(tracked_identities) ? tracked_identities.keys : []
        ) rescue nil
      end
      raise
    ensure
      gate_writer.close if defined?(gate_writer) && gate_writer && !gate_writer.closed?
      gate_reader.close if defined?(gate_reader) && gate_reader && !gate_reader.closed?
    end

    def upgrade_path_bind_spawned_runner(pid, timeout_seconds: 1.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        identity = monitor_test_process_identity(pid)
        return identity if identity && identity[:pgid] == pid
        return nil unless upgrade_path_child_running?(pid)
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    rescue StandardError
      nil
    end

    def upgrade_path_cleanup_unbound_spawn!(pid, timeout_seconds: 1.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return true if waited
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end

      begin
        Process.kill('KILL', -pid) if Process.getpgid(pid) == pid
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      Process.waitpid(pid)
      true
    rescue Errno::ECHILD
      true
    end

    def upgrade_path_child_running?(pid)
      waited = Process.waitpid2(pid, Process::WNOHANG)
      waited.nil?
    rescue Errno::ECHILD
      false
    end

    def upgrade_path_monitor_receipt_path!(log_path, project_root)
      paths = File.readlines(log_path, chomp: true, encoding: Encoding::UTF_8).filter_map do |line|
        line.delete_prefix('SANEMASTER_MONITOR_RECEIPT=') if line.start_with?('SANEMASTER_MONITOR_RECEIPT=')
      end
      raise 'Canonical monitor_tests did not report exactly one receipt path.' unless paths.length == 1

      path = File.realpath(paths.first)
      allowed_root = File.realpath(File.join(project_root, 'outputs', 'monitor-tests'))
      raise 'Canonical monitor_tests receipt escaped outputs/monitor-tests.' unless path.start_with?("#{allowed_root}/")
      raise 'Canonical monitor_tests receipt is not a regular file.' unless File.file?(path) && !File.symlink?(path)

      path
    end

    def upgrade_path_validate_monitor_receipt!(path, project_root:, scheme:, test_selector:, started_at:, finished_at:,
                                               run_id:, nonce:)
      receipt = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      receipt_directory = File.realpath(File.dirname(path))
      monitor_run_id = File.basename(receipt_directory)
      binding = Digest::SHA256.hexdigest("#{run_id}\0#{nonce}")[0, 16]
      unless monitor_run_id.end_with?("-upgrade-#{binding}")
        raise 'Canonical monitor_tests run directory is not bound to the upgrade challenge.'
      end
      expected = {
        'source' => 'SaneMaster.monitor_tests',
        'status' => 'passed',
        'run_id' => monitor_run_id,
        'upgrade_run_id' => run_id,
        'upgrade_nonce' => nonce,
        'host' => Socket.gethostname,
        'scheme' => scheme,
        'test_selector' => test_selector,
        'result_bundle_exists' => true,
        'result_bundle_valid' => true,
        'xcresult_verified' => true,
        'exit_status' => 0,
        'timed_out' => false
      }
      expected.each { |key, value| raise "Canonical monitor_tests receipt has invalid #{key}." unless receipt[key] == value }
      %w[discovered_test_count passed_test_count matched_test_count].each do |key|
        raise "Canonical monitor_tests receipt has invalid #{key}." unless receipt[key].to_i.positive?
      end
      receipt_started = Time.parse(receipt.fetch('started_at'))
      receipt_finished = Time.parse(receipt.fetch('completed_at'))
      skew = UPGRADE_MONITOR_CLOCK_SKEW_SECONDS
      raise 'Canonical monitor_tests receipt predates the upgrade proof run.' if receipt_started < started_at - skew
      raise 'Canonical monitor_tests receipt postdates the upgrade proof run.' if receipt_finished > finished_at + skew
      raise 'Canonical monitor_tests receipt has inverted timestamps.' if receipt_finished < receipt_started

      bundle = File.realpath(receipt.fetch('result_bundle_path'))
      allowed_root = File.realpath(File.join(project_root, 'outputs', 'monitor-tests'))
      raise 'Canonical monitor_tests result bundle escaped outputs/monitor-tests.' unless bundle.start_with?("#{allowed_root}/")
      raise 'Canonical monitor_tests result bundle is not bound to its receipt run.' unless File.dirname(bundle) == receipt_directory
      raise 'Canonical monitor_tests result bundle has a noncanonical name.' unless File.basename(bundle) == 'test.xcresult'
      raise 'Canonical monitor_tests xcresult path mismatch.' unless File.realpath(receipt.fetch('xcresult_path')) == bundle
      info = File.join(bundle, 'Info.plist')
      raise 'Canonical monitor_tests result bundle is missing regular Info.plist.' unless File.file?(info) && !File.symlink?(info)

      summary = monitor_test_result_summary(bundle, test_selector)
      raise "Independent xcresult validation failed: #{summary[:error]}" unless summary[:ok]
      raise 'Independent xcresult validation found no matching passed upgrade test.' unless summary[:matched_test_count].to_i.positive?

      [receipt, summary]
    rescue JSON::ParserError, KeyError, ArgumentError => e
      raise "Canonical monitor_tests receipt is invalid: #{e.message}"
    end

    def upgrade_path_result_bundle_manifest!(bundle, project_root)
      root = File.realpath(bundle)
      allowed_root = File.realpath(File.join(project_root, 'outputs', 'monitor-tests'))
      raise 'Result bundle escaped outputs/monitor-tests.' unless root.start_with?("#{allowed_root}/")

      entries = []
      total_bytes = 0
      Find.find(root) do |path|
        metadata = File.lstat(path)
        raise "Result bundle contains symlink: #{path}" if metadata.symlink?
        raise "Result bundle contains unsupported entry: #{path}" unless metadata.file? || metadata.directory?

        relative = path.delete_prefix("#{root}/")
        relative = '.' if path == root
        total_bytes += metadata.size if metadata.file?
        raise 'Result bundle exceeds maximum byte size.' if total_bytes > UPGRADE_RESULT_BUNDLE_MAX_BYTES
        entries << [relative, metadata.directory? ? 'directory' : 'file', metadata.mode & 0o7777, metadata.size,
                    metadata.file? ? Digest::SHA256.file(path).hexdigest : nil]
        raise 'Result bundle exceeds maximum entry count.' if entries.length > UPGRADE_RESULT_BUNDLE_MAX_ENTRIES
      end
      digest = Digest::SHA256.hexdigest(entries.sort_by(&:first).map { |entry| JSON.generate(entry) }.join("\n"))
      { 'sha256' => digest, 'entries' => entries.length, 'bytes' => total_bytes }
    end

    def upgrade_path_write_json_artifact!(path, payload, maximum_bytes)
      bytes = JSON.pretty_generate(payload) + "\n"
      raise "Generated upgrade artifact exceeds #{maximum_bytes} bytes." if bytes.bytesize > maximum_bytes

      File.write(path, bytes, encoding: Encoding::UTF_8)
      File.chmod(0o600, path)
    end

    def upgrade_path_process_identity(argv, status)
      executable = File.realpath(argv.fetch(0))
      runner = File.realpath(argv.fetch(1))
      {
        'pid' => status[:pid],
        'exitStatus' => status[:exit_status],
        'executable' => { 'path' => executable, 'sha256' => Digest::SHA256.file(executable).hexdigest, 'size' => File.size(executable) },
        'runner' => { 'path' => runner, 'sha256' => Digest::SHA256.file(runner).hexdigest, 'size' => File.size(runner) },
        'argv' => argv,
        'argvDigest' => Digest::SHA256.hexdigest(JSON.generate(argv))
      }
    end

    def upgrade_path_evidence_manifest(paths, project_root)
      paths.map do |role, path|
        {
          'role' => role,
          'path' => path.sub(%r{\A#{Regexp.escape(project_root)}/?}, ''),
          'sha256' => Digest::SHA256.file(path).hexdigest,
          'size' => File.size(path)
        }
      end
    end

    def upgrade_path_validate_artifact!(path, maximum_bytes, label, allow_empty: false)
      metadata = File.lstat(path)
      raise "Configured upgrade test #{label} must be a regular file." unless metadata.file? && !metadata.symlink?
      raise "Configured upgrade test #{label} is empty." if !allow_empty && metadata.size.zero?
      raise "Configured upgrade test #{label} exceeds #{maximum_bytes} bytes." if metadata.size > maximum_bytes
    rescue Errno::ENOENT
      raise "Configured upgrade test did not write #{label}."
    end

    def upgrade_path_secure_directory!(directory, project_root: nil)
      expanded = File.expand_path(directory)
      FileUtils.mkdir_p(expanded, mode: 0o700)
      expanded = File.realpath(expanded)
      if project_root
        root = File.realpath(project_root)
        raise "Receipt directory escapes project: #{expanded}" unless expanded.start_with?("#{root}/")
      end
      current = expanded
      loop do
        metadata = File.lstat(current)
        raise "Refusing symlinked proof directory: #{current}" if metadata.symlink?
        break if current == File.dirname(current) || (project_root && current == File.realpath(project_root))

        current = File.dirname(current)
      end
      File.chmod(0o700, expanded)
    end
  end
end
