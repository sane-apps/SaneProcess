#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'shellwords'
require 'time'

class ToolDiscoveryReceipt
  DEFAULT_LIMIT = 12
  DEFAULT_TIMEOUT_SECONDS = 180
  STOPWORDS = %w[
    missing
    tool
    tools
    workaround
    workarounds
    already
    have
    using
    use
    uses
    need
    needs
    find
    check
    for
    this
    that
    with
    from
    into
  ].freeze
  DOC_CANDIDATES = %w[
    AGENTS.md
    CLAUDE.md
    README.md
    DEVELOPMENT.md
    ARCHITECTURE.md
  ].freeze
  SESSION_DOC_CANDIDATES = %w[
    SESSION_HANDOFF.md
  ].freeze
  SESSION_QUERY_TERMS = %w[
    session
    handoff
    recent
    latest
    current
    today
  ].freeze
  CANONICAL_TOOL_PATHS = [
    {
      name: 'Tool discovery and canonical path selection',
      keywords: %w[tool tools missing workflow sop standard documented enforce enforced path best hunting workaround],
      command: 'ruby scripts/SaneMaster.rb tool_discovery --query "..."',
      source: 'scripts/SaneMaster.rb tool_discovery',
      why: 'Proof step before claiming a tool is missing or inventing a workaround.'
    },
    {
      name: 'Build and test an app',
      keywords: %w[build test verify compile xcode unit ui failing],
      command: 'ruby scripts/SaneMaster.rb verify [--ui]',
      source: 'scripts/SaneMaster.rb verify',
      why: 'Canonical build and test path. Routes to the Mini when required.'
    },
    {
      name: 'Live project status',
      keywords: %w[status health summary crossref cross-reference issue inbox release git],
      command: 'ruby scripts/SaneMaster.rb status',
      source: 'scripts/SaneMaster.rb status',
      why: 'Canonical live status path across git, inbox, issues, release lanes, and current signals.'
    },
    {
      name: 'Run and verify a live app',
      keywords: %w[launch run smoke runtime end-to-end e2e screenshot visual qa],
      command: 'ruby scripts/SaneMaster.rb test_mode --release --no-logs',
      source: 'scripts/SaneMaster.rb test_mode',
      why: 'Canonical kill → build → launch path for real runtime checks.'
    },
    {
      name: 'Mini screenshot capture',
      keywords: %w[screenshot screenshots capture visual mini screen window app prompt screencapture],
      command: '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh --app "AppName" --mode temp',
      source: 'scripts/mini/capture-mini-screenshot.sh',
      why: 'Canonical Mini GUI-session capture path. Do not use raw ssh mini screencapture.'
    },
    {
      name: 'App Store submission and review readiness',
      keywords: %w[appstore review submission submit asc metadata iap rejected approve approved],
      command: 'ruby scripts/SaneMaster.rb appstore_preflight',
      source: 'scripts/SaneMaster.rb appstore_preflight',
      why: 'Canonical App Store compliance and submission check before resubmitting.'
    },
    {
      name: 'Release readiness and shipping',
      keywords: %w[release ship publish notarize appcast deploy dist sparkle],
      command: 'ruby scripts/SaneMaster.rb release_preflight',
      source: 'scripts/SaneMaster.rb release_preflight',
      why: 'Canonical preflight before any direct-release publish path.'
    },
    {
      name: 'Cloudflare release surface checks',
      keywords: %w[cloudflare pages r2 worker workers appcast drift deploy deployment release dist dns cdn],
      command: 'ruby scripts/SaneMaster.rb release_preflight; use the Cloudflare MCP/plugin only as an optional read-only cross-check when installed',
      source: 'scripts/SaneMaster.rb release_preflight, release.sh, Cloudflare MCP/plugin',
      why: 'Release preflight stays the portable source of truth; Cloudflare MCP is a high-value optional probe for Pages/R2/Worker drift.'
    },
    {
      name: 'Customer support triage and replies',
      keywords: %w[email inbox support license github issue customer reply resolve],
      command: 'ruby scripts/SaneMaster.rb check_inbox [check|review <id>|read <id>|reply ...]',
      source: 'scripts/SaneMaster.rb check_inbox',
      why: 'Canonical review gate for customer email and linked GitHub issue work.'
    },
    {
      name: 'Mini control-plane sync',
      keywords: %w[mini sync codex profile control-plane automation restart],
      command: 'ruby scripts/SaneMaster.rb sync_mini [mini] [--quiet] [--no-restart]',
      source: 'scripts/SaneMaster.rb sync_mini',
      why: 'Canonical Mini control-plane parity path instead of hunting automation scripts.'
    },
    {
      name: 'Revenue, downloads, and funnel analytics',
      keywords: %w[sales revenue downloads events funnel conversion orders refunds],
      command: 'ruby scripts/SaneMaster.rb sales && ruby scripts/SaneMaster.rb downloads && ruby scripts/SaneMaster.rb events',
      source: 'scripts/SaneMaster.rb sales/downloads/events',
      why: 'Canonical sales and analytics path instead of ad hoc vendor curls.'
    },
    {
      name: 'Listing and setup action tracker',
      keywords: %w[listing listings directory directories portal setup tracker workbook spreadsheet],
      command: 'ruby scripts/SaneMaster.rb listing_actions',
      source: 'scripts/SaneMaster.rb listing_actions',
      why: 'Canonical listing/setup action tracker generated from inbox history.'
    },
    {
      name: 'Hosted-file dashboard tracker',
      keywords: %w[hosted file hosted-file lemonsqueezy dashboard drift upload workbook],
      command: 'ruby scripts/SaneMaster.rb hosted_file_actions',
      source: 'scripts/SaneMaster.rb hosted_file_actions',
      why: 'Canonical hosted-file dashboard tracker for Lemon Squeezy drift.'
    },
    {
      name: 'MCP and tooling health',
      keywords: %w[mcp toolserver transport doctor health duplicate orphan crashed crash],
      command: 'ruby scripts/SaneMaster.rb mcp_watchdog doctor && ~/.codex/bin/check-mcps',
      source: 'scripts/SaneMaster.rb mcp_watchdog',
      why: 'Watchdog is the background-machine truth; check-mcps is the live active-session tool-call probe.'
    },
    {
      name: 'Semantic cross-session recall',
      keywords: %w[central-memory central memory semantic recall remember vector pgvector postgresql learnings research],
      command: '~/.codex/bin/check-mcps; use central-memory recall/remember when the MCP is installed',
      source: 'scripts/mcp-central-memory/server.mjs',
      why: 'Central memory is optional for public SaneProcess users, but when present it should be the first semantic recall layer above graph/Serena memory.'
    },
    {
      name: 'iOS simulator proof with XcodeBuildMCP',
      keywords: %w[xcodebuildmcp xcode mcp simulator ios iphone ipad screenshot video tap swipe gesture accessibility hierarchy lldb breakpoint coverage device build_run_sim session_show_defaults],
      command: 'Use XcodeBuildMCP session_show_defaults before simulator build/run/test when the tool is available; fall back to SaneMaster verify/test_mode',
      source: '~/.codex/bin/xcode-mcpbridge-wrapper.sh, XcodeBuildMCP',
      why: 'XcodeBuildMCP adds simulator UI automation, LLDB/device workflows, coverage, and session defaults without replacing Mini-first SaneMaster verification or Apple xcrun mcpbridge.'
    }
  ].freeze

  def initialize(argv)
    @options = {
      project_root: File.expand_path('../..', __dir__),
      out_dir: nil,
      query: nil,
      limit: DEFAULT_LIMIT,
      timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
      run_doctor: true,
      run_validation: true,
      json_stdout: false
    }
    parse!(argv)
    @options[:out_dir] ||= File.join(@options[:project_root], 'outputs', 'tool-discovery')
  end

  def run
    raise OptionParser::MissingArgument, '--query is required' if query.empty?

    FileUtils.mkdir_p(@options[:out_dir])

    receipt = {
      generated_at: Time.now.iso8601,
      query: query,
      query_terms: query_terms,
      project_root: @options[:project_root],
      checks: {
        canonical_paths: canonical_path_matches,
        skills_registry: search_skills_registry,
        global_skills: search_global_skills,
        local_code: search_local_code,
        project_docs: search_project_docs,
        doctor: run_doctor_check,
        validation_report: run_validation_check
      }
    }
    receipt[:summary] = build_summary(receipt)

    json_path, markdown_path = write_receipt(receipt)

    if @options[:json_stdout]
      puts JSON.pretty_generate(receipt.merge(paths: { json: json_path, markdown: markdown_path }))
    else
      print_human_summary(receipt, json_path, markdown_path)
    end
  end

  private

  def parse!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: tool_discovery_receipt.rb --query "missing tool question" [options]'
      opts.on('--query TEXT', 'Question or workflow to investigate') { |v| @options[:query] = v.to_s.strip }
      opts.on('--project-root PATH', 'Project root to inspect') { |v| @options[:project_root] = File.expand_path(v) }
      opts.on('--out-dir PATH', 'Directory for receipt artifacts') { |v| @options[:out_dir] = File.expand_path(v) }
      opts.on('--limit N', Integer, 'Max matches per section') { |v| @options[:limit] = [v, 1].max }
      opts.on('--timeout-seconds N', Integer, 'Timeout for doctor/validation commands') { |v| @options[:timeout_seconds] = [v, 30].max }
      opts.on('--skip-doctor', 'Skip SaneMaster doctor') { @options[:run_doctor] = false }
      opts.on('--skip-validation', 'Skip validation_report') { @options[:run_validation] = false }
      opts.on('--json', 'Print the receipt JSON to stdout') { @options[:json_stdout] = true }
    end
    parser.parse!(argv)
  end

  def query
    @options[:query].to_s.strip
  end

  def query_terms
    raw_terms = query.downcase.scan(/[a-z0-9][a-z0-9_-]+/)
    preferred = raw_terms.select { |term| term.length >= 4 && !STOPWORDS.include?(term) }
    preferred = raw_terms.select { |term| term.length >= 4 } if preferred.empty?
    terms = preferred.empty? ? raw_terms : preferred
    ([query] + terms).uniq.first(8)
  end

  def project_docs
    docs = DOC_CANDIDATES.dup
    if (query_terms & SESSION_QUERY_TERMS).any?
      docs.concat(SESSION_DOC_CANDIDATES)
    end

    docs
      .map { |name| File.join(@options[:project_root], name) }
      .select { |path| File.exist?(path) }
  end

  def canonical_path_matches
    downcased_query = query.downcase
    matches = CANONICAL_TOOL_PATHS.each_with_object([]) do |entry, acc|
      score = entry[:keywords].count do |keyword|
        downcased_query.include?(keyword) || query_terms.include?(keyword)
      end
      next if score.zero?

      acc << entry.merge(score: score)
    end

    matches = [CANONICAL_TOOL_PATHS.first.merge(score: 1)] if matches.empty?
    matches.sort_by { |entry| [-entry[:score], entry[:name]] }.first(5)
  end

  def search_skills_registry
    registries = [
      File.expand_path('~/.codex/SKILLS_REGISTRY.md'),
      File.expand_path('~/.claude/SKILLS_REGISTRY.md')
    ].uniq.select { |path| File.exist?(path) }

    {
      source: registries,
      matches: registries.empty? ? [] : rg_matches(registries),
      exists: !registries.empty?
    }
  end

  def search_global_skills
    skill_roots = [
      File.expand_path('~/.codex/skills'),
      File.expand_path('~/.claude/skills')
    ].uniq.select { |path| Dir.exist?(path) }

    files = skill_roots.flat_map do |skill_root|
      Dir.glob(File.join(skill_root, '**', 'SKILL.md'))
    end.sort

    {
      source: skill_roots,
      matches: rg_matches(files),
      file_count: files.length
    }
  end

  def search_local_code
    code_roots = %w[scripts templates].map { |name| File.join(@options[:project_root], name) }
    files = code_roots.flat_map do |root|
      next [] unless Dir.exist?(root)

      Dir.glob(File.join(root, '**', '*'))
    end.select { |path| File.file?(path) }

    {
      source: code_roots,
      matches: rg_matches(files),
      file_count: files.length
    }
  end

  def search_project_docs
    {
      source: project_docs,
      matches: rg_matches(project_docs),
      file_count: project_docs.length
    }
  end

  def rg_matches(files)
    return [] if files.empty?

    terms = query_terms
    matches = []
    seen = {}

    terms.each do |term|
      rg_command = [rg_binary, '-n', '--with-filename', '--fixed-strings', '--ignore-case', term, *files]
      stdout, stderr, status = Open3.capture3(*rg_command)
      next if !status.success? && stdout.to_s.strip.empty? && stderr.to_s !~ /No such file|Permission denied/

      stdout.each_line do |line|
        next if seen[line]

        seen[line] = true
        file, line_no, content = line.split(':', 3)
        next unless file && line_no && content

        matches << {
          term: term,
          file: file,
          line: line_no.to_i,
          content: content.strip
        }
        return matches if matches.length >= @options[:limit]
      end
    end

    matches
  rescue StandardError => e
    [{
      term: 'error',
      file: 'search',
      line: 0,
      content: "search failed: #{e.message}"
    }]
  end

  def run_doctor_check
    return { skipped: true, status: 'skipped' } unless @options[:run_doctor]

    script = File.join(@options[:project_root], 'scripts', 'SaneMaster.rb')
    watchdog_command = [RbConfig.ruby, script, 'mcp_watchdog', 'doctor', '--quiet', '--json']
    live_probe = File.expand_path('~/.codex/bin/check-mcps')
    probe_command = [live_probe]

    watchdog = capture_command(watchdog_command, chdir: @options[:project_root], timeout_seconds: @options[:timeout_seconds])
    probe = if File.executable?(live_probe)
              capture_command(probe_command, chdir: @options[:project_root], timeout_seconds: @options[:timeout_seconds])
            else
              {
                command: probe_command,
                stdout: '',
                stderr: "#{live_probe} is not executable",
                exit_code: 127,
                timed_out: false,
                success: false
              }
            end

    watchdog_payload = parse_json(watchdog[:stdout])
    watchdog_issues = watchdog_health_issues(watchdog, watchdog_payload)
    probe_lines = combined_output_lines(probe)
    probe_failures = probe_lines.select { |line| line.start_with?('[FAIL]') }
    probe_warnings = probe_lines.select { |line| line.start_with?('[WARN]') }
    status = if watchdog[:timed_out] || probe[:timed_out]
               'timed_out'
             elsif watchdog_issues.any? || !probe[:success] || probe_failures.any?
               'failed'
             elsif probe_warnings.any?
               'warning'
             else
               'ok'
             end

    {
      command: "#{watchdog_command.join(' ')} && #{probe_command.join(' ')}",
      status: status,
      watchdog: {
        command: watchdog_command.join(' '),
        exit_code: watchdog[:exit_code],
        timed_out: watchdog[:timed_out],
        issues: watchdog_issues,
        configured_servers: watchdog_payload&.dig('doctor', 'configured_servers'),
        running_servers: watchdog_payload&.dig('doctor', 'running_servers')
      },
      live_probe: {
        command: probe_command.join(' '),
        exit_code: probe[:exit_code],
        timed_out: probe[:timed_out],
        pass_count: probe_lines.count { |line| line.start_with?('[PASS]') },
        warnings: probe_warnings,
        failures: probe_failures,
        summary_lines: probe_lines.first(20)
      },
      exit_code: watchdog[:exit_code].to_i.zero? ? probe[:exit_code] : watchdog[:exit_code],
      timed_out: watchdog[:timed_out] || probe[:timed_out],
      warning_lines: probe_warnings + watchdog_issues,
      summary_lines: (probe_lines + watchdog_issues).first(20)
    }
  end

  def watchdog_health_issues(result, payload)
    issues = []
    issues << 'mcp_watchdog doctor command failed' unless result[:success]
    issues << 'mcp_watchdog doctor JSON parse failed' if payload.nil?
    doctor = payload && payload['doctor']
    return issues unless doctor

    issues << "missing runtime MCPs: #{doctor['missing_runtime'].join(', ')}" if doctor['missing_runtime'].to_a.any?
    issues << "duplicate MCP servers: #{doctor['duplicate_servers'].join(', ')}" if doctor['duplicate_servers'].to_a.any?
    issues << "duplicate Codex MCP groups: #{doctor['duplicate_codex_servers'].join(', ')}" if doctor['duplicate_codex_servers'].to_a.any?
    issues << "orphan MCP process count: #{doctor['orphan_count']}" if doctor['orphan_count'].to_i.positive?
    issues << "stale Codex sidecars: #{doctor['stale_sidecars'].length}" if doctor['stale_sidecars'].to_a.any?
    issues << "recent watchdog errors: #{doctor['recent_errors'].length}" if doctor['recent_errors'].to_a.any?
    transport_errors = doctor.dig('session_transport', 'total').to_i
    issues << "recent MCP transport errors: #{transport_errors}" if transport_errors.positive?
    issues
  end

  def run_validation_check
    return { skipped: true, status: 'skipped' } unless @options[:run_validation]

    script = File.join(@options[:project_root], 'scripts', 'validation_report.rb')
    command = [RbConfig.ruby, script, '--json']
    env = {
      'SANE_NO_KEYCHAIN' => '1',
      'SANE_KEYCHAIN_FALLBACK' => '0',
      'SANE_ALLOW_KEYCHAIN_PROMPTS' => '0'
    }
    result = capture_command(command, chdir: @options[:project_root], timeout_seconds: @options[:timeout_seconds], env: env)

    payload = parse_json(result[:stdout])
    {
      command: command.join(' '),
      status: validation_health_status(result, payload),
      status_detail: validation_status_detail(result, payload),
      exit_code: result[:exit_code],
      timed_out: result[:timed_out],
      verdict: payload && payload['verdict'],
      verdict_status: payload && payload.dig('verdict', 'status'),
      verdict_detail: payload && payload.dig('verdict', 'detail'),
      issue_count: payload && payload['issues']&.length,
      warning_count: payload && payload['warnings']&.length,
      parse_error: payload.nil? ? 'validation report did not return JSON' : nil
    }
  end

  def validation_health_status(result, payload)
    return 'timed_out' if result[:timed_out]
    return 'failed' unless result[:success]
    return 'parse_failed' unless payload
    return 'partial' if validation_signing_skipped?(payload)

    payload.dig('verdict', 'status').to_s == 'WORKING' ? 'ok' : 'blocked'
  end

  def validation_status_detail(result, payload)
    return nil unless result[:success] && payload
    return 'signing/notary checks skipped in no-prompt mode' if validation_signing_skipped?(payload)

    payload.dig('verdict', 'detail')
  end

  def validation_signing_skipped?(payload)
    Array(payload && payload['warnings']).any? do |warning|
      warning.to_s.include?('Code-signing keychain/notary checks skipped in no-prompt validation mode')
    end
  end

  def build_summary(receipt)
    canonical_matches = receipt.dig(:checks, :canonical_paths).to_a.length
    skill_matches = receipt.dig(:checks, :skills_registry, :matches).to_a.length +
                    receipt.dig(:checks, :global_skills, :matches).to_a.length
    local_matches = receipt.dig(:checks, :local_code, :matches).to_a.length +
                    receipt.dig(:checks, :project_docs, :matches).to_a.length
    doctor = receipt.dig(:checks, :doctor) || {}
    validation = receipt.dig(:checks, :validation_report) || {}

    existing_path_found = canonical_matches.positive? || skill_matches.positive? || local_matches.positive?
    recommendation = if existing_path_found
                       'Existing path found. Reuse or extend what is already here before adding a new tool.'
                     else
                       'No obvious existing path found. New tooling may be justified if the workflow is recurring.'
                     end

    {
      existing_path_found: existing_path_found,
      recommendation: recommendation,
      doctor_status: doctor[:status] || 'skipped',
      validation_status: validation[:status] || 'skipped',
      doctor_ok: skipped_check?(doctor) ? nil : doctor[:status] == 'ok',
      validation_ok: skipped_check?(validation) ? nil : validation[:status] == 'ok',
      validation_blocks_tool_use: validation[:status].to_s == 'failed' || validation[:status].to_s == 'timed_out' || validation[:status].to_s == 'parse_failed',
      canonical_commands: receipt.dig(:checks, :canonical_paths).to_a.map { |entry| entry[:command] },
      top_existing_paths: top_paths(receipt)
    }
  end

  def skipped_check?(check)
    check[:skipped] || check[:status].to_s == 'skipped'
  end

  def top_paths(receipt)
    canonical = receipt.dig(:checks, :canonical_paths).to_a.map { |entry| entry[:source] }
    groups = %i[skills_registry global_skills local_code project_docs]
    (canonical + groups.flat_map do |group|
      receipt.dig(:checks, group, :matches).to_a.map { |match| match[:file] }
    end).uniq.first(10)
  end

  def write_receipt(receipt)
    slug = query.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')[0, 50]
    timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
    json_path = File.join(@options[:out_dir], "#{timestamp}-#{slug}.json")
    markdown_path = File.join(@options[:out_dir], "#{timestamp}-#{slug}.md")

    File.write(json_path, JSON.pretty_generate(receipt))
    File.write(markdown_path, build_markdown(receipt, json_path))
    [json_path, markdown_path]
  end

  def build_markdown(receipt, json_path)
    lines = []
    lines << "# Tool Discovery Receipt"
    lines << ''
    lines << "- Generated: #{receipt[:generated_at]}"
    lines << "- Query: #{receipt[:query]}"
    lines << "- Project root: `#{receipt[:project_root]}`"
    lines << "- JSON receipt: `#{json_path}`"
    lines << ''
    lines << "## Recommendation"
    lines << receipt.dig(:summary, :recommendation).to_s
    lines << ''

    lines << '## Canonical Tool Paths'
    canonical_paths = receipt.dig(:checks, :canonical_paths).to_a
    if canonical_paths.empty?
      lines << 'No canonical tool match found.'
    else
      canonical_paths.each do |entry|
        lines << "- **#{entry[:name]}**"
        lines << "  - Command: `#{entry[:command]}`"
        lines << "  - Why: #{entry[:why]}"
        lines << "  - Source: `#{entry[:source]}`"
      end
    end
    lines << ''

    {
      'Skills Registry' => receipt.dig(:checks, :skills_registry, :matches),
      'Global Skills' => receipt.dig(:checks, :global_skills, :matches),
      'Local Code' => receipt.dig(:checks, :local_code, :matches),
      'Project Docs' => receipt.dig(:checks, :project_docs, :matches)
    }.each do |label, matches|
      lines << "## #{label}"
      if matches.to_a.empty?
        lines << 'No matches.'
      else
        matches.each do |match|
          lines << "- `#{match[:file]}:#{match[:line]}` #{match[:content]}"
        end
      end
      lines << ''
    end

    doctor = receipt[:checks][:doctor] || {}
    validation = receipt[:checks][:validation_report] || {}
    lines << "## Health Checks"
    lines << "- MCP health: #{doctor[:status] || 'skipped'}"
    validation_line = validation[:status] || 'skipped'
    validation_line = "#{validation_line} (#{validation[:status_detail]})" if validation[:status_detail]
    lines << "- Project validation report: #{validation_line}"
    verdict_line = validation[:verdict_status] || 'n/a'
    verdict_line = "#{verdict_line} — #{validation[:verdict_detail]}" if validation[:verdict_detail]
    lines << "- Validation verdict: #{verdict_line}"
    lines << ''
    lines.join("\n")
  end

  def print_human_summary(receipt, json_path, markdown_path)
    puts '🔎 Tool discovery receipt complete.'
    puts "Query: #{receipt[:query]}"
    puts "Existing path found: #{receipt.dig(:summary, :existing_path_found) ? 'yes' : 'no'}"
    puts "Recommendation: #{receipt.dig(:summary, :recommendation)}"
    puts "MCP health: #{receipt.dig(:checks, :doctor, :status) || 'skipped'}"
    validation = receipt.dig(:checks, :validation_report) || {}
    validation_line = validation[:status] || 'skipped'
    validation_line = "#{validation_line} (#{validation[:status_detail]})" if validation[:status_detail]
    puts "Project validation: #{validation_line}"
    puts "JSON: #{json_path}"
    puts "Markdown: #{markdown_path}"
    receipt.dig(:checks, :canonical_paths).to_a.first(5).each do |entry|
      puts "  * #{entry[:command]} — #{entry[:why]}"
    end
    top_paths(receipt).first(5).each { |path| puts "  - #{path}" }
  end

  def combined_output_lines(result)
    [result[:stdout], result[:stderr]].compact.flat_map { |text| text.to_s.lines.map(&:strip) }.reject(&:empty?)
  end

  def parse_json(text)
    JSON.parse(text)
  rescue JSON::ParserError, TypeError
    nil
  end

  def capture_command(command, chdir:, timeout_seconds:, env: {})
    stdout = +''
    stderr = +''
    exit_code = nil
    timed_out = false

    Open3.popen3(env, *command, chdir: chdir) do |stdin, out, err, wait_thr|
      stdin.close
      stdout_thread = Thread.new { stdout << out.read.to_s }
      stderr_thread = Thread.new { stderr << err.read.to_s }

      unless wait_thr.join(timeout_seconds)
        timed_out = true
        Process.kill('TERM', wait_thr.pid) rescue nil
        wait_thr.join(5) || Process.kill('KILL', wait_thr.pid) rescue nil
        wait_thr.join(5)
      end

      stdout_thread.join
      stderr_thread.join
      exit_code = wait_thr.value.exitstatus
    end

    {
      command: command,
      stdout: stdout,
      stderr: stderr,
      exit_code: exit_code,
      timed_out: timed_out,
      success: !timed_out && exit_code.to_i.zero?
    }
  end

  def rg_binary
    @rg_binary ||= begin
      paths = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
      binary = paths.map { |dir| File.join(dir, 'rg') }.find { |candidate| File.executable?(candidate) }
      binary || 'rg'
    end
  end
end

ToolDiscoveryReceipt.new(ARGV).run if $PROGRAM_NAME == __FILE__
