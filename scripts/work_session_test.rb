#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'sanemaster/base'
require 'stringio'
include TestFramework

class WorkSessionFixture
  include SaneMasterModules::Base
  attr_reader :identities, :events, :commands
  attr_accessor :fail_spawn, :missing_assertions

  def initialize
    @identities = {}
    @events = []
    @commands = []
    @next_pid = 900_000
  end

  def work_session_process_identity(pid) = @identities[pid]
  def work_session_assertions_ready?(pid) = identities.key?(pid) && !missing_assertions
  def sleep(*) = nil
  def ensure_sop_dirs = nil
  def acquire_server_maintenance_holder! = nil
  def apply_work_session_defaults = raise('must not change lock preferences')
  def capture_work_session_defaults = raise('must not capture stale lock preferences')
  def restore_work_session_defaults = raise('must not restore stale lock preferences')

  def spawn(*args, **options)
    raise 'fixture spawn failed' if fail_spawn
    @next_pid += 1
    @commands << [args, options]
    @events << [:spawn, @next_pid]
    @identities[@next_pid] = {
      'uid' => Process.uid, 'executable' => '/usr/bin/caffeinate', 'started_at' => "start-#{@next_pid}"
    }
    @next_pid
  end

  def kill(signal, pid)
    raise Errno::ESRCH unless identities[pid]
    return 1 if signal == 0
    @events << [:kill, pid, read_work_session_record&.fetch('pid')]
    @identities.delete(pid)
    1
  end
end

def work_session_fixture
  Dir.mktmpdir('work-session-test') do |dir|
    base = SaneMasterModules::Base
    names = %i[WORK_SESSION_CAFFEINATE_PID_FILE WORK_SESSION_CAFFEINATE_LOG WORK_SESSION_STATE_FILE WORK_SESSION_RESTART_INHIBIT]
    saved = names.to_h { |name| [name, base.const_get(name)] }
    saved.each_key { |name| base.send(:remove_const, name); base.const_set(name, File.join(dir, name.to_s)) }
    fixture = WorkSessionFixture.new
    methods = %i[spawn detach kill].to_h { |name| [name, Process.method(name)] }
    Process.define_singleton_method(:spawn) { |*args, **opts| fixture.spawn(*args, **opts) }
    Process.define_singleton_method(:detach) { |_pid| nil }
    Process.define_singleton_method(:kill) { |signal, pid| fixture.kill(signal, pid) }
    yield fixture, base
  ensure
    methods&.each { |name, method| Process.define_singleton_method(name, method) }
    saved&.each { |name, value| base.send(:remove_const, name); base.const_set(name, value) }
  end
end

exit(run_tests('Bounded work-session protection') do
  test_category('Renewal, ownership, and settings preservation') do
    test('bounded detached replacement exists before the previous owned process is stopped') do
      work_session_fixture do |guard, base|
        assert(guard.activate_work_session_caffeinate)
        old = guard.read_work_session_record
        assert(guard.activate_work_session_caffeinate)
        current = guard.read_work_session_record
        command, options = guard.commands.last
        assert_eq(command, ['/usr/bin/nice', '-n', '10', '/usr/bin/caffeinate', '-dimsu', '-t', '43200'])
        assert_eq(options[:pgroup], true)
        assert_eq(options[:in], File::NULL)
        assert_eq(current['uid'], Process.uid)
        assert((Time.iso8601(current['expires_at']) - Time.now).between?(43_198, 43_200))
        assert_eq(guard.events.last, [:kill, old['pid'], current['pid']])
        assert_eq(File.stat(base::WORK_SESSION_CAFFEINATE_PID_FILE).mode & 0o777, 0o600)
        guard.stop_work_session_caffeinate
        assert(!guard.identities.key?(current['pid']))
        assert(!File.exist?(base::WORK_SESSION_CAFFEINATE_PID_FILE))
      end
      true
    end

    test('legacy integer and reused PID records never authorize a kill') do
      work_session_fixture do |guard, base|
        pid = guard.spawn
        File.write(base::WORK_SESSION_CAFFEINATE_PID_FILE, pid.to_s)
        assert_eq(guard.read_work_session_caffeinate_pid, pid)
        assert(!guard.owned_work_session_process?(guard.read_work_session_record))
        assert(guard.activate_work_session_caffeinate)
        assert(guard.identities.key?(pid), 'legacy process was killed')
        current = guard.read_work_session_record
        guard.identities[current['pid']]['started_at'] = 'different process incarnation'
        guard.stop_work_session_caffeinate
        assert(guard.identities.key?(current['pid']), 'reused PID was killed')
        assert(!guard.events.any? { |event| event.first == :kill })
      end
      true
    end

    test('spawn failure preserves the prior session and reports failure') do
      work_session_fixture do |guard, base|
        assert(guard.activate_work_session_caffeinate)
        previous = File.read(base::WORK_SESSION_CAFFEINATE_PID_FILE)
        guard.fail_spawn = true
        assert(!guard.activate_work_session_caffeinate)
        assert_eq(File.read(base::WORK_SESSION_CAFFEINATE_PID_FILE), previous)
        assert(!guard.events.any? { |event| event.first == :kill })
      end
      true
    end

    test('missing owned assertions rejects startup without stopping the old session') do
      work_session_fixture do |guard, base|
        assert(guard.activate_work_session_caffeinate)
        old = guard.read_work_session_record
        guard.missing_assertions = true
        assert(!guard.activate_work_session_caffeinate)
        assert_eq(guard.read_work_session_record, old)
        assert(guard.identities.key?(old['pid']))
        assert_eq(guard.events.count { |event| event.first == :kill }, 1)
      end
      true
    end

    test('normal startup and off preserve current preferences and legacy snapshots') do
      work_session_fixture do |guard, base|
        File.write(base::WORK_SESSION_STATE_FILE, '{"old":"snapshot"}')
        guard.ensure_work_session_ready!('verify')
        assert(guard.owned_work_session_process?(guard.read_work_session_record))
        guard.work_session_off
        assert_eq(File.read(base::WORK_SESSION_STATE_FILE), '{"old":"snapshot"}')
      end
      true
    end

    test('expired or unverified records are not reported as protected') do
      work_session_fixture do |guard, base|
        assert(guard.activate_work_session_caffeinate)
        record = guard.read_work_session_record.merge('expires_at' => (Time.now - 1).utc.iso8601)
        File.write(base::WORK_SESSION_CAFFEINATE_PID_FILE, JSON.generate(record))
        output = StringIO.new
        previous_stdout, $stdout = $stdout, output
        guard.print_work_session_status
        assert_includes(output.string, 'NOT PROTECTED')
      ensure
        $stdout = previous_stdout if previous_stdout
      end
      true
    end
  end
end ? 0 : 1)
