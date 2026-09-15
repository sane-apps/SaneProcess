# frozen_string_literal: true

require 'json'
require 'optparse'
require 'time'
require 'fileutils'
require 'open3'

module SaneMasterModules
  module OperatorBrief
    # Release surfaces that commonly stall mid-flight (dirty / unpushed / handoff open).
    FINISH_LINE_PATHS = [
      'apps/SaneClip',
      'apps/SaneClick',
      'apps/SaneHosts',
      'apps/SaneBar',
      'apps/SaneLot',
      'apps/SaneScan',
      'websites/sanelot.com',
      'sanelot',
      'clients/autodealertool/extension',
      'meta'
    ].freeze

    def operator_brief(args)
      options = operator_brief_options(args)
      report = operator_brief_report(options)
      if options[:json]
        puts JSON.pretty_generate(report)
      else
        output = operator_brief_markdown(report)
        FileUtils.mkdir_p(File.dirname(options[:output]))
        File.write(options[:output], output)
        puts output
      end
      report[:status] == 'clear'
    end

    private

    def operator_brief_options(args)
      options = {
        nightly_report: File.expand_path('~/SaneApps/outputs/nightly_report.md'),
        morning_report: File.expand_path('~/SaneApps/outputs/morning_report.md'),
        handoff: File.join(saneprocess_repo_root, 'SESSION_HANDOFF.md'),
        portfolio_root: File.expand_path('~/SaneApps'),
        output: File.expand_path('~/SaneApps/outputs/operator_brief.md'),
        json: false,
        strict: false,
        skip_finish_line: false
      }

      OptionParser.new do |parser|
        parser.on('--nightly-report PATH') { |value| options[:nightly_report] = File.expand_path(value) }
        parser.on('--morning-report PATH') { |value| options[:morning_report] = File.expand_path(value) }
        parser.on('--handoff PATH') { |value| options[:handoff] = File.expand_path(value) }
        parser.on('--portfolio-root PATH') { |value| options[:portfolio_root] = File.expand_path(value) }
        parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
        parser.on('--json') { options[:json] = true }
        parser.on('--strict') { options[:strict] = true }
        parser.on('--skip-finish-line') { options[:skip_finish_line] = true }
      end.parse!(args)

      options
    end

    def operator_brief_report(options)
      nightly = read_text(options[:nightly_report])
      morning = read_text(options[:morning_report])
      handoff = read_text(options[:handoff])
      priorities = []
      notices = []

      priorities.concat(nightly_priorities(nightly))
      priorities.concat(handoff_priorities(handoff))
      priorities.concat(finish_line_priorities(options[:portfolio_root])) unless options[:skip_finish_line]
      notices.concat(morning_notices(morning, options[:morning_report]))
      notices.concat(agentmemory_watch_notices(options[:portfolio_root]))

      {
        generated_at: Time.now.utc.iso8601,
        status: priorities.empty? ? 'clear' : 'needs_attention',
        priorities: priorities.first(12),
        notices: notices.first(8),
        sources: options.slice(:nightly_report, :morning_report, :handoff, :portfolio_root)
      }
    end

    def finish_line_priorities(portfolio_root)
      return [] if portfolio_root.to_s.strip.empty? || !Dir.exist?(portfolio_root)

      # map+compact (not filter_map): Ruby 2.6-compatible like dirty_repos.
      FINISH_LINE_PATHS.map do |relative|
        path = File.join(portfolio_root, relative)
        next unless File.directory?(path)

        unless Dir.exist?(File.join(path, '.git'))
          next "Finish-line: #{relative} is not a git repo (never initialized)." if relative.include?('island-style')

          next
        end

        bits = []
        dirty = git_text(path, %w[status --porcelain]).lines.reject(&:empty?)
        bits << "#{dirty.length} dirty" unless dirty.empty?

        ahead = git_ahead_count(path)
        bits << "#{ahead} unpushed" if ahead.positive?

        handoff = read_text(File.join(path, 'SESSION_HANDOFF.md'))
        if handoff.match?(/open items?|pending release|not deployed|needs? (?:a )?(?:proof|rerun)|version skew|unpushed/i)
          bits << 'handoff still open'
        end

        next if bits.empty?

        "Finish-line: #{relative} (#{bits.join(', ')})."
      end.compact
    end

    def agentmemory_watch_notices(portfolio_root)
      watch = File.join(portfolio_root, 'infra/SaneProcess/outputs/agentmemory-watch/latest.json')
      return [] unless File.file?(watch)

      raw = JSON.parse(File.read(watch))
      return [] if raw['passed'] == true

      failed = Array(raw['checks']).reject { |c| c['passed'] }.map { |c| c['id'] }
      ["AgentMemory watch red: #{failed.empty? ? 'see latest.json' : failed.join(', ')}."]
    rescue StandardError
      []
    end

    def git_text(path, args)
      out, _err, status = Open3.capture3('git', '-C', path, *args)
      status.success? ? out : ''
    rescue StandardError
      ''
    end

    def git_ahead_count(path)
      # @{u} fails when no upstream; treat as 0 rather than inventing a push target.
      out = git_text(path, %w[rev-list --count @{u}..HEAD])
      out.strip.to_i
    end

    def nightly_priorities(text)
      return ['Nightly report missing; verify com.saneapps.nightly ran.'] if text.empty?

      items = []
      build = section(text, 'Build Results')
      tests = section(text, 'Test Results')
      failed_builds = failed_apps(build)
      failed_tests = failed_apps(tests)

      items << "Fix failed nightly builds: #{failed_builds.join(', ')}." unless failed_builds.empty?
      items << "Fix failed nightly tests: #{failed_tests.join(', ')}." unless failed_tests.empty?

      if (gate = text.lines.find { |line| line.include?('**Workflow gate:** FAIL') })
        items << "Investigate SaneAI workflow gate: #{gate.gsub(/\*+/, '').strip}."
      end

      if text.match?(/^## Machine Cleanup/m) && section(text, 'Machine Cleanup').include?('**FAIL**')
        items << 'Clean up Mini machine cleanup failure before the next release/test run.'
      end

      dirty = dirty_repos(text)
      items << "Review dirty repos blocking sync: #{dirty.join(', ')}." unless dirty.empty?
      items
    end

    def handoff_priorities(text)
      return [] if text.empty?

      items = handoff_bullets(text).each_with_object([]) do |bullet, memo|
        first = bullet[:first].gsub(/\s+/, ' ').strip
        next unless first.match?(/hard release blocker|no-go|blocked by/i)

        memo << bullet[:text].gsub(/\s+/, ' ').strip
      end
      support_mentions = text.scan(/(?:new email|bounced outbound)[ \t]+#\d+/i).uniq
      items << "Support follow-up surfaced: #{support_mentions.join(', ')}." unless support_mentions.empty?
      items
    end

    def handoff_bullets(text)
      bullets = []
      current = nil
      first = nil
      text.lines.each do |line|
        if line.start_with?('- ')
          bullets << { first: first, text: current } if current
          current = line.sub(/\A-\s*/, '').strip
          first = current
        elsif current && line.start_with?('  ')
          current = "#{current} #{line.strip}"
        elsif current
          bullets << { first: first, text: current }
          current = nil
          first = nil
        end
      end
      bullets << { first: first, text: current } if current
      bullets
    end

    def morning_notices(text, path)
      return ["Morning report missing at #{path}; business/opportunity brief is stale."] if text.empty?

      first_date = text[/\d{4}-\d{2}-\d{2}/]
      if first_date && first_date != Time.now.strftime('%Y-%m-%d')
        ["Morning report appears stale (#{first_date}); refresh business signals."]
      else
        []
      end
    end

    def failed_apps(section_text)
      current = nil
      section_text.lines.each_with_object([]) do |line, apps|
        current = Regexp.last_match(1).strip if line =~ /^###\s+(.+)/
        apps << current if current && line.include?('**FAIL**')
      end.uniq
    end

    def dirty_repos(text)
      # map+compact, not filter_map: must stay Ruby 2.6-compatible (system ruby).
      text.lines.map do |line|
        next unless line.start_with?('| ')
        cells = line.split('|').map(&:strip)
        next unless cells.length >= 6
        next unless cells[2].include?('Dirty') || cells[2].include?('failed') || cells[3].to_i.positive?

        cells[1]
      end.compact.uniq
    end

    def section(text, heading)
      start = text.index(/^## #{Regexp.escape(heading)}$/)
      return '' unless start

      rest = text[start..]
      finish = rest.index(/^## /, 1)
      finish ? rest[0...finish] : rest
    end

    def operator_brief_markdown(report)
      lines = [
        '# SaneApps Operator Brief',
        '',
        "Generated at #{report[:generated_at]}",
        '',
        "Status: #{report[:status] == 'clear' ? 'CLEAR' : 'NEEDS ATTENTION'}",
        '',
        '## Top Priorities',
        ''
      ]
      priorities = report[:priorities]
      lines.concat(priorities.empty? ? ['- No blockers found in current receipts.'] : priorities.map { |item| "- #{item}" })
      unless report[:notices].empty?
        lines += ['', '## Notices', '']
        lines.concat(report[:notices].map { |item| "- #{item}" })
      end
      lines += ['', '## Sources', '']
      report[:sources].each { |key, value| lines << "- #{key}: #{value}" }
      lines << ''
      lines.join("\n")
    end

    def read_text(path)
      return '' unless path && File.file?(path)

      File.read(path, encoding: Encoding::UTF_8)
    rescue StandardError
      ''
    end
  end
end
