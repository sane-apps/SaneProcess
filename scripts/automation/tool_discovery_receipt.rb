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
    SESSION_HANDOFF.md
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
    DOC_CANDIDATES
      .map { |name| File.join(@options[:project_root], name) }
      .select { |path| File.exist?(path) }
  end

  def search_skills_registry
    registry = File.expand_path('~/.claude/SKILLS_REGISTRY.md')
    {
      source: registry,
      matches: File.exist?(registry) ? rg_matches([registry]) : [],
      exists: File.exist?(registry)
    }
  end

  def search_global_skills
    skill_root = File.expand_path('~/.codex/skills')
    files = Dir.glob(File.join(skill_root, '**', 'SKILL.md')).sort
    {
      source: skill_root,
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
    return { skipped: true } unless @options[:run_doctor]

    script = File.join(@options[:project_root], 'scripts', 'SaneMaster.rb')
    command = [RbConfig.ruby, script, 'doctor']
    result = capture_command(command, chdir: @options[:project_root], timeout_seconds: @options[:timeout_seconds])
    lines = combined_output_lines(result).first(20)

    {
      command: command.join(' '),
      status: result[:timed_out] ? 'timed_out' : (result[:success] ? 'ok' : 'failed'),
      exit_code: result[:exit_code],
      timed_out: result[:timed_out],
      warning_lines: lines.select { |line| line.match?(/[⚠️❌]/) },
      summary_lines: lines
    }
  end

  def run_validation_check
    return { skipped: true } unless @options[:run_validation]

    script = File.join(@options[:project_root], 'scripts', 'validation_report.rb')
    command = [RbConfig.ruby, script, '--json']
    result = capture_command(command, chdir: @options[:project_root], timeout_seconds: @options[:timeout_seconds])

    payload = parse_json(result[:stdout])
    {
      command: command.join(' '),
      status: result[:timed_out] ? 'timed_out' : (result[:success] ? 'ok' : 'failed'),
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

  def build_summary(receipt)
    skill_matches = receipt.dig(:checks, :skills_registry, :matches).to_a.length +
                    receipt.dig(:checks, :global_skills, :matches).to_a.length
    local_matches = receipt.dig(:checks, :local_code, :matches).to_a.length +
                    receipt.dig(:checks, :project_docs, :matches).to_a.length
    doctor = receipt.dig(:checks, :doctor) || {}
    validation = receipt.dig(:checks, :validation_report) || {}

    existing_path_found = skill_matches.positive? || local_matches.positive?
    recommendation = if existing_path_found
                       'Existing path found. Reuse or extend what is already here before adding a new tool.'
                     else
                       'No obvious existing path found. New tooling may be justified if the workflow is recurring.'
                     end

    {
      existing_path_found: existing_path_found,
      recommendation: recommendation,
      doctor_ok: doctor[:status] == 'ok',
      validation_ok: validation[:status] == 'ok',
      top_existing_paths: top_paths(receipt)
    }
  end

  def top_paths(receipt)
    groups = %i[skills_registry global_skills local_code project_docs]
    groups.flat_map do |group|
      receipt.dig(:checks, group, :matches).to_a.map { |match| match[:file] }
    end.uniq.first(10)
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
    lines << "- Doctor: #{doctor[:status] || 'skipped'}"
    lines << "- Validation report: #{validation[:status] || 'skipped'}"
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
    puts "Doctor: #{receipt.dig(:checks, :doctor, :status) || 'skipped'}"
    puts "Validation: #{receipt.dig(:checks, :validation_report, :status) || 'skipped'}"
    puts "JSON: #{json_path}"
    puts "Markdown: #{markdown_path}"
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

  def capture_command(command, chdir:, timeout_seconds:)
    stdout = +''
    stderr = +''
    exit_code = nil
    timed_out = false

    Open3.popen3(*command, chdir: chdir) do |stdin, out, err, wait_thr|
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
