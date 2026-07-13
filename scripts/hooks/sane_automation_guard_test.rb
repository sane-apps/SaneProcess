#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'test/test_framework'
require_relative 'sane_automation_guard'

include TestFramework

HOOK_DIR = File.expand_path(__dir__)
INSTALLER = File.expand_path('../automation/codex-automation-mini.rb', __dir__)
GUARD = File.join(HOOK_DIR, 'sane_automation_guard.rb')

def valid_cron(overrides = {})
  {
    'version' => 1, 'id' => 'test-cron', 'kind' => 'cron', 'name' => 'Test Cron',
    'prompt' => 'Say "hi" — with\nnewline', 'status' => 'ACTIVE',
    'rrule' => 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', 'model' => 'gpt-5.5',
    'reasoning_effort' => 'medium', 'execution_environment' => 'local',
    'cwds' => ['/Users/stephansmac/SaneApps/infra/SaneProcess']
  }.merge(overrides)
end

VALID_THREAD_ID = '019f0f84-f36c-7d20-befe-ec52c0cbc553'

def valid_heartbeat(overrides = {})
  valid_cron({
    'kind' => 'heartbeat', 'target_thread_id' => VALID_THREAD_ID,
    'model' => 'gpt-5.5', 'reasoning_effort' => 'medium'
  }.merge(overrides))
end

def make_target_fixture(archived: 0, rollout_id: VALID_THREAD_ID, thread_id: VALID_THREAD_ID,
                        rollout: true, model: 'gpt-5.5', effort: 'medium')
  root = Dir.mktmpdir
  cwd_root = File.join(root, 'Users', 'stephansmac', 'SaneApps')
  cwd = File.join(cwd_root, 'infra', 'SaneProcess')
  sessions = File.join(root, '.codex', 'sessions')
  rollout_path = File.join(sessions, '2026', '07', '13', "rollout-#{thread_id}.jsonl")
  db = File.join(root, 'state_5.sqlite')
  FileUtils.mkdir_p(cwd)
  FileUtils.mkdir_p(File.dirname(rollout_path))
  if rollout
    File.write(rollout_path, JSON.generate({
      'type' => 'session_meta', 'payload' => { 'id' => rollout_id, 'cwd' => cwd }
    }) + "\n")
  end
  schema = <<~SQL
    CREATE TABLE threads (
      id TEXT PRIMARY KEY, archived INTEGER NOT NULL, cwd TEXT NOT NULL,
      rollout_path TEXT NOT NULL, model TEXT, reasoning_effort TEXT
    );
  SQL
  _out, err, status = Open3.capture3('sqlite3', db, schema)
  raise "fixture schema failed: #{err}" unless status.success?
  values = [thread_id, archived, cwd, rollout_path, model, effort].map do |value|
    value.nil? ? 'NULL' : "'#{value.to_s.gsub("'", "''")}'"
  end
  _out, err, status = Open3.capture3('sqlite3', db,
                                      "INSERT INTO threads VALUES (#{values.join(', ')})")
  raise "fixture insert failed: #{err}" unless status.success?
  resolver = SaneAutomationGuard::HeartbeatTargetResolver.new(
    state_db: db, sessions_root: sessions, allowed_cwd_roots: [cwd_root]
  )
  [root, resolver, db, rollout_path]
end

exit(run_tests('SaneAutomationGuard') do

test_category('TOML parser') do

  test('parses strings, ints, arrays with escapes') do
    toml = <<~TOML
      version = 1
      name = "He said \\"hi\\" \\\\ done"
      cwds = ["/a/b", "/c d/e"]
      created_at = 1779357959687
    TOML
    h = SaneAutomationGuard.parse_toml(toml)
    assert_eq(h['version'], 1)
    assert_eq(h['name'], 'He said "hi" \\ done')
    assert_eq(h['cwds'], ['/a/b', '/c d/e'])
    assert_eq(h['created_at'], 1_779_357_959_687)
  end
end

test_category('Model gate') do

  # framework note: `expected: false` is swallowed by `tc[:expected] || tc[:expect]`,
  # so truthy sentinels are used instead of booleans
  parameterized_test('gpt version policy', [
    { input: 'gpt-5.5', expected: 'ok' }, { input: 'gpt-5.5-codex', expected: 'ok' },
    { input: 'gpt-5.10', expected: 'ok' }, { input: 'gpt-6', expected: 'ok' },
    { input: 'gpt-10.2', expected: 'ok' },
    { input: 'gpt-5', expected: 'no' }, { input: 'gpt-4.1', expected: 'no' },
    { input: 'o3', expected: 'no' }, { input: '', expected: 'no' }, { input: nil, expected: 'no' }
  ]) do |model, expected|
    assert_eq(SaneAutomationGuard.gpt_version_ok?(model), expected == 'ok', "model=#{model.inspect}")
  end
end

test_category('Automation validation') do

  test('valid cron passes on Mini') do
    v = SaneAutomationGuard.validate_automation(valid_cron, dir_id: 'test-cron', host_is_mini: true)
    assert_eq(v, [])
  end

  parameterized_test('cron policy violations', [
    { input: { 'model' => 'gpt-4.1' }, expected: /gpt-5.5 or newer/ },
    { input: { 'reasoning_effort' => 'low' }, expected: /reasoning_effort/ },
    { input: { 'cwds' => [] }, expected: /non-empty `cwds`/ },
    { input: { 'cwds' => ['relative/path'] }, expected: /absolute path/ },
    { input: { 'prompt' => '' }, expected: /missing required field `prompt`/ },
    { input: { 'status' => 'RUNNING' }, expected: /must be ACTIVE or PAUSED/ }
  ]) do |overrides, pattern|
    v = SaneAutomationGuard.validate_automation(valid_cron(overrides), dir_id: 'test-cron', host_is_mini: true)
    assert(v.any? { |msg| msg =~ pattern }, "expected #{pattern} in #{v.inspect}")
  end

  test('id must match directory name') do
    v = SaneAutomationGuard.validate_automation(valid_cron, dir_id: 'other-dir', host_is_mini: true)
    assert(v.any? { |m| m.include?('does not match directory') })
  end

  test('initialized unarchived Mini-local heartbeat target passes') do
    root, resolver = make_target_fixture
    assert_eq(SaneAutomationGuard.validate_automation(valid_heartbeat, dir_id: 'test-cron',
                                                       host_is_mini: true, target_resolver: resolver), [])
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test('PAUSED heartbeat may retain a missing target but cannot activate') do
    root, resolver = make_target_fixture
    paused = valid_heartbeat('status' => 'PAUSED', 'target_thread_id' => '')
    assert_eq(SaneAutomationGuard.validate_automation(paused, dir_id: 'test-cron', host_is_mini: true,
                                                      target_resolver: resolver), [])
    active = paused.merge('status' => 'ACTIVE')
    violations = SaneAutomationGuard.validate_automation(active, dir_id: 'test-cron', host_is_mini: true,
                                                          target_resolver: resolver)
    assert(violations.any? { |message| message.include?('canonical lowercase UUID') })
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test('ACTIVE automations violate on non-Mini hosts; PAUSED pass') do
    v = SaneAutomationGuard.validate_automation(valid_cron, dir_id: 'test-cron', host_is_mini: false)
    assert(v.any? { |m| m.include?('PAUSED on non-Mini') })
    v2 = SaneAutomationGuard.validate_automation(valid_cron('status' => 'PAUSED'), dir_id: 'test-cron', host_is_mini: false)
    assert_eq(v2, [])
  end
end


test_category('Live heartbeat target validation') do

  parameterized_test('invalid target state fails closed', [
    { input: :missing_row, expected: /no thread row/ },
    { input: :missing_rollout, expected: /missing or not a regular file/ },
    { input: :id_mismatch, expected: /does not match target/ },
    { input: :archived, expected: /is archived/ },
    { input: :malformed_id, expected: /canonical lowercase UUID/ }
  ]) do |scenario, expected|
    options = {}
    options[:rollout] = false if scenario == :missing_rollout
    options[:rollout_id] = '019f0f84-f36c-7d20-befe-ec52c0cbc554' if scenario == :id_mismatch
    options[:archived] = 1 if scenario == :archived
    root, resolver, db = make_target_fixture(**options)
    target = scenario == :malformed_id ? '019f0f84-f36c' : VALID_THREAD_ID
    if scenario == :missing_row
      _out, err, status = Open3.capture3('sqlite3', db, 'DELETE FROM threads')
      raise "fixture delete failed: #{err}" unless status.success?
    end
    violations = resolver.validate(target, automation: valid_heartbeat)
    assert(violations.any? { |message| message =~ expected }, "expected #{expected} in #{violations.inspect}")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test('out-of-scope cwd fails') do
    root, resolver, db, rollout_path = make_target_fixture
    outside = File.join(root, 'tmp', 'outside')
    FileUtils.mkdir_p(outside)
    _out, err, status = Open3.capture3('sqlite3', db,
                                      "UPDATE threads SET cwd = '#{outside.gsub("'", "''")}'")
    raise "fixture update failed: #{err}" unless status.success?
    payload = { 'type' => 'session_meta', 'payload' => { 'id' => VALID_THREAD_ID, 'cwd' => outside } }
    File.write(rollout_path, JSON.generate(payload) + "\n")
    violations = resolver.validate(VALID_THREAD_ID, automation: valid_heartbeat)
    assert(violations.any? { |message| message.include?('not an allowed Mini-local directory') })
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test('missing state DB fails closed') do
    Dir.mktmpdir do |root|
      resolver = SaneAutomationGuard::HeartbeatTargetResolver.new(
        state_db: File.join(root, 'missing.sqlite'), sessions_root: root, allowed_cwd_roots: [root]
      )
      violations = resolver.validate(VALID_THREAD_ID, automation: valid_heartbeat)
      assert(violations.any? { |message| message.include?('failed closed') })
    end
  end

  test('unreadable state DB query fails closed through injected store') do
    failing_store = Object.new
    failing_store.define_singleton_method(:fetch_thread) do |_db, _thread_id|
      raise 'permission denied while opening state DB'
    end
    resolver = SaneAutomationGuard::HeartbeatTargetResolver.new(
      state_db: '/injected/state.sqlite', sessions_root: '/injected/sessions',
      allowed_cwd_roots: ['/Users/stephansmac/SaneApps'], thread_store: failing_store
    )
    violations = resolver.validate(VALID_THREAD_ID, automation: valid_heartbeat)
    assert(violations.any? { |message| message.include?('failed closed') && message.include?('permission denied') })
  end

  test('declarative heartbeat metadata cannot bypass missing thread model defaults') do
    root, resolver = make_target_fixture(model: nil, effort: nil)
    violations = resolver.validate(VALID_THREAD_ID, automation: valid_heartbeat)
    assert(violations.any? { |message| message.include?('thread row model/reasoning') })
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end
end

test_category('Store validation + installer') do

  test('validate_store flags bad entries, skips non-spec dirs') do
    Dir.mktmpdir do |store|
      FileUtils.mkdir_p(File.join(store, 'manual-review')) # no automation.toml -> skipped
      good = File.join(store, 'good-cron'); FileUtils.mkdir_p(good)
      File.write(File.join(good, 'automation.toml'),
                 "id = \"good-cron\"\nkind = \"cron\"\nname = \"G\"\nprompt = \"p\"\nstatus = \"PAUSED\"\n" \
                 "rrule = \"FREQ=DAILY\"\nmodel = \"gpt-5.5\"\nreasoning_effort = \"high\"\ncwds = [\"/tmp\"]\n")
      bad = File.join(store, 'bad-cron'); FileUtils.mkdir_p(bad)
      File.write(File.join(bad, 'automation.toml'),
                 "id = \"bad-cron\"\nkind = \"cron\"\nname = \"B\"\nprompt = \"p\"\nstatus = \"ACTIVE\"\n" \
                 "rrule = \"FREQ=DAILY\"\nmodel = \"gpt-4.1\"\nreasoning_effort = \"low\"\ncwds = []\n")
      report = SaneAutomationGuard.validate_store(store, host_is_mini: true)
      assert_eq(report[:checked], 2)
      assert_eq(report[:skipped], 1)
      assert_eq(report[:violations].keys, ['bad-cron'])
      assert_eq(report[:violations]['bad-cron'].size, 3)
    end
  end

  test('guard CLI exits 0 clean / 1 with violations') do
    Dir.mktmpdir do |store|
      good = File.join(store, 'ok'); FileUtils.mkdir_p(good)
      File.write(File.join(good, 'automation.toml'),
                 "id = \"ok\"\nkind = \"cron\"\nname = \"G\"\nprompt = \"p\"\nstatus = \"PAUSED\"\n" \
                 "rrule = \"FREQ=DAILY\"\nmodel = \"gpt-6\"\nreasoning_effort = \"medium\"\ncwds = [\"/tmp\"]\n")
      _o, _e, s = Open3.capture3('ruby', GUARD, '--validate', store)
      assert_eq(s.exitstatus, 0)
      File.write(File.join(good, 'automation.toml'), "id = \"ok\"\nkind = \"cron\"\n")
      _o, err, s2 = Open3.capture3('ruby', GUARD, '--validate', store)
      assert_eq(s2.exitstatus, 1)
      assert_match(err, /VIOLATIONS/)
    end
  end

  test('guard CLI distinguishes schema-valid specs from live-target-valid heartbeats') do
    root, _resolver, db, rollout_path = make_target_fixture
    store = File.join(root, 'automations')
    spec_dir = File.join(store, 'test-cron')
    FileUtils.mkdir_p(spec_dir)
    hb = valid_heartbeat
    File.write(File.join(spec_dir, 'automation.toml'), hb.map { |key, value|
      %(#{key} = "#{value.to_s.gsub('\\', '\\\\').gsub('"', '\\"')}")
    }.join("\n") + "\n")
    env = {
      'SANE_AUTOMATION_STATE_DB' => db,
      'SANE_AUTOMATION_SESSIONS_ROOT' => File.dirname(File.dirname(File.dirname(File.dirname(rollout_path)))),
      'SANE_AUTOMATION_ALLOWED_CWD_ROOTS' => File.join(root, 'Users', 'stephansmac', 'SaneApps')
    }
    _out, err, status = Open3.capture3(env, 'ruby', GUARD, '--validate', store)
    assert_eq(status.exitstatus, 0)
    assert_match(err, /schema-valid/)
    assert_match(err, /1 ACTIVE heartbeat target\(s\) live-target-valid/)
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test('installer installs valid spec, preserves created_at, rejects bad spec') do
    Dir.mktmpdir do |store|
      env = { 'SANE_AUTOMATION_STORE' => store }
      spec = File.join(store, 'spec.json')
      File.write(spec, JSON.generate(valid_cron('status' => 'PAUSED')))
      out, _e, s = Open3.capture3(env, '/usr/bin/ruby', INSTALLER, 'install', spec)
      assert_eq(s.exitstatus, 0)
      toml_path = out.strip
      assert(File.file?(toml_path), 'toml written')
      first = SaneAutomationGuard.parse_toml(File.read(toml_path, encoding: 'UTF-8'))
      assert_eq(first['id'], 'test-cron')
      assert_eq(first['prompt'], %q{Say "hi" — with\nnewline})
      assert_eq(first['cwds'], ['/Users/stephansmac/SaneApps/infra/SaneProcess'])
      created = first['created_at']
      assert(created.is_a?(Integer) && created.positive?)

      sleep 0.01
      _o, _e2, s2 = Open3.capture3(env, '/usr/bin/ruby', INSTALLER, 'install', spec)
      assert_eq(s2.exitstatus, 0)
      second = SaneAutomationGuard.parse_toml(File.read(toml_path, encoding: 'UTF-8'))
      assert_eq(second['created_at'], created, 'created_at preserved on reinstall')
      assert(second['updated_at'] >= created)

      File.write(spec, JSON.generate(valid_cron('model' => 'gpt-4.1')))
      _o, err, s3 = Open3.capture3(env, '/usr/bin/ruby', INSTALLER, 'install', spec)
      assert_eq(s3.exitstatus, 1)
      assert_match(err, /spec rejected/)
    end
  end

end

end)
