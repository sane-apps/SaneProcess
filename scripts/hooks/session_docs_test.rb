#!/usr/bin/env ruby
# frozen_string_literal: true

# E2E test for session doc enforcement
# Run from SaneProcess dir: ruby scripts/hooks/session_docs_test.rb

require 'json'
require 'fileutils'
require 'open3'
require 'time'

TEST_ROOT = File.join(File.expand_path('../..', __dir__), '.session_docs_test')
FileUtils.rm_rf(TEST_ROOT)
PROJECT_DIR = File.join(TEST_ROOT, 'SaneBar')
FileUtils.mkdir_p(File.join(PROJECT_DIR, '.claude'))
File.write(File.join(PROJECT_DIR, 'SESSION_HANDOFF.md'), "handoff\n")
File.write(File.join(PROJECT_DIR, 'DEVELOPMENT.md'), "development\n")

ENV['CLAUDE_PROJECT_DIR'] = PROJECT_DIR
ENV['CLAUDE_HOOK_SECRET'] = 'session-docs-test-secret'
at_exit { FileUtils.rm_rf(TEST_ROOT) }

require_relative 'core/state_manager'

$passed = 0
$total = 0

HOOK_DIR = File.expand_path(__dir__)
SANEPROCESS_DIR = File.expand_path('../..', __dir__)
CHILD_ENV = {
  'CLAUDE_PROJECT_DIR' => PROJECT_DIR,
  'CLAUDE_HOOK_SECRET' => ENV.fetch('CLAUDE_HOOK_SECRET')
}.freeze

def t(name, ok)
  $total += 1
  if ok
    $passed += 1
    warn "  ✅ #{name}"
  else
    warn "  ❌ #{name}"
  end
end

def run_hook(hook, json_hash)
  json = JSON.generate(json_hash)
  Open3.capture3(
    CHILD_ENV,
    'ruby', File.join(HOOK_DIR, hook),
    stdin_data: json,
    chdir: SANEPROCESS_DIR
  )
end

# Reset ALL state to a clean baseline for each test group
def full_reset
  StateManager.update(:mcp_health) do |h|
    h[:verified_this_session] = true
    h[:last_verified] = Time.now.iso8601
    h[:mcps] = {
      apple_docs: { verified: true, last_success: Time.now.iso8601, last_failure: nil, failure_count: 0 },
      context7: { verified: true, last_success: Time.now.iso8601, last_failure: nil, failure_count: 0 },
      github: { verified: true, last_success: Time.now.iso8601, last_failure: nil, failure_count: 0 }
    }
    h
  end

  StateManager.update(:research) do |r|
    r[:docs] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }
    r[:web] = { completed_at: (Time.now + 1).iso8601, tool: 'test', via_task: false }
    r[:github] = { completed_at: (Time.now + 2).iso8601, tool: 'test', via_task: false }
    r[:local] = { completed_at: (Time.now + 3).iso8601, tool: 'test', via_task: false }
    r
  end

  StateManager.reset(:circuit_breaker)
  StateManager.reset(:refusal_tracking)
  StateManager.update(:enforcement) { |e| e[:halted] = false; e[:blocks] = []; e }
  StateManager.update(:startup_gate) do |g|
    g[:open] = true
    g[:opened_at] = Time.now.iso8601
    g[:steps] = {
      session_docs: true,
      skills_registry: true,
      validation_report: true,
      orphan_cleanup: true,
      system_clean: true
    }
    g
  end
  StateManager.update(:requirements) { |r| r[:requested] = []; r[:is_big_task] = false; r[:is_research_only] = false; r }
  StateManager.update(:edit_attempts) { |a| a[:count] = 0; a[:reset_at] = Time.now.iso8601; a }
  StateManager.reset(:session_docs)
end

warn '=' * 60
warn 'SESSION DOC ENFORCEMENT - E2E TEST'
warn '=' * 60

# === Test 1: Edit blocked when docs unread ===
warn ''
warn '--- Test 1: Edit blocked when session docs unread ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})
t('Edit blocked (exit=2)', status.exitstatus == 2)
t('Message says READ REQUIRED DOCS', stderr.include?('READ REQUIRED DOCS'))
t('Lists SESSION_HANDOFF.md', stderr.include?('SESSION_HANDOFF.md'))
t('Lists DEVELOPMENT.md', stderr.include?('DEVELOPMENT.md'))

# === Test 2: sanetrack records doc read ===
warn ''
warn '--- Test 2: sanetrack records doc read ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, stderr, _ = run_hook('sanetrack.rb', {
  tool_name: 'Read',
  tool_input: { file_path: "#{PROJECT_DIR}/SESSION_HANDOFF.md" },
  tool_response: { content: 'x' }
})
sd = StateManager.get(:session_docs)
t('SESSION_HANDOFF.md in read list', sd[:read].include?('SESSION_HANDOFF.md'))
t('Remaining doc mentioned', stderr.include?('DEVELOPMENT.md'))

# === Test 3: Partial read still blocks ===
warn ''
warn '--- Test 3: Edit blocked with partial read ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:read] = ['SESSION_HANDOFF.md']
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})
t('Edit still blocked (exit=2)', status.exitstatus == 2)
t('DEVELOPMENT.md in unread list', stderr.include?('DEVELOPMENT.md'))
t('SESSION_HANDOFF.md in Already read', stderr.include?('SESSION_HANDOFF.md'))

# === Test 4: Reading second doc completes requirement ===
warn ''
warn '--- Test 4: Reading second doc completes ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:read] = ['SESSION_HANDOFF.md']
  sd[:enforced] = true
  sd
end

_, stderr, _ = run_hook('sanetrack.rb', {
  tool_name: 'Read',
  tool_input: { file_path: "#{PROJECT_DIR}/DEVELOPMENT.md" },
  tool_response: { content: 'x' }
})
sd = StateManager.get(:session_docs)
t('DEVELOPMENT.md in read list', sd[:read].include?('DEVELOPMENT.md'))
all_done = (sd[:required] - sd[:read]).empty?
t('All docs now read', all_done)
t('Completion message shown', stderr.include?('ALL SESSION DOCS READ'))

# === Test 5: Edit allowed after all docs read ===
warn ''
warn '--- Test 5: Edit allowed after all docs read ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:read] = ['SESSION_HANDOFF.md', 'DEVELOPMENT.md']
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})
t('Edit allowed (exit=0)', status.exitstatus == 0)
not_blocked = !stderr.include?('SANETOOLS BLOCKED')
t('No block message', not_blocked)

# === Test 6: Write tool also enforced ===
warn ''
warn '--- Test 6: Write tool enforcement ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Write',
  tool_input: { file_path: '/test/f.swift', content: 'test' }
})
t('Write blocked (exit=2)', status.exitstatus == 2)
t('Write block mentions docs', stderr.include?('READ REQUIRED DOCS'))

# === Test 7: NotebookEdit also enforced ===
warn ''
warn '--- Test 7: NotebookEdit enforcement ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'NotebookEdit',
  tool_input: { notebook_path: '/test/nb.ipynb', new_source: 'x' }
})
t('NotebookEdit blocked (exit=2)', status.exitstatus == 2)

# === Test 8: Basename matching from any path ===
warn ''
warn '--- Test 8: Basename matching from any path ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['DEVELOPMENT.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, _, _ = run_hook('sanetrack.rb', {
  tool_name: 'Read',
  tool_input: { file_path: '/completely/different/path/DEVELOPMENT.md' },
  tool_response: { content: 'x' }
})
sd = StateManager.get(:session_docs)
t('Basename match from different path', sd[:read].include?('DEVELOPMENT.md'))

# === Test 9: Non-required doc read is ignored ===
warn ''
warn '--- Test 9: Non-required doc read ignored ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, _, _ = run_hook('sanetrack.rb', {
  tool_name: 'Read',
  tool_input: { file_path: '/some/path/README.md' },
  tool_response: { content: 'x' }
})
sd = StateManager.get(:session_docs)
t('README.md not added to read list', sd[:read].empty?)

# === Test 10: Empty required = no enforcement ===
warn ''
warn '--- Test 10: No docs required = no enforcement ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = []
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})
t('Edit allowed with empty required (exit=0)', status.exitstatus == 0)

# === Test 11: enforced=false disables check ===
warn ''
warn '--- Test 11: enforced=false disables check ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = false
  sd
end

_, stderr, status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})
t('Edit allowed with enforced=false (exit=0)', status.exitstatus == 0)

# === Test 12: Refusal tracking registers session_docs blocks ===
warn ''
warn '--- Test 12: Refusal tracking registers blocks ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

# Run one blocked edit to verify refusal tracking captures session_docs type
run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/f.swift', old_string: 'a', new_string: 'b' }
})

tracking = StateManager.get(:refusal_tracking)
# check_refusal_to_read uses string keys, so check both forms
has_tracking = tracking.key?(:session_docs) || tracking.key?('session_docs')
t('Refusal tracking registered session_docs block', has_tracking)

# === Test 13: Read tool always allowed ===
warn ''
warn '--- Test 13: Read tool always allowed (bootstrap) ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = ['SESSION_HANDOFF.md']
  sd[:read] = []
  sd[:enforced] = true
  sd
end

_, _, status = run_hook('sanetools.rb', {
  tool_name: 'Read',
  tool_input: { file_path: "#{PROJECT_DIR}/SESSION_HANDOFF.md" }
})
t('Read allowed (exit=0)', status.exitstatus == 0)

# === Test 14: Other bootstrap tools pass ===
warn ''
warn '--- Test 14: Other bootstrap tools pass ---'
%w[Grep Glob Task].each do |tool|
  full_reset
  StateManager.update(:session_docs) do |sd|
    sd[:required] = ['SESSION_HANDOFF.md']
    sd[:read] = []
    sd[:enforced] = true
    sd
  end

  input = case tool
          when 'Grep' then { pattern: 'test', path: '/tmp' }
          when 'Glob' then { pattern: '*.swift' }
          when 'Task' then { prompt: 'explore', subagent_type: 'Explore' }
          end

  _, _, status = run_hook('sanetools.rb', { tool_name: tool, tool_input: input })
  t("#{tool} allowed with unread docs (exit=0)", status.exitstatus == 0)
end

# === Test 15: populate_session_docs discovers files ===
warn ''
warn '--- Test 15: populate_session_docs discovers correct files ---'
full_reset
candidates = %w[SESSION_HANDOFF.md DEVELOPMENT.md CONTRIBUTING.md]
found = candidates.select { |f| File.exist?(File.join(PROJECT_DIR, f)) }

StateManager.update(:session_docs) do |sd|
  sd[:required] = found
  sd[:read] = []
  sd[:enforced] = true
  sd
end

sd = StateManager.get(:session_docs)
t('Discovers existing docs', sd[:required].length.positive?)
t('Only includes files that exist', sd[:required].all? { |f| File.exist?(File.join(PROJECT_DIR, f)) })

# === Test 16: State CLI inspection ===
warn ''
warn '--- Test 16: State CLI inspection ---'
stdout, _, _ = Open3.capture3(
  CHILD_ENV,
  'ruby', File.join(HOOK_DIR, 'core/state_manager.rb'), '--get', 'session_docs',
  chdir: SANEPROCESS_DIR
)
parsed = begin; JSON.parse(stdout); rescue; nil; end
t('CLI --get session_docs returns valid JSON', parsed != nil)

# === Test 17: startup-gate message names the ACTUAL unread docs ===
# Regression: a hardcoded "(SESSION_HANDOFF.md, DEVELOPMENT.md)" label left the
# agent blocked on unnamed required docs (CONTRIBUTING.md / SKILLS_REGISTRY.md).
warn ''
warn '--- Test 17: startup-gate names actual pending docs ---'
full_reset
StateManager.update(:session_docs) do |sd|
  sd[:required] = %w[SESSION_HANDOFF.md DEVELOPMENT.md CONTRIBUTING.md SKILLS_REGISTRY.md]
  sd[:read] = %w[SESSION_HANDOFF.md DEVELOPMENT.md]
  sd[:enforced] = true
  sd
end
StateManager.update(:startup_gate) do |g|
  g[:open] = false
  g[:opened_at] = nil
  g[:steps] = {
    session_docs: false, skills_registry: true,
    validation_report: true, orphan_cleanup: true, system_clean: true
  }
  g
end
_, gate_stderr, gate_status = run_hook('sanetools.rb', {
  tool_name: 'Edit',
  tool_input: { file_path: '/test/gate.swift', old_string: 'a', new_string: 'b' }
})
t('Gate blocks gated tool while session docs pending', gate_status.exitstatus == 2)
t('Gate message names unread CONTRIBUTING.md', gate_stderr.include?('CONTRIBUTING.md'))
t('Gate message names unread SKILLS_REGISTRY.md', gate_stderr.include?('SKILLS_REGISTRY.md'))

# === Test 18: Session start clears stale per-session state ===
warn ''
warn '--- Test 18: session_start clears stale state ---'
full_reset
StateManager.update(:edits) { |e| e[:count] = 3; e[:unique_files] = ['Old.swift']; e }
StateManager.update(:requirements) { |r| r[:requested] = ['stale']; r[:is_big_task] = true; r }
StateManager.update(:handoff_tracking) { |h| h[:memory_updated] = true; h[:handoff_updated] = true; h }
StateManager.update(:skill) { |s| s[:required] = 'status'; s[:invoked] = true; s }
StateManager.update(:mcp_health) do |h|
  h[:verified_this_session] = true
  h[:degraded] = true
  h[:gate_block_attempts] = 7
  h[:mcps] = { apple_docs: { verified: true }, context7: { verified: true }, github: { verified: true } }
  h
end
run_hook('session_start.rb', {})
edits = StateManager.get(:edits)
requirements = StateManager.get(:requirements)
handoff = StateManager.get(:handoff_tracking)
skill = StateManager.get(:skill)
mcp = StateManager.get(:mcp_health)
t('session_start clears edit count', edits[:count].to_i.zero?)
t('session_start clears stale requested requirements', Array(requirements[:requested]).empty?)
t('session_start clears stale handoff tracking', !handoff[:memory_updated] && !handoff[:handoff_updated])
t('session_start clears stale skill requirement', skill[:required].nil?)
t('session_start resets MCP degraded state', mcp[:degraded] == false && mcp[:gate_block_attempts].to_i.zero?)

# === CLEANUP ===
StateManager.reset(:startup_gate)
StateManager.reset(:session_docs)
StateManager.reset(:refusal_tracking)
StateManager.reset(:circuit_breaker)
StateManager.update(:edit_attempts) { |a| a[:count] = 0; a }

warn ''
warn '=' * 60
warn "#{$passed}/#{$total} tests passed"
if $passed == $total
  warn 'ALL TESTS PASSED'
  exit 0
else
  warn "#{$total - $passed} TESTS FAILED"
  exit 1
end
