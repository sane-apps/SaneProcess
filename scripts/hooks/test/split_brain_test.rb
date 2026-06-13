#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# STATE SPLIT-BRAIN REGRESSION TEST
# ==============================================================================
# Guards the fix for the #1 root-cause bug (audit_v3, 2026-06-12): Ruby hooks
# keyed state to `CLAUDE_PROJECT_DIR || Dir.pwd` while the shell gates check
# `[ -f .saneprocess ]` in cwd. When CLAUDE_PROJECT_DIR was a marker-less umbrella
# dir, a breaker trip written to the umbrella state.json blocked unrelated repos,
# and recovery operated on a different file than the one that tripped.
#
# core/project_root.rb (SaneProjectRoot.resolve) unifies resolution to the nearest
# `.saneprocess` ancestor. session_start.rb#clear_stale_error_signatures adds a
# session-boundary defense so stale cross-session signatures can't combine with
# one fresh error to trip.
#
# This test proves, against the REAL hooks (driven as subprocesses):
#   A. Resolver: umbrella cwd/env resolves to the repo `.saneprocess` root, so a
#      trip written by PreToolUse and a recovery reset hit the SAME state file.
#   B. In-session 2x same-signature STILL trips (semantics preserved).
#   C. Sibling-hook feedback (SANETOOLS BLOCKED) still does NOT trip (244f739).
#   D. A stale cross-session signature count (left at 2) + one fresh error does
#      NOT trip, because session_start drops carried-over counts when untripped.
#   E. session_start NEVER clears a TRIPPED breaker (VULN-007 preserved).
#
# Run: ruby scripts/hooks/test/split_brain_test.rb
# ==============================================================================

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'

HOOKS_DIR = File.expand_path('..', __dir__)
RESOLVER  = File.join(HOOKS_DIR, 'core', 'project_root.rb')
SANETRACK = File.join(HOOKS_DIR, 'sanetrack.rb')
SESSION_START = File.join(HOOKS_DIR, 'session_start.rb')
STATE_MANAGER = File.join(HOOKS_DIR, 'core', 'state_manager.rb')

TEST_SECRET = 'saneprocess-split-brain-test-secret'

@passed = 0
@failed = 0

def check(name)
  ok = yield
  if ok
    @passed += 1
    puts "  PASS: #{name}"
  else
    @failed += 1
    puts "  FAIL: #{name}"
  end
rescue StandardError => e
  @failed += 1
  puts "  FAIL: #{name} (#{e.class}: #{e.message})"
end

# Build an isolated sandbox: an umbrella dir (NO .saneprocess) containing a repo
# dir (WITH .saneprocess). Returns [umbrella, repo].
def make_sandbox(tmp)
  umbrella = File.join(tmp, 'umbrella')
  repo = File.join(umbrella, 'repo')
  FileUtils.mkdir_p(File.join(repo, '.claude'))
  File.write(File.join(repo, '.saneprocess'), "{\n}\n")
  [umbrella, repo]
end

# Run a hook (or arbitrary ruby script) as a subprocess with a controlled env and
# cwd. `env` overrides; `stdin` is JSON-encoded if a Hash.
def run_ruby(script, *args, cwd:, env: {}, stdin: nil)
  full_env = {
    'CLAUDE_HOOK_SECRET' => TEST_SECRET,
    'SANE_ENV_CACHE_WRITE' => '0',
    'TIER_TEST_MODE' => 'true',
    'LANG' => 'en_US.UTF-8'
  }.merge(env)
  stdin_data = stdin.is_a?(Hash) ? stdin.to_json : stdin
  Open3.capture3(full_env, 'ruby', script, *args, chdir: cwd, stdin_data: stdin_data.to_s)
end

# Read the breaker section from a state.json via the signed reader so symbol/HMAC
# handling matches production exactly.
def read_breaker(state_file)
  return {} unless File.exist?(state_file)

  out, = run_ruby('-e', <<~RUBY, cwd: File.dirname(File.dirname(state_file)))
    $LOAD_PATH.unshift #{HOOKS_DIR.inspect}
    require 'json'
    require #{File.join(HOOKS_DIR, 'state_signer').inspect}
    data = StateSigner.read_verified(#{state_file.inspect}, symbolize: true) || {}
    print JSON.generate(data[:circuit_breaker] || {})
  RUBY
  JSON.parse(out) rescue {}
end

# Drive one PostToolUse error through sanetrack.rb with the given tool_response.
def post_error(repo, env, tool_response)
  run_ruby(SANETRACK, cwd: repo, env: env, stdin: {
             'tool_name' => 'Bash',
             'tool_input' => { 'command' => 'do_thing' },
             'tool_response' => tool_response
           })
end

# An error response that normalizes to a stable signature (exit_code != 0 with no
# special pattern => COMMAND_FAILED).
def command_failure
  { 'exit_code' => 1, 'stderr' => 'boom: the build failed unexpectedly' }
end

puts '=' * 60
puts 'STATE SPLIT-BRAIN REGRESSION TEST'
puts '=' * 60

# ---------------------------------------------------------------------------
# A. Resolver unifies the state path: trip + recovery hit the SAME file.
# ---------------------------------------------------------------------------
puts "\nA. Resolver unifies state path (trip and recovery share one file):"
Dir.mktmpdir('split-brain-A-') do |tmp|
  umbrella, repo = make_sandbox(tmp)
  repo_state = File.join(repo, '.claude', 'state.json')
  umbrella_state = File.join(umbrella, '.claude', 'state.json')

  # Session env mimics the bug: CLAUDE_PROJECT_DIR is the marker-less umbrella,
  # but cwd is the real repo (where the shell gate fired the hook).
  env = { 'CLAUDE_PROJECT_DIR' => umbrella }

  # 1) Resolver resolves to the repo, not the umbrella.
  out, err = run_ruby(RESOLVER, '--show', cwd: repo, env: env)
  show_output = "#{out}#{err}"
  check('resolver resolves umbrella-env + repo-cwd to the repo root') do
    show_output.include?("resolve:           #{repo}") || show_output.include?("resolve:           #{File.realpath(repo)}")
  end

  # 2) Trip the breaker via the same resolved path (3x same signature).
  3.times { post_error(repo, env, command_failure) }
  cb = read_breaker(repo_state)
  check('breaker trips at the REPO state file (not the umbrella)') { cb['tripped'] == true }
  check('umbrella state.json was never written by the hooks') { !File.exist?(umbrella_state) }

  # 3) Recovery: the canonical reset clears the breaker in the SAME file.
  run_ruby(File.join(HOOKS_DIR, 'sanetools.rb'), '--reset', cwd: repo, env: env)
  cb_after = read_breaker(repo_state)
  check('repo-rooted recovery clears the trip in the same file') { cb_after['tripped'] == false }
end

# ---------------------------------------------------------------------------
# B. In-session 2x same-signature STILL trips.
# ---------------------------------------------------------------------------
puts "\nB. In-session same-signature trip is preserved:"
Dir.mktmpdir('split-brain-B-') do |tmp|
  _umbrella, repo = make_sandbox(tmp)
  state = File.join(repo, '.claude', 'state.json')
  env = { 'CLAUDE_PROJECT_DIR' => repo }

  post_error(repo, env, command_failure)
  cb1 = read_breaker(state)
  check('not tripped after 1 error') { cb1['tripped'] != true }

  post_error(repo, env, command_failure)
  cb2 = read_breaker(state)
  check('TRIPPED after 2nd identical signature in-session') { cb2['tripped'] == true }
end

# ---------------------------------------------------------------------------
# B2. If env and cwd are different marked repos, cwd wins.
# ---------------------------------------------------------------------------
puts "\nB2. Marked cwd beats different marked CLAUDE_PROJECT_DIR:"
Dir.mktmpdir('split-brain-B2-') do |tmp|
  repo_a = File.join(tmp, 'repo-a')
  repo_b = File.join(tmp, 'repo-b')
  FileUtils.mkdir_p([repo_a, repo_b])
  File.write(File.join(repo_a, '.saneprocess'), "{\n}\n")
  File.write(File.join(repo_b, '.saneprocess'), "{\n}\n")

  env = { 'CLAUDE_PROJECT_DIR' => repo_a }
  out, err = run_ruby(RESOLVER, '--show', cwd: repo_b, env: env)
  show_output = "#{out}#{err}"
  check('resolver follows cwd repo when both env and cwd are marked') do
    show_output.include?("resolve:           #{repo_b}") || show_output.include?("resolve:           #{File.realpath(repo_b)}")
  end
end

# ---------------------------------------------------------------------------
# C. Sibling-hook feedback does NOT trip (244f739 behavior preserved).
# ---------------------------------------------------------------------------
puts "\nC. Sibling-hook feedback never counts toward a trip:"
Dir.mktmpdir('split-brain-C-') do |tmp|
  _umbrella, repo = make_sandbox(tmp)
  state = File.join(repo, '.claude', 'state.json')
  env = { 'CLAUDE_PROJECT_DIR' => repo }

  sibling_feedback = {
    'exit_code' => 2,
    'stderr' => "SANETOOLS BLOCKED\n\nEDIT BLOCKED: research required\nhook feedback"
  }
  5.times { post_error(repo, env, sibling_feedback) }
  cb = read_breaker(state)
  check('breaker did NOT trip on 5x sibling-hook feedback') { cb['tripped'] != true }
  check('no error_signatures recorded for sibling feedback') do
    (cb['error_signatures'] || {}).empty?
  end
end

# ---------------------------------------------------------------------------
# D. Stale cross-session signature + one fresh error does NOT trip.
#    (session_start drops carried-over counts when the breaker is untripped.)
# ---------------------------------------------------------------------------
puts "\nD. Stale cross-session signature cannot combine with one fresh error:"
Dir.mktmpdir('split-brain-D-') do |tmp|
  _umbrella, repo = make_sandbox(tmp)
  state = File.join(repo, '.claude', 'state.json')
  env = { 'CLAUDE_PROJECT_DIR' => repo }

  # Seed a stale signature count of 2 (as if left by a PRIOR session), untripped.
  seed = <<~RUBY
    $LOAD_PATH.unshift #{HOOKS_DIR.inspect}
    require #{STATE_MANAGER.inspect}
    StateManager.update(:circuit_breaker) do |cb|
      cb[:error_signatures] = { 'COMMAND_FAILED' => 2 }
      cb[:failures] = 2
      cb[:tripped] = false
      cb
    end
  RUBY
  run_ruby('-e', seed, cwd: repo, env: env)
  seeded = read_breaker(state)
  check('seed: stale COMMAND_FAILED count is 2, untripped') do
    signatures = seeded['error_signatures'] || {}
    (signatures['COMMAND_FAILED'] == 2 || signatures[:COMMAND_FAILED] == 2) && seeded['tripped'] != true
  end

  # New session boundary: session_start must clear the stale counts (untripped).
  run_ruby(SESSION_START, cwd: repo, env: env)
  cleared = read_breaker(state)
  check('session_start cleared the stale signature count') do
    (cleared['error_signatures'] || {}).empty? && (cleared['failures'] || 0).zero?
  end

  # One fresh error this session must NOT trip (would have been the "3rd" before).
  post_error(repo, env, command_failure)
  cb = read_breaker(state)
  check('one fresh error after a cleared session does NOT trip') { cb['tripped'] != true }
end

# ---------------------------------------------------------------------------
# E. session_start NEVER clears a TRIPPED breaker (VULN-007 preserved).
# ---------------------------------------------------------------------------
puts "\nE. A tripped breaker survives a session restart (VULN-007):"
Dir.mktmpdir('split-brain-E-') do |tmp|
  _umbrella, repo = make_sandbox(tmp)
  state = File.join(repo, '.claude', 'state.json')
  env = { 'CLAUDE_PROJECT_DIR' => repo }

  # Trip it.
  3.times { post_error(repo, env, command_failure) }
  check('breaker is tripped before restart') { read_breaker(state)['tripped'] == true }

  # session_start must NOT clear the trip or its signatures.
  run_ruby(SESSION_START, cwd: repo, env: env)
  cb = read_breaker(state)
  check('breaker STAYS tripped after session_start (no restart bypass)') { cb['tripped'] == true }
  check('tripped breaker keeps its error_signatures (not wiped)') do
    !(cb['error_signatures'] || {}).empty?
  end
end

puts
puts '=' * 60
puts "RESULTS: #{@passed} passed, #{@failed} failed"
puts '=' * 60

exit(@failed.zero? ? 0 : 1)
