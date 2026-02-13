#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Checks Module
# ==============================================================================
# Extracted from sanetools.rb per Rule #10 (file size limit)
# Contains all check_* functions for PreToolUse enforcement
# ==============================================================================

require_relative 'core/state_manager'
require_relative 'sanetools_gaming'
require_relative 'sanetools_deploy'

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

  FILE_SIZE_SOFT_LIMIT = 500
  FILE_SIZE_HARD_LIMIT = 800
  FILE_SIZE_HARD_LIMIT_MD = 1500

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

  SIGNIFICANT_FILE_PATTERNS = [
    %r{scripts/hooks/.*\.rb$},
    %r{scripts/sanemaster/.*\.rb$},
    %r{scripts/SaneMaster\.rb$},
    %r{docs/.*\.md$}
  ].freeze

  class << self
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
        if p.match?(BLOCKED_PATH_PATTERN)
          return "BLOCKED PATH: #{path}\n" \
                 "This path is outside your project scope.\n" \
                 "DO THIS: Work only within the project directory.\n" \
                 "READ: DEVELOPMENT.md for allowed paths and project structure."
        end

        # Path traversal detection: check for sensitive dirs anywhere in path
        # Catches: ./test/../.ssh/key, /foo/bar/.ssh/id_rsa
        if p.match?(%r{/\.ssh/}) || p.match?(%r{/\.aws/}) || p.match?(%r{/\.gnupg/})
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
                 "Split file first. Use extensions like Manager+Feature.swift"
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

      if projected_count > hard_limit
        return "FILE SIZE BLOCKED (Rule #10)\n" \
               "#{path}: #{projected_count} lines > #{hard_limit} limit\n" \
               "Split file first. Use extensions like Manager+Feature.swift"
      elsif projected_count > FILE_SIZE_SOFT_LIMIT && !is_markdown
        warn "FILE SIZE WARNING: #{path} at #{projected_count} lines (limit: #{hard_limit})"
      end

      nil
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

      if command.match?(bash_file_write_pattern)
        target_match = command.match(/(?:>|>>|tee\s+)\s*([^\s|&;]+)/)
        target = target_match ? target_match[1] : nil

        return nil if target && target.match?(SAFE_REDIRECT_TARGETS)

        if command.match?(/^\s*\S+.*2>&1\s*$/) || command.match?(/2>\/dev\/null/)
          unless command.match?(/[^2]>\s*[^&]/) || command.match?(/>>/)
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

    # Categories that require specific MCPs — auto-satisfy if those MCPs aren't available.
    # :web and :local use built-in tools (WebSearch, Read/Grep/Glob) so always required.
    MCP_DEPENDENT_CATEGORIES = {
      docs: [:apple_docs, :context7],
      github: [:github]
    }.freeze

    # Returns only the research categories that should be enforced,
    # skipping MCP-dependent ones if those MCPs aren't installed.
    def effective_research_categories(research_categories)
      research = StateManager.get(:research)
      health = StateManager.get(:mcp_health)
      mcps = health[:mcps] || {}

      research_categories.keys.select do |cat|
        if MCP_DEPENDENT_CATEGORIES.key?(cat) && !research[cat]
          # Check if any MCP for this category has ever been called
          mcp_keys = MCP_DEPENDENT_CATEGORIES[cat]
          mcp_keys.any? do |key|
            data = mcps[key]
            data.is_a?(Hash) && (data[:last_success] || data[:last_failure])
          end
        else
          true
        end
      end
    end

    def check_research_before_edit(tool_name, edit_tools, research_categories)
      return nil unless edit_tools.include?(tool_name)

      research = StateManager.get(:research)
      effective_categories = effective_research_categories(research_categories)

      total = effective_categories.length
      done = effective_categories.count { |cat| research[cat] }
      complete = done == total

      return nil if complete

      missing = effective_categories.reject { |cat| research[cat] }

      # Build specific instructions for each missing category
      missing_instructions = missing.map do |cat|
        case cat
        when :docs then "  1. DOCS: mcp__apple-docs, mcp__context7, or WebSearch for docs (verify APIs exist)"
        when :web then "  2. WEB: WebSearch (current best practices)"
        when :github then "  3. GITHUB: mcp__github__search_* or WebSearch for examples (real-world code)"
        when :local then "  4. LOCAL: Read/Grep/Glob (understand existing code)"
        else "  #{cat}: Complete this research category"
        end
      end.join("\n")

      "RESEARCH INCOMPLETE [#{done}/#{total} complete: missing #{missing.join(', ')}]\n" \
      "Cannot edit until ALL #{total} research categories are done.\n" \
      "MISSING (do these NOW):\n" \
      "#{missing_instructions}\n" \
      "Rule #2: VERIFY, THEN TRY. Research once, succeed once.\n" \
      "Reset: rr- (clear research to start over)"
    end

    def check_external_mutations(tool_name, external_mutation_pattern, research_categories)
      return nil unless tool_name.match?(external_mutation_pattern)

      research = StateManager.get(:research)
      effective = effective_research_categories(research_categories)
      complete = effective.all? { |cat| research[cat] }

      return nil if complete

      missing = effective.reject { |cat| research[cat] }
      "EXTERNAL MUTATION BLOCKED\n" \
      "Tool '#{tool_name}' affects external systems. Research first.\n" \
      "Missing: #{missing.join(', ')}. Use read-only tools to understand state first.\n" \
      "Reset: rr- (clear research to start over)"
    end

    def check_circuit_breaker
      cb = StateManager.get(:circuit_breaker)
      return nil unless cb[:tripped]

      "CIRCUIT BREAKER TRIPPED\n" \
      "#{cb[:failures]} consecutive failures detected.\n" \
      "Last error: #{cb[:last_error]}\n" \
      "Reset: rb- (clear circuit breaker to retry)"
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

    # === PREFLIGHT: MCP Verification System ===
    # Block edits until ALL MCPs have been verified this session
    # User insight: "how can you make sure all systems are go before work begins?"

    CLAUDE_DIR = File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.claude')
    MEMORY_STAGING_FILE = File.join(CLAUDE_DIR, 'memory_staging.json')

    # MCP verification tools (read-only operations to prove connectivity)
    # NOTE: Official Memory MCP (@modelcontextprotocol/server-memory) is global, not project-verified
    MCP_VERIFICATION_INFO = {
      apple_docs: { name: 'Apple Docs', tool: 'mcp__apple-docs__search_apple_docs' },
      context7: { name: 'Context7', tool: 'mcp__context7__resolve-library-id' },
      github: { name: 'GitHub', tool: 'mcp__github__search_repositories' }
    }.freeze

    def check_pending_mcp_actions(tool_name, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      # Only enforce MCP verification for projects with .saneprocess manifest
      project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
      return nil unless File.exist?(File.join(project_dir, '.saneprocess'))

      # Get MCP health state
      health = StateManager.get(:mcp_health)

      # If all verified, allow edits
      return nil if health[:verified_this_session]

      # Check which MCPs are still unverified
      mcps = health[:mcps] || {}
      unverified = MCP_VERIFICATION_INFO.select do |key, _info|
        mcp_data = mcps[key]
        !mcp_data || !mcp_data[:verified]
      end

      # If all verified (but flag not set), allow and fix state
      if unverified.empty?
        StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
        return nil
      end

      # Also check for memory staging (pending MCP action)
      pending_actions = []
      if File.exist?(MEMORY_STAGING_FILE)
        begin
          staging = JSON.parse(File.read(MEMORY_STAGING_FILE))
          if staging['needs_memory_update']
            entity_name = staging.dig('suggested_entity', 'name') || 'learnings'
            pending_actions << "Memory staging needs saving: #{entity_name}"
          end
        rescue StandardError
          pending_actions << 'Memory staging file needs review'
        end
      end

      # Build comprehensive error message
      total_mcps = MCP_VERIFICATION_INFO.length
      verified_count = total_mcps - unverified.length
      unverified_list = unverified.map do |key, info|
        "  ⬜ #{info[:name]}: #{info[:tool]}"
      end.join("\n")

      msg = "MCP VERIFICATION INCOMPLETE [#{verified_count}/#{total_mcps} verified]\n" \
            "Cannot edit until all #{total_mcps} MCPs are verified this session.\n" \
            "\n" \
            "Unverified MCPs (run each tool once to verify):\n" \
            "#{unverified_list}\n"

      if pending_actions.any?
        msg += "\n" \
               "Pending MCP actions:\n" \
               "#{pending_actions.map { |a| "  ⚠️  #{a}" }.join("\n")}\n"
      end

      msg += "\nCall each unverified MCP tool once to proceed."
      msg
    end

    # === EDIT ATTEMPT LIMIT ===
    # Prevents "no big deal" syndrome: 3 edit attempts without research = STOP
    # User insight: "genius with impulse control of a two year old"
    # This enforces the pause-and-think pattern

    MAX_EDIT_ATTEMPTS_BEFORE_RESEARCH = 3

    def check_edit_attempt_limit(tool_name, edit_tools)
      return nil unless edit_tools.include?(tool_name)

      attempts = StateManager.get(:edit_attempts) || {}
      count = attempts[:count] || 0

      # If under limit, increment and allow
      if count < MAX_EDIT_ATTEMPTS_BEFORE_RESEARCH
        StateManager.update(:edit_attempts) do |a|
          a ||= {}
          a[:count] = (a[:count] || 0) + 1
          a[:last_attempt] = Time.now.iso8601
          a
        end
        return nil
      end

      # At or over limit - reset research AND revoke plan approval
      # If 3 edits didn't work, your understanding is wrong - research AGAIN
      StateManager.reset(:research)

      # Revoke plan approval - must show a NEW plan
      StateManager.update(:planning) do |p|
        p[:plan_approved] = false
        p[:plan_shown] = false
        p[:replan_count] = (p[:replan_count] || 0) + 1
        p
      end

      "EDIT ATTEMPT LIMIT + REPLAN REQUIRED\n" \
      "#{count} edit attempts failed. Your approach is wrong.\n" \
      "Research RESET + plan approval REVOKED. You MUST:\n" \
      "  1. Redo ALL 4 research categories (docs, web, github, local)\n" \
      "  2. Show a NEW plan and get user approval\n" \
      "This is the process that ALWAYS works when followed.\n" \
      "Reset: rr- (clear research), pa+ (approve plan)"
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
