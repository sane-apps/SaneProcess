#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require_relative 'test/test_framework'

include TestFramework

exit(run_tests('SaneTrack Codex Review Lane Tests') do
  Dir.mktmpdir('sanetrack-codex-review-') do |dir|
    old_home = ENV['HOME']
    old_saneapps_root = ENV['SANEAPPS_ROOT']
    old_receipt_root = ENV['SANEPROCESS_GPT_AUDIT_RECEIPT_ROOT']
    ENV['HOME'] = dir
    ENV['SANEAPPS_ROOT'] = dir
    ENV['SANEPROCESS_GPT_AUDIT_RECEIPT_ROOT'] = dir
    File.write(File.join(dir, '.saneprocess'), "name: HookTest\n")
    File.write(File.join(dir, '.gitignore'), "/.claude/\n/.codex/\n/*.md\n/*manifest*.json\n/audit-bundle.txt\n/gpt_audit.py\n")
    system('git', '-C', dir, 'init', '-q')
    system('git', '-C', dir, 'config', 'user.email', 'test@example.com')
    system('git', '-C', dir, 'config', 'user.name', 'Test')
    system('git', '-C', dir, 'add', '.saneprocess', '.gitignore')
    system('git', '-C', dir, 'commit', '-q', '-m', 'fixture')
    trusted_codex = File.join(dir, '.codex', 'packages', 'standalone', 'current', 'bin', 'codex')
    FileUtils.mkdir_p(File.dirname(trusted_codex))
    File.write(trusted_codex, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, trusted_codex)
    FileUtils.mkdir_p(File.join(dir, '.claude'))
    ENV['CLAUDE_PROJECT_DIR'] = dir
    Dir.chdir(dir) do
      require_relative 'sanetrack'
      MandatoryWorkflows.singleton_class.send(:define_method, :valid_codex_signature?) { |_path| true }

      reset_skill = lambda do
        StateManager.reset(:skill)
        StateManager.update(:skill) do |state|
          state[:required] = 'docs_audit'
          state[:invoked] = true
          state[:invoked_at] = Time.now.iso8601
          state[:subagents_spawned] = 0
          state[:native_review_fingerprints] = []
          state[:codex_review_lanes_completed] = 0
          state[:codex_review_lane_fingerprints] = []
          state[:review_source_fingerprint] = nil
          state[:runner_proved] = false
          state
        end
      end

      direct_artifact = File.join(dir, 'direct-review.md')
      review_command = "codex exec --ephemeral -s read-only -o #{direct_artifact} 'Review the hook changes as the security perspective'"
      canonical_runner = File.expand_path('../automation/gpt_audit.py', __dir__)
      python_launcher = MandatoryWorkflows::TRUSTED_PYTHON_LAUNCHER
      python_realpath = File.realpath(python_launcher)
      canonical_command = "#{python_launcher} #{canonical_runner} --backend codex-exec"
      prompt_root = File.join(dir, '.codex', 'skills', 'audit', 'prompts')
      FileUtils.mkdir_p(prompt_root)
      bundle_path = File.join(dir, 'audit-bundle.txt')
      File.write(bundle_path, "Bundle evidence\n")
      report_path = File.join(dir, 'summary.md')
      manifest_for = lambda do |named_artifacts|
        now = Time.now.to_f
        File.write(report_path, "Synthesized report\n")
        results = named_artifacts.map do |name, path|
          {
            'name' => name, 'ok' => true, 'output_path' => path,
            'output_sha256' => Digest::SHA256.file(path).hexdigest,
            'command_mode' => 'codex exec --ephemeral', 'read_only' => true,
            'isolated_user_config' => true, 'output_nonempty' => true
          }
        end
        prompt_evidence = named_artifacts.map do |name, _path|
          prompt = File.join(prompt_root, "#{name}.md")
          File.write(prompt, "Review perspective #{name}\n")
          { 'name' => name, 'path' => prompt, 'sha256' => Digest::SHA256.file(prompt).hexdigest, 'size' => File.size(prompt) }
        end
        normalized = JSON.generate([python_realpath, canonical_runner, '--backend', 'codex-exec'])
        source = MandatoryWorkflows.repo_source_snapshot(dir)
        source = source.merge(
          'completed_sha256' => source['sha256'],
          'completed_file_count' => source['file_count'],
          'stable' => true
        )
        {
          'runner' => { 'path' => canonical_runner, 'schema_version' => 4 },
          'repo' => dir,
          'invocation' => {
            'nonce' => 'a' * 32, 'command_sha256' => Digest::SHA256.hexdigest(normalized),
            'normalized_command' => normalized,
            'python_interpreter' => { 'realpath' => python_realpath, 'sha256' => Digest::SHA256.file(python_realpath).hexdigest }
          },
          'inputs' => {
            'bundle' => { 'path' => bundle_path, 'sha256' => Digest::SHA256.file(bundle_path).hexdigest, 'size' => File.size(bundle_path) },
            'prompts' => prompt_evidence,
            'repo_source' => source
          },
          'backend' => 'codex-exec', 'started_at' => now - 0.25, 'completed_at' => now,
          'execution' => {
            'command_mode' => 'codex exec --ephemeral', 'read_only' => true,
            'isolated_user_config' => true, 'allow_partial' => false, 'codex_bin_override' => false,
            'testing_mode' => false,
            'codex_binary' => { 'realpath' => File.realpath(trusted_codex), 'sha256' => Digest::SHA256.file(File.realpath(trusted_codex)).hexdigest }
          },
          'summary' => {
            'total' => results.length, 'succeeded' => results.length, 'failed' => 0,
            'required_success' => results.length, 'minimum_met' => true, 'authoritative' => true
          },
          'synthesis' => { 'status' => 'succeeded', 'error' => nil },
          'report' => report_path, 'report_sha256' => Digest::SHA256.file(report_path).hexdigest,
          'results' => results
        }
      end
      receipt_for = lambda do |path, manifest|
        "CODEX_FANOUT_RECEIPT=#{path} CODEX_FANOUT_NONCE=#{manifest['invocation']['nonce']} CODEX_FANOUT_COMMAND_SHA256=#{manifest['invocation']['command_sha256']}\n"
      end

      test('does not count direct Codex exec without canonical fan-out receipt') do
        reset_skill.call
        File.write(direct_artifact, "Security review findings\n")
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 0, 'output' => 'review completed' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('counts only completed nonempty native Task results and deduplicates identity') do
        reset_skill.call
        process_result('spawn_agent', { 'task_name' => 'review' }, { 'status' => 'completed', 'agent_id' => 'codex-1', 'result' => 'review' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'started', 'task_id' => 'task-1', 'result' => 'launched' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'completed', 'task_id' => 'task-2', 'result' => '  ' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'failed', 'task_id' => 'task-failed', 'result' => 'partial' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'completed', 'result' => 'Missing stable identity' })
        process_result('Task', { 'description' => 'Implement the fix' }, { 'status' => 'completed', 'task_id' => 'task-implementation', 'result' => 'Changed code' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'completed', 'task_id' => 'task-3', 'result' => 'Concrete review findings' })
        process_result('Task', { 'description' => 'review' }, { 'status' => 'completed', 'task_id' => 'task-3', 'result' => 'Repeated delivery' })
        assert_eq(StateManager.get(:skill)[:subagents_spawned], 1)
        true
      end

      test('deduplicates an identical completed reviewer lane') do
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 0, 'output' => 'review completed' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('does not count failed or started-only Codex commands') do
        reset_skill.call
        File.write(direct_artifact, "Review result\n")
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 1, 'error' => 'failed' })
        process_result('Bash', { 'command' => review_command }, { 'status' => 'started', 'output' => 'session running' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('does not count arbitrary implementation sessions') do
        reset_skill.call
        File.write(direct_artifact, "Implementation notes\n")
        command = "codex exec --ephemeral -s read-only -o #{direct_artifact} 'Review the bug, then implement the fix'"
        process_result('Bash', { 'command' => command }, { 'exit_code' => 0, 'output' => 'completed' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('does not count success without a nonempty output artifact') do
        reset_skill.call
        FileUtils.rm_f(direct_artifact)
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 0, 'output' => 'completed' })
        File.write(direct_artifact, "   \n")
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 0, 'output' => 'completed' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects stale artifacts and compound-shell success masking') do
        reset_skill.call
        File.write(direct_artifact, "Old review\n")
        old_time = Time.now - 60
        File.utime(old_time, old_time, direct_artifact)
        process_result('Bash', { 'command' => review_command }, { 'exit_code' => 0, 'output' => 'completed' })
        File.write(direct_artifact, "Current review\n")
        masked = "#{review_command} || true"
        process_result('Bash', { 'command' => masked }, { 'exit_code' => 0, 'output' => 'completed' })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('requires both ephemeral and read-only isolation flags') do
        reset_skill.call
        File.write(direct_artifact, "Review result\n")
        [
          "codex exec -s read-only -o #{direct_artifact} 'Review the change'",
          "codex exec --ephemeral -o #{direct_artifact} 'Review the change'",
          "codex exec --ephemeral -s workspace-write -o #{direct_artifact} 'Review the change'"
        ].each do |command|
          process_result('Bash', { 'command' => command }, { 'exit_code' => 0, 'output' => 'completed' })
        end
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('counts and deduplicates fully validated canonical gpt_audit lanes') do
        reset_skill.call
        first = File.join(dir, 'security.md')
        second = File.join(dir, 'correctness.md')
        File.write(first, "Security finding\n")
        File.write(second, "Correctness finding\n")
        manifest_path = File.join(dir, 'manifest.json')
        manifest = manifest_for.call([['security', first], ['correctness', second]])
        File.write(manifest_path, JSON.pretty_generate(manifest))
        command = canonical_command
        response = { 'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest) }
        process_result('Bash', { 'command' => command }, response)
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 2)
        process_result('Bash', { 'command' => command }, response)
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 2)
        true
      end

      test('later source edits invalidate accumulated native and Codex review credits') do
        reset_skill.call
        artifact = File.join(dir, 'source-bound.md')
        File.write(artifact, "Source-bound finding\n")
        manifest_path = File.join(dir, 'source-bound-manifest.json')
        manifest = manifest_for.call([['source-bound', artifact]])
        File.write(manifest_path, JSON.generate(manifest))
        process_result('Bash', { 'command' => canonical_command }, {
          'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest)
        })
        codex_state = StateManager.get(:skill)
        assert_eq(codex_state[:codex_review_lanes_completed], 1,
                  "Codex source binding failed: #{codex_state.inspect}")
        process_result('Task', { 'description' => 'Review source behavior' }, {
          'status' => 'completed', 'task_id' => 'source-review', 'result' => 'Reviewed current source'
        })
        combined_state = StateManager.get(:skill)
        assert_eq(combined_state[:codex_review_lanes_completed], 1,
                  "Native review changed source binding: #{combined_state.inspect}; current=#{MandatoryWorkflows.repo_source_snapshot(dir).inspect}")
        assert_eq(StateManager.get(:skill)[:subagents_spawned], 1)

        changed = File.join(dir, 'source.rb')
        File.write(changed, "puts :changed\n")
        process_result('Write', { 'file_path' => changed }, {})
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        assert_eq(StateManager.get(:skill)[:subagents_spawned], 0)
        assert_eq(StateManager.get(:skill)[:review_source_fingerprint], nil)
        true
      end

      test('accepts documented backslash-newline continuation without accepting a compound command') do
        reset_skill.call
        artifact = File.join(dir, 'continued.md')
        File.write(artifact, "Continued command finding\n")
        manifest_path = File.join(dir, 'continued-manifest.json')
        manifest = manifest_for.call([['continued', artifact]])
        File.write(manifest_path, JSON.generate(manifest))
        continued = "#{python_launcher} #{canonical_runner} \\\n  --backend codex-exec"
        process_result('Bash', { 'command' => continued }, {
          'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest)
        })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 1)
        true
      end

      test('rejects a canonical gpt_audit receipt for another repo under SANEAPPS_ROOT') do
        reset_skill.call
        unrelated_repo = File.join(dir, 'unrelated-app')
        FileUtils.mkdir_p(unrelated_repo)
        unrelated_bundle = File.join(unrelated_repo, 'audit-bundle.txt')
        File.write(unrelated_bundle, "Unrelated repository evidence\n")
        artifact = File.join(dir, 'wrong-repo-security.md')
        File.write(artifact, "Security finding for another repository\n")
        manifest_path = File.join(dir, 'wrong-repo-manifest.json')
        command_args = ['--backend', 'codex-exec', '--repo', unrelated_repo]
        command = ([python_launcher, canonical_runner] + command_args).shelljoin
        normalized = JSON.generate([python_realpath, canonical_runner, *command_args])
        manifest = manifest_for.call([['security', artifact]])
        manifest['repo'] = unrelated_repo
        manifest['inputs']['bundle'] = {
          'path' => unrelated_bundle,
          'sha256' => Digest::SHA256.file(unrelated_bundle).hexdigest,
          'size' => File.size(unrelated_bundle)
        }
        manifest['invocation'].merge!(
          'normalized_command' => normalized,
          'command_sha256' => Digest::SHA256.hexdigest(normalized)
        )
        File.write(manifest_path, JSON.pretty_generate(manifest))

        process_result('Bash', { 'command' => command }, {
          'exit_code' => 0,
          'output' => receipt_for.call(manifest_path, manifest)
        })

        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects a manifest bound to a PATH-shadowing Codex binary') do
        reset_skill.call
        artifact = File.join(dir, 'shadowed-codex.md')
        File.write(artifact, "Review finding\n")
        shadowed_codex = File.join(dir, 'path-shadow-bin', 'codex')
        FileUtils.mkdir_p(File.dirname(shadowed_codex))
        File.write(shadowed_codex, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, shadowed_codex)
        manifest_path = File.join(dir, 'shadowed-codex-manifest.json')
        manifest = manifest_for.call([['security', artifact]])
        manifest['execution']['codex_binary'] = {
          'realpath' => File.realpath(shadowed_codex),
          'sha256' => Digest::SHA256.file(shadowed_codex).hexdigest
        }
        File.write(manifest_path, JSON.pretty_generate(manifest))
        process_result('Bash', { 'command' => canonical_command }, {
          'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest)
        })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end


      test('rejects a repo or PATH-shadowing Python launcher') do
        reset_skill.call
        artifact = File.join(dir, 'fake-python.md')
        File.write(artifact, "Review finding\n")
        fake_python = File.join(dir, 'python3')
        File.write(fake_python, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, fake_python)
        manifest_path = File.join(dir, 'fake-python-manifest.json')
        manifest = manifest_for.call([['security', artifact]])
        normalized = JSON.generate([File.realpath(fake_python), canonical_runner, '--backend', 'codex-exec'])
        manifest['invocation'].merge!(
          'normalized_command' => normalized,
          'command_sha256' => Digest::SHA256.hexdigest(normalized),
          'python_interpreter' => {
            'realpath' => File.realpath(fake_python), 'sha256' => Digest::SHA256.file(fake_python).hexdigest
          }
        )
        File.write(manifest_path, JSON.pretty_generate(manifest))
        process_result('Bash', { 'command' => "#{fake_python} #{canonical_runner} --backend codex-exec" }, {
          'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest)
        })
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects noncanonical and non-Codex manifest receipts') do
        reset_skill.call
        artifact = File.join(dir, 'other.md')
        File.write(artifact, "Review result\n")
        manifest_path = File.join(dir, 'other-manifest.json')
        File.write(manifest_path, JSON.generate({
          'backend' => 'responses-api',
          'execution' => { 'command_mode' => 'responses-api', 'read_only' => false, 'isolated_user_config' => false },
          'summary' => { 'minimum_met' => true },
          'results' => [{ 'name' => 'review', 'ok' => true, 'output_path' => artifact, 'output_nonempty' => true }]
        }))
        receipt = { 'exit_code' => 0, 'output' => "CODEX_FANOUT_RECEIPT=#{manifest_path}\n" }
        process_result('Bash', { 'command' => 'echo fake audit receipt' }, receipt)
        process_result('Bash', { 'command' => "python3 scripts/automation/gpt_audit.py --backend responses-api" }, receipt)
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects echoed commands and manifests without isolated user config') do
        reset_skill.call
        File.write(direct_artifact, "Review result\n")
        echoed = "echo codex exec --ephemeral -s read-only -o #{direct_artifact} 'Review the change'"
        process_result('Bash', { 'command' => echoed }, { 'exit_code' => 0, 'output' => 'completed' })

        artifact = File.join(dir, 'unisolated.md')
        File.write(artifact, "Review result\n")
        manifest_path = File.join(dir, 'unisolated-manifest.json')
        File.write(manifest_path, JSON.generate({
          'backend' => 'codex-exec',
          'execution' => { 'command_mode' => 'codex exec --ephemeral', 'read_only' => true, 'isolated_user_config' => false },
          'summary' => { 'minimum_met' => true },
          'results' => [{ 'name' => 'review', 'ok' => true, 'output_path' => artifact, 'command_mode' => 'codex exec --ephemeral', 'read_only' => true, 'isolated_user_config' => false, 'output_nonempty' => true }]
        }))
        receipt = { 'exit_code' => 0, 'output' => "CODEX_FANOUT_RECEIPT=#{manifest_path}\n" }
        command = "python3 #{canonical_runner} --backend codex-exec"
        process_result('Bash', { 'command' => command }, receipt)
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects forged non-authoritative and failed-synthesis manifests') do
        reset_skill.call
        artifact = File.join(dir, 'forged.md')
        File.write(artifact, "Plausible review output\n")
        command = "python3 #{canonical_runner} --backend codex-exec"

        [
          [{ 'minimum_met' => true, 'authoritative' => false }, { 'status' => 'succeeded', 'error' => nil }],
          [{ 'minimum_met' => true, 'authoritative' => true }, { 'status' => 'failed', 'error' => 'synthesis failed' }]
        ].each_with_index do |(summary, synthesis), index|
          manifest_path = File.join(dir, "forged-manifest-#{index}.json")
          manifest = manifest_for.call([['review', artifact]])
          manifest['summary'].merge!(summary)
          manifest['synthesis'] = synthesis
          File.write(manifest_path, JSON.generate(manifest))
          response = { 'exit_code' => 0, 'output' => "CODEX_FANOUT_RECEIPT=#{manifest_path}\n" }
          process_result('Bash', { 'command' => command }, response)
        end

        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects duplicate names, duplicate artifacts, bad hashes, and inconsistent counts') do
        variants = []
        first = File.join(dir, 'integrity-a.md')
        second = File.join(dir, 'integrity-b.md')
        File.write(first, "Finding A\n")
        File.write(second, "Finding B\n")

        duplicate_name = manifest_for.call([['same', first], ['same', second]])
        duplicate_artifact = manifest_for.call([['first', first], ['second', first]])
        bad_hash = manifest_for.call([['first', first]])
        bad_hash['results'][0]['output_sha256'] = '0' * 64
        bad_counts = manifest_for.call([['first', first]])
        bad_counts['summary']['succeeded'] = 2
        partial = manifest_for.call([['first', first]])
        partial['execution']['allow_partial'] = true
        partial['summary']['authoritative'] = false
        test_mode = manifest_for.call([['first', first]])
        test_mode['execution']['testing_mode'] = true
        stale = manifest_for.call([['first', first]])
        stale['started_at'] = Time.now.to_f - 7200
        stale['completed_at'] = Time.now.to_f - 7100
        variants.concat([duplicate_name, duplicate_artifact, bad_hash, bad_counts, partial, test_mode, stale])

        variants.each_with_index do |manifest, index|
          reset_skill.call
          path = File.join(dir, "integrity-manifest-#{index}.json")
          File.write(path, JSON.generate(manifest))
          response = { 'exit_code' => 0, 'output' => "CODEX_FANOUT_RECEIPT=#{path}\n" }
          process_result('Bash', { 'command' => "python3 #{canonical_runner}" }, response)
          assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        end
        true
      end

      test('rejects fake runner scripts and codex binary override commands') do
        reset_skill.call
        artifact = File.join(dir, 'fake-script.md')
        File.write(artifact, "Finding\n")
        manifest_path = File.join(dir, 'fake-script-manifest.json')
        File.write(manifest_path, JSON.generate(manifest_for.call([['review', artifact]])))
        response = { 'exit_code' => 0, 'output' => "CODEX_FANOUT_RECEIPT=#{manifest_path}\n" }
        fake_runner = File.join(dir, 'gpt_audit.py')
        File.write(fake_runner, "print('fake')\n")
        process_result('Bash', { 'command' => "python3 #{fake_runner}" }, response)
        process_result('Bash', { 'command' => "python3 #{canonical_runner} --codex-bin /tmp/fake-codex" }, response)
        assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        true
      end

      test('rejects every shell control and compound receipt command form') do
        artifact = File.join(dir, 'shell-control.md')
        File.write(artifact, "Finding\n")
        manifest = manifest_for.call([['shell-control', artifact]])
        manifest_path = File.join(dir, 'shell-control-manifest.json')
        File.write(manifest_path, JSON.generate(manifest))
        response = { 'exit_code' => 0, 'output' => receipt_for.call(manifest_path, manifest) }
        [
          "#{canonical_command};true", "#{canonical_command}\ntrue", "#{canonical_command}&&true",
          "#{canonical_command}||true", "#{canonical_command}|tee /tmp/x", "$(#{canonical_command})",
          "`#{canonical_command}`", "#{canonical_command}>/tmp/x", "#{canonical_command}</tmp/x"
        ].each do |command|
          reset_skill.call
          process_result('Bash', { 'command' => command }, response)
          assert_eq(StateManager.get(:skill)[:codex_review_lanes_completed], 0)
        end
        true
      end

      StateManager.reset(:skill)
    end
  ensure
    ENV.delete('CLAUDE_PROJECT_DIR')
    ENV['HOME'] = old_home
    ENV['SANEAPPS_ROOT'] = old_saneapps_root
    ENV['SANEPROCESS_GPT_AUDIT_RECEIPT_ROOT'] = old_receipt_root
  end
end)
