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
    { input: 'gpt-6', expected: 'ok' }, { input: 'gpt-10.2', expected: 'ok' },
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

  test('heartbeat requires target_thread_id') do
    hb = valid_cron('kind' => 'heartbeat')
    v = SaneAutomationGuard.validate_automation(hb, dir_id: 'test-cron', host_is_mini: true)
    assert(v.any? { |m| m.include?('target_thread_id') })
    hb['target_thread_id'] = '019f0f84-f36c'
    assert_eq(SaneAutomationGuard.validate_automation(hb, dir_id: 'test-cron', host_is_mini: true), [])
  end

  test('ACTIVE automations violate on non-Mini hosts; PAUSED pass') do
    v = SaneAutomationGuard.validate_automation(valid_cron, dir_id: 'test-cron', host_is_mini: false)
    assert(v.any? { |m| m.include?('PAUSED on non-Mini') })
    v2 = SaneAutomationGuard.validate_automation(valid_cron('status' => 'PAUSED'), dir_id: 'test-cron', host_is_mini: false)
    assert_eq(v2, [])
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

  test('installer installs valid spec, preserves created_at, rejects bad spec') do
    Dir.mktmpdir do |store|
      env = { 'SANE_AUTOMATION_STORE' => store }
      spec = File.join(store, 'spec.json')
      File.write(spec, JSON.generate(valid_cron('status' => 'PAUSED')))
      out, _e, s = Open3.capture3(env, 'ruby', INSTALLER, 'install', spec)
      assert_eq(s.exitstatus, 0)
      toml_path = out.strip
      assert(File.file?(toml_path), 'toml written')
      first = SaneAutomationGuard.parse_toml(File.read(toml_path, encoding: 'UTF-8'))
      assert_eq(first['id'], 'test-cron')
      created = first['created_at']
      assert(created.is_a?(Integer) && created.positive?)

      sleep 0.01
      _o, _e2, s2 = Open3.capture3(env, 'ruby', INSTALLER, 'install', spec)
      assert_eq(s2.exitstatus, 0)
      second = SaneAutomationGuard.parse_toml(File.read(toml_path, encoding: 'UTF-8'))
      assert_eq(second['created_at'], created, 'created_at preserved on reinstall')
      assert(second['updated_at'] >= created)

      File.write(spec, JSON.generate(valid_cron('model' => 'gpt-4.1')))
      _o, err, s3 = Open3.capture3(env, 'ruby', INSTALLER, 'install', spec)
      assert_eq(s3.exitstatus, 1)
      assert_match(err, /spec rejected/)
    end
  end

end

end)