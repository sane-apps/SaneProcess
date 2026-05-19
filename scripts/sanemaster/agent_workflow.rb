# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'yaml'
require 'digest'

module SaneMasterModules
  module AgentWorkflow
    DEFAULT_AGENT_EVAL_FIXTURE = File.expand_path('../agent_eval_fixtures.json', __dir__)

    def agent_eval(args = [])
      options = parse_agent_workflow_options(args)
      fixture_path = options.fetch(:fixture, DEFAULT_AGENT_EVAL_FIXTURE)
      result = run_agent_eval_fixture(fixture_path)
      record_process_metric('agent_eval', success: result[:passed], cases: result[:case_count], failed: result[:failed_count]) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_agent_eval_result(result)
      end

      result[:passed]
    end

    def skill_lint(args = [])
      options = parse_agent_workflow_options(args)
      paths = options[:paths]
      paths = default_skill_lint_paths if paths.empty?
      result = lint_skill_paths(paths)
      record_process_metric('skill_lint', success: result[:passed], skills: result[:skill_count], failed: result[:failed_count]) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_skill_lint_result(result)
      end

      result[:passed]
    end

    def agent_env_review(args = [])
      options = parse_agent_workflow_options(args)
      result = build_agent_env_review
      record_process_metric('agent_env_review', success: result[:blockers].empty?, blockers: result[:blockers].length, warnings: result[:warnings].length) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_agent_env_review(result)
      end

      result
    end

    def run_agent_eval_fixture(fixture_path)
      fixture = JSON.parse(File.read(fixture_path))
      cases = Array(fixture.fetch('cases'))
      results = cases.map { |entry| evaluate_agent_case(entry) }
      failed = results.reject { |entry| entry[:passed] }
      {
        fixture: fixture_path,
        case_count: results.length,
        passed_count: results.length - failed.length,
        failed_count: failed.length,
        passed: failed.empty?,
        cases: results
      }
    end

    def evaluate_agent_case(entry)
      id = entry.fetch('id')
      prompt = entry.fetch('prompt')
      expected = entry.fetch('expect', {})
      actual = classify_agent_prompt(prompt)
      issues = []

      Array(expected['commands']).each do |command|
        issues << "missing command #{command}" unless actual[:commands].include?(command)
      end

      Array(expected['skills']).each do |skill|
        issues << "missing skill #{skill}" unless actual[:skills].include?(skill)
      end

      if expected.key?('subagent') && actual[:subagent] != expected['subagent']
        issues << "subagent expected #{expected['subagent']} got #{actual[:subagent]}"
      end

      if expected.key?('approval') && actual[:approval] != expected['approval']
        issues << "approval expected #{expected['approval']} got #{actual[:approval]}"
      end

      Array(expected['forbid_commands']).each do |command|
        issues << "forbidden command #{command}" if actual[:commands].include?(command)
      end

      Array(expected['forbid_skills']).each do |skill|
        issues << "forbidden skill #{skill}" if actual[:skills].include?(skill)
      end

      Array(expected['notes_include']).each do |note|
        issues << "missing note #{note}" unless actual[:notes].any? { |actual_note| actual_note.include?(note) }
      end

      {
        id: id,
        prompt: prompt,
        passed: issues.empty?,
        issues: issues,
        actual: actual
      }
    end

    def classify_agent_prompt(prompt)
      text = prompt.to_s.downcase
      commands = []
      skills = []
      notes = []
      subagent = false
      approval = false

      if text.match?(/\b(gmail|personal email|personal inbox)\b/)
        skills << 'gmail'
      elsif text.match?(/\b(check|read|triage|reply|send|resolve|draft).*\b(email|inbox)\b|\binbox\b/)
        commands << 'check_inbox'
        skills << 'check-inbox'
        approval = true if text.match?(/\b(reply|send|resolve|draft)\b/)
      end

      if text.match?(/\b(sales|revenue)\b/)
        commands << 'sales'
        commands << 'events'
        notes << 'Revenue questions need sales plus funnel context.'
      end

      commands << 'downloads' if text.match?(/\b(download stats|downloads|download analytics)\b/)
      commands << 'events' if text.match?(/\b(conversions|upgrades|new users|funnel|source of sales)\b/)

      if text.match?(/\b(missing tool|better tool|workaround|install.*tool|upgrade.*tool|tooling gap)\b/)
        commands << 'tool_discovery'
        skills << 'evolve'
      end

      if text.match?(/\b(verify|does it build|run verification|test suite|build and test|build.*test)\b/)
        commands << 'verify'
        skills << 'verify'
        notes << 'Build/test/runtime workflows are Mini-first.'
      end

      if text.match?(/\b(launch|runtime|run the app|test mode)\b/)
        commands << 'test_mode'
        notes << 'Build/test/runtime workflows are Mini-first.'
      end

      if text.match?(/\b(ship it|prepare.*release|clear.*shipping|clear for release|release readiness)\b/)
        commands << 'release_preflight'
        skills << 'ship'
      end

      if text.match?(/\b(full audit|audit the app|audit docs|documentation audit|docs audit|saneapps audit)\b/)
        commands << 'audit'
        skills << 'audit'
        subagent = true
      end

      if text.match?(/\b(review this code|code review|critic)\b/)
        skills << 'critic'
        subagent = true
      end

      if text.match?(/\b(ui|visual|screenshot|customer workflow|prove.*works)\b/)
        commands << 'visual_smoke'
        commands << 'customer_ui_sweep' if text.include?('workflow') || text.include?('customer')
      end

      if text.match?(/\b(memory|handoff|context|research cache|agent workflow)\b/)
        commands << 'agent_env_review' if text.match?(/\b(improve|audit|review|workflow|tooling|takeaways)\b/)
      end

      notes << 'Subagent prompts must include hook compliance, stop-on-block, and Mini-first instructions.' if subagent
      notes << 'NVIDIA agents and nv sweeps are exception-only unless explicitly requested.' if text.match?(/\b(nvidia|nv sweep|model sweep|outside models)\b/)

      {
        commands: commands.uniq,
        skills: skills.uniq,
        subagent: subagent,
        approval: approval,
        notes: notes.uniq
      }
    end

    def lint_skill_paths(paths)
      skill_files = paths.flat_map { |path| skill_files_under(path) }.uniq.sort
      results = skill_files.map { |file| lint_skill_file(file) }
      missing = paths.select { |path| File.directory?(path) && File.basename(path) != 'skills' && !File.exist?(File.join(path, 'SKILL.md')) }
      missing.each do |path|
        results << {
          file: File.join(path, 'SKILL.md'),
          passed: false,
          issues: ['skill directory is missing SKILL.md']
        }
      end

      failed = results.reject { |entry| entry[:passed] }
      duplicate_drift = duplicate_skill_drift(results)
      {
        paths: paths,
        skill_count: results.length,
        passed_count: results.length - failed.length,
        failed_count: failed.length,
        duplicate_drift: duplicate_drift,
        passed: failed.empty?,
        skills: results
      }
    end

    def lint_skill_file(file)
      content = File.read(file)
      issues = []
      frontmatter = content[/\A---\n(.*?)\n---/m, 1].to_s
      description = skill_frontmatter_description(frontmatter)
      skill_name = skill_frontmatter_name(frontmatter)
      body = content.sub(/\A---\n.*?\n---\n/m, '')

      issues << 'missing frontmatter description' if description.empty?
      issues << 'description is too short to route reliably' if !description.empty? && description.length < 60
      issues << 'missing "when to use" or trigger guidance' unless body.match?(/when to use|when this skill|trigger|use when/i) || description.match?(/use when|trigger/i)
      issues << 'contains unresolved TODO placeholder' if unresolved_todo_placeholder?(content)
      issues << 'contains legacy NVIDIA/nv default guidance' if legacy_nvidia_default_guidance?(content)

      {
        file: file,
        name: skill_name.empty? ? File.basename(File.dirname(file)) : skill_name,
        content_sha: Digest::SHA256.hexdigest(content),
        passed: issues.empty?,
        issues: issues
      }
    end

    def build_agent_env_review
      metrics_summary = respond_to?(:process_metrics_summary, true) ? send(:process_metrics_summary, send(:read_process_metric_events)) : {}
      metrics_path = respond_to?(:process_metrics_path) ? process_metrics_path : nil
      research_caches = research_cache_summaries
      research_lines = research_caches.sum { |entry| entry[:lines] }
      tool_receipts = Dir.glob(File.join(Dir.pwd, 'outputs', 'tool-discovery', '*.{md,json}'))
      missing_skill_dirs = default_skill_lint_paths.select { |path| File.directory?(path) && File.basename(path) != 'skills' && !File.exist?(File.join(path, 'SKILL.md')) }
      skill_lint_result = lint_skill_paths(default_skill_lint_paths)
      sop_review_result = respond_to?(:build_sop_review, true) ? build_sop_review(send(:read_process_metric_events)) : nil

      blockers = []
      warnings = []
      actions = []

      if metrics_summary[:total_events].to_i.zero?
        warnings << "no process metrics found at #{metrics_path || 'unknown metrics path'}"
      end

      if metrics_summary.dig(:verify, :attempts).to_i < 30
        warnings << 'process metrics have fewer than 30 verify attempts; trend confidence is low'
        actions << 'keep process_metrics collection enabled and review again after 30+ verify attempts'
      end

      if metrics_summary.dig(:sessions, :total).to_i < 30
        warnings << 'process metrics have fewer than 30 session_end events; SOP scoring trend is weak'
      end

      if research_lines > 200
        warnings << ".claude/research.md is #{research_lines} lines; active cache is above the 200-line target"
        actions << 'promote durable research into ARCHITECTURE, DEVELOPMENT, Serena, or memory graph before compacting'
      end

      if missing_skill_dirs.any?
        blockers << "skill directories missing SKILL.md: #{missing_skill_dirs.map { |path| File.basename(path) }.join(', ')}"
        actions << 'run skill_lint and either add SKILL.md or remove stale skill directories'
      end

      unless skill_lint_result[:passed]
        failed_files = skill_lint_result[:skills].reject { |entry| entry[:passed] }.map { |entry| File.basename(File.dirname(entry[:file])) }.uniq
        blockers << "skill_lint failed for: #{failed_files.join(', ')}"
        actions << 'run skill_lint --json and fix the listed skill routing issues'
      end

      if sop_review_result
        blockers.concat(sop_review_result[:blockers].map { |item| "SOP review: #{item}" })
        warnings.concat(sop_review_result[:warnings].map { |item| "SOP review: #{item}" })
        actions.concat(sop_review_result[:recommended_actions])
      end

      if skill_lint_result[:duplicate_drift].any?
        names = skill_lint_result[:duplicate_drift].map { |entry| entry[:name] }
        warnings << "duplicate skill names with divergent content: #{names.join(', ')}"
        actions << 'consolidate duplicate skill names or document intentional client-specific drift'
      end

      actions << 'run agent_eval before changing trigger maps, mandatory workflows, or AGENTS.md skill routing'
      actions << 'run process_eval before changing support, release, UI verification, delegation, or session-end policy'
      actions << 'use process_metrics --export-html for human review artifacts; keep Markdown as durable source of truth'

      {
        generated_at: Time.now.utc.iso8601,
        project: File.basename(Dir.pwd),
        metrics_path: metrics_path,
        metrics: metrics_summary,
        research_cache_lines: research_lines,
        research_caches: research_caches,
        tool_discovery_receipts: tool_receipts.length,
        skill_lint: {
          skill_count: skill_lint_result[:skill_count],
          failed_count: skill_lint_result[:failed_count],
          duplicate_drift_count: skill_lint_result[:duplicate_drift].length
        },
        sop_review: sop_review_result,
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    def unresolved_todo_placeholder?(content)
      content.each_line.any? do |line|
        line.match?(/^\s*(?:[-*]\s*)?(?:#\s*)?TODO\s*:\s*(add|fill|fix|implement|replace|set up|tbd|update|wire)\b/i)
      end
    end

    def legacy_nvidia_default_guidance?(content)
      content.match?(/FREE MODELS VIA DIRECT BASH|No subagents|NVIDIA reviews|free NVIDIA models|Fire \d+ .*nv Calls|Fire \d+ parallel nv calls/i)
    end

    def skill_frontmatter_description(frontmatter)
      parsed = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false) || {}
      parsed.fetch('description', '').to_s.strip
    rescue Psych::SyntaxError
      frontmatter[/^description:\s*['"]?(.*?)['"]?\s*$/i, 1].to_s.strip
    end

    def skill_frontmatter_name(frontmatter)
      parsed = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false) || {}
      parsed.fetch('name', '').to_s.strip
    rescue Psych::SyntaxError
      frontmatter[/^name:\s*['"]?(.*?)['"]?\s*$/i, 1].to_s.strip
    end

    def duplicate_skill_drift(results)
      results.group_by { |entry| entry[:name].to_s }
             .select { |name, entries| !name.empty? && entries.length > 1 && entries.map { |entry| entry[:content_sha] }.uniq.length > 1 }
             .reject { |_name, entries| known_cross_client_skill_pair?(entries.map { |entry| entry[:file] }) }
             .map do |name, entries|
               {
                 name: name,
                 files: entries.map { |entry| entry[:file] },
                 variants: entries.map { |entry| entry[:content_sha] }.uniq.length
               }
             end
    end

    def known_cross_client_skill_pair?(files)
      roots = files.map do |file|
        expanded = File.expand_path(file)
        if expanded.start_with?(File.expand_path('~/.codex/skills') + '/')
          :codex
        elsif expanded.start_with?(File.expand_path('~/.agents/skills') + '/')
          :agents
        else
          :other
        end
      end.uniq
      roots.sort == %i[agents codex]
    end

    def research_cache_summaries
      %w[.codex/research.md .claude/research.md].each_with_object([]) do |relative_path, summaries|
        path = File.join(Dir.pwd, relative_path)
        next summaries unless File.exist?(path)

        summaries << {
          path: path,
          lines: File.readlines(path).length
        }
      end
    end

    private

    def parse_agent_workflow_options(args)
      options = { json: false, paths: [] }
      rest = args.dup
      until rest.empty?
        token = rest.shift
        case token
        when '--json'
          options[:json] = true
        when '--fixture'
          options[:fixture] = rest.shift
        when '--path'
          options[:paths] << File.expand_path(rest.shift)
        else
          options[:paths] << File.expand_path(token) if token && !token.start_with?('--')
        end
      end
      options
    end

    def skill_files_under(path)
      return [] unless File.exist?(path)
      return [path] if File.file?(path) && File.basename(path) == 'SKILL.md'
      return [File.join(path, 'SKILL.md')] if File.directory?(path) && File.exist?(File.join(path, 'SKILL.md'))

      Dir.glob(File.join(path, '**', 'SKILL.md'))
    end

    def default_skill_lint_paths
      [
        File.expand_path('~/.codex/skills'),
        File.expand_path('~/.agents/skills'),
        File.join(Dir.pwd, '.codex', 'skills'),
        File.join(Dir.pwd, '.agents', 'skills')
      ].select { |path| File.exist?(path) }
    end

    def print_agent_eval_result(result)
      puts 'Agent Workflow Eval'
      puts '=' * 24
      puts "Fixture: #{result[:fixture]}"
      puts "Passed: #{result[:passed_count]}/#{result[:case_count]}"
      result[:cases].reject { |entry| entry[:passed] }.each do |entry|
        puts "  ❌ #{entry[:id]}: #{entry[:issues].join('; ')}"
      end
      puts result[:passed] ? '✅ agent_eval passed' : '❌ agent_eval failed'
    end

    def print_skill_lint_result(result)
      puts 'Skill Lint'
      puts '=' * 10
      puts "Passed: #{result[:passed_count]}/#{result[:skill_count]}"
      result[:skills].reject { |entry| entry[:passed] }.each do |entry|
        puts "  ❌ #{entry[:file]}: #{entry[:issues].join('; ')}"
      end
      puts result[:passed] ? '✅ skill_lint passed' : '❌ skill_lint found issues'
    end

    def print_agent_env_review(result)
      puts 'Agent Environment Review'
      puts '=' * 24
      puts "Project: #{result[:project]}"
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Tool-discovery receipts: #{result[:tool_discovery_receipts]}"
      puts "Research cache lines: #{result[:research_cache_lines]}"
      if result[:skill_lint]
        puts "Skill lint: #{result[:skill_lint][:skill_count] - result[:skill_lint][:failed_count]}/#{result[:skill_lint][:skill_count]} passed"
      end
      result[:blockers].each { |item| puts "  ❌ #{item}" }
      result[:warnings].each { |item| puts "  ⚠️  #{item}" }
      puts 'Recommended actions:'
      result[:recommended_actions].each { |item| puts "  - #{item}" }
    end
  end
end
