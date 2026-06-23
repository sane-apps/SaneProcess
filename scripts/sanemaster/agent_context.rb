# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'yaml'
require 'digest'
require 'securerandom'
require 'shellwords'
require 'English'

module SaneMasterModules
  module AgentContext
    CONTEXT_BUNDLE_SCHEMA = 'saneapps.context_bundle.v1'
    DEFAULT_CONTEXT_OUTPUT_DIR = File.join('outputs', 'context-bundles')
    OKF_HEADER_EXAMPLE = '## Topic | Updated: YYYY-MM-DD | Status: verified | TTL: 30d'
    DEFAULT_CONTEXT_SOURCE_PATHS = %w[
      AGENTS.md
      SESSION_HANDOFF.md
      ARCHITECTURE.md
      DEVELOPMENT.md
      .claude/research.md
      .codex/research.md
    ].freeze
    SOURCE_BODY_LIMITS = {
      'AGENTS.md' => 18_000,
      'SESSION_HANDOFF.md' => 24_000,
      'ARCHITECTURE.md' => 10_000,
      'DEVELOPMENT.md' => 10_000,
      '.claude/research.md' => 12_000,
      '.codex/research.md' => 12_000
    }.freeze

    def context_bundle(args = [])
      options = parse_context_bundle_options(args)
      result = build_context_bundle(options)

      unless options[:dry_run]
        assert_context_bundle_output_available!(result)
        FileUtils.mkdir_p(File.dirname(result[:output_path]))
        File.write(result[:output_path], render_context_bundle_markdown(result))
        File.write(result[:manifest_path], JSON.pretty_generate(context_bundle_manifest(result)))
      end

      if respond_to?(:record_process_metric)
        metric = {
          success: true,
          schema_version: 1,
          dry_run: options[:dry_run],
          artifact_written: !options[:dry_run],
          research_cards: result.dig(:research, :cards).length,
          memory_cards: result.dig(:serena_memories, :cards).length
        }
        unless options[:dry_run]
          metric[:output_path] = result[:output_path]
          metric[:manifest_path] = result[:manifest_path]
        end
        record_process_metric('context_bundle', metric)
      end

      if options[:json]
        puts JSON.pretty_generate(context_bundle_manifest(result))
      else
        print_context_bundle_result(result)
      end

      result
    end

    def build_context_bundle(options = {})
      generated_at = Time.now.utc
      root = context_bundle_root(options[:root])
      output_path = normalize_context_output_path(options[:output], root, generated_at)
      manifest_path = output_path.sub(/\.md\z/, '.json')
      max_research = context_card_limit(options.fetch(:max_research, 24), '--max-research')
      max_memory = context_card_limit(options.fetch(:max_memory, 40), '--max-memory')
      research_cards = research_knowledge_cards(max_cards: max_research, root: root)
      memory_cards = serena_memory_cards(max_cards: max_memory, root: root)
      source_cards = context_source_cards(root)
      {
        schema: CONTEXT_BUNDLE_SCHEMA,
        generated_at: generated_at.iso8601,
        project: File.basename(root),
        source_root: root,
        task: options[:task].to_s.strip,
        output_path: output_path,
        manifest_path: manifest_path,
        okf: {
          format: 'Markdown body with YAML frontmatter and linkable source cards',
          source_of_truth: 'existing repo docs, research cache, proof receipts, Serena memory files, and process metrics',
          header_example: OKF_HEADER_EXAMPLE,
          sharing: 'local trusted-review context; redact before sharing outside SaneApps'
        },
        git: git_context_summary,
        sources: source_cards,
        research: research_index(research_cards),
        serena_memories: serena_memory_index(memory_cards),
        recent_receipts: recent_context_receipts(root),
        recommended_checks: %w[agent_eval process_eval skill_lint],
        warnings: context_bundle_warnings(research_cards, memory_cards, source_cards)
      }
    end

    def context_bundle_manifest(result)
      result.merge(
        sources: result[:sources].map { |source| source.reject { |key, _value| key == :excerpt } }
      )
    end

    def render_context_bundle_markdown(result)
      frontmatter = {
        'schema' => result[:schema],
        'generated_at' => result[:generated_at],
        'project' => result[:project],
        'task' => result[:task],
        'source_root' => result[:source_root]
      }

      lines = []
      lines << YAML.dump(frontmatter).strip
      lines << '---'
      lines << ''
      lines << "# Context Bundle: #{result[:project]}"
      lines << ''
      lines << '## Task'
      lines << (result[:task].empty? ? 'No task supplied.' : result[:task])
      lines << ''
      lines << '## Use This For'
      lines << '- Subagent prompts, critic briefs, and resume context inside this trusted repo.'
      lines << '- Treat linked repo files and receipts as source of truth; this bundle is a snapshot.'
      lines << '- Do not share outside SaneApps without redaction; excerpts can contain internal or customer notes.'
      lines << ''
      lines << '## Git State'
      lines << "- Branch: #{result.dig(:git, :branch)}"
      lines << "- Head: #{result.dig(:git, :head)}"
      lines << "- Dirty paths: #{result.dig(:git, :dirty_count)}"
      Array(result.dig(:git, :status)).first(30).each { |entry| lines << "  - `#{entry}`" }
      lines << ''
      lines << '## Source Cards'
      result[:sources].each do |source|
        mode = source[:truncated] ? 'tail excerpt' : 'full file'
        lines << "- `#{source[:path]}` lines=#{source[:lines]} sha=#{source[:sha256][0, 12]} included_chars=#{source[:included_chars]} mode=#{mode}"
      end
      lines << ''
      lines << '## Research Knowledge Cards'
      if result.dig(:research, :cards).empty?
        lines << 'No research cache cards found.'
      else
        result.dig(:research, :cards).each do |card|
          lines << "- #{card[:state]}: `#{card[:title]}` updated=#{card[:updated] || 'unknown'} ttl=#{card[:ttl] || 'unknown'} source=`#{card[:source]}` line=#{card[:line]} promote=#{card[:promotion_target]}"
        end
      end
      lines << ''
      lines << '## Serena Memory Index'
      if result.dig(:serena_memories, :cards).empty?
        lines << 'No Serena memory files found.'
      else
        result.dig(:serena_memories, :cards).each do |card|
          lines << "- #{card[:topic]}: `#{card[:title]}` path=`#{card[:path]}` lines=#{card[:lines]} okf_header=#{card[:okf_header]}"
        end
      end
      lines << ''
      lines << '## Recent Receipts'
      if result[:recent_receipts].empty?
        lines << 'No recent receipts found.'
      else
        result[:recent_receipts].each { |receipt| lines << "- `#{receipt[:path]}` mtime=#{receipt[:mtime]} bytes=#{receipt[:bytes]}" }
      end
      lines << ''
      lines << '## Recommended Checks'
      result[:recommended_checks].each { |command| lines << "- `ruby scripts/SaneMaster.rb #{command}`" }
      lines << ''
      if result[:warnings].any?
        lines << '## Organization Warnings'
        result[:warnings].each { |warning| lines << "- #{warning}" }
        lines << ''
        lines << "Expected research-card header shape: `#{OKF_HEADER_EXAMPLE}`"
        lines << ''
      end
      lines << '## Source Excerpts'
      lines << 'Long files use tail excerpts. Each block says whether it is the full file or a clipped tail snapshot.'
      result[:sources].each do |source|
        lines << "### #{source[:path]}"
        lines << ''
        if source[:truncated]
          lines << "_Tail excerpt: last #{source[:included_chars]} of #{source[:bytes]} characters from the same snapshot hashed above._"
        else
          lines << '_Full file excerpt from the same snapshot hashed above._'
        end
        lines << ''
        lines << '```markdown'
        lines << source[:excerpt].to_s
        lines << '```'
        lines << ''
      end
      lines.join("\n")
    end

    def research_knowledge_cards(max_cards: 24, root: context_bundle_root)
      context_research_paths(root).flat_map do |path|
        parse_research_cards(path)
      end.sort_by { |card| [research_state_rank(card[:state]), -(card[:updated_time]&.to_i || 0)] }
         .first(max_cards.to_i)
    end

    def parse_research_cards(path)
      return [] unless File.exist?(path)

      cards = []
      File.readlines(path).each_with_index do |line, index|
        next unless line.start_with?('## ')

        cards << research_card_from_header(path, line.sub(/^##\s*/, '').strip, index + 1)
      end
      cards
    end

    def research_card_from_header(path, header, line)
      match = header.match(/\A(.+?)\s+\|\s+Updated:\s*([^|]+)\s+\|\s+Status:\s*([^|]+)\s+\|\s+TTL:\s*([^|]+)\z/)
      title = match ? match[1].strip : header
      updated = match ? match[2].strip : nil
      status = match ? match[3].strip : 'unstructured'
      ttl = match ? match[4].strip : nil
      updated_time = parse_context_time(updated)
      ttl_days = ttl.to_s[/(\d+)\s*d/i, 1]&.to_i
      age_days = updated_time ? ((Time.now.utc - updated_time) / 86_400).floor : nil
      metadata_issue = research_metadata_issue(match, updated, updated_time, ttl, ttl_days)
      state = research_card_state(status, age_days, ttl_days, metadata_issue)
      {
        title: title,
        updated: updated,
        updated_time: updated_time,
        status: status,
        ttl: ttl,
        age_days: age_days,
        state: state,
        metadata_valid: metadata_issue.nil? && !match.nil?,
        metadata_issue: metadata_issue,
        source: path,
        line: line,
        promotion_target: research_promotion_target(title, status, state)
      }
    end

    def serena_memory_cards(max_cards: 40, root: context_bundle_root)
      memory_root = File.join(root, '.serena', 'memories')
      return [] unless File.directory?(memory_root)

      Dir.glob(File.join(memory_root, '**', '*.md')).sort_by { |path| -safe_file_mtime_i(path) }
         .first(max_cards.to_i)
         .map { |path| serena_memory_card(memory_root, path) }
         .compact
    end

    def serena_memory_card(root, path)
      lines = File.readlines(path)
      relative = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      topic = relative.include?('/') ? relative.split('/').first : 'global'
      first_heading = lines.find { |line| line.start_with?('#') }.to_s.sub(/^#+\s*/, '').strip
      {
        path: File.join('.serena', 'memories', relative),
        title: first_heading.empty? ? File.basename(path, '.md') : first_heading,
        topic: topic,
        lines: lines.length,
        bytes: File.size(path),
        mtime: File.mtime(path).utc.iso8601,
        okf_header: lines.first(20).any? { |line| line.include?('Updated:') && line.include?('Status:') }
      }
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    private

    def parse_context_bundle_options(args)
      options = {
        task: '',
        output: nil,
        json: false,
        dry_run: false,
        max_research: 24,
        max_memory: 40
      }
      rest = args.dup
      task_parts = []
      until rest.empty?
        token = rest.shift
        case token
        when '--task'
          options[:task] = rest.shift.to_s
        when '--output'
          options[:output] = rest.shift.to_s
        when '--max-research'
          options[:max_research] = parse_context_positive_integer(rest.shift, '--max-research')
        when '--max-memory'
          options[:max_memory] = parse_context_positive_integer(rest.shift, '--max-memory')
        when '--json'
          options[:json] = true
        when '--dry-run'
          options[:dry_run] = true
        else
          task_parts << token if token && !token.start_with?('--')
        end
      end
      options[:task] = task_parts.join(' ') if options[:task].to_s.strip.empty? && task_parts.any?
      options[:output] ||= default_context_bundle_path(Time.now.utc)
      options
    end

    def parse_context_positive_integer(value, flag)
      raise ArgumentError, "#{flag} requires a positive integer" unless value.to_s.match?(/\A[1-9]\d*\z/)

      value.to_i
    end

    def context_card_limit(value, flag)
      return value if value.is_a?(Integer) && value.positive?

      parse_context_positive_integer(value, flag)
    end

    def context_bundle_root(root = nil)
      return File.expand_path(root) unless root.to_s.strip.empty?

      output = `git rev-parse --show-toplevel 2>/dev/null`
      if $CHILD_STATUS&.success? && !output.to_s.strip.empty?
        comparable_context_path(output.strip)
      else
        comparable_context_path(Dir.pwd)
      end
    rescue StandardError
      comparable_context_path(Dir.pwd)
    end

    def normalize_context_output_path(output, root, time)
      path = output.to_s.strip.empty? ? default_context_bundle_path(time, root) : output
      expanded = File.expand_path(path, root)
      unless context_path_inside_root?(expanded, root)
        raise ArgumentError, 'context_bundle --output must stay inside the repo root'
      end
      raise ArgumentError, 'context_bundle --output must end with .md' unless expanded.end_with?('.md')

      expanded
    end

    def context_path_inside_root?(path, root)
      expanded_root = comparable_context_path(root)
      expanded_path = comparable_context_path(path)
      expanded_path == expanded_root || expanded_path.start_with?("#{expanded_root}/")
    end

    def comparable_context_path(path)
      File.expand_path(path).sub(%r{\A/private/}, '/')
    end

    def assert_context_bundle_output_available!(result)
      [result[:output_path], result[:manifest_path]].each do |path|
        raise ArgumentError, "context_bundle output already exists: #{path}" if File.exist?(path)
      end
    end

    def default_context_bundle_path(time, root = context_bundle_root)
      File.join(
        root,
        DEFAULT_CONTEXT_OUTPUT_DIR,
        "context-bundle-#{time.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}.md"
      )
    end

    def context_research_paths(root = context_bundle_root)
      %w[.claude/research.md .codex/research.md].map { |path| File.join(root, path) }.select { |path| File.exist?(path) }
    end

    def research_index(cards)
      stale = cards.count { |card| card[:state] == 'stale' }
      {
        card_count: cards.length,
        stale_count: stale,
        active_count: cards.count { |card| card[:state] == 'active' },
        unstructured_count: cards.count { |card| card[:status] == 'unstructured' },
        invalid_count: cards.count { |card| card[:state] == 'invalid' },
        cards: cards.map { |card| card.reject { |key, _value| key == :updated_time } }
      }
    end

    def serena_memory_index(cards)
      {
        card_count: cards.length,
        missing_okf_header_count: cards.count { |card| !card[:okf_header] },
        topics: cards.group_by { |card| card[:topic] }.transform_values(&:length),
        cards: cards
      }
    end

    def context_source_cards(root = context_bundle_root)
      DEFAULT_CONTEXT_SOURCE_PATHS.map do |relative_path|
        path = File.join(root, relative_path)
        next unless File.exist?(path)

        content = File.read(path)
        limit = SOURCE_BODY_LIMITS.fetch(relative_path, 8_000)
        excerpt = context_source_excerpt(content, limit)
        {
          path: relative_path,
          lines: content.lines.length,
          bytes: content.bytesize,
          sha256: Digest::SHA256.hexdigest(content),
          included_chars: excerpt.length,
          truncated: content.length > limit,
          excerpt: excerpt
        }
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end.compact
    end

    def context_source_excerpt(content, limit)
      return content if content.length <= limit.to_i

      content[-limit.to_i, limit.to_i]
    end

    def recent_context_receipts(root = context_bundle_root, limit = 20)
      patterns = [
        File.join(root, 'outputs', 'tool-discovery', '*.{md,json}'),
        File.join(root, 'outputs', 'context-bundles', '*.{md,json}'),
        File.join(root, 'outputs', 'visual-audit*', '*.{md,json,png}'),
        File.join(root, 'outputs', '*receipt*.{md,json}')
      ]
      Dir.glob(patterns).uniq.select { |path| File.file?(path) }
         .sort_by { |path| -safe_file_mtime_i(path) }
         .first(limit)
         .map do |path|
           {
             path: relative_context_path(path, root),
             bytes: File.size(path),
             mtime: File.mtime(path).utc.iso8601
           }
         rescue Errno::ENOENT, Errno::EACCES
           nil
         end
         .compact
    end

    def context_bundle_warnings(research_cards, memory_cards, source_cards)
      warnings = []
      warnings << 'No AGENTS.md source card found.' unless source_cards.any? { |card| card[:path] == 'AGENTS.md' }
      stale_research = research_cards.count { |card| card[:state] == 'stale' }
      warnings << "#{stale_research} research card(s) are stale and should be promoted or refreshed." if stale_research.positive?
      unstructured = research_cards.count { |card| card[:status] == 'unstructured' }
      warnings << "#{unstructured} research card(s) lack OKF-style Updated/Status/TTL metadata. Expected: #{OKF_HEADER_EXAMPLE}" if unstructured.positive?
      invalid = research_cards.count { |card| card[:state] == 'invalid' }
      warnings << "#{invalid} research card(s) have invalid freshness metadata and should be corrected." if invalid.positive?
      missing_okf = memory_cards.count { |card| !card[:okf_header] }
      if missing_okf.positive?
        warnings << "#{missing_okf} Serena memory file(s) lack OKF-style header metadata; leave old memories alone unless they become active again. Expected: Updated: YYYY-MM-DD | Status: verified | TTL: 30d"
      end
      warnings
    end

    def git_context_summary
      {
        branch: git_capture('rev-parse', '--abbrev-ref', 'HEAD'),
        head: git_capture('rev-parse', '--short', 'HEAD'),
        status: git_status_lines,
        dirty_count: git_status_lines.length
      }
    end

    def git_status_lines
      @git_status_lines ||= git_capture('status', '--short').split("\n").reject(&:empty?)
    end

    def git_capture(*args)
      output = `git #{args.map { |arg| Shellwords.escape(arg) }.join(' ')} 2>/dev/null`
      $CHILD_STATUS&.success? ? output.strip : 'unknown'
    rescue StandardError
      'unknown'
    end

    def parse_context_time(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def research_metadata_issue(match, updated, updated_time, ttl, ttl_days)
      return nil unless match
      return 'invalid Updated value' if updated_time.nil? && !updated.to_s.strip.empty?
      return 'Updated date is in the future' if updated_time && updated_time > Time.now.utc + 3600
      return 'invalid TTL value' if ttl_days.nil? && !ttl.to_s.strip.empty?

      nil
    end

    def research_card_state(status, age_days, ttl_days, metadata_issue = nil)
      return 'invalid' if metadata_issue
      return 'unstructured' if status.to_s == 'unstructured'
      return 'active' if status.to_s.downcase.include?('active')
      return 'stale' if ttl_days.to_i.positive? && age_days && age_days > ttl_days.to_i

      'current'
    end

    def research_state_rank(state)
      { 'active' => 0, 'stale' => 1, 'invalid' => 2, 'unstructured' => 3, 'current' => 4 }.fetch(state.to_s, 5)
    end

    def research_promotion_target(title, status, state)
      text = "#{title} #{status}".downcase
      return 'SESSION_HANDOFF.md' if state == 'active'
      return 'ARCHITECTURE.md or DEVELOPMENT.md' if state == 'stale'
      return 'correct research header metadata' if state == 'invalid'
      return 'Serena memory; mirror durable facts to memory graph' if text.match?(/\b(bug|support|customer|release|proof|app store|setapp)\b/)
      return 'DEVELOPMENT.md' if text.match?(/\b(test|verify|build|tool|script|hook)\b/)

      'keep in research cache'
    end

    def safe_file_mtime_i(path)
      File.mtime(path).to_i
    rescue Errno::ENOENT, Errno::EACCES
      0
    end

    def relative_context_path(path, root)
      expanded = File.expand_path(path)
      expanded_root = File.expand_path(root)
      return expanded.delete_prefix("#{expanded_root}/") if expanded.start_with?("#{expanded_root}/")

      expanded
    end

    def print_context_bundle_result(result)
      puts 'Context Bundle'
      puts '=' * 14
      puts "Output: #{result[:output_path]}"
      puts "Manifest: #{result[:manifest_path]}"
      puts "Task: #{result[:task].empty? ? '(none)' : result[:task]}"
      puts "Sources: #{result[:sources].length}"
      puts "Research cards: #{result.dig(:research, :card_count)} (#{result.dig(:research, :stale_count)} stale)"
      puts "Serena memories indexed: #{result.dig(:serena_memories, :card_count)}"
      result[:warnings].each { |warning| puts "  WARNING: #{warning}" }
    end
  end
end
