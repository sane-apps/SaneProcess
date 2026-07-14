# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require 'time'
require 'tmpdir'
require_relative 'core/state_manager'
require_relative 'state_signer'

# Canonical SaneMaster runner receipt and replay-resistance self-tests.
module SaneTrackRunnerProofTest
  def self.run(process_result_proc, write_runner_proof_fixture_proc, ship_clearance_proof_proc)
    passed = 0
    failed = 0

    Dir.mktmpdir('sanetrack-runner-proof') do |tmpdir|
      old_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = File.join(tmpdir, 'process_metrics.jsonl')
      Dir.chdir(tmpdir) do
        system('git', 'init', '-q')
        system('git', 'config', 'user.email', 'test@example.com')
        system('git', 'config', 'user.name', 'Test')
        File.write('README.md', "runner proof fixture\n")
        system('git', 'add', 'README.md')
        system('git', 'commit', '-q', '-m', 'init')
        canonical_sanemaster = File.expand_path('../SaneMaster.rb', __dir__)
        {
          'status' => "ruby #{canonical_sanemaster} status",
          'verify' => "ruby #{canonical_sanemaster} verify",
          'ship' => "ruby #{canonical_sanemaster} release_preflight",
          'check_inbox' => "ruby #{canonical_sanemaster} check_inbox"
        }.each do |workflow, runner_command|
          StateManager.reset(:skill)
          StateManager.update(:skill) do |skill|
            skill[:required] = workflow
            skill[:runner_proved] = false
            skill[:runner_started] = false
            skill[:runner_proved] = false
            skill[:runner_commands] = []
            skill
          end

          receipt_id = write_runner_proof_fixture_proc.call(workflow, ENV['SANEMASTER_PROCESS_METRICS_PATH'])
          process_result_proc.call('Bash', { 'command' => runner_command }, { 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{receipt_id}" })
          skill = StateManager.get(:skill)
          if skill[:runner_proved] == true && skill[:runner_commands].include?(runner_command)
            passed += 1
            warn "  PASS: #{workflow} runner command satisfies workflow proof"
          else
            failed += 1
            warn "  FAIL: #{workflow} runner command should satisfy workflow proof, got #{skill.inspect}"
          end
        end

        wrapper_dir = File.join(tmpdir, 'scripts')
        FileUtils.mkdir_p(wrapper_dir)
        wrapper = File.join(wrapper_dir, 'SaneMaster.rb')
        wrapper_source = <<~BASH
          #!/bin/bash
          set -e
          find_saneprocess_infra() { :; }
          INFRA="#{canonical_sanemaster}"
          exec "${INFRA}" "$@"
        BASH
        File.write(wrapper, wrapper_source)
        FileUtils.chmod(0o755, wrapper)
        system('git', 'add', 'scripts/SaneMaster.rb')
        system('git', 'commit', '-q', '-m', 'add canonical wrapper')

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        wrapper_receipt = write_runner_proof_fixture_proc.call('status', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        wrapper_command = './scripts/SaneMaster.rb status'
        process_result_proc.call('Bash', { 'command' => wrapper_command }, {
          'exit_code' => 0, 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{wrapper_receipt}"
        })
        if StateManager.get(:skill)[:runner_proved] == true
          passed += 1
          warn '  PASS: clean canonical app wrapper normalizes to the infra runner receipt hash'
        else
          failed += 1
          warn '  FAIL: canonical app wrapper should prove the matching workflow receipt'
        end

        File.open(wrapper, 'a') { |file| file.puts('echo unsafe-extra-command') }
        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        dirty_wrapper_receipt = write_runner_proof_fixture_proc.call('status', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        process_result_proc.call('Bash', { 'command' => wrapper_command }, {
          'exit_code' => 0, 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{dirty_wrapper_receipt}"
        })
        if StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: modified app wrapper cannot reuse a canonical runner receipt'
        else
          failed += 1
          warn '  FAIL: dirty app wrapper must not prove a canonical workflow receipt'
        end
        File.write(wrapper, wrapper_source)

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        incomplete_id = write_runner_proof_fixture_proc.call(
          'status', ENV['SANEMASTER_PROCESS_METRICS_PATH'], exit_status: 3
        )
        process_result_proc.call('Bash', { 'command' => "ruby #{canonical_sanemaster} status" }, {
          'exit_code' => 3, 'output' => "incomplete\nSANEMASTER_WORKFLOW_RECEIPT=#{incomplete_id}"
        })
        if StateManager.get(:skill)[:runner_proved] == true
          passed += 1
          warn '  PASS: status exit 3 with matching incomplete receipt counts as completed status proof'
        else
          failed += 1
          warn '  FAIL: matching status exit 3 receipt should count as completed-but-incomplete proof'
        end

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        rejected_nonzero_id = write_runner_proof_fixture_proc.call(
          'status', ENV['SANEMASTER_PROCESS_METRICS_PATH'], exit_status: 2
        )
        process_result_proc.call('Bash', { 'command' => "ruby #{canonical_sanemaster} status" }, {
          'exit_code' => 2, 'output' => "failed\nSANEMASTER_WORKFLOW_RECEIPT=#{rejected_nonzero_id}"
        })
        if StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: arbitrary nonzero status cannot prove runner completion'
        else
          failed += 1
          warn '  FAIL: only documented status exit 3 may count as incomplete completion'
        end

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        write_runner_proof_fixture_proc.call('status', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        process_result_proc.call('Bash', { 'command' => "ruby #{canonical_sanemaster} status; true" }, { 'exit_code' => 0, 'output' => 'ok' })
        if StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: compound runner command cannot reuse a successful receipt'
        else
          failed += 1
          warn '  FAIL: compound runner command must not prove status'
        end

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        receipt_id = write_runner_proof_fixture_proc.call('status', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        clean_status = "ruby #{canonical_sanemaster} status"
        receipt_output = "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{receipt_id}"
        process_result_proc.call('Bash', { 'command' => clean_status }, { 'exit_code' => 0, 'output' => receipt_output })
        first_proved = StateManager.get(:skill)[:runner_proved] == true
        StateManager.update(:skill) { |skill| skill[:runner_proved] = false; skill }
        process_result_proc.call('Bash', { 'command' => clean_status }, { 'exit_code' => 0, 'output' => receipt_output })
        if first_proved && StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: consumed workflow receipt cannot prove a second runner invocation'
        else
          failed += 1
          warn '  FAIL: runner receipt replay must be rejected'
        end

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'status', runner_proved: false, runner_started: false) }
        forged_id = write_runner_proof_fixture_proc.call('status', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        fake_runner = File.join(Dir.tmpdir, 'SaneMaster.rb')
        File.write(fake_runner, "#!/usr/bin/env ruby\n")
        process_result_proc.call(
          'Bash', { 'command' => "ruby #{fake_runner} status" },
          { 'exit_code' => 0, 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{forged_id}" }
        )
        if StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: noncanonical SaneMaster runner cannot reuse a forged metric and echoed receipt ID'
        else
          failed += 1
          warn '  FAIL: noncanonical SaneMaster runner must not prove status'
        end
        FileUtils.rm_f(fake_runner)

        %w[status check_inbox].zip([
          'bash scripts/automation/sane-status-crossref.sh',
          'bash scripts/check-inbox.sh check'
        ]).each do |workflow, direct_command|
          StateManager.reset(:skill)
          StateManager.update(:skill) { |skill| skill.merge(required: workflow, runner_proved: false, runner_started: false) }
          direct_id = write_runner_proof_fixture_proc.call(workflow, ENV['SANEMASTER_PROCESS_METRICS_PATH'])
          process_result_proc.call(
            'Bash', { 'command' => direct_command },
            { 'exit_code' => 0, 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{direct_id}" }
          )
          if StateManager.get(:skill)[:runner_proved] == false && StateManager.get(:skill)[:runner_started] == false
            passed += 1
            warn "  PASS: direct #{workflow} implementation pattern is not presented as receipt-bound truth"
          else
            failed += 1
            warn "  FAIL: direct #{workflow} implementation must not match canonical runner proof"
          end
        end

        StateManager.reset(:skill)
        StateManager.update(:skill) { |skill| skill.merge(required: 'ship', runner_proved: false, runner_started: false) }
        write_runner_proof_fixture_proc.call('ship', ENV['SANEMASTER_PROCESS_METRICS_PATH'])
        process_result_proc.call(
          'Bash', { 'command' => "ruby #{canonical_sanemaster} release_preflight" },
          { 'exit_code' => 0, 'output' => "ok\nSANEMASTER_WORKFLOW_RECEIPT=#{'f' * 32}" }
        )
        if StateManager.get(:skill)[:runner_proved] == false
          passed += 1
          warn '  PASS: ship proof must bind to the just-completed release_preflight workflow receipt'
        else
          failed += 1
          warn '  FAIL: stale release_preflight status cannot prove an unrelated ship command'
        end

        clearance_path = File.expand_path('~/.claude/ship_clearance/TestApp.json')
        valid_clearance = {
          'app' => 'TestApp',
          'project_dir' => Dir.pwd,
          'git_sha' => `git -C #{Dir.pwd.shellescape} rev-parse HEAD`.strip,
          'cleared_at' => Time.now.utc.iso8601,
          'expires_at' => (Time.now.utc + 3600).iso8601
        }
        invalid_clearances = [
          valid_clearance.reject { |key, _| key == 'project_dir' },
          valid_clearance.reject { |key, _| key == 'git_sha' },
          valid_clearance.merge('expires_at' => 'not-a-time'),
          valid_clearance.merge('expires_at' => (Time.now.utc - 60).iso8601)
        ]
        invalid_clearances_rejected = invalid_clearances.all? do |payload|
          StateSigner.write_signed(clearance_path, payload)
          ship_clearance_proof_proc.call.nil?
        end
        if invalid_clearances_rejected
          passed += 1
          warn '  PASS: ship completion proof rejects incomplete malformed and expired clearance'
        else
          failed += 1
          warn '  FAIL: ship completion proof accepted an invalid clearance token'
        end
      end
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics_path
      Thread.current[:saneprocess_sanetrack_release_receipt_signer] = nil
    end

    [passed, failed]
  end
end
