#!/usr/bin/env ruby
# frozen_string_literal: true

# SaneTools Checks Module: all check_* functions for PreToolUse enforcement
# (extracted from sanetools.rb per Rule #10).

require 'json'
require 'socket'
require_relative 'core/mandatory_workflows'
require_relative 'core/state_manager'
require_relative 'sanetools_gaming'
require_relative 'sanetools_deploy'
require_relative 'sanetools_github_guard'
require_relative 'sanetools_research'

module SaneToolsChecks
  # Constants needed by checks
  BLOCKED_PATH_PATTERN = Regexp.union(
    %r{^~?/\.ssh},
    %r{^/etc(/|$)},    # Match /etc and /etc/anything
    %r{^/var(/|$)},    # Match /var and /var/anything
    %r{^/usr(/|$)},    # Match /usr and /usr/anything (system binaries)
    %r{^~?/\.aws},
    %r{^~?/\.gnupg},
    /\.env$/,
    /credentials\.json$/i,  # Block credentials.json but not credentials_template.json
    /secrets?\.ya?ml$/i,
    # C1: HMAC secret moved to macOS Keychain (not file-readable)
    # Legacy file path still blocked for migration safety
    /\.claude_hook_secret$/,
    # Block netrc (contains credentials)
    /\.netrc$/
  ).freeze

  STATE_FILE_PATTERN = %r{\.claude/[^/]+\.json$}.freeze

  LOCAL_UI_TOOL_PATTERN = Regexp.union(
    /^mcp__computer_use__/,
    /^computer-use\./,
    /^mcp__browser__/,
    /^browser\./
  ).freeze

  LOCAL_UI_APPROVAL = 'MR. SANE APPROVES LOCAL UI ON AIR'
  MINI_UNAVAILABLE_APPROVAL = 'MR. SANE CONFIRMS MINI UNAVAILABLE'
  MINI_SCREENSHOT_WRAPPER = '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh'

  FILE_SIZE_SOFT_LIMIT = 500
  FILE_SIZE_HARD_LIMIT = 800
  FILE_SIZE_HARD_LIMIT_MD = 1500
  CORE_DOC_BASENAMES = %w[
    AGENTS.md
    README.md
    DEVELOPMENT.md
    ARCHITECTURE.md
    SESSION_HANDOFF.md
  ].freeze
  SECRET_STARTUP_BASENAMES = %w[
    .zshenv
    .zprofile
    .zshrc
    .bash_profile
    .bashrc
    .profile
  ].freeze

  # === SENSITIVE FILE PATTERNS ===
  # Files with elevated blast radius — edits affect CI/CD, signing, deployment, or security.
  # First edit blocks with explanation; retry auto-approves (user saw the warning).
  SENSITIVE_FILE_PATTERNS = [
    %r{\.github/workflows/},          # CI/CD pipelines
    %r{\.gitlab-ci\.yml$}i,           # GitLab CI
    /Dockerfile/i,                     # Container builds
    /docker-compose/i,                 # Container orchestration
    /Jenkinsfile$/i,                   # Jenkins pipelines
    /Fastfile$/,                       # Fastlane (notarize, upload, deploy)
    /\.entitlements$/,                 # App security permissions
    /\.xcconfig$/,                     # Xcode build configuration
    /Podfile$/,                        # CocoaPods dependencies
    /Package\.resolved$/,              # SPM lockfile
    /\.mcp\.json$/                     # MCP server configuration
  ].freeze

  SAFE_REDIRECT_TARGETS = Regexp.union(
    '/dev/null',
    %r{^/tmp/},
    %r{^/var/tmp/},
    %r{DerivedData/},
    %r{\.build/},
    %r{^build/}
  ).freeze

  def self.workflow_runner_block_message(skill_name, skill_state)
    runner_command = MandatoryWorkflows.runner_command_for(skill_name)
    description = MandatoryWorkflows.skill_requirements.dig(skill_name.to_sym, :description).to_s
    header = if skill_name.to_s == 'evolve'
               'TOOL DISCOVERY REQUIRED'
             else
               'RUNNER-BACKED WORKFLOW REQUIRED'
             end

    reason = if description.empty?
               "The '#{skill_name}' workflow is mandatory for this prompt."
             else
               "The '#{skill_name}' workflow is mandatory for this prompt (#{description})."
             end

    if skill_name.to_s == 'evolve'
      prompt = skill_state[:required_prompt].to_s.strip
      query = prompt.empty? ? 'describe the missing tool or workaround' : prompt
      escaped_query = query.gsub('"', '\"')
      runner_command = "ruby scripts/SaneMaster.rb tool_discovery --query \"#{escaped_query}\""
    end

    "#{header}\n" \
    "#{reason}\n" \
    "Run this first:\n" \
    "  #{runner_command}\n" \
    "Then continue once the workflow proof exists."
  end

  SIGNIFICANT_FILE_PATTERNS = [
    %r{scripts/hooks/.*\.rb$},
    %r{scripts/sanemaster/.*\.rb$},
    %r{scripts/SaneMaster\.rb$},
    %r{docs/.*\.md$}
  ].freeze

  class << self
    include SaneToolsGitHubGuard

    def check_local_ui_tool_guard(tool_name, tool_input)
      return nil unless tool_name.to_s.match?(LOCAL_UI_TOOL_PATTERN)
      return nil unless running_on_macbook_air?
      return nil if ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] == LOCAL_UI_APPROVAL
      return nil if ENV['SANE_MINI_UNAVAILABLE'] == MINI_UNAVAILABLE_APPROVAL

      app = tool_input['app'] || tool_input[:app] ||
            tool_input['application'] || tool_input[:application] ||
            tool_input['url'] || tool_input[:url] ||
            'local UI'

      "MINI-FIRST LOCAL UI BLOCKED\n" \
      "Tool: #{tool_name}\n" \
      "Target: #{app}\n" \
      "This would control the MacBook Air instead of the Mac Mini.\n" \
      "DO THIS: run SaneApps browser/UI/release work on the Mini via ssh mini, SaneMaster, sane_test.rb, or Mini-side automation.\n" \
      "ONLY FALLBACK: set SANE_MINI_UNAVAILABLE='#{MINI_UNAVAILABLE_APPROVAL}' or SANE_APPROVE_LOCAL_UI_ON_AIR='#{LOCAL_UI_APPROVAL}' after explicit user approval."
    end

    def check_canonical_action_path(tool_name, tool_input)
      return nil unless tool_name == 'Bash'

      command = tool_input['command'] || tool_input[:command] || ''
      return nil unless command.match?(/\bssh\s+(?:[^'"]*\s+)?mini\b/i)
      return nil unless command.match?(/\bscreencapture\b/i)

      "CANONICAL ACTION PATH BLOCKED\n" \
      "Mini screenshots must not use raw ssh + screencapture.\n" \
      "That path can fail outside the Mini's logged-in GUI session and produce false blockers.\n" \
      "DO THIS: run #{MINI_SCREENSHOT_WRAPPER} with the needed --app/--window-name/--path arguments.\n" \
      "For app-owned SaneApps captures, this wrapper also runs the visual workspace guard."
    end

    def check_secret_startup_autoload(tool_name, tool_input, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      path = tool_input['file_path'] || tool_input['path'] || tool_input[:file_path] || tool_input[:path]
      return nil unless path && SECRET_STARTUP_BASENAMES.include?(File.basename(path.to_s))

      content = [
        tool_input['content'],
        tool_input[:content],
        tool_input['new_string'],
        tool_input[:new_string]
      ].compact.join("\n")
      return nil if content.empty?

      return nil unless content.match?(/security\s+find-generic-password/) ||
                        content.match?(%r{(?:source|\.)\s+["']?\$?HOME/?\.config/nv/env}) ||
                        content.match?(/export\s+[A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PRIVATE_KEY)=/)

      "SECRET STARTUP AUTOLOAD BLOCKED\n" \
      "Do not load credentials from shell startup files. Agent shells can snapshot their environment.\n" \
      "DO THIS: keep startup files secret-free and use sane_load_secrets or a tool-specific wrapper for explicit credential access.\n" \
      "RECREATE TEST: a clean login shell must show API/token variables unset until sane_load_secrets is called."
    end

    def running_on_macbook_air?
      return true if ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] == '1'
      return false if ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] == '1'

      host = Socket.gethostname.to_s.downcase
      return false if host.include?('mini')

      true
    rescue StandardError
      true
    end

    def check_blocked_path(tool_input, tool_name = nil, edit_tools = [])
      path = tool_input['file_path'] || tool_input['path'] || tool_input[:file_path] || tool_input[:path]
      return nil unless path

      require 'uri'

      # VULN-003 FIX: Sanitize null bytes (can bypass path detection)
      sanitized_path = path.gsub(/\x00|\u0000/, '')

      # VULN-003 FIX: Recursive URL decoding (double encoding bypass)
      # %252e -> %2e -> . requires multiple decode passes
      decoded_path = sanitized_path
      10.times do # Max 10 iterations to prevent infinite loops
        new_decoded = URI.decode_www_form_component(decoded_path) rescue decoded_path
        break if new_decoded == decoded_path
        decoded_path = new_decoded.gsub(/\x00|\u0000/, '') # Sanitize after each decode
      end

      expanded_path = File.expand_path(sanitized_path) rescue sanitized_path
      expanded_decoded = File.expand_path(decoded_path) rescue decoded_path
      project_dir = File.expand_path(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd) rescue nil

      # Traversal detection: if input uses ".." to reach sensitive path segments, block it.
      # The raw path may not resolve to /etc from this CWD, but from a different CWD it would.
      # Intent is clear: traversal + sensitive target = block.
      if sanitized_path.include?('..')
        [sanitized_path, decoded_path].each do |raw|
          if raw.match?(%r{(?:^|/)(?:etc|var|usr)(/|$)}) ||
             raw.match?(%r{/\.(ssh|aws|gnupg)(/|$)})
            return "BLOCKED PATH (traversal detected): #{path}\n" \
                   "Path traversal to sensitive directory detected.\n" \
                   "DO THIS: Use direct paths within the project."
          end
        end
      end

      [sanitized_path, decoded_path, expanded_path, expanded_decoded].each do |p|
        in_project = project_dir && p.start_with?("#{project_dir}/")
        if p.match?(BLOCKED_PATH_PATTERN)
          next if in_project

          return "BLOCKED PATH: #{path}\n" \
                 "This path is outside your project scope.\n" \
                 "DO THIS: Work only within the project directory.\n" \
                 "READ: DEVELOPMENT.md for allowed paths and project structure."
        end

        # Path traversal detection: check for sensitive dirs anywhere in path
        # Catches: ./test/../.ssh/key, /foo/bar/.ssh/id_rsa
        # SSH trust files (authorized_keys, known_hosts) are not secrets and are
        # legitimately managed by tooling (loopback SSH gives release scripts a
        # stable Full Disk Access identity); private keys and config stay blocked.
        sensitive_ssh = p.match?(%r{/\.ssh/}) && !p.match?(%r{/\.ssh/(?:authorized_keys|known_hosts)\z})
        if sensitive_ssh || p.match?(%r{/\.aws/}) || p.match?(%r{/\.gnupg/})
          return "BLOCKED PATH (traversal detected): #{path}\n" \
                 "Path traversal to sensitive directory detected.\n" \
                 "DO THIS: Use direct paths within the project.\n" \
                 "READ: The path you requested resolves outside allowed areas."
        end

        # State files: block edits only, allow reads
        if p.match?(STATE_FILE_PATTERN) && edit_tools.include?(tool_name)
          return "STATE FILE PROTECTED: #{path}\n" \
                 "Claude cannot edit .claude/*.json files directly.\n" \
                 "Use user commands (s+/s-/sl+/sl-) instead."
        end
      end

      nil
    end

    # === SENSITIVE FILE PROTECTION ===
    # Blocks first edit attempt on high-blast-radius files.
    # Retry auto-approves (user saw the block message and didn't intervene).
    def check_sensitive_file_edit(tool_name, tool_input, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      path = tool_input['file_path'] || tool_input[:file_path] || ''
      return nil if path.empty?

      basename = File.basename(path)
      matched = SENSITIVE_FILE_PATTERNS.find { |p| path.match?(p) || basename.match?(p) }
      return nil unless matched

      # Check if already approved this session
      # Note: JSON round-trip may store path as symbol key (symbolize_names: true)
      approvals = StateManager.get(:sensitive_approvals)
      return nil if approvals.any? { |k, _| k.to_s == path }

      # Record approval for retry
      StateManager.update(:sensitive_approvals) do |a|
        a[path] = { approved_at: Time.now.iso8601 }
        a
      end

      "SENSITIVE FILE — CONFIRM INTENT\n" \
      "File: #{path}\n" \
      "This file has elevated blast radius (CI/CD, build config, signing, or dependencies).\n" \
      "Changes here can affect builds, deployment, security, or dependency resolution.\n" \
      "\n" \
      "If this edit is intentional, retry — it will proceed.\n" \
      "This check fires once per file per session."
    end

    def check_file_size(tool_name, tool_input, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      path = tool_input['file_path'] || tool_input[:file_path]
      return nil unless path

      is_markdown = path.end_with?('.md')
      hard_limit = is_markdown ? FILE_SIZE_HARD_LIMIT_MD : FILE_SIZE_HARD_LIMIT

      # Handle Write tool: check new content directly
      content = tool_input['content'] || tool_input[:content]
      if content
        projected_count = content.lines.count
        if projected_count > hard_limit
          return "FILE SIZE BLOCKED (Rule #10)\n" \
                 "#{path}: #{projected_count} lines > #{hard_limit} limit\n" \
                 "Split ownership first. Extensions count toward the same component owner."
        elsif projected_count > FILE_SIZE_SOFT_LIMIT && !is_markdown
          warn "FILE SIZE WARNING: #{path} at #{projected_count} lines (limit: #{hard_limit})"
        end
        return nil
      end

      # Handle Edit tool: calculate delta from old_string/new_string
      return nil unless File.exist?(path)
      line_count = File.readlines(path).count rescue 0

      old_string = tool_input['old_string'] || tool_input[:old_string] || ''
      new_string = tool_input['new_string'] || tool_input[:new_string] || ''
      lines_added = new_string.lines.count - old_string.lines.count
      projected_count = line_count + lines_added

      # Shrinking/neutral edits always pass: an oversized file can only be
      # split or reduced by editing it (merge-conflict resolution included).
      return nil if lines_added <= 0

      if projected_count > hard_limit
        return "FILE SIZE BLOCKED (Rule #10)\n" \
               "#{path}: #{projected_count} lines > #{hard_limit} limit\n" \
               "Split ownership first. Extensions count toward the same component owner."
      elsif projected_count > FILE_SIZE_SOFT_LIMIT && !is_markdown
        warn "FILE SIZE WARNING: #{path} at #{projected_count} lines (limit: #{hard_limit})"
      end

      nil
    end

    def check_new_file_policy(tool_name, tool_input)
      return nil unless tool_name == 'Write'

      path = tool_input['file_path'] || tool_input[:file_path]
      return nil if path.to_s.empty?
      return nil if File.exist?(path)

      expanded_path = File.expand_path(path)
      project_dir = File.expand_path(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd)
      return nil unless expanded_path.start_with?("#{project_dir}/")

      return nil unless expanded_path.end_with?('.md')
      return nil if allowed_markdown_path?(expanded_path, project_dir)

      "NEW DOCUMENT BLOCKED (Rules #9 and #16)\n" \
      "File: #{path}\n" \
      "Do not create orphan markdown files. Integrate durable content into the 5-doc standard:\n" \
      "  AGENTS.md, README.md, DEVELOPMENT.md, ARCHITECTURE.md, SESSION_HANDOFF.md\n" \
      "Use .claude/research.md or .codex/research.md only for dated research-cache entries.\n" \
      "Generated receipts belong under outputs/."
    end

    def allowed_markdown_path?(expanded_path, project_dir)
      relative = expanded_path.delete_prefix("#{project_dir}/")
      return true if CORE_DOC_BASENAMES.include?(relative)
      return true if relative.match?(%r{\A\.(claude|codex)/research\.md\z})
      return true if relative.start_with?('outputs/')

      false
    end

    def check_component_owner_size(tool_name, tool_input, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      path = tool_input['file_path'] || tool_input[:file_path]
      return nil unless path.to_s.end_with?('.swift')

      owner_files = swift_owner_files(path)
      return nil if owner_files.empty?

      current_total = owner_files.sum { |file| File.exist?(file) ? (File.readlines(file).count rescue 0) : 0 }
      projected_total = current_total + projected_line_delta(tool_name, tool_input, path)
      return nil if projected_total <= current_total

      if projected_total > FILE_SIZE_HARD_LIMIT
        return "COMPONENT OWNER SIZE BLOCKED (Rule #10)\n" \
               "#{swift_owner_name(path)} owner: #{projected_total} lines > #{FILE_SIZE_HARD_LIMIT} limit\n" \
               "Files counted:\n" \
               "#{owner_files.map { |file| "  - #{file}" }.join("\n")}\n" \
               "Split ownership before adding more code. Extensions count toward the same component owner."
      elsif projected_total > FILE_SIZE_SOFT_LIMIT
        warn "COMPONENT OWNER SIZE WARNING: #{swift_owner_name(path)} owner at #{projected_total} lines (soft limit: #{FILE_SIZE_SOFT_LIMIT})"
      end

      nil
    end

    def swift_owner_files(path)
      expanded_path = File.expand_path(path)
      dir = File.dirname(expanded_path)
      owner = swift_owner_name(expanded_path)
      files = Dir.glob([
        File.join(dir, "#{owner}.swift"),
        File.join(dir, "#{owner}+*.swift")
      ])
      files << expanded_path unless files.include?(expanded_path)
      files.uniq
    end

    def swift_owner_name(path)
      File.basename(path, '.swift').split('+', 2).first
    end

    def projected_line_delta(tool_name, tool_input, path)
      content = tool_input['content'] || tool_input[:content]
      if tool_name == 'Write' && content
        existing = File.exist?(path) ? (File.readlines(path).count rescue 0) : 0
        return content.lines.count - existing
      end

      old_string = tool_input['old_string'] || tool_input[:old_string] || ''
      new_string = tool_input['new_string'] || tool_input[:new_string] || ''
      new_string.lines.count - old_string.lines.count
    end

    def check_table_ban(tool_name, tool_input, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      content = tool_input['new_string'] || tool_input[:new_string] ||
                tool_input['content'] || tool_input[:content] || ''
      return nil if content.empty?

      table_patterns = [
        /\|[-:]+\|/,
        /^\s*\|.*\|.*\|/m
      ]

      if table_patterns.any? { |p| content.match?(p) }
        pipe_lines = content.lines.count { |l| l.count('|') >= 2 }
        if pipe_lines >= 2
          return "TABLE BLOCKED\n" \
                 "Markdown tables render poorly in terminal.\n" \
                 "Use plain lists or bullet points instead."
        end
      end

      nil
    end

    def check_bash_bypass(tool_name, tool_input, bash_file_write_pattern)
      return nil unless tool_name == 'Bash'

      command = tool_input['command'] || tool_input[:command] || ''

      unless command.match?(/SaneMaster\.rb/)
        state_bypass_patterns = [
          /ruby\s+-e.*\.claude\/.*\.json/i,
          /\brm\s+(-[rf]+\s+)?[^\|]*\.claude\/.*\.json/i,
          />\s*[^\s]*\.claude\/.*\.json/i,
          /\btee\s+[^\s]*\.claude\/.*\.json/i
        ]

        if state_bypass_patterns.any? { |p| command.match?(p) }
          return "STATE BYPASS BLOCKED\n" \
                 "Command appears to manipulate .claude state files: #{command[0..60]}...\n" \
                 "Claude cannot modify enforcement state via bash.\n" \
                 "Use user commands (s+/s-/sl+/sl-) instead."
        end
      end

      # Redirect operators always sit outside quotes, so blanking quoted
      # strings removes literal '>' false positives ('<item>', "a > b")
      # without hiding real redirects.
      scan = command.gsub(/'[^']*'/, "''").gsub(/"[^"]*"/, '""')

      if scan.match?(bash_file_write_pattern)
        target_match = scan.match(/(?:>|>>|tee\s+)\s*([^\s|&;]+)/)
        target = target_match ? target_match[1] : nil
        target ||= scan[/\bcurl\b[^|;&]*\s-o\s+([^\s|&;]+)/, 1]

        return nil if target && target.match?(SAFE_REDIRECT_TARGETS)

        if scan.match?(/^\s*\S+.*2>&1\s*$/) || scan.match?(/2>\/dev\/null/)
          unless scan.match?(/[^2]>\s*[^&]/) || scan.match?(/>>/)
            return nil
          end
        end

        return "BASH FILE WRITE BLOCKED\n" \
               "Command appears to write files: #{command[0..80]}...\n" \
               "Use Edit or Write tool instead - bash writes bypass tracking.\n" \
               "Allowed: /tmp/, /dev/null, build dirs, stderr redirects (2>&1)"
      end

      nil
    end

    def check_readme_on_commit(tool_name, tool_input)
      return nil unless tool_name == 'Bash'

      command = tool_input['command'] || tool_input[:command] || ''
      return nil unless command.match?(/git\s+commit/)

      edits = StateManager.get(:edits)
      edited_files = edits[:unique_files] || []

      significant_edits = edited_files.any? do |f|
        SIGNIFICANT_FILE_PATTERNS.any? { |p| f.match?(p) }
      end

      return nil unless significant_edits

      readme_updated = edited_files.any? { |f| f.match?(/README\.md$/i) }
      return nil if readme_updated

      warn '---'
      warn 'README UPDATE REMINDER'
      warn ''
      warn 'You edited significant files but README.md was not updated:'
      significant = edited_files.select { |f| SIGNIFICANT_FILE_PATTERNS.any? { |p| f.match?(p) } }
      significant.first(5).each { |f| warn "  - #{File.basename(f)}" }
      warn ''
      warn 'Consider updating README.md to reflect these changes.'
      warn '---'

      nil
    end

    def check_subagent_bypass(tool_name, tool_input, edit_keywords, research_categories)
      return nil unless tool_name == 'Task'

      prompt = tool_input['prompt'] || tool_input[:prompt] || ''
      prompt_lower = prompt.downcase

      is_edit_task = edit_keywords.any? { |kw| prompt_lower.include?(kw) }
      return nil unless is_edit_task

      research = StateManager.get(:research)
      complete = effective_research_categories(research_categories).all? { |cat| research[cat] }

      unless complete
        return "SUBAGENT BYPASS BLOCKED\n" \
               "Task for editing: #{prompt[0..50]}... Complete research first.\n" \
               "Reset: rr- (clear research to start over)"
      end

      nil
    end

    def check_circuit_breaker
      cb = StateManager.get(:circuit_breaker)
      return nil unless cb[:tripped]

      "CIRCUIT BREAKER TRIPPED\n" \
      "#{cb[:failures]} consecutive failures detected.\n" \
      "Last error: #{cb[:last_error]}\n" \
      "Rule #3: stop, read the error, and research before retrying.\n" \
      "Reset only after documenting the root cause: rb-"
    end

    # === SESSION DOC ENFORCEMENT ===
    # Block edit tools until required session docs have been read
    def check_session_docs_read(tool_name, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      session_docs = StateManager.get(:session_docs)
      return nil unless session_docs[:enforced]

      required = session_docs[:required] || []
      return nil if required.empty?

      already_read = session_docs[:read] || []
      unread = required - already_read
      return nil if unread.empty?

      total_docs = required.length
      read_count = already_read.length
      "READ REQUIRED DOCS FIRST [#{read_count}/#{total_docs} read]\n" \
      "Session docs must be read before editing.\n" \
      "\n" \
      "Unread (use Read tool on each):\n" \
      "#{unread.map { |f| "  → #{f}" }.join("\n")}\n" \
      "\n" \
      "Already read: #{already_read.any? ? already_read.join(', ') : 'none'}\n" \
      "\n" \
      "WHY: These docs contain recent work context, SOPs, and gotchas.\n" \
      "Skipping them leads to rediscovering known issues."
    end

    # === PLANNING ENFORCEMENT ===
    # Block edit tools until user approves a plan
    # Research/read tools always allowed (anti-loop design)
    def check_planning_required(tool_name, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      planning = StateManager.get(:planning)
      return nil unless planning[:required]
      return nil if planning[:plan_approved]

      replan = planning[:replan_count].to_i
      note = replan > 0 ? " (re-plan ##{replan})" : ''

      "PLAN REQUIRED#{note}\n" \
      "Show your approach and get user approval before editing.\n" \
      "  1. Describe plan (files, changes, approach)\n" \
      "  2. User says 'approved'/'go ahead'/'lgtm'\n" \
      "  3. Or use EnterPlanMode\n" \
      "Research tools still work. Only edits are blocked.\n" \
      "Reset: pa+ (manually approve plan)"
    end

    def check_enforcement_halted
      enf = StateManager.get(:enforcement)
      return nil unless enf[:halted]

      warn "Enforcement halted: #{enf[:halted_reason]}"
      nil
    end

    def check_research_only_mode(tool_name, edit_tools, global_mutation_pattern, external_mutation_pattern)
      reqs = StateManager.get(:requirements)
      return nil unless reqs[:is_research_only]

      if edit_tools.include?(tool_name) ||
         tool_name.match?(global_mutation_pattern) ||
         tool_name.match?(external_mutation_pattern)
        return "RESEARCH-ONLY MODE ACTIVE\n" \
               "User requested research/investigation only.\n" \
               "Tool '#{tool_name}' is blocked because it would make changes.\n" \
               "If you want to make changes, ask user to start a new session with an action request."
      end

      nil
    end

  def check_tool_discovery_required(tool_name, tool_input, edit_tools)
    skill = StateManager.get(:skill)
    required_skill = skill[:required].to_s
    requirements = MandatoryWorkflows.skill_requirements[required_skill.to_sym]
    return nil unless requirements && requirements[:requires_runner]
    return nil if skill[:runner_proved] || skill[:runner_used]

    if tool_name == 'Bash'
      command = tool_input['command'] || tool_input[:command] || ''
      allowed_patterns = MandatoryWorkflows.runner_patterns_for(required_skill)
      return nil if allowed_patterns.any? { |pattern| command.match?(pattern) }
    end

    return nil unless edit_tools.include?(tool_name) || %w[Bash Task].include?(tool_name)
    workflow_runner_block_message(required_skill, skill)
  end

    def check_saneloop_required(tool_name, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      reqs = StateManager.get(:requirements)
      return nil unless reqs[:is_big_task]

      saneloop = StateManager.get(:saneloop)
      return nil if saneloop[:active]

      "SANELOOP REQUIRED\n" \
      "Big task detected but SaneLoop not active.\n" \
      "This task matches big-task indicators (all/complete/rewrite/system/etc).\n" \
      "Reset: sl+ \"<task description>\" (start SaneLoop for this task)"
    end

    def check_requirements(tool_name, bootstrap_tool_pattern, edit_tools, research_categories)
      return nil if tool_name.match?(bootstrap_tool_pattern)
      return nil unless edit_tools.include?(tool_name)

      reqs = StateManager.get(:requirements)
      requested = reqs[:requested] || []
      satisfied = reqs[:satisfied] || []

      return nil if requested.empty?

      unsatisfied = requested - satisfied

      return nil if unsatisfied.empty?

      if unsatisfied.include?('research')
        research = StateManager.get(:research)
        if effective_research_categories(research_categories).all? { |cat| research[cat] }
          StateManager.update(:requirements) do |r|
            r[:satisfied] ||= []
            r[:satisfied] << 'research' unless r[:satisfied].include?('research')
            r
          end
          unsatisfied.delete('research')
        end
      end

      return nil if unsatisfied.empty?

      satisfied_count = requested.length - unsatisfied.length
      "REQUIREMENTS NOT MET [#{satisfied_count}/#{requested.length} satisfied]\n" \
      "User requested: #{requested.join(', ')}\n" \
      "Unsatisfied: #{unsatisfied.join(', ')}\n" \
      "Complete these before editing.\n" \
      "Reset: Type 'reset?' to see all available reset commands"
    end

    # === INTELLIGENCE: Refusal to Read Detection ===
    # Detect when AI is blocked repeatedly for same reason but keeps trying
    # instead of reading the message and following instructions

    def check_refusal_to_read(tool_name, block_reason)
      return nil unless block_reason

      # Extract the block type from the reason
      block_type = case block_reason
                   when /RESEARCH INCOMPLETE/i then 'research_incomplete'
                   when /BLOCKED PATH/i then 'blocked_path'
                   when /FILE SIZE/i then 'file_size'
                   when /BASH.*WRITE/i then 'bash_write'
                   when /STATE.*BYPASS|STATE.*PROTECTED/i then 'state_bypass'
                   when /MCP.*VERIFICATION/i then 'mcp_verification'
                   when /SANELOOP REQUIRED/i then 'saneloop_required'
                   when /READ REQUIRED DOCS/i then 'session_docs'
                   else 'other'
                   end

      # Track consecutive blocks of same type
      blocks = StateManager.get(:refusal_tracking) || {}
      current = blocks[block_type] || { count: 0, last_tool: nil }

      # Increment if same block type
      current[:count] += 1
      current[:last_tool] = tool_name
      current[:last_at] = Time.now.iso8601

      StateManager.update(:refusal_tracking) do |b|
        b[block_type] = current
        b
      end

      # Escalate based on count
      case current[:count]
      when 1
        nil # First block - normal message
      when 2
        # Second block - add READ THE MESSAGE reminder
        "\n" \
        "⚠️  SAME BLOCK TWICE - READ THE MESSAGE ABOVE\n" \
        "You were just blocked for this. The FIX is in the message.\n" \
        "DO NOT try again. READ the block message. FOLLOW the instructions."
      else
        # 3+ blocks - halt and require acknowledgment
        "REFUSAL TO READ DETECTED - SESSION HALTED\n" \
        "You've been blocked #{current[:count]}x for: #{block_type}\n" \
        "\n" \
        "Each block message told you EXACTLY what to do.\n" \
        "You ignored it and kept trying different approaches.\n" \
        "\n" \
        "THIS IS THE PROBLEM THE HOOKS EXIST TO SOLVE.\n" \
        "\n" \
        "USER: Type 'reset blocks' or 'unblock' to allow retry.\n" \
        "      Type 'reset?' to see all reset commands.\n" \
        "      Resets are LOGGED and do NOT disable enforcement."
      end
    end

    def reset_refusal_tracking(block_type = nil)
      if block_type
        StateManager.update(:refusal_tracking) { |b| b.delete(block_type); b }
      else
        StateManager.reset(:refusal_tracking)
      end
    end

    # Reset tracking when AI does the RIGHT thing (reward obedience)
    def reward_correct_behavior(action_type)
      case action_type
      when :research_done
        reset_refusal_tracking('research_incomplete')
        warn "✅ Research complete. You may now edit."
      when :used_correct_tool
        warn "✅ Correct tool used. Proceeding."
      when :read_sop
        warn "✅ SOP acknowledged. You're following the process."
      end
    end

    # === INTELLIGENCE: Gaming Detection ===
    # Extracted to sanetools_gaming.rb per Rule #10
    include SaneToolsGaming

    # === DEPLOYMENT SAFETY ===
    # Extracted to sanetools_deploy.rb per Rule #10
    include SaneToolsDeploy
    include SaneToolsResearch

    # === EDIT ATTEMPT LIMIT ===
    # Legacy no-op kept for compatibility with tests and callers. The original
    # implementation counted every successful Edit tool call as a failed attempt,
    # so normal multi-file work could revoke plan approval after three good
    # edits and trap Claude in a replan loop. Real repeated-failure handling now
    # lives in circuit_breaker/refusal_tracking, which are keyed off actual
    # failures and blocks instead of successful edits.

    MAX_EDIT_ATTEMPTS_BEFORE_RESEARCH = 3

    def check_edit_attempt_limit(tool_name, edit_tools)
      nil
    end

    def reset_edit_attempts
      StateManager.update(:edit_attempts) do |a|
        a ||= {}
        a[:count] = 0
        a[:reset_at] = Time.now.iso8601
        a
      end
    rescue StandardError
      # Don't fail on reset errors
    end
  end
end
