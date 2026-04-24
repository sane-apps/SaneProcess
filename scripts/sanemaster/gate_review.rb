# frozen_string_literal: true

require 'json'

module SaneMasterModules
  module GateReview
    GATE_REVIEW_STOPWORDS = %w[
      a an and are as at be been being but by for from in into is it its of on or
      that the this those these to was were with without
    ].freeze

    def run_gate_review(args)
      args = args.dup
      json_mode = args.delete('--json')

      if args.empty? || args.include?('--help') || args.include?('-h')
        print_gate_review_usage
        return false
      end

      fixture_path = args.shift
      unless fixture_path && File.file?(fixture_path)
        warn "Missing gate review fixture: #{fixture_path}"
        return false
      end

      fixture = JSON.parse(File.read(fixture_path))
      result = review_gate_fixture(fixture, fixture_path: fixture_path)
      record_process_metric(
        'gate_review',
        success: result[:passed],
        fixture: fixture_path,
        passed_count: result[:passed_count],
        failed_count: result[:failed_count]
      ) if respond_to?(:record_process_metric)

      if json_mode
        puts JSON.pretty_generate(result)
      else
        print_gate_review_result(result)
      end

      result[:passed]
    rescue JSON::ParserError => e
      warn "Invalid gate review JSON: #{e.message}"
      false
    rescue ArgumentError => e
      warn "Invalid gate review fixture: #{e.message}"
      false
    end

    def review_gate_fixture(fixture = nil, fixture_path: nil, **keyword_fixture)
      fixture = keyword_fixture if fixture.nil? && keyword_fixture.any?
      rules = gate_review_rules_from_fixture(fixture)
      rule_results = rules.each_with_index.map { |rule, index| review_gate_rule(rule, index: index) }
      failed = rule_results.count { |result| !result[:passed] }

      {
        fixture: fixture_path,
        passed: failed.zero?,
        passed_count: rule_results.length - failed,
        failed_count: failed,
        rules: rule_results
      }
    end

    def review_gate_rule(raw_rule = nil, index: 0, **keyword_rule)
      raw_rule = keyword_rule if raw_rule.nil? && keyword_rule.any?
      rule = normalize_gate_review_rule(raw_rule, index: index)
      trigger_tokens = gate_review_tokenize(rule[:trigger])
      seed_matches = gate_review_match?(rule[:trigger], rule[:seed])

      block_results = rule[:block].each_with_index.map do |example, example_index|
        { index: example_index, text: example, matched: gate_review_match?(rule[:trigger], example) }
      end

      allow_results = rule[:allow].each_with_index.map do |example, example_index|
        { index: example_index, text: example, matched: gate_review_match?(rule[:trigger], example) }
      end

      missing_blocks = block_results.reject { |result| result[:matched] }
      false_positives = allow_results.select { |result| result[:matched] }
      block_hits = block_results.count { |result| result[:matched] }
      all_hits = block_hits + false_positives.length

      issues = []
      issues << 'trigger has no reviewable tokens' if trigger_tokens.empty?
      issues << 'seed does not match trigger' unless seed_matches
      issues << 'at least one block example is required' if rule[:block].empty?
      issues << 'at least one allow example is required' if rule[:allow].empty?
      missing_blocks.each do |result|
        issues << "block[#{result[:index]}] did not match trigger: #{gate_review_clip(result[:text])}"
      end
      false_positives.each do |result|
        issues << "allow[#{result[:index]}] matched trigger: #{gate_review_clip(result[:text])}"
      end

      {
        id: rule[:id],
        trigger: rule[:trigger],
        trigger_tokens: trigger_tokens,
        passed: issues.empty?,
        issues: issues,
        seed_matches: seed_matches,
        block_count: rule[:block].length,
        allow_count: rule[:allow].length,
        missing_blocks: missing_blocks,
        false_positives: false_positives,
        precision: all_hits.zero? ? nil : (block_hits.to_f / all_hits).round(3),
        recall: rule[:block].empty? ? nil : (block_hits.to_f / rule[:block].length).round(3)
      }
    end

    def gate_review_match?(trigger, text)
      trigger_tokens = gate_review_tokenize(trigger)
      return false if trigger_tokens.empty?

      text_tokens = gate_review_tokenize(text)
      (trigger_tokens - text_tokens).empty?
    end

    def gate_review_tokenize(text)
      text.to_s
          .downcase
          .gsub(/[^a-z0-9]+/, ' ')
          .split
          .reject { |token| token.length < 2 || GATE_REVIEW_STOPWORDS.include?(token) }
          .map { |token| normalize_gate_review_token(token) }
          .uniq
    end

    private

    def gate_review_rules_from_fixture(fixture)
      if fixture.is_a?(Array)
        fixture
      elsif fixture.is_a?(Hash) && fixture.key?('rules')
        fixture.fetch('rules')
      elsif fixture.is_a?(Hash)
        [fixture]
      else
        raise ArgumentError, 'fixture must be an object, an array, or an object with a rules array'
      end.tap do |rules|
        raise ArgumentError, 'rules must be a non-empty array' unless rules.is_a?(Array) && rules.any?
      end
    end

    def normalize_gate_review_rule(raw_rule, index:)
      raise ArgumentError, "rule[#{index}] must be an object" unless raw_rule.is_a?(Hash)

      id = first_gate_review_value(raw_rule, 'id', 'name') || "rule_#{index + 1}"
      trigger = first_gate_review_value(raw_rule, 'trigger', 'pattern', 'rule')
      seed = first_gate_review_value(raw_rule, 'seed', 'lesson', 'incident', 'source')
      block = gate_review_array(first_gate_review_value(raw_rule, 'block', 'blocks', 'should_block', 'expected_block'))
      allow = gate_review_array(first_gate_review_value(raw_rule, 'allow', 'allows', 'should_allow', 'expected_allow'))

      raise ArgumentError, "rule[#{index}] is missing trigger" if trigger.to_s.strip.empty?
      raise ArgumentError, "rule[#{index}] is missing seed" if seed.to_s.strip.empty?

      {
        id: id.to_s,
        trigger: trigger.to_s,
        seed: gate_review_example_text(seed),
        block: block.map { |example| gate_review_example_text(example) },
        allow: allow.map { |example| gate_review_example_text(example) }
      }
    end

    def first_gate_review_value(hash, *keys)
      keys.each do |key|
        return hash[key] if hash.key?(key)

        symbol_key = key.to_sym
        return hash[symbol_key] if hash.key?(symbol_key)
      end
      nil
    end

    def gate_review_array(value)
      case value
      when nil
        []
      when Array
        value
      else
        [value]
      end
    end

    def gate_review_example_text(value)
      if value.is_a?(Hash)
        first_gate_review_value(value, 'text', 'prompt', 'command', 'message').to_s
      else
        value.to_s
      end
    end

    def normalize_gate_review_token(token)
      normalized = token.to_s
      if normalized.length > 4 && normalized.end_with?('ies')
        normalized = "#{normalized[0..-4]}y"
      elsif normalized.length > 4 && normalized.end_with?('s') && !normalized.end_with?('ss', 'us')
        normalized = normalized[0..-2]
      end
      normalized
    end

    def gate_review_clip(text, max = 96)
      value = text.to_s.gsub(/\s+/, ' ').strip
      value.length > max ? "#{value[0, max - 3]}..." : value
    end

    def print_gate_review_usage
      puts <<~USAGE
        Usage: ruby scripts/SaneMaster.rb gate_review <fixture.json> [--json]

        Fixture format:
          {
            "rules": [
              {
                "id": "no-force-push-main",
                "trigger": "force push main",
                "seed": "A release was damaged by force push main",
                "block": ["git push --force origin main"],
                "allow": ["git push origin feature-branch", "git status"]
              }
            ]
          }

        A candidate gate passes only when the seed and every block example match,
        no allow example matches, and both block and allow examples are present.
      USAGE
    end

    def print_gate_review_result(result)
      puts '--- [ GATE REVIEW ] ---'
      puts "Fixture: #{result[:fixture]}" if result[:fixture]
      result[:rules].each do |rule|
        marker = rule[:passed] ? '[PASS]' : '[FAIL]'
        precision = rule[:precision] ? format('%.3f', rule[:precision]) : 'n/a'
        recall = rule[:recall] ? format('%.3f', rule[:recall]) : 'n/a'
        puts "#{marker} #{rule[:id]} (precision #{precision}, recall #{recall})"
        rule[:issues].each { |issue| puts "  - #{issue}" }
      end
      puts "Summary: #{result[:passed_count]} passed, #{result[:failed_count]} failed"
    end
  end
end
