# frozen_string_literal: true

# ==============================================================================
# SaneTrack Self-Tests (extracted from sanetrack.rb)
# ==============================================================================

require 'open3'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'core/state_manager'

module SaneTrackTest
  def self.run(process_result_proc, detect_actual_failure_proc, normalize_error_proc,
               check_tautologies_proc, invalidate_empty_research_proc, source_file)
    warn 'SaneTrack Self-Test'
    warn '=' * 40

    # Reset state
    StateManager.reset(:edits)
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) { |e| e[:halted] = false; e[:blocks] = []; e }

    passed = 0
    failed = 0

    # Test 1: Track edit
    process_result_proc.call('Edit', { 'file_path' => '/test/file1.swift' }, { 'success' => true })
    edits = StateManager.get(:edits)
    if edits[:count] == 1 && edits[:unique_files].include?('/test/file1.swift')
      passed += 1
      warn '  PASS: Edit tracking'
    else
      failed += 1
      warn '  FAIL: Edit tracking'
    end

    # Test 2: Track multiple edits to same file
    process_result_proc.call('Edit', { 'file_path' => '/test/file1.swift' }, { 'success' => true })
    edits = StateManager.get(:edits)
    if edits[:count] == 2 && edits[:unique_files].length == 1
      passed += 1
      warn '  PASS: Unique file tracking'
    else
      failed += 1
      warn '  FAIL: Unique file tracking'
    end

    # Test 3: Track failure
    process_result_proc.call('Bash', {}, { 'error' => 'command not found' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:failures] == 1
      passed += 1
      warn '  PASS: Failure tracking'
    else
      failed += 1
      warn '  FAIL: Failure tracking'
    end

    # Test 4: Reset failure on success
    process_result_proc.call('Bash', {}, { 'output' => 'success' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:failures] == 0
      passed += 1
      warn '  PASS: Failure reset on success'
    else
      failed += 1
      warn '  FAIL: Failure reset on success'
    end

    Dir.mktmpdir('sanetrack-bash-mutation-') do |dir|
      old_dir = Dir.pwd
      Dir.chdir(dir)
      system('git', 'init', '-q')
      system('git', 'config', 'user.email', 'test@example.com')
      system('git', 'config', 'user.name', 'Test')
      File.write('README.md', "fixture\n")
      system('git', 'add', 'README.md')
      system('git', 'commit', '-q', '-m', 'init')
      StateManager.reset(:edits)
      FileUtils.mkdir_p('Sources')
      File.write('Sources/Generated.swift', "changed\n")
      process_result_proc.call(
        'Bash',
        { 'command' => "ruby -e 'File.write(\"Sources/Generated.swift\", \"changed\\n\")'" },
        { 'exit_code' => 0, 'stdout' => 'ok' }
      )
      edits = StateManager.get(:edits)
      changed_path = File.realpath(File.expand_path('Sources/Generated.swift', dir))
      tracked_paths = Array(edits[:unique_files]).map { |path| File.realpath(path) rescue path }
      if edits[:count].to_i.positive? && tracked_paths.include?(changed_path)
        passed += 1
        warn '  PASS: Bash mutation tracking records git-changed files'
      else
        failed += 1
        warn "  FAIL: Bash mutation tracking missed changed file, got #{edits.inspect}"
      end
    ensure
      Dir.chdir(old_dir) if old_dir
    end

    # Test 5: Circuit breaker trips at 2 failures
    StateManager.reset(:circuit_breaker)
    process_result_proc.call('Bash', {}, { 'error' => 'fail 1' })
    one_failure_cb = StateManager.get(:circuit_breaker)
    if !one_failure_cb[:tripped]
      passed += 1
      warn '  PASS: Circuit breaker does not trip at 1 failure'
    else
      failed += 1
      warn '  FAIL: Circuit breaker should not trip at 1 failure'
    end

    process_result_proc.call('Bash', {}, { 'error' => 'fail 2' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:tripped]
      passed += 1
      warn '  PASS: Circuit breaker trips at 2 failures'
    else
      failed += 1
      warn '  FAIL: Circuit breaker should trip at 2 failures'
    end

    # === INTELLIGENCE TESTS ===

    # Test 6: Error signature normalization
    StateManager.reset(:circuit_breaker)
    sig1 = normalize_error_proc.call('ruby: command not found')
    sig2 = normalize_error_proc.call('bash: npm: command not found')
    if sig1 == 'COMMAND_NOT_FOUND' && sig2 == 'COMMAND_NOT_FOUND'
      passed += 1
      warn '  PASS: Error signature normalization (COMMAND_NOT_FOUND)'
    else
      failed += 1
      warn "  FAIL: Expected COMMAND_NOT_FOUND, got #{sig1}, #{sig2}"
    end

    # Test 7: Per-signature trip (2x same with successes between)
    StateManager.reset(:circuit_breaker)
    process_result_proc.call('Bash', {}, { 'error' => 'command not found: ruby' })
    process_result_proc.call('Bash', {}, { 'output' => 'success' })  # Success resets legacy, not signature
    process_result_proc.call('Bash', {}, { 'error' => 'command not found: npm' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:tripped] && cb[:error_signatures] && cb[:error_signatures][:COMMAND_NOT_FOUND] == 2
      passed += 1
      warn '  PASS: Per-signature trip at 2x same (with successes between)'
    else
      failed += 1
      warn "  FAIL: Per-signature trip - tripped=#{cb[:tripped]}, signatures=#{cb[:error_signatures]}"
    end

    # Test 8: Action log for learning
    StateManager.update(:action_log) { |_| [] }  # Initialize empty
    process_result_proc.call('Edit', { 'file_path' => '/test/file.swift' }, { 'success' => true })
    process_result_proc.call('Bash', { 'command' => 'ruby test.rb' }, { 'error' => 'syntax error' })
    log = StateManager.get(:action_log)
    if log.is_a?(Array) && log.length >= 2
      first = log[-2]  # Second to last (Edit)
      last = log[-1]   # Last (Bash with error)
      if first && last && first[:tool] == 'Edit' && last[:error_sig] == 'SYNTAX_ERROR'
        passed += 1
        warn '  PASS: Action log for learning'
      else
        failed += 1
        warn "  FAIL: Action log content - first=#{first}, last=#{last}"
      end
    else
      failed += 1
      warn "  FAIL: Action log - got #{log.inspect[0..100]}"
    end

    # === Q2 VALIDATION: DOOM LOOP TRACKING ===
    warn ''
    warn 'Testing doom loop validation tracking:'

    # Test: Breaker trip on repeated signature increments doom_loops_caught
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:validation)
    process_result_proc.call('Bash', {}, { 'error' => 'permission denied on /etc/hosts' })
    process_result_proc.call('Bash', {}, { 'output' => 'ok' })
    process_result_proc.call('Bash', {}, { 'error' => 'access denied to file' })
    validation = StateManager.get(:validation)
    if validation[:doom_loops_caught] == 1
      passed += 1
      warn '  PASS: Doom loop caught on 2x same signature'
    else
      failed += 1
      warn "  FAIL: Expected doom_loops_caught=1, got #{validation[:doom_loops_caught]}"
    end

    # Test: Breaker trip on 2 consecutive failures also counts
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:validation)
    process_result_proc.call('Bash', {}, { 'error' => 'fail 1' })
    process_result_proc.call('Bash', {}, { 'error' => 'fail 2' })
    validation = StateManager.get(:validation)
    if validation[:doom_loops_caught] >= 1
      passed += 1
      warn '  PASS: Doom loop caught on 2 consecutive failures'
    else
      failed += 1
      warn "  FAIL: Expected doom_loops_caught>=1, got #{validation[:doom_loops_caught]}"
    end

    # === JSON INTEGRATION TESTS ===
    warn ''
    warn 'Testing JSON parsing (integration):'

    # Test valid JSON with success response
    json_input = '{"tool_name":"Edit","tool_input":{"file_path":"/test/integrated.swift"},"tool_response":{"success":true}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Valid JSON parsed correctly (exit 0)'
    else
      failed += 1
      warn "  FAIL: Valid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test JSON with error response (still returns 0 - PostToolUse is tracking only)
    json_input = '{"tool_name":"Bash","tool_input":{"command":"test"},"tool_response":{"error":"command failed"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Error response still returns exit 0 (PostToolUse is passive)'
    else
      failed += 1
      warn "  FAIL: PostToolUse should always exit 0, got #{status.exitstatus}"
    end

    # Test invalid JSON doesn't crash
    json_input = 'this is not valid json'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Invalid JSON returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test empty input doesn't crash
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: '')
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Empty input returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Empty input should return exit 0, got #{status.exitstatus}"
    end

    # === DETECT ACTUAL FAILURE TESTS ===
    warn ''
    warn 'Testing failure detection (no false positives):'

    # Test: Read file content with error-like text is NOT a failure
    result = detect_actual_failure_proc.call('Read', { 'content' => 'def handle_error: raise TypeError' })
    if result.nil?
      passed += 1
      warn '  PASS: Read file content with error text is not a failure'
    else
      failed += 1
      warn "  FAIL: Read content should not be flagged - got #{result}"
    end

    # Test: Bash with non-zero exit code IS a failure
    result = detect_actual_failure_proc.call('Bash', { 'exit_code' => 1, 'stdout' => '' })
    if result == 'COMMAND_FAILED'
      passed += 1
      warn '  PASS: Bash non-zero exit code is a failure'
    else
      failed += 1
      warn "  FAIL: Expected COMMAND_FAILED, got #{result.inspect}"
    end

    # Test: MCP tool success is not a failure
    result = detect_actual_failure_proc.call('mcp__apple-docs__search_apple_docs', { 'results' => [] })
    if result.nil?
      passed += 1
      warn '  PASS: MCP success is not a failure'
    else
      failed += 1
      warn "  FAIL: MCP success should return nil, got #{result}"
    end

    # === TAUTOLOGY DETECTION TESTS (Rule #7) ===
    warn ''
    warn 'Testing tautology detection (Rule #7):'

    # Test: Detects #expect(true) in test file
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/MyTests.swift',
      'new_string' => '@Test func bad() { #expect(true) }'
    })
    if result&.include?('RULE #7 WARNING')
      passed += 1
      warn '  PASS: Detects #expect(true) in test file'
    else
      failed += 1
      warn "  FAIL: Should detect tautology, got #{result.inspect}"
    end

    # Test: Ignores tautology in non-test file
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Sources/Main.swift',
      'new_string' => 'let x = true; #expect(true)'
    })
    if result.nil?
      passed += 1
      warn '  PASS: Ignores tautology in non-test file'
    else
      failed += 1
      warn "  FAIL: Should ignore non-test file, got #{result.inspect}"
    end

    # Test: Allows real assertions
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/ValidTests.swift',
      'new_string' => '@Test func good() { #expect(result == 42) }'
    })
    if result.nil?
      passed += 1
      warn '  PASS: Allows real assertions in test file'
    else
      failed += 1
      warn "  FAIL: Real assertion should be allowed, got #{result.inspect}"
    end

    # Test: Detects mock-passthrough (handler set up, assertion only checks mock)
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/BadTests.swift',
      'new_string' => <<~SWIFT
        @Test func testHidden() {
            mockSearch.cachedHiddenAppsHandler = { return [app1, app2] }
            let result = mockSearch.cachedHiddenApps()
            #expect(result.count == 2)
        }
      SWIFT
    })
    if result&.include?('RULE #7 WARNING') && result&.match?(/[Mm]ock/)
      passed += 1
      warn '  PASS: Detects mock-passthrough test'
    else
      failed += 1
      warn "  FAIL: Should detect mock-passthrough, got #{result.inspect}"
    end

    # Test: Allows tests that use real objects (not mock-passthrough)
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/GoodTests.swift',
      'new_string' => <<~SWIFT
        @Test func classifiesZone() {
            let zone = service.classifyZone(itemX: 200, itemWidth: 22, separatorX: 500, alwaysHiddenSeparatorX: nil)
            #expect(zone == .hidden)
        }
      SWIFT
    })
    if result.nil?
      passed += 1
      warn '  PASS: Allows real service call test'
    else
      failed += 1
      warn "  FAIL: Real service test should be allowed, got #{result.inspect}"
    end

    # === RESEARCH OUTPUT VALIDATION TESTS ===
    warn ''
    warn 'Testing research output validation:'

    # Test: Empty research output gets invalidated
    StateManager.update(:research) do |r|
      r[:web] = { completed_at: Time.now.iso8601, tool: 'WebSearch', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('WebSearch', { 'content' => 'no results found' })
    research_after = StateManager.get(:research)
    if research_after[:web].nil?
      passed += 1
      warn '  PASS: Empty research output invalidated (web)'
    else
      failed += 1
      warn "  FAIL: Empty research should be invalidated, got #{research_after[:web].inspect}"
    end

    # Test: Meaningful research output is kept
    StateManager.update(:research) do |r|
      r[:local] = { completed_at: Time.now.iso8601, tool: 'Read', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('Read', { 'content' => 'class StateManager\n  def get(section)\n    ...' })
    research_after = StateManager.get(:research)
    if research_after[:local]
      passed += 1
      warn '  PASS: Meaningful research output kept (local)'
    else
      failed += 1
      warn '  FAIL: Meaningful research should be kept'
    end

    # Test: Zero-result count gets invalidated
    StateManager.update(:research) do |r|
      r[:github] = { completed_at: Time.now.iso8601, tool: 'mcp__github__search_repositories', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('mcp__github__search_repositories', { 'content' => '0 matches' })
    research_after = StateManager.get(:research)
    if research_after[:github].nil?
      passed += 1
      warn '  PASS: Zero-result research invalidated (github)'
    else
      failed += 1
      warn "  FAIL: Zero-result research should be invalidated"
    end

    # === HANDOFF TRACKING TESTS ===
    warn ''
    warn 'Testing handoff tracking:'

    # Test: Root MEMORY.md marks memory_updated
    StateManager.reset(:handoff_tracking)
    process_result_proc.call('Edit', { 'file_path' => '/tmp/project/MEMORY.md' }, { 'success' => true })
    handoff = StateManager.get(:handoff_tracking)
    if handoff[:memory_updated] == true
      passed += 1
      warn '  PASS: Root MEMORY.md marks memory_updated'
    else
      failed += 1
      warn "  FAIL: Root MEMORY.md should set memory_updated, got #{handoff.inspect}"
    end

    # Test: Serena write_memory marks memory_updated (no file_path)
    StateManager.reset(:handoff_tracking)
    process_result_proc.call('mcp__serena__write_memory', {}, { 'success' => true })
    handoff = StateManager.get(:handoff_tracking)
    if handoff[:memory_updated] == true
      passed += 1
      warn '  PASS: Serena write_memory marks memory_updated'
    else
      failed += 1
      warn "  FAIL: Serena write_memory should set memory_updated, got #{handoff.inspect}"
    end

    # Test: Memory MCP mutations mark memory_updated
    %w[mcp__memory__add_observations mcp__memory__create_entities mcp__memory__create_relations].each do |memory_tool|
      StateManager.reset(:handoff_tracking)
      process_result_proc.call(memory_tool, {}, { 'success' => true })
      handoff = StateManager.get(:handoff_tracking)
      if handoff[:memory_updated] == true
        passed += 1
        warn "  PASS: #{memory_tool} marks memory_updated"
      else
        failed += 1
        warn "  FAIL: #{memory_tool} should mark memory_updated, got #{handoff.inspect}"
      end
    end

    # Test: Hook file edit marks always-persist work
    StateManager.reset(:handoff_tracking)
    process_result_proc.call('Edit', { 'file_path' => '/tmp/project/scripts/hooks/sanestop.rb' }, { 'success' => true })
    handoff = StateManager.get(:handoff_tracking)
    if handoff[:always_persist_required] == true && handoff[:always_persist_files]&.include?('sanestop.rb')
      passed += 1
      warn '  PASS: Hook edits mark always-persist work'
    else
      failed += 1
      warn "  FAIL: Hook edits should mark always-persist work, got #{handoff.inspect}"
    end

    # Test: Durable doc edit marks always-persist work
    StateManager.reset(:handoff_tracking)
    process_result_proc.call('Edit', { 'file_path' => '/tmp/project/AGENTS.md' }, { 'success' => true })
    handoff = StateManager.get(:handoff_tracking)
    if handoff[:always_persist_required] == true && handoff[:always_persist_files]&.include?('AGENTS.md')
      passed += 1
      warn '  PASS: Durable docs mark always-persist work'
    else
      failed += 1
      warn "  FAIL: Durable docs should mark always-persist work, got #{handoff.inspect}"
    end

    # === TOOL DISCOVERY RECEIPT TESTS ===
    warn ''
    warn 'Testing tool discovery receipt tracking:'

    StateManager.reset(:skill)
    StateManager.update(:skill) do |s|
      s[:required] = 'docs_audit'
      s[:invoked] = true
      s[:subagents_spawned] = 0
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end
    process_result_proc.call('Task', { 'prompt' => 'Run engineer audit perspective', 'subagent_type' => 'general-purpose' }, { 'output' => 'ok' })
    skill = StateManager.get(:skill)
    if skill[:subagents_spawned] == 1
      passed += 1
      warn '  PASS: docs_audit Task call increments subagent count'
    else
      failed += 1
      warn "  FAIL: docs_audit subagent count should increment, got #{skill.inspect}"
    end

    process_result_proc.call('Bash', { 'command' => 'python3 scripts/automation/gpt_audit.py --title Test' }, { 'output' => 'ok' })
    skill = StateManager.get(:skill)
    if skill[:runner_used] != true
      passed += 1
      warn '  PASS: gpt_audit.py no longer satisfies docs_audit'
    else
      failed += 1
      warn "  FAIL: gpt_audit.py should not satisfy docs_audit, got #{skill.inspect}"
    end

    Dir.mktmpdir('sanetrack-tool-discovery') do |tmpdir|
      old_sp_root = ENV['SANEPROCESS_ROOT']
      ENV['SANEPROCESS_ROOT'] = tmpdir # isolate canonical-root search to this clean dir
      Dir.chdir(tmpdir) do
        StateManager.reset(:skill)
        StateManager.update(:skill) do |s|
          s[:required] = 'evolve'
          s[:required_prompt] = 'missing screenshot diff tool'
          s[:runner_used] = false
          s[:runner_commands] = []
          s
        end
        process_result_proc.call('Bash', { 'command' => 'ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"' }, { 'output' => 'ok' })
        skill = StateManager.get(:skill)
        if skill[:runner_started] == true && skill[:runner_used] != true
          passed += 1
          warn '  PASS: tool_discovery command without receipt records attempt only'
        else
          failed += 1
          warn "  FAIL: tool_discovery command without receipt should not prove workflow, got #{skill.inspect}"
        end

        FileUtils.mkdir_p(File.join(Dir.pwd, 'outputs', 'tool-discovery'))
        File.write(
          File.join(Dir.pwd, 'outputs', 'tool-discovery', 'skipped.json'),
          JSON.generate(
            authoritative: false,
            route: 'tool_discovery_receipt.rb',
            query: 'missing screenshot diff tool',
            summary: { doctor_status: 'skipped', validation_status: 'skipped' }
          )
        )
        process_result_proc.call('Bash', { 'command' => 'ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"' }, { 'output' => 'ok' })
        skill = StateManager.get(:skill)
        if skill[:runner_used] != true
          passed += 1
          warn '  PASS: non-authoritative tool_discovery receipt does not satisfy evolve'
        else
          failed += 1
          warn "  FAIL: non-authoritative receipt should not prove evolve, got #{skill.inspect}"
        end

        File.write(
          File.join(Dir.pwd, 'outputs', 'tool-discovery', 'sanetrack-test.json'),
          JSON.generate(
            authoritative: true,
            route: 'SaneMaster.rb tool_discovery',
            query: 'missing screenshot diff tool',
            summary: { doctor_status: 'ok', validation_status: 'blocked' }
          )
        )
        process_result_proc.call('Bash', { 'command' => 'ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"' }, { 'output' => 'ok' })
        skill = StateManager.get(:skill)
        if skill[:runner_used] == true && skill[:runner_commands].any? { |cmd| cmd.include?('tool_discovery') }
          passed += 1
          warn '  PASS: SaneMaster tool_discovery command satisfies evolve receipt'
        else
          failed += 1
          warn "  FAIL: tool_discovery command should satisfy evolve receipt, got #{skill.inspect}"
        end
      end
      ENV['SANEPROCESS_ROOT'] = old_sp_root
    end

    # Cross-cwd: SaneMaster writes the receipt under the canonical SaneProcess root,
    # but the session cwd is an app repo (e.g. SaneBar). The proof must still be found.
    Dir.mktmpdir('sanetrack-sp-root') do |sp_root|
      Dir.mktmpdir('sanetrack-app-cwd') do |app_cwd|
        old_sp_root2 = ENV['SANEPROCESS_ROOT']
        ENV['SANEPROCESS_ROOT'] = sp_root
        FileUtils.mkdir_p(File.join(sp_root, 'outputs', 'tool-discovery'))
        File.write(
          File.join(sp_root, 'outputs', 'tool-discovery', 'receipt.json'),
          JSON.generate(
            authoritative: true,
            route: 'SaneMaster.rb tool_discovery',
            query: 'missing screenshot diff tool',
            summary: { doctor_status: 'ok', validation_status: 'blocked' }
          )
        )
        StateManager.reset(:skill)
        StateManager.update(:skill) do |s|
          s[:required] = 'evolve'
          s[:runner_used] = false
          s[:runner_proved] = false
          s[:runner_commands] = []
          s
        end
        Dir.chdir(app_cwd) do
          process_result_proc.call('Bash', { 'command' => 'ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"' }, { 'output' => 'ok' })
        end
        skill = StateManager.get(:skill)
        ENV['SANEPROCESS_ROOT'] = old_sp_root2
        if skill[:runner_used] == true && skill[:runner_proved] == true
          passed += 1
          warn '  PASS: evolve receipt in canonical SaneProcess root proves runner from any cwd'
        else
          failed += 1
          warn "  FAIL: evolve receipt in SaneProcess root should prove runner cross-cwd, got #{skill.inspect}"
        end
      end
    end

    Dir.mktmpdir('sanetrack-runner-proof') do |tmpdir|
      old_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = File.join(tmpdir, 'process_metrics.jsonl')
      Dir.chdir(tmpdir) do
        {
          'status' => 'ruby scripts/SaneMaster.rb status',
          'verify' => 'ruby scripts/SaneMaster.rb verify',
          'ship' => 'ruby scripts/SaneMaster.rb release_preflight',
          'check_inbox' => 'ruby scripts/SaneMaster.rb check_inbox'
        }.each do |workflow, runner_command|
          StateManager.reset(:skill)
          StateManager.update(:skill) do |s|
            s[:required] = workflow
            s[:runner_used] = false
            s[:runner_started] = false
            s[:runner_proved] = false
            s[:runner_commands] = []
            s
          end

          write_runner_proof_fixture(workflow, ENV['SANEMASTER_PROCESS_METRICS_PATH'])
          process_result_proc.call('Bash', { 'command' => runner_command }, { 'output' => 'ok' })
          skill = StateManager.get(:skill)
          if skill[:runner_used] == true && skill[:runner_commands].include?(runner_command)
            passed += 1
            warn "  PASS: #{workflow} runner command satisfies workflow proof"
          else
            failed += 1
            warn "  FAIL: #{workflow} runner command should satisfy workflow proof, got #{skill.inspect}"
          end
        end
      end
      ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_metrics_path
    end

    # === MCP VERIFICATION TRACKING TESTS ===
    # Plugin-loaded MCP servers expose tools as mcp__plugin_<plugin>_<server>__*
    # instead of mcp__<server>__*; both prefixes must count as the same server.
    warn ''
    warn 'Testing MCP verification tracking (bare + plugin-loaded prefixes):'

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__context7__resolve-library-id', {}, { 'content' => 'Library ID: /vercel/next.js' })
    health = StateManager.get(:mcp_health)
    if health[:mcps] && health[:mcps][:context7] && health[:mcps][:context7][:verified]
      passed += 1
      warn '  PASS: bare context7 tool marks context7 verified'
    else
      failed += 1
      warn "  FAIL: bare context7 tool should verify context7, got #{health.inspect[0..150]}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_context7_context7__resolve-library-id', {}, { 'content' => 'Library ID: /vercel/next.js' })
    health = StateManager.get(:mcp_health)
    if health[:mcps] && health[:mcps][:context7] && health[:mcps][:context7][:verified]
      passed += 1
      warn '  PASS: plugin-loaded context7 tool marks context7 verified'
    else
      failed += 1
      warn "  FAIL: plugin-loaded context7 tool should verify context7, got #{health.inspect[0..150]}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_apple-docs_apple-docs__search_apple_docs', {}, { 'content' => 'FileManager documentation found' })
    process_result_proc.call('mcp__plugin_gh-tools_github__search_repositories', {}, { 'content' => 'Found 3 repositories' })
    health = StateManager.get(:mcp_health)
    apple_ok = health[:mcps] && health[:mcps][:apple_docs] && health[:mcps][:apple_docs][:verified]
    github_ok = health[:mcps] && health[:mcps][:github] && health[:mcps][:github][:verified]
    if apple_ok && github_ok
      passed += 1
      warn '  PASS: plugin-loaded apple-docs/github tools mark their MCPs verified'
    else
      failed += 1
      warn "  FAIL: plugin-loaded apple-docs/github should verify, got apple=#{apple_ok.inspect} github=#{github_ok.inspect}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_serena_serena__read_memory', {}, { 'content' => 'memory body with details' })
    health = StateManager.get(:mcp_health)
    verified_any = (health[:mcps] || {}).any? { |_mcp, data| data[:verified] }
    if !verified_any
      passed += 1
      warn '  PASS: unrelated plugin MCP tool verifies nothing'
    else
      failed += 1
      warn "  FAIL: unrelated plugin tool should verify nothing, got #{health.inspect[0..150]}"
    end

    # Plugin-prefixed research tools must still be revoked on empty output
    StateManager.update(:research) do |r|
      r[:github] = { completed_at: Time.now.iso8601, tool: 'mcp__plugin_gh-tools_github__search_repositories', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('mcp__plugin_gh-tools_github__search_repositories', { 'content' => '0 matches' })
    research_after = StateManager.get(:research)
    if research_after[:github].nil?
      passed += 1
      warn '  PASS: plugin-loaded github empty result invalidates research'
    else
      failed += 1
      warn "  FAIL: plugin-loaded github empty result should invalidate research, got #{research_after[:github].inspect}"
    end

    StateManager.reset(:mcp_health)

    # === CLEANUP: Reset circuit breaker only (don't reset research - breaks normal ops) ===
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) { |e| e[:halted] = false; e[:blocks] = []; e }

    warn ''
    warn "#{passed}/#{passed + failed} tests passed"

    if failed == 0
      warn ''
      warn 'ALL TESTS PASSED'
      0
    else
      warn ''
      warn "#{failed} TESTS FAILED"
      1
    end
  end
end

module SaneTrackTest
  def self.write_runner_proof_fixture(workflow, metrics_path)
    timestamp = Time.now.utc.iso8601
    case workflow
    when 'verify'
      FileUtils.mkdir_p(File.dirname(metrics_path))
      File.open(metrics_path, 'a') do |file|
        file.puts(JSON.generate('timestamp' => timestamp, 'type' => 'verify', 'cwd' => Dir.pwd, 'success' => true, 'tests_run' => 12))
      end
    when 'status', 'check_inbox'
      FileUtils.mkdir_p(File.dirname(metrics_path))
      File.open(metrics_path, 'a') do |file|
        file.puts(JSON.generate('timestamp' => timestamp, 'type' => 'workflow_receipt', 'cwd' => Dir.pwd, 'workflow' => workflow, 'success' => true))
      end
    when 'ship'
      File.write(File.join(Dir.pwd, '.saneprocess'), "name: TestApp\n")
      FileUtils.mkdir_p(File.join(Dir.pwd, 'outputs'))
      File.write(
        File.join(Dir.pwd, 'outputs', 'release_preflight_status.json'),
        JSON.pretty_generate('generatedAt' => timestamp, 'status' => 'passed')
      )
      require_relative 'state_signer'
      StateSigner.write_signed(
        File.expand_path('~/.claude/ship_clearance/TestApp.json'),
        {
          'app' => 'TestApp',
          'project_dir' => Dir.pwd,
          'cleared_at' => timestamp,
          'expires_at' => (Time.now.utc + 3600).iso8601
        }
      )
    end
  end
end
