#!/usr/bin/env ruby
# frozen_string_literal: true

# Hook/launchd/ssh shells often run with a C locale, which makes Ruby default
# to US-ASCII and raise "invalid byte sequence" when UTF-8 file or tool
# content hits a regex or parser. Force UTF-8 before anything reads content.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

#
# SaneProcess QA Script
# Automated product verification before release
#
# Usage: ruby scripts/qa.rb
#
# Checks:
# - All hooks exist and have valid Ruby syntax
# - init.sh downloads all hooks
# - README matches actual hook count
# - docs/SaneProcess.md matches rule count
# - All URLs in docs are reachable
# - All hooks use stdin pattern (not ENV vars)
# - SaneMaster CLI and modules have valid syntax
# - Hook tests pass
#

require 'net/http'
require 'uri'
require 'json'
require 'open3'
require_relative 'qa_drift_checks'

class SaneProcessQA
  include QaDriftChecks
  HOOKS_DIR = File.join(__dir__, 'hooks')
  INIT_SCRIPT = File.join(__dir__, 'init.sh')
  README = File.join(__dir__, '..', 'README.md')
  SOP_DOC = File.join(__dir__, '..', 'docs', 'SaneProcess.md')
  HOOKS_README = File.join(__dir__, 'hooks', 'README.md')
  SETTINGS_JSON = File.join(__dir__, '..', '.claude', 'settings.json')

  # Main hooks that get registered in settings.json (4-hook architecture)
  EXPECTED_HOOKS = %w[
    saneprompt.rb
    sanetools.rb
    sanetrack.rb
    sanestop.rb
    session_start.rb
    task_completed_gate.rb
  ].freeze

  SELF_TEST_MODULES = %w[
    saneprompt_test.rb
    sanetools_test.rb
    sanetools_gate_test.rb
    sanetools_test_scenarios.rb
    sanetrack_test.rb
    sanestop_test.rb
    sanestop_persistence_test.rb
  ].freeze

  # Runtime modules are derived from the entry hooks' actual require_relative
  # graph, so this set can never drift from reality. Hand-maintained lists
  # went 8 files stale and shipped LoadError installs (2026-06-11 audit).
  def self.required_hook_modules
    seen = {}
    queue = EXPECTED_HOOKS.dup
    hooks_root = File.expand_path(HOOKS_DIR)
    until queue.empty?
      rel = queue.shift
      next if seen.key?(rel)

      path = File.join(hooks_root, rel)
      next unless File.exist?(path)

      seen[rel] = true
      File.read(path, encoding: Encoding::UTF_8)
          .scan(/require_relative\s+['"]([^'"]+)['"]/).flatten.each do |target|
        target += '.rb' unless target.end_with?('.rb')
        full = File.expand_path(File.join(File.dirname(path), target))
        next unless full.start_with?("#{hooks_root}/")

        queue << full.delete_prefix("#{hooks_root}/")
      end
    end
    seen.keys.sort
  end

  # All files required for the advertised runtime + per-hook self-tests
  ALL_HOOK_FILES = (required_hook_modules + SELF_TEST_MODULES).uniq.freeze

  EXPECTED_RULE_COUNT = 17

  SANEMASTER_CLI = File.join(__dir__, 'SaneMaster.rb')
  SANEMASTER_DIR = File.join(__dir__, 'sanemaster')
  SANEPROCESS_ROOT = File.expand_path('..', __dir__)
  QA_CHILD_COMMAND_TIMEOUT_SECONDS = Integer(ENV.fetch('SANEPROCESS_QA_CHILD_TIMEOUT_SECONDS', '75'))
  QA_SELF_TEST_TIMEOUT_SECONDS = Integer(ENV.fetch('SANEPROCESS_QA_SELF_TEST_TIMEOUT_SECONDS', '150'))

  EXPECTED_SANEMASTER_MODULES = %w[
    base.rb
    bootstrap.rb
    circuit_breaker_state.rb
    compliance_report.rb
    dependencies.rb
    diagnostics.rb
    export.rb
    generation.rb
    generation_assets.rb
    generation_mocks.rb
    generation_templates.rb
    md_export.rb
    memory.rb
    meta.rb
    quality.rb
    saneui_guard.rb
    session.rb
    sop_loop.rb
    structural_compliance.rb
    test_mode.rb
    verify.rb
  ].freeze

  def initialize
    @errors = []
    @warnings = []
  end

  def run
    puts "═══════════════════════════════════════════════════════════════"
    puts "                  SaneProcess QA Check"
    puts "═══════════════════════════════════════════════════════════════"
    puts

    check_hooks_exist
    check_hooks_syntax
    check_hooks_use_stdin
    check_hooks_registered
    check_sanemaster_syntax
    check_init_script
    check_hook_dependency_manifest
    check_readme_hook_count
    check_sop_doc_rule_count
    check_hooks_readme
    check_version_consistency
    check_urls
    check_state_schema_drift
    check_rule_count_crossref
    check_stale_references
    check_file_line_counts
    run_hook_tests
    run_self_tests
    check_test_count_claims

    puts
    puts "═══════════════════════════════════════════════════════════════"

    if @errors.empty? && @warnings.empty?
      puts "✅ All checks passed!"
      exit 0
    else
      unless @warnings.empty?
        puts "⚠️  Warnings (#{@warnings.count}):"
        @warnings.each { |w| puts "   - #{w}" }
        puts
      end

      unless @errors.empty?
        puts "❌ Errors (#{@errors.count}):"
        @errors.each { |e| puts "   - #{e}" }
        puts
        exit 1
      end

      exit 0
    end
  end

  private

  def check_hooks_exist
    print "Checking hooks exist... "

    missing = ALL_HOOK_FILES.reject do |hook|
      File.exist?(File.join(HOOKS_DIR, hook))
    end

    if missing.empty?
      puts "✅ #{ALL_HOOK_FILES.count} runtime/test hook files present"
    else
      @errors << "Missing hooks: #{missing.join(', ')}"
      puts "❌ Missing: #{missing.join(', ')}"
    end
  end

  def check_hooks_syntax
    print "Checking Ruby syntax... "

    invalid = []
    ALL_HOOK_FILES.each do |hook|
      path = File.join(HOOKS_DIR, hook)
      next unless File.exist?(path)

      _result, success = capture_qa_command('ruby', '-c', path, timeout: 15)
      invalid << hook unless success
    end

    if invalid.empty?
      puts "✅ All runtime/test hook files have valid syntax"
    else
      @errors << "Invalid syntax in: #{invalid.join(', ')}"
      puts "❌ Invalid: #{invalid.join(', ')}"
    end
  end

  def check_hooks_use_stdin
    print "Checking hooks use stdin for input... "

    uses_env_for_input = []
    EXPECTED_HOOKS.each do |hook|
      path = File.join(HOOKS_DIR, hook)
      next unless File.exist?(path)

      content = File.read(path)
      # Check for deprecated patterns: ENV['CLAUDE_TOOL_INPUT'] or ENV['CLAUDE_TOOL_OUTPUT']
      # These should use stdin instead. CLAUDE_PROJECT_DIR and CLAUDE_SESSION_ID are OK.
      if content.match?(/ENV\[['"]CLAUDE_TOOL_INPUT/) ||
         content.match?(/ENV\.fetch\(['"]CLAUDE_TOOL_INPUT/) ||
         content.match?(/ENV\[['"]CLAUDE_TOOL_OUTPUT/) ||
         content.match?(/ENV\.fetch\(['"]CLAUDE_TOOL_OUTPUT/)
        uses_env_for_input << hook
      end
    end

    if uses_env_for_input.empty?
      puts "✅ All hooks use stdin"
    else
      @errors << "Hooks using ENV for tool input (should use stdin): #{uses_env_for_input.join(', ')}"
      puts "❌ Using ENV for input: #{uses_env_for_input.join(', ')}"
    end
  end

def check_hooks_registered
  print "Checking hooks registered in settings... "

  global_settings = File.expand_path("~/.claude/settings.json")
  settings_files = [SETTINGS_JSON, global_settings].uniq.select { |f| File.exist?(f) }

  if settings_files.empty?
    @errors << "No settings.json found (project or global)"
    puts "❌ Missing"
    return
  end

  # Extract hooks from all settings files (project + global)
  registered_hooks = []
  found_in = nil
  settings_files.each do |path|
    begin
      settings = JSON.parse(File.read(path))
    rescue JSON::ParserError
      next
    end

    hooks_section = settings["hooks"] || {}
    %w[UserPromptSubmit SessionStart PreToolUse PostToolUse TaskCompleted Stop].each do |hook_type|
      entries = hooks_section[hook_type] || []
      entries.each do |entry|
        hook_list = entry["hooks"] || []
        hook_list.each do |hook|
          command = hook["command"] || ""
          EXPECTED_HOOKS.each do |expected_hook|
            next unless command.match?(/(?:\A|[\s\/])#{Regexp.escape(expected_hook)}(?:\z|[\s"'])/)

            registered_hooks << expected_hook
            found_in = path == SETTINGS_JSON ? "project" : "global"
          end
        end
      end
    end
  end

  registered_hooks.uniq!

  # Check which expected hooks are NOT registered
  not_registered = EXPECTED_HOOKS - registered_hooks

  if not_registered.empty?
    puts "✅ All #{EXPECTED_HOOKS.count} hooks registered (#{found_in})"
  else
    @errors << "Hooks NOT registered in any settings.json: #{not_registered.join(", ")}"
    puts "❌ Not registered: #{not_registered.join(", ")}"
  end
end

  def check_sanemaster_syntax
    print "Checking SaneMaster syntax... "

    invalid = []

    # Check main CLI
    if File.exist?(SANEMASTER_CLI)
      _result, success = capture_qa_command('ruby', '-c', SANEMASTER_CLI, timeout: 15)
      invalid << 'SaneMaster.rb' unless success
    else
      @errors << "SaneMaster.rb not found"
      puts "❌ Missing"
      return
    end

    # Check all modules exist and have valid syntax
    missing_modules = []
    EXPECTED_SANEMASTER_MODULES.each do |mod|
      path = File.join(SANEMASTER_DIR, mod)
      unless File.exist?(path)
        missing_modules << mod
        next
      end

      _result, success = capture_qa_command('ruby', '-c', path, timeout: 15)
      invalid << mod unless success
    end

    if missing_modules.any?
      @errors << "Missing SaneMaster modules: #{missing_modules.join(', ')}"
      puts "❌ Missing modules: #{missing_modules.join(', ')}"
      return
    end

    if invalid.empty?
      puts "✅ SaneMaster + #{EXPECTED_SANEMASTER_MODULES.count} modules valid"
    else
      @errors << "Invalid syntax in SaneMaster: #{invalid.join(', ')}"
      puts "❌ Invalid: #{invalid.join(', ')}"
    end
  end

  def check_init_script
    print "Checking init.sh... "

    unless File.exist?(INIT_SCRIPT)
      @errors << "init.sh not found"
      puts "❌ Missing"
      return
    end

    content = File.read(INIT_SCRIPT, encoding: Encoding::UTF_8)

    # init.sh installs hooks by wholesale glob copy (scripts/hooks/*.rb +
    # core/*.rb), so per-file drift is impossible. Assert the glob copy is
    # still present rather than parsing hand-maintained lists.
    has_flat_glob = content.include?('"$SRC"/*.rb')
    has_core_glob = content.include?('"$SRC"/core/*.rb')

    if has_flat_glob && has_core_glob
      puts "✅ init.sh wholesale-copies the hook tree (#{ALL_HOOK_FILES.count} required files derive from the require graph)"
    else
      @errors << 'init.sh: wholesale hook copy globs missing — installs will drift from the require graph'
      puts '❌ init.sh hook copy globs not found'
    end
  end

  def check_hook_dependency_manifest
    print "Checking hook dependency coverage... "

    known_files = ALL_HOOK_FILES.dup
    missing = top_level_hook_dependencies.reject { |dep| known_files.include?(dep) }

    if missing.empty?
      puts "✅ All top-level require_relative deps are covered"
    else
      @errors << "Hook dependency manifest missing: #{missing.join(', ')}"
      puts "❌ Missing: #{missing.join(', ')}"
    end
  end

  def check_readme_hook_count
    print "Checking README.md hook count... "

    unless File.exist?(README)
      @warnings << "README.md not found"
      puts "⚠️  Not found"
      return
    end

    content = File.read(README)

    # README says "4 Enforcement Hooks" (user-facing count = registered hooks minus session_start)
    # Also accept "N hooks" or "N SOP enforcement hooks"
    hook_counts = content.scan(/(\d+)\s+(?:SOP |production-ready )?enforcement\s+hooks?/i).flatten.map(&:to_i)
    hook_counts += content.scan(/(\d+)\s+(?:SOP enforcement |production-ready )?hooks?(?!\s+registered)/i).flatten.map(&:to_i) if hook_counts.empty?

    if hook_counts.empty?
      @warnings << "README.md: No hook count found"
      puts "⚠️  No count found"
      return
    end

    # 4 enforcement hooks is correct (saneprompt, sanetools, sanetrack, sanestop)
    enforcement_count = EXPECTED_HOOKS.count - 1  # minus session_start
    wrong_counts = hook_counts.reject { |c| c == enforcement_count }
    if wrong_counts.empty?
      puts "✅ Hook count correct (#{enforcement_count} enforcement)"
    else
      @errors << "README.md says #{wrong_counts.first} hooks, should be #{enforcement_count}"
      puts "❌ Says #{wrong_counts.first}, should be #{enforcement_count}"
    end
  end

  def check_sop_doc_rule_count
    print "Checking docs/SaneProcess.md rule count... "

    unless File.exist?(SOP_DOC)
      @warnings << "docs/SaneProcess.md not found"
      puts "⚠️  Not found"
      return
    end

    content = File.read(SOP_DOC)

    # Look for "17 Golden Rules" or similar
    rule_counts = content.scan(/(\d+)\s+Golden Rules?/i).flatten.map(&:to_i)

    if rule_counts.empty?
      @warnings << "docs/SaneProcess.md: No rule count found"
      puts "⚠️  No count found"
      return
    end

    wrong_counts = rule_counts.reject { |c| c == EXPECTED_RULE_COUNT }
    if wrong_counts.empty?
      puts "✅ Rule count correct (#{EXPECTED_RULE_COUNT})"
    else
      @errors << "SaneProcess.md says #{wrong_counts.first} rules, should be #{EXPECTED_RULE_COUNT}"
      puts "❌ Says #{wrong_counts.first}, should be #{EXPECTED_RULE_COUNT}"
    end
  end

  def check_hooks_readme
    print "Checking hooks/README.md... "

    unless File.exist?(HOOKS_README)
      @warnings << "hooks/README.md not found"
      puts "⚠️  Not found"
      return
    end

    content = File.read(HOOKS_README)

    # Check each expected hook is mentioned
    missing = ALL_HOOK_FILES.reject do |hook|
      content.include?(hook)
    end

    if missing.empty?
      puts "✅ All hooks documented"
    else
      @errors << "hooks/README.md missing: #{missing.join(', ')}"
      puts "❌ Missing docs: #{missing.join(', ')}"
    end
  end

  def check_version_consistency
    print "Checking version consistency... "

    versions = {}

    # Check README.md
    if File.exist?(README)
      content = File.read(README)
      if (match = content.match(/SaneProcess v(\d+\.\d+)/i))
        versions['README.md'] = match[1]
      end
    end

    # Check docs/SaneProcess.md
    if File.exist?(SOP_DOC)
      content = File.read(SOP_DOC)
      if (match = content.match(/SaneProcess v(\d+\.\d+)/i))
        versions['SaneProcess.md'] = match[1]
      end
    end

    # Check init.sh
    if File.exist?(INIT_SCRIPT)
      content = File.read(INIT_SCRIPT)
      if (match = content.match(/Version (\d+\.\d+)/i))
        versions['init.sh'] = match[1]
      end
    end

    if versions.empty?
      @warnings << "No version strings found"
      puts "⚠️  No versions found"
      return
    end

    unique_versions = versions.values.uniq
    if unique_versions.count == 1
      puts "✅ All files at v#{unique_versions.first}"
    else
      details = versions.map { |f, v| "#{f}=v#{v}" }.join(', ')
      @errors << "Version mismatch: #{details}"
      puts "❌ Mismatch: #{details}"
    end
  end

  def check_urls
    print "Checking URLs in docs... "

    urls_to_check = []

    # Collect URLs from key files
    [README, SOP_DOC, File.join(__dir__, '..', '.claude', 'SOP_CONTEXT.md')].each do |file|
      next unless File.exist?(file)

      content = File.read(file)
      # Extract URLs
      content.scan(%r{https?://[^\s\)\]"']+}).each do |url|
        # Skip localhost, example.com, placeholder URLs
        next if url.include?('localhost')
        next if url.include?('example.com')
        next if url.include?('XXXX')
        next if url.include?('<')

        urls_to_check << { url: url.gsub(/[,\.]$/, ''), file: File.basename(file) }
      end
    end

    if urls_to_check.empty?
      puts "⚠️  No URLs found"
      return
    end

    bad_urls = []
    urls_to_check.uniq { |u| u[:url] }.each do |entry|
      begin
        uri = URI.parse(entry[:url])
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 5

        response = http.head(uri.request_uri)
        # Accept 2xx, 3xx, 404 for GitHub raw URLs that may not exist yet
        unless response.code.to_i < 400 || (response.code.to_i == 404 && entry[:url].include?('raw.githubusercontent'))
          bad_urls << "#{entry[:url]} (#{response.code}) in #{entry[:file]}"
        end
      rescue StandardError => e
        bad_urls << "#{entry[:url]} (#{e.class.name}) in #{entry[:file]}"
      end
    end

    if bad_urls.empty?
      puts "✅ #{urls_to_check.count} URLs reachable"
    else
      bad_urls.each { |u| @warnings << "Unreachable URL: #{u}" }
      puts "⚠️  #{bad_urls.count} unreachable"
    end
  end

  def run_hook_tests
    print "Running hook integration tests... "

    test_file = File.join(HOOKS_DIR, 'test_hooks.rb')
    unless File.exist?(test_file)
      @warnings << "Hook integration tests not found at #{test_file}"
      puts "⚠️  Tests not found"
      return
    end

    result, success = capture_qa_command('ruby', test_file)
    if (match = result.match(/TOTAL: (\d+)\/(\d+) passed(?:, (\d+) weak)?/))
      passed = match[1].to_i
      total = match[2].to_i
      weak = match[3]&.to_i || 0
      failed = total - passed

      if failed == 0
        weak_note = weak > 0 ? " (#{weak} weak)" : ''
        puts "✅ #{passed}/#{total} passed#{weak_note}"
      else
        @errors << "Hook integration tests: #{failed} failed"
        puts "❌ #{passed}/#{total} passed, #{failed} failed"
      end
    elsif success
      puts "✅ Tests pass"
    else
      @errors << "Hook integration tests failed"
      puts "❌ Tests failed"
      puts result.lines.last(5).join if result.lines.count > 0
    end
  end

  def run_self_tests
    print "Running self-tests... "

    hooks_with_self_test = %w[saneprompt sanetools sanetrack sanestop]
    total_passed = 0
    total_failed = 0
    failures = []

    hooks_with_self_test.each do |hook|
      hook_path = File.join(HOOKS_DIR, "#{hook}.rb")
      next unless File.exist?(hook_path)

      result, success = capture_qa_command('ruby', hook_path, '--self-test', timeout: QA_SELF_TEST_TIMEOUT_SECONDS)
      # Match "N/N tests passed" specifically — avoid false matches like "4/5 categories"
      if (match = result.match(/(\d+)\/(\d+) tests passed/))
        passed = match[1].to_i
        total = match[2].to_i
        total_passed += passed
        total_failed += (total - passed)
        failures << "#{hook}: #{total - passed} failed" if total > passed
      elsif success
        # Can't parse count but it passed
        total_passed += 1
      else
        total_failed += 1
        failures << "#{hook}: self-test failed"
      end
    end

    if total_failed == 0
      puts "✅ #{total_passed} passed across #{hooks_with_self_test.length} hooks"
    else
      @errors << "Self-tests: #{failures.join(', ')}"
      puts "❌ #{total_passed} passed, #{total_failed} failed"
      failures.each { |f| puts "   #{f}" }
    end
  end

  def top_level_hook_dependencies
    sources = ALL_HOOK_FILES
    sources.each_with_object([]) do |relative_path, deps|
      path = File.join(HOOKS_DIR, relative_path)
      next unless File.exist?(path)

      File.foreach(path) do |line|
        next unless (match = line.match(/^require_relative ['"]([^'"]+)['"]/))

        dep = normalize_hook_dependency(relative_path, match[1])
        deps << dep if dep
      end
    end.uniq.sort
  end

  def capture_qa_command(*command, timeout: QA_CHILD_COMMAND_TIMEOUT_SECONDS, chdir: SANEPROCESS_ROOT)
    stdout_reader = nil
    stderr_reader = nil

    Open3.popen3(*command, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }

      unless wait_thr.join(timeout)
        Process.kill('TERM', wait_thr.pid)
        unless wait_thr.join(2)
          Process.kill('KILL', wait_thr.pid)
          wait_thr.join
        end

        output = [stdout_reader.value, stderr_reader.value].join
        output << "\nTimed out after #{timeout}s: #{command.join(' ')}"
        return [output, false]
      end

      output = [stdout_reader.value, stderr_reader.value].join
      return [output, wait_thr.value.success?]
    end
  rescue StandardError => e
    ["#{e.class}: #{e.message}", false]
  end

  def normalize_hook_dependency(source_relative_path, dependency)
    dep_with_ext = dependency.end_with?('.rb') ? dependency : "#{dependency}.rb"
    source_dir = File.dirname(File.join(HOOKS_DIR, source_relative_path))
    resolved = File.expand_path(dep_with_ext, source_dir)
    hooks_root = "#{File.expand_path(HOOKS_DIR)}/"
    return nil unless resolved.start_with?(hooks_root)

    resolved.delete_prefix(hooks_root)
  end
end

# Run if executed directly
SaneProcessQA.new.run if __FILE__ == $PROGRAM_NAME
