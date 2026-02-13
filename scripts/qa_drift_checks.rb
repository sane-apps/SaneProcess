#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# QA Drift Detection Module
# ==============================================================================
# Catches the exact problems that cause AI auditors to produce wrong findings:
# stale docs, mismatched counts, dead references, oversized files.
#
# Extracted from qa.rb per Rule #10 (file size limits).
#
# Usage:
#   require_relative 'qa_drift_checks'
#   include QaDriftChecks
# ==============================================================================

module QaDriftChecks
  ARCHITECTURE_MD = File.join(__dir__, '..', 'ARCHITECTURE.md')
  STATE_MANAGER_RB = File.join(__dir__, 'hooks', 'core', 'state_manager.rb')
  RULE_TRACKER_RB = File.join(__dir__, 'hooks', 'rule_tracker.rb')

  # === CHECK 1: State Schema Drift ===
  # Parses ARCHITECTURE.md JSON schema block and compares top-level keys
  # against StateManager::SCHEMA in state_manager.rb.
  def check_state_schema_drift
    print 'Checking state schema drift... '

    unless File.exist?(ARCHITECTURE_MD)
      @warnings << 'ARCHITECTURE.md not found'
      puts '⚠️  Not found'
      return
    end

    unless File.exist?(STATE_MANAGER_RB)
      @warnings << 'state_manager.rb not found'
      puts '⚠️  Not found'
      return
    end

    # Extract documented keys from ARCHITECTURE.md JSON block
    arch_content = File.read(ARCHITECTURE_MD)
    json_match = arch_content.match(/### State Schema\s+```json\s+(\{[\s\S]*?\n```)/m)
    unless json_match
      @warnings << 'ARCHITECTURE.md: State schema JSON block not found'
      puts '⚠️  No schema block'
      return
    end

    # Parse the JSON (strip trailing ```)
    json_text = json_match[1].sub(/\n```\z/, '')
    begin
      doc_schema = JSON.parse(json_text)
    rescue JSON::ParserError => e
      @errors << "ARCHITECTURE.md state schema is invalid JSON: #{e.message}"
      puts '❌ Invalid JSON'
      return
    end
    doc_keys = doc_schema.keys.sort

    # Extract code keys from state_manager.rb SCHEMA hash
    sm_content = File.read(STATE_MANAGER_RB)
    # Match top-level symbol keys in SCHEMA = { ... }.freeze
    code_keys = sm_content.scan(/^\s+(\w+):\s*\{/).flatten
    # Also catch simple values like: action_log: [], learnings: [], refusal_tracking: {}, sensitive_approvals: {}
    code_keys += sm_content.scan(/^\s+(\w+):\s*[\[\{]/).flatten
    code_keys = code_keys.uniq.sort
    # Filter to only keys that are actually in the SCHEMA block (between SCHEMA = { and }.freeze)
    schema_block = sm_content[/SCHEMA\s*=\s*\{(.*?)\}\.freeze/m, 1] || ''
    code_keys = schema_block.scan(/^\s{4}(\w+):/).flatten.uniq.sort

    missing_in_docs = code_keys - doc_keys
    extra_in_docs = doc_keys - code_keys

    if missing_in_docs.empty? && extra_in_docs.empty?
      puts "✅ #{doc_keys.count} sections match code"
    else
      if missing_in_docs.any?
        @errors << "ARCHITECTURE.md missing state sections: #{missing_in_docs.join(', ')}"
      end
      if extra_in_docs.any?
        @errors << "ARCHITECTURE.md has extra state sections not in code: #{extra_in_docs.join(', ')}"
      end
      puts "❌ Drift: #{missing_in_docs.count} missing, #{extra_in_docs.count} extra"
    end
  end

  # === CHECK 2: Rule Count Cross-Check ===
  # Verifies rule_tracker.rb RULES count matches README "16 Golden Rules"
  def check_rule_count_crossref
    print 'Checking rule count cross-reference... '

    unless File.exist?(RULE_TRACKER_RB)
      @warnings << 'rule_tracker.rb not found'
      puts '⚠️  Not found'
      return
    end

    # Count rules in rule_tracker.rb
    rt_content = File.read(RULE_TRACKER_RB)
    code_rules = rt_content.scan(/^\s+(\d+)\s*=>/).flatten.map(&:to_i)
    code_count = code_rules.count

    # Check README
    readme_path = File.join(__dir__, '..', 'README.md')
    readme_rule_count = nil
    if File.exist?(readme_path)
      readme_content = File.read(readme_path)
      if (m = readme_content.match(/(\d+)\s+Golden Rules/i))
        readme_rule_count = m[1].to_i
      end
    end

    # Check CLAUDE.md for rule references
    claude_md = File.join(__dir__, '..', 'CLAUDE.md')
    claude_rule_refs = []
    if File.exist?(claude_md)
      claude_content = File.read(claude_md)
      claude_rule_refs = claude_content.scan(/#(\d+)\s+[A-Z]/).flatten.map(&:to_i)
    end

    issues = []

    if readme_rule_count && readme_rule_count != code_count
      issues << "README says #{readme_rule_count} rules, rule_tracker.rb has #{code_count}"
    end

    # Check rule numbering is contiguous 0..N
    expected_range = (0...code_count).to_a
    if code_rules.sort != expected_range
      issues << "rule_tracker.rb rules not contiguous 0..#{code_count - 1}: #{code_rules.sort.inspect}"
    end

    if issues.empty?
      puts "✅ #{code_count} rules consistent"
    else
      issues.each { |i| @errors << i }
      puts "❌ #{issues.count} issue(s)"
    end
  end

  # === CHECK 3: Test Count Verification ===
  # Compares actual test counts from running tests against README claims.
  # Checks: tier total, self-test total, grand total, and internal consistency.
  def check_test_count_claims
    print 'Checking test count claims... '

    readme_path = File.join(__dir__, '..', 'README.md')
    unless File.exist?(readme_path)
      @warnings << 'README.md not found'
      puts '⚠️  Not found'
      return
    end

    readme_content = File.read(readme_path)
    issues = []

    # Extract README claims
    claimed_total = readme_content[/\*\*(\d+)\s+Tests\*\*/i, 1]&.to_i
    claimed_tier = readme_content[/Tier Tests \((\d+)\)/i, 1]&.to_i
    claimed_self = readme_content[/Self-Tests \((\d+)\)/i, 1]&.to_i

    # Extract per-tier counts from table rows (Easy, Hard, Villain)
    tier_rows = {}
    readme_content.scan(/\|\s*(Easy|Hard|Villain)\s*\|\s*(\d+)\s*\|/i) do |tier, count|
      tier_rows[tier.downcase] = count.to_i
    end
    tier_row_sum = tier_rows.values.sum if tier_rows.any?

    # Extract per-hook self-test counts
    self_rows = {}
    readme_content.scan(/\|\s*(saneprompt|sanetrack|sanetools|sanestop)\s*\|\s*(\d+)\s*\|/i) do |hook, count|
      self_rows[hook.downcase] = count.to_i
    end
    self_row_sum = self_rows.values.sum if self_rows.any?

    # Internal consistency: do table rows sum to header?
    if tier_row_sum && claimed_tier && tier_row_sum != claimed_tier
      issues << "README tier rows sum to #{tier_row_sum}, header says #{claimed_tier}"
    end
    if self_row_sum && claimed_self && self_row_sum != claimed_self
      issues << "README self-test rows sum to #{self_row_sum}, header says #{claimed_self}"
    end
    if claimed_total && claimed_tier && claimed_self && claimed_tier + claimed_self != claimed_total
      issues << "README total (#{claimed_total}) != tier (#{claimed_tier}) + self (#{claimed_self})"
    end

    # Get actual tier test total
    test_file = File.join(__dir__, 'hooks', 'test', 'tier_tests.rb')
    if File.exist?(test_file)
      result = `ruby #{test_file} 2>&1`
      if (match = result.match(/TOTAL: (\d+)\/(\d+) passed/))
        actual_tier = match[2].to_i
        if claimed_tier && claimed_tier != actual_tier
          issues << "README claims #{claimed_tier} tier tests, actual: #{actual_tier}"
        end
      end
    end

    # Get actual self-test totals per hook
    actual_self_total = 0
    %w[saneprompt sanetools sanetrack sanestop].each do |hook|
      hook_path = File.join(__dir__, 'hooks', "#{hook}.rb")
      next unless File.exist?(hook_path)

      result = `ruby #{hook_path} --self-test 2>&1`
      if (match = result.match(/(\d+)\/(\d+) tests passed/))
        actual = match[2].to_i
        actual_self_total += actual
        if self_rows[hook] && self_rows[hook] != actual
          issues << "README claims #{self_rows[hook]} #{hook} self-tests, actual: #{actual}"
        end
      end
    end

    if claimed_self && actual_self_total > 0 && claimed_self != actual_self_total
      issues << "README claims #{claimed_self} total self-tests, actual: #{actual_self_total}"
    end

    if issues.empty?
      puts '✅ Test counts match'
    else
      issues.each { |i| @errors << i }
      puts "❌ #{issues.count} count mismatch(es)"
    end
  end

  # === CHECK 4: Stale Code References ===
  # Greps for patterns known to be removed/changed, catching forgotten references
  def check_stale_references
    print 'Checking for stale references... '

    # Patterns that should NOT appear in current codebase
    # Each entry: [pattern, description, file_glob]
    stale_patterns = [
      ['research.*5.*categor', 'Research is 4 categories (not 5) since memory removal', 'hooks/**/*.rb'],
      ['tracked_count == 5', 'Research tracks 4 categories (not 5)', 'hooks/**/*.rb'],
      ['localhost:37777', 'claude-mem/Sane-Mem removed Feb 2026', 'hooks/**/*.rb'],
      ['sane.mem', 'claude-mem/Sane-Mem removed Feb 2026', 'hooks/**/*.rb'],
      ['claude.mem', 'claude-mem plugin removed Feb 2026', 'hooks/**/*.rb']
    ]

    found = []
    stale_patterns.each do |pattern, desc, glob|
      Dir.glob(File.join(__dir__, glob)).each do |file|
        # Skip test files — they may legitimately reference old patterns for testing
        next if file.include?('/test/')

        content = File.read(file)
        content.each_line.with_index(1) do |line, num|
          next if line.strip.start_with?('#') # Skip comments

          if line.match?(/#{pattern}/i)
            found << "#{File.basename(file)}:#{num} — #{desc}"
          end
        end
      end
    end

    if found.empty?
      puts '✅ No stale references'
    else
      found.uniq.each { |f| @errors << "Stale reference: #{f}" }
      puts "❌ #{found.uniq.count} stale reference(s)"
    end
  end

  # === CHECK 5: File Line Count Audit ===
  # Enforces Rule #10: 500 soft limit, 800 hard limit
  def check_file_line_counts
    print 'Checking hook file sizes... '

    soft_limit = 500
    hard_limit = 800

    warnings = []
    errors = []

    # Check all .rb files in hooks/ (excluding test/)
    Dir.glob(File.join(__dir__, 'hooks', '**', '*.rb')).each do |file|
      next if file.include?('/test/')

      lines = File.readlines(file).count
      basename = file.sub("#{__dir__}/hooks/", '')

      if lines > hard_limit
        errors << "#{basename}: #{lines} lines (HARD LIMIT #{hard_limit})"
      elsif lines > soft_limit
        warnings << "#{basename}: #{lines} lines (soft limit #{soft_limit})"
      end
    end

    # Also check qa.rb itself and SaneMaster modules
    [File.join(__dir__, 'qa.rb'), File.join(__dir__, 'qa_drift_checks.rb')].each do |file|
      next unless File.exist?(file)

      lines = File.readlines(file).count
      basename = File.basename(file)
      if lines > hard_limit
        errors << "#{basename}: #{lines} lines (HARD LIMIT #{hard_limit})"
      elsif lines > soft_limit
        warnings << "#{basename}: #{lines} lines (soft limit #{soft_limit})"
      end
    end

    if errors.empty? && warnings.empty?
      puts '✅ All files within limits'
    else
      errors.each { |e| @errors << "File too large: #{e}" }
      warnings.each { |w| @warnings << "File growing: #{w}" }
      if errors.any?
        puts "❌ #{errors.count} over hard limit"
      else
        puts "⚠️  #{warnings.count} approaching limit"
      end
    end
  end
end
