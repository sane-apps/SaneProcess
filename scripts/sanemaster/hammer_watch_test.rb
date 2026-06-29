#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the hammer detector: re-hitting a gate with no new work between
# attempts is flagged; legitimate iteration (changing fingerprint) never is.
# Run: ruby scripts/sanemaster/hammer_watch_test.rb

require 'json'
require 'fileutils'
require 'tmpdir'
require 'time'

ENV['CLAUDE_HOOK_SECRET'] ||= 'hammer-watch-test-secret'
require_relative 'hammer_watch'
HW = SaneMasterModules::HammerWatch

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
  Dir.mktmpdir('hammer-watch-') do |dir|
    Dir.chdir(dir) do
      FileUtils.mkdir_p('.claude')
      yield
    end
  end
end

NOW = Time.parse('2026-06-29T12:00:00Z')

warn '--- streak accrues only on no-progress re-hits ---'
in_tmp do
  t('first hit is not hammering', HW.record_block(gate: 'research', fingerprint: 'A', now: NOW) == 1 && !HW.hammering?(gate: 'research'))
  t('second identical-fingerprint hit increments', HW.record_block(gate: 'research', fingerprint: 'A', now: NOW + 1) == 2)
  third = HW.record_block(gate: 'research', fingerprint: 'A', now: NOW + 2)
  t('third no-progress hit reaches the threshold', third == HW::HAMMER_THRESHOLD)
  t('gate is now flagged as hammering', HW.hammering?(gate: 'research'))
  t('a hammer banner is produced', !HW.banner(gate: 'research').nil?)
end

warn ''
warn '--- a changing fingerprint = real iteration, never flagged ---'
in_tmp do
  HW.record_block(gate: 'research', fingerprint: 'A', now: NOW)
  HW.record_block(gate: 'research', fingerprint: 'A', now: NOW + 1)
  reset = HW.record_block(gate: 'research', fingerprint: 'B', now: NOW + 2) # did new work
  t('new fingerprint resets the streak to 1', reset == 1)
  HW.record_block(gate: 'research', fingerprint: 'B', now: NOW + 3)
  t('two hits across two distinct fingerprints is not hammering', !HW.hammering?(gate: 'research'))
end

warn ''
warn '--- clearing on a pass resolves the streak ---'
in_tmp do
  3.times { |i| HW.record_block(gate: 'research', fingerprint: 'A', now: NOW + i) }
  t('hammering before clear', HW.hammering?(gate: 'research'))
  HW.clear(gate: 'research', now: NOW + 10)
  t('not hammering after the gate is passed/cleared', !HW.hammering?(gate: 'research'))
end

warn ''
warn '--- real progress changes the measured fingerprint ---'
in_tmp do
  system('git', 'init', '-q')
  first = HW.current_fingerprint
  File.write('new_research_test.rb', 'proof')
  second = HW.current_fingerprint
  t('creating an untracked file changes the fingerprint', first != second)
end
in_tmp do
  first = HW.current_fingerprint
  File.write('.claude/gate-override-log.jsonl', JSON.generate('gate' => 'research', 'verdict' => 'uphold') + "\n")
  second = HW.current_fingerprint
  t('recording a certifier verdict changes the fingerprint', first != second)
end

warn ''
warn '--- fail-safe + tamper-evidence (never falsely accuse) ---'
in_tmp do
  3.times { HW.record_block(gate: 'research', fingerprint: '', now: NOW) }
  t('an unmeasurable (empty) fingerprint never accrues a streak', !HW.hammering?(gate: 'research'))
end
in_tmp do
  forged = { 'research' => { 'streak' => 99, 'fingerprint' => 'A' }, '__sig__' => 'deadbeef' }
  File.write('.claude/gate-hits.json', JSON.generate(forged))
  t('a hand-forged hits file (bad signature) is ignored', !HW.hammering?(gate: 'research'))
end

warn ''
warn "#{$passed}/#{$total} hammer-watch tests passed"
exit($passed == $total ? 0 : 1)
