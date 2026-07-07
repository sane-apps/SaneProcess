#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the gate certifier override + unfair-gate self-improvement.
# Run: ruby scripts/sanemaster/gate_override_test.rb

require 'json'
require 'fileutils'
require 'tmpdir'
require 'time'

ENV['CLAUDE_HOOK_SECRET'] ||= 'gate-override-test-secret'
require_relative 'gate_override'
GO = SaneMasterModules::GateOverride

$passed = 0
$total = 0

def t(name, ok)
  $total += 1
  if ok
    $passed += 1
    warn "  ✅ #{name}"
  else
    warn "  ❌ #{name}"
  end
end

def in_tmp
  Dir.mktmpdir('gate-override-') do |dir|
    Dir.chdir(dir) do
      FileUtils.mkdir_p('.claude')
      yield
    end
  end
end

NOW = Time.parse('2026-06-29T12:00:00Z')
TRIGGER = NOW - 600 # the block fired 10 min before the certifier ruled on it

warn '--- override token lifecycle ---'
in_tmp do
  GO.record(gate: 'research', slug: 'foo', verdict: 'override', note: 'apple-docs down', now: NOW)
  t('override clears a block it post-dates',
    GO.clears?(gate: 'research', slug: 'foo', trigger_time: TRIGGER, now: NOW + 60))
  t('override does NOT clear a different slug',
    !GO.clears?(gate: 'research', slug: 'bar', trigger_time: TRIGGER, now: NOW + 60))
  t('override does NOT clear a different gate',
    !GO.clears?(gate: 'verify-escalation', slug: 'foo', trigger_time: TRIGGER, now: NOW + 60))
  t('override does NOT clear a block that POST-dates it (newer trigger ⇒ re-earn)',
    !GO.clears?(gate: 'research', slug: 'foo', trigger_time: NOW + 300, now: NOW + 360))
  t('override EXPIRES after its TTL',
    !GO.clears?(gate: 'research', slug: 'foo', trigger_time: TRIGGER, now: NOW + GO::DEFAULT_TTL_SECONDS + 60))
end

warn ''
warn '--- only "override" mints a clearing token ---'
in_tmp do
  GO.record(gate: 'research', slug: 'foo', verdict: 'uphold', note: 'really not done', now: NOW)
  t('uphold verdict mints NO clearing token',
    !GO.clears?(gate: 'research', slug: 'foo', trigger_time: TRIGGER, now: NOW + 60))
  GO.record(gate: 'research', slug: 'foo', verdict: 'fill', note: 'did the searches', now: NOW)
  t('fill verdict mints NO clearing token (the real tool-calls satisfy the floor instead)',
    !GO.clears?(gate: 'research', slug: 'foo', trigger_time: TRIGGER, now: NOW + 60))
end

warn ''
warn '--- a hand-forged token is rejected (tamper-evident) ---'
in_tmp do
  forged = {
    'overrides' => [{
      'gate' => 'research', 'slug' => 'foo', 'verdict' => 'override',
      'certified_at' => NOW.utc.iso8601, 'ttl_seconds' => 7200
    }],
    '__sig__' => 'deadbeefdeadbeef'
  }
  File.write('.claude/gate-overrides.json', JSON.pretty_generate(forged))
  t('hand-forged (bad-signature) override grants nothing',
    !GO.clears?(gate: 'research', slug: 'foo', trigger_time: TRIGGER, now: NOW + 60))
end

warn ''
warn '--- self-improvement: gate auto-flags as unfair after threshold ---'
in_tmp do
  (1...GO::UNFAIR_THRESHOLD).each do |i|
    GO.record(gate: 'research', slug: "slug#{i}", verdict: 'override', note: 'x', now: NOW + i)
  end
  t('below threshold a gate is NOT yet flagged unfair', !GO.unfair?(gate: 'research'))
  GO.record(gate: 'research', slug: 'slugN', verdict: 'override', note: 'x', now: NOW + GO::UNFAIR_THRESHOLD)
  t('at threshold the gate flags itself unfair', GO.unfair?(gate: 'research'))
  t('unfair banner is produced for a flagged gate', !GO.unfair_banner(gate: 'research').nil?)
  t('an un-overridden gate is not flagged', !GO.unfair?(gate: 'verify-escalation'))
end

warn ''
warn "#{$passed}/#{$total} gate-override tests passed"
exit($passed == $total ? 0 : 1)
