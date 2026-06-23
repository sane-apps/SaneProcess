# frozen_string_literal: true

require 'json'
require 'optparse'
require 'time'
require 'fileutils'

module SaneMasterModules
  module OperatorBrief
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
        output: File.expand_path('~/SaneApps/outputs/operator_brief.md'),
        json: false,
        strict: false
      }

      OptionParser.new do |parser|
        parser.on('--nightly-report PATH') { |value| options[:nightly_report] = File.expand_path(value) }
        parser.on('--morning-report PATH') { |value| options[:morning_report] = File.expand_path(value) }
        parser.on('--handoff PATH') { |value| options[:handoff] = File.expand_path(value) }
        parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
        parser.on('--json') { options[:json] = true }
        parser.on('--strict') { options[:strict] = true }
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
      notices.concat(morning_notices(morning, options[:morning_report]))

      {
        generated_at: Time.now.utc.iso8601,
        status: priorities.empty? ? 'clear' : 'needs_attention',
        priorities: priorities.first(10),
        notices: notices.first(8),
        sources: options.slice(:nightly_report, :morning_report, :handoff)
      }
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
      text.lines.filter_map do |line|
        next unless line.start_with?('| ')
        cells = line.split('|').map(&:strip)
        next unless cells.length >= 6
        next unless cells[2].include?('Dirty') || cells[2].include?('failed') || cells[3].to_i.positive?

        cells[1]
      end.uniq
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
