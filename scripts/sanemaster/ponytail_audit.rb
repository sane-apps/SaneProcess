# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'time'

module SaneMasterModules
  module PonytailAudit
    PONYTAIL_AUDIT_SCHEMA = 'saneapps.ponytail_audit.v1'
    PONYTAIL_AUDIT_OUTPUT_DIR = File.join('outputs', 'ponytail-audit')
    PONYTAIL_TAGS = %w[native delete shrink yagni].freeze
    PONYTAIL_AUDIT_TIMEOUT_SECONDS = 240
    PonytailCommandStatus = Struct.new(:success_value, :exitstatus) do
      def success?
        success_value
      end
    end

    def ponytail_audit(args = [])
      options = parse_ponytail_audit_options(args)
      result = build_ponytail_audit(options)
      write_ponytail_audit_receipts(result)

      record_process_metric(
        'ponytail_audit',
        success: result[:success],
        target_root: result[:target_root],
        findings: result[:findings].length,
        safe_to_cut: result[:summary][:safe_to_cut],
        needs_proof: result[:summary][:needs_replacement_proof] + result[:summary][:needs_visual_proof],
        security_sensitive: result[:summary][:security_sensitive],
        markdown_path: result[:markdown_path],
        json_path: result[:json_path]
      ) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(ponytail_audit_manifest(result))
      else
        print_ponytail_audit_result(result)
      end

      result[:success]
    end

    def build_ponytail_audit(options)
      generated_at = Time.now.utc
      target_root = File.expand_path(options[:target])
      output_dir = File.expand_path(options[:output], target_root)
      stamp = generated_at.strftime('%Y%m%dT%H%M%SZ')
      markdown_path = File.join(output_dir, "#{stamp}-ponytail-audit.md")
      json_path = File.join(output_dir, "#{stamp}-ponytail-audit.json")
      last_message_path = File.join(output_dir, "#{stamp}-ponytail-final.md")
      stdout_path = File.join(output_dir, "#{stamp}-ponytail-stdout.log")
      stderr_path = File.join(output_dir, "#{stamp}-ponytail-stderr.log")

      FileUtils.mkdir_p(output_dir)
      command = ponytail_audit_command(options, target_root, last_message_path)
      stdout, stderr, status = capture_ponytail_audit(command, timeout_seconds: options[:timeout_seconds])
      final_message = File.exist?(last_message_path) ? File.read(last_message_path, encoding: Encoding::UTF_8) : stdout.to_s
      findings = ponytail_audit_findings(final_message)

      result = {
        schema: PONYTAIL_AUDIT_SCHEMA,
        generated_at: generated_at.iso8601,
        host: Socket.gethostname,
        target_root: target_root,
        mode: options[:diff] ? 'review' : 'audit',
        model: options[:model],
        command: command,
        command_display: command.shelljoin,
        success: status.success?,
        exit_status: status.exitstatus,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        final_message_path: last_message_path,
        markdown_path: markdown_path,
        json_path: json_path,
        stdout: stdout.to_s,
        stderr: stderr.to_s,
        final_message: final_message.to_s,
        findings: findings,
        summary: ponytail_audit_summary(findings)
      }
      File.write(stdout_path, stdout.to_s)
      File.write(stderr_path, stderr.to_s)
      result
    rescue Errno::ENOENT => e
      generated_at ||= Time.now.utc
      target_root ||= File.expand_path(options[:target])
      output_dir ||= File.expand_path(options[:output], target_root)
      FileUtils.mkdir_p(output_dir)
      stamp ||= generated_at.strftime('%Y%m%dT%H%M%SZ')
      {
        schema: PONYTAIL_AUDIT_SCHEMA,
        generated_at: generated_at.iso8601,
        host: Socket.gethostname,
        target_root: target_root,
        mode: options[:diff] ? 'review' : 'audit',
        model: options[:model],
        command: [],
        command_display: '',
        success: false,
        exit_status: 127,
        stdout_path: File.join(output_dir, "#{stamp}-ponytail-stdout.log"),
        stderr_path: File.join(output_dir, "#{stamp}-ponytail-stderr.log"),
        final_message_path: File.join(output_dir, "#{stamp}-ponytail-final.md"),
        markdown_path: File.join(output_dir, "#{stamp}-ponytail-audit.md"),
        json_path: File.join(output_dir, "#{stamp}-ponytail-audit.json"),
        stdout: '',
        stderr: e.message,
        final_message: '',
        findings: [],
        summary: ponytail_audit_summary([])
      }
    end

    def write_ponytail_audit_receipts(result)
      FileUtils.mkdir_p(File.dirname(result[:markdown_path]))
      File.write(result[:markdown_path], render_ponytail_audit_markdown(result))
      File.write(result[:json_path], JSON.pretty_generate(ponytail_audit_manifest(result)))
    end

    def ponytail_audit_manifest(result)
      result.reject { |key, _value| %i[stdout stderr final_message].include?(key) }
    end

    def parse_ponytail_audit_options(args)
      options = {
        target: Dir.pwd,
        output: PONYTAIL_AUDIT_OUTPUT_DIR,
        model: ENV.fetch('SANEMASTER_PONYTAIL_MODEL', 'gpt-5.4'),
        timeout_seconds: PONYTAIL_AUDIT_TIMEOUT_SECONDS,
        diff: false,
        json: false
      }

      queue = args.dup
      until queue.empty?
        arg = queue.shift
        case arg
        when '--target'
          options[:target] = queue.shift || abort('❌ --target requires a path')
        when '--output'
          options[:output] = queue.shift || abort('❌ --output requires a path')
        when '--model'
          options[:model] = queue.shift || abort('❌ --model requires a model name')
        when '--timeout'
          options[:timeout_seconds] = Integer(queue.shift || abort('❌ --timeout requires seconds'), exception: false) ||
                                      abort('❌ --timeout requires an integer number of seconds')
        when '--diff'
          options[:diff] = true
        when '--json'
          options[:json] = true
        else
          abort "❌ Unknown ponytail_audit option: #{arg}"
        end
      end

      abort "❌ Ponytail target does not exist: #{options[:target]}" unless File.directory?(File.expand_path(options[:target]))

      options
    end

    def ponytail_audit_command(options, target_root, last_message_path)
      skill = options[:diff] ? '@ponytail-review' : '@ponytail-audit'
      prompt = <<~PROMPT
        #{skill}

        Audit this repository for over-engineering and bloat. Return only actionable findings.
        Classify each finding with one of these tags: native, delete, shrink, yagni.
        Include exact file paths. Do not propose deleting customer safety proof, security-sensitive
        host-file writing behavior, or release gates unless you also name the replacement proof.
      PROMPT

      [
        'codex', 'exec',
        '--ephemeral',
        '--cd', target_root,
        '--sandbox', 'read-only',
        '-m', options[:model],
        '--output-last-message', last_message_path,
        '--color', 'never',
        prompt
      ]
    end

    def capture_ponytail_audit(command, timeout_seconds: PONYTAIL_AUDIT_TIMEOUT_SECONDS)
      stdout_text = +''
      stderr_text = +''
      Open3.popen3({ 'NO_COLOR' => '1' }, *command, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        readers = [
          Thread.new { stdout.read },
          Thread.new { stderr.read }
        ]
        readers.each { |thread| thread.report_on_exception = false if thread.respond_to?(:report_on_exception=) }

        unless wait_thr.join(timeout_seconds)
          kill_ponytail_process_group(wait_thr.pid)
          stdout_text = readers[0].value.to_s
          stderr_text = [readers[1].value.to_s, "Timed out after #{timeout_seconds}s"].reject(&:empty?).join("\n")
          return [stdout_text, stderr_text, PonytailCommandStatus.new(false, 124)]
        end

        stdout_text = readers[0].value.to_s
        stderr_text = readers[1].value.to_s
        [stdout_text, stderr_text, wait_thr.value]
      end
    rescue Interrupt
      kill_ponytail_process_group(wait_thr.pid) if defined?(wait_thr) && wait_thr
      raise
    end

    def kill_ponytail_process_group(pid)
      Process.kill('TERM', -pid)
      sleep 1
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def ponytail_audit_findings(text)
      findings = []
      current = nil
      text.to_s.each_line do |line|
        stripped = line.strip
        next if stripped.empty?

        tag = PONYTAIL_TAGS.find { |candidate| stripped.match?(/\b#{Regexp.escape(candidate)}\b/i) }
        bullet = stripped.start_with?('-', '*') || stripped.match?(/\A\d+[.)]\s/)
        if tag && (bullet || stripped.start_with?('`'))
          current = {
            tag: tag,
            text: stripped.sub(/\A[-*]\s*/, '').sub(/\A\d+[.)]\s*/, ''),
            paths: stripped.scan(/`([^`]+)`/).flatten,
            disposition: ponytail_finding_disposition(stripped)
          }
          findings << current
        elsif current && (stripped.start_with?('`') || stripped.start_with?('File:', 'Path:'))
          current[:text] = "#{current[:text]} #{stripped}"
          current[:paths] |= stripped.scan(/`([^`]+)`/).flatten
          current[:disposition] = ponytail_finding_disposition(current[:text])
        end
      end
      findings
    end

    def ponytail_finding_disposition(text)
      case text
      when /privileged|xpc|authorization|SMAppService|root|sudo|keychain|host-file|HostsPrivileged/i
        'security_sensitive'
      when /customer[_-]?ui|CustomerUI|sweep|proof|receipt|XCUITest|source-grep|grep test|Tests\//i
        'needs_replacement_proof'
      when /website|visual|screenshot|\.html|\.css/i
        'needs_visual_proof'
      when /docs?\/|AGENTS\.md|ARCHITECTURE\.md|DEVELOPMENT\.md|SESSION_HANDOFF\.md|README\.md|\.md`/i
        'docs_consolidation'
      else
        'safe_to_cut'
      end
    end

    def ponytail_audit_summary(findings)
      dispositions = findings.group_by { |finding| finding[:disposition] }
      {
        total_findings: findings.length,
        by_tag: PONYTAIL_TAGS.to_h { |tag| [tag.to_sym, findings.count { |finding| finding[:tag] == tag }] },
        safe_to_cut: dispositions.fetch('safe_to_cut', []).length,
        needs_replacement_proof: dispositions.fetch('needs_replacement_proof', []).length,
        needs_visual_proof: dispositions.fetch('needs_visual_proof', []).length,
        docs_consolidation: dispositions.fetch('docs_consolidation', []).length,
        security_sensitive: dispositions.fetch('security_sensitive', []).length
      }
    end

    def render_ponytail_audit_markdown(result)
      lines = []
      lines << "# Ponytail Audit: #{File.basename(result[:target_root])}"
      lines << ''
      lines << "- Generated: #{result[:generated_at]}"
      lines << "- Target: `#{result[:target_root]}`"
      lines << "- Mode: #{result[:mode]}"
      lines << "- Model: #{result[:model]}"
      lines << "- Success: #{result[:success]} (exit #{result[:exit_status]})"
      lines << "- Raw final: `#{result[:final_message_path]}`"
      lines << ''
      lines << '## Summary'
      lines << "- Total findings: #{result[:summary][:total_findings]}"
      lines << "- Safe cuts: #{result[:summary][:safe_to_cut]}"
      lines << "- Needs replacement proof: #{result[:summary][:needs_replacement_proof]}"
      lines << "- Needs visual proof: #{result[:summary][:needs_visual_proof]}"
      lines << "- Docs consolidation: #{result[:summary][:docs_consolidation]}"
      lines << "- Security-sensitive: #{result[:summary][:security_sensitive]}"
      lines << ''
      lines << '## Findings'
      if result[:findings].empty?
        lines << 'No tagged Ponytail findings were parsed. See the raw final message.'
      else
        result[:findings].each_with_index do |finding, index|
          paths = finding[:paths].empty? ? 'none parsed' : finding[:paths].map { |path| "`#{path}`" }.join(', ')
          lines << "#{index + 1}. **#{finding[:tag]}** / #{finding[:disposition]}: #{finding[:text]}"
          lines << "   Paths: #{paths}"
        end
      end
      lines << ''
      lines << '## Raw Final Message'
      lines << ''
      lines << result[:final_message].to_s
      lines.join("\n")
    end

    def print_ponytail_audit_result(result)
      puts "Ponytail audit #{result[:success] ? 'completed' : 'failed'} for #{result[:target_root]}"
      puts "Findings: #{result[:summary][:total_findings]} total, #{result[:summary][:safe_to_cut]} safe cuts, #{result[:summary][:security_sensitive]} security-sensitive"
      puts "Markdown: #{result[:markdown_path]}"
      puts "JSON: #{result[:json_path]}"
      puts "Raw final: #{result[:final_message_path]}"
    end
  end
end
