#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'release_guardrail_test_support'

include TestFramework
include ReleaseGuardrailTestSupport

ReleaseGuardrailTestSupport.register(__FILE__, 'SaneMaster resource soak targets') do
  subject = ReleaseGuardrailHarness.new

  test_category('Resource soak target ownership') do
    test('command-tree parser preserves argv after the separator without a shell') do
      options = subject.send(
        :parse_resource_soak_args,
        ['--target', 'command-tree', '--cwd', '/tmp', '--timeout-seconds', '12', '--',
         'node', 'worker.mjs', '--label', 'a; touch /tmp/must-not-run']
      )

      assert_eq(options[:target], 'command-tree')
      assert_eq(options[:duration_seconds], 12)
      assert_eq(options[:command_argv], ['node', 'worker.mjs', '--label', 'a; touch /tmp/must-not-run'])
      assert(options[:require_fd])
      assert(!options[:require_physical])
      true
    end

    test('private Brave target rejects a normal signed-in browser receipt') do
      Dir.mktmpdir('resource-soak-browser-', '/private/tmp') do |dir|
        profile = File.join(dir, 'profile')
        FileUtils.mkdir_p(profile)
        receipt = File.join(dir, 'session.json')
        File.write(
          receipt,
          JSON.generate(
            schema_version: 1, browser: 'brave', private_automation: false, root_pid: 42,
            executable: RbConfig.ruby, user_data_dir: profile, extension_id: 'a' * 32,
            session_id: 'private-session-1', source_fingerprint: 'source-sha',
            package_sha256: 'b' * 64, created_at: '2026-08-09T11:59:00Z'
          )
        )
        File.chmod(0o600, receipt)

        raised = false
        begin
          subject.send(:resource_soak_prepare_browser_target,
                       target: 'browser-extension', session_receipt: receipt)
        rescue SaneMasterModules::ResourceSoakTargets::ResourceSoakTargetError => e
          raised = e.message.include?('private Brave automation session')
        end
        assert(raised, 'normal browser sessions must not become resource-soak targets')
      end
      true
    end

    test('private Brave target binds exact root identity and private profile') do
      Dir.mktmpdir('resource-soak-browser-', '/private/tmp') do |dir|
        profile = File.join(dir, 'profile')
        FileUtils.mkdir_p(profile)
        executable = File.join(dir, 'Brave Browser')
        File.write(executable, "fixture\n")
        File.chmod(0o700, executable)
        started_at = '2026-08-09T12:00:00Z'
        receipt = File.join(dir, 'session.json')
        File.write(
          receipt,
          JSON.generate(
            schema_version: 1, browser: 'brave', private_automation: true, root_pid: 42,
            executable: executable, user_data_dir: profile, extension_id: 'a' * 32,
            process_started_at: started_at, session_id: 'private-session-1',
            source_fingerprint: 'source-sha', package_sha256: 'b' * 64,
            created_at: '2026-08-09T11:59:00Z'
          )
        )
        File.chmod(0o600, receipt)
        subject.define_singleton_method(:resource_soak_process_rows) do
          [{ pid: 42, ppid: 1, pgid: 42, uid: Process.uid, started_at: started_at,
             executable: executable, command: "#{executable} --user-data-dir=#{profile}" }]
        end

        target = subject.send(:resource_soak_prepare_browser_target,
                              target: 'browser-extension', session_receipt: receipt)
        assert_eq(target[:kind], 'browser-extension')
        assert_eq(target[:ownership], 'attached')
        assert_eq(target[:root_identity][:pid], 42)
        assert_eq(target[:candidate][:extension_id], 'a' * 32)
        assert_eq(target[:candidate][:session_id], 'private-session-1')
      ensure
        subject.singleton_class.remove_method(:resource_soak_process_rows) rescue nil
      end
      true
    end

    test('process-tree sampling includes descendants but excludes siblings') do
      rows = [
        { pid: 10, ppid: 1, pgid: 10, uid: Process.uid, started_at: 'root', executable: '/tmp/root', command: '/tmp/root' },
        { pid: 11, ppid: 10, pgid: 10, uid: Process.uid, started_at: 'child', executable: '/tmp/child', command: '/tmp/child' },
        { pid: 12, ppid: 11, pgid: 10, uid: Process.uid, started_at: 'grandchild', executable: '/tmp/grandchild', command: '/tmp/grandchild' },
        { pid: 99, ppid: 1, pgid: 99, uid: Process.uid, started_at: 'other', executable: '/tmp/other', command: '/tmp/other' }
      ]
      subject.define_singleton_method(:resource_soak_process_rows) { rows }
      target = { candidate: { pid: 10 } }

      selected = subject.send(:resource_soak_target_rows, target).map { |row| row[:pid] }.sort
      assert_eq(selected, [10, 11, 12])
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_process_rows) rescue nil
    end

    test('Mini ps rows retain their trailing newline without disappearing') do
      status = Struct.new(:success?).new(true)
      line = "   42     1    42   #{Process.uid} Sun Aug  9 19:55:01 2026     /bin/sleep 30\n"
      subject.define_singleton_method(:resource_soak_capture) { |*_command| [line, status] }

      rows = subject.send(:resource_soak_process_rows)
      assert_eq(rows.length, 1)
      assert_eq(rows.first[:pid], 42)
      assert_eq(rows.first[:command], '/bin/sleep 30')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_capture) rescue nil
    end

    test('owned cleanup signals only the exact owned process group') do
      rows = [{ pid: 70, ppid: 1, pgid: 70, uid: Process.uid, started_at: 'root',
                executable: '/tmp/worker', command: '/tmp/worker' }]
      calls = 0
      subject.define_singleton_method(:resource_soak_process_rows) do
        calls += 1
        calls == 1 ? rows : []
      end
      signals = []
      subject.define_singleton_method(:resource_soak_signal_group) { |pgid, signal| signals << [pgid, signal] }
      subject.define_singleton_method(:resource_soak_wait_for_group_exit) { |_target, _seconds| [] }
      identity = rows.first.slice(:pid, :pgid, :uid, :started_at, :executable)
      target = { ownership: 'owned', pgid: 70, candidate: { pid: 70 },
                 root_identity: identity, last_identities: [identity] }

      subject.send(:resource_soak_cleanup_target, target)
      assert_eq(signals, [[70, 'TERM']])
      assert_eq(subject.send(:resource_soak_cleanup_issue, target, result: 'terminated'), nil)
      assert_includes(subject.send(:resource_soak_cleanup_issue, target, result: 'refused_identity_drift'),
                      'cleanup incomplete')
      true
    ensure
      subject.singleton_class.remove_method(:resource_soak_process_rows) rescue nil
      subject.singleton_class.remove_method(:resource_soak_signal_group) rescue nil
      subject.singleton_class.remove_method(:resource_soak_wait_for_group_exit) rescue nil
    end

    test('new target receipt records schema ownership pid sets and fd metrics') do
      Dir.mktmpdir('resource-soak-receipt-') do |dir|
        artifact = File.join(dir, 'receipt.json')
        log = File.join(dir, 'receipt.log')
        target = {
          kind: 'command-tree', ownership: 'owned', pgid: 44,
          root_identity: { pid: 44, pgid: 44, uid: Process.uid, started_at: 'start', executable: '/tmp/worker' },
          candidate: { pid: 44, pgid: 44, process_path: '/tmp/worker', process_started_at: 'start' }
        }
        subject.define_singleton_method(:resource_soak_prepare_target) { |_options| target }
        subject.define_singleton_method(:resource_soak_target_sample) do |_target|
          { sampled_at: Time.now.utc.iso8601, cpu: 0.2, rss_mb: 20.0,
            physical_footprint_mb: nil, fd_count: 7, pids: [44, 45], process_count: 2 }
        end
        subject.define_singleton_method(:resource_soak_cleanup_target) { |_target| { attempted: true, result: 'terminated' } }

        report = nil
        with_env('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => '0') do
          report = subject.resource_soak_report(
            ['--target', 'command-tree', '--artifact', artifact, '--log', log,
             '--duration-seconds', '0', '--no-exit', '--', 'ignored-fixture']
          )
        end
        payload = JSON.parse(File.read(artifact))
        assert(report[:ok], report[:issues].inspect)
        assert_eq(payload['schema_version'], 2)
        assert_eq(payload.dig('target', 'ownership'), 'owned')
        assert_eq(payload.dig('target', 'observed_pid_sets'), [[44, 45]])
        assert_eq(payload.dig('target', 'cleanup', 'result'), 'terminated')
        assert_eq(payload['peak_fd_count'], 7)
      ensure
        subject.singleton_class.remove_method(:resource_soak_prepare_target) rescue nil
        subject.singleton_class.remove_method(:resource_soak_target_sample) rescue nil
        subject.singleton_class.remove_method(:resource_soak_cleanup_target) rescue nil
      end
      true
    end

    test('implementation has no broad process kill primitive') do
      sources = %w[resource_soak.rb resource_soak_targets.rb].map do |name|
        File.read(File.expand_path(name, __dir__), encoding: Encoding::UTF_8)
      end
      assert(!sources.join.match?(/\b(?:pkill|killall)\b/), 'resource soak must never use broad process kills')
      ruby_27_only_call = '.filter_' + 'map'
      assert(!sources.join.include?(ruby_27_only_call), 'resource soak must stay compatible with Mini Ruby 2.6')
      assert_includes(sources[1], "Process.kill(signal, -Integer(pgid))")
      true
    end

    test('atomic writer rejects hardlinks and replaces an unchanged regular inode') do
      Dir.mktmpdir('resource-soak-atomic-', '/private/tmp') do |dir|
        victim = File.join(dir, 'victim')
        linked = File.join(dir, 'linked.json')
        File.write(victim, 'original')
        File.link(victim, linked)
        raised = false
        begin
          subject.send(:safe_resource_soak_write, linked, 'unsafe')
        rescue RuntimeError
          raised = true
        end
        assert(raised, 'hardlinked destinations must be rejected')
        assert_eq(File.read(victim), 'original')

        receipt = File.join(dir, 'receipt.json')
        File.write(receipt, 'old')
        old_inode = File.stat(receipt).ino
        subject.send(:safe_resource_soak_write, receipt, 'new')
        assert_eq(File.read(receipt), 'new')
        assert(File.stat(receipt).ino != old_inode, 'replacement must use an atomic new inode')
        assert_eq(File.stat(receipt).mode & 0o777, 0o600)
      end
      true
    end

    test('SaneMaster resource soak route fails closed when Mini is unavailable') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__), encoding: Encoding::UTF_8)
      assert_includes(source, 'MINI_REQUIRED_COMMANDS = Set.new(%w[resource_soak resource-soak])')
      assert_includes(source, 'will not fall back to local execution')
      assert_includes(source, 'requires the Mac mini and cannot run with a local bypass')
      true
    end
  end
end

exit(ReleaseGuardrailTestSupport.run_file(__FILE__)) if __FILE__ == $PROGRAM_NAME
