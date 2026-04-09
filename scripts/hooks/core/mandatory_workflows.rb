# frozen_string_literal: true

module MandatoryWorkflows
  WORKFLOWS = {
    docs_audit: {
      patterns: [
        /\b(docs[- ]?audit|\/docs-audit)\b/i,
        /\baudit\b.*\b(docs|documentation)\b/i,
        /\bdocumentation\s+audit\b/i,
        /\b14[- ]?perspective\b/i,
        /\bfull\s+audit\b/i
      ],
      requires_subagents: true,
      min_subagents: 5,
      description: 'Multi-perspective GPT subagent documentation audit'
    },
    evolve: {
      patterns: [
        /\b(evolve|\/evolve)\b/i,
        /\bupdate\s+(tools|dependencies|mcps?)\b/i,
        /\bcheck\s+for\s+updates\b/i,
        /\b(missing|lack|need)\s+(a\s+)?tool\b/i,
        /\bhunting\s+around\s+for\s+tools?\b/i,
        /\bbest\s+tools?\b/i,
        /\bwell[- ]document(ed|ation)\b/i,
        /\b(part\s+of\s+(our\s+)?)?sop\b.*\b(tools?|tooling)\b/i,
        /\b(tools?|tooling)\b.*\b(enforced|enforce)\b/i,
        /\bcanonical\s+tool\b/i,
        /\bstandard\s+tool\s+path\b/i,
        /\bworkaround\b/i,
        /\bduplicate\s+work\b/i,
        /\bfragment(ed|ation)\b/i,
        /\bwhat\s+(am\s+)?i\s+missing\b/i,
        /\bdo\s+we\s+already\s+have\b/i,
        /\binstall\s+(the\s+)?tool\b/i
      ],
      requires_runner: true,
      description: 'Tool discovery, upgrade, and gap check',
      runner_command: 'ruby scripts/SaneMaster.rb tool_discovery --query "..."',
      runner_patterns: [
        %r{SaneMaster\.rb\s+(?:tool_discovery|tool_receipt)\b}i,
        %r{scripts/automation/tool_discovery_receipt\.rb}i
      ]
    },
    status: {
      patterns: [
        %r{(?:^|\s)/status\b}i,
        /\b(run|check|project)\s+status\b/i,
        /\bwhat(?:'s| is)\s+the\s+status\b/i,
        /\bhealth\s+check\b/i
      ],
      requires_runner: true,
      description: 'Live status cross-reference workflow',
      runner_command: 'ruby scripts/SaneMaster.rb status',
      runner_patterns: [
        %r{SaneMaster\.rb\s+status\b}i,
        %r{scripts/automation/sane-status-crossref\.sh\b}i
      ]
    },
    verify: {
      patterns: [
        %r{(?:^|\s)/verify\b}i,
        /\bverify(?:\s+(?:this|the|that|current))?(?:\s+(?:project|app|repo|changes|build))?\b/i,
        /\bdoes\s+it\s+build\b/i,
        /\brun\s+(?:the\s+)?(?:verify|verification|checks?)\b/i
      ],
      requires_runner: true,
      description: 'Canonical build and test workflow',
      runner_command: 'ruby scripts/SaneMaster.rb verify',
      runner_patterns: [
        %r{SaneMaster\.rb\s+verify\b}i
      ]
    },
    ship: {
      patterns: [
        %r{(?:^|\s)/ship\b}i,
        /\bship\s+it\b/i,
        /\bprepare\s+for\s+release\b/i,
        /\bready\s+to\s+ship\b/i,
        /\brelease\s+(?:readiness|preflight|check)\b/i
      ],
      requires_runner: true,
      description: 'Release-readiness workflow',
      runner_command: 'ruby scripts/SaneMaster.rb release_preflight',
      runner_patterns: [
        %r{SaneMaster\.rb\s+release_preflight\b}i
      ]
    },
    check_inbox: {
      patterns: [
        %r{(?:^|\s)/(?:check-inbox|check_inbox)\b}i,
        /\bcheck\s+(?:the\s+)?inbox\b/i,
        /\bsupport\s+inbox\b/i,
        /\bcustomer\s+emails?\b/i,
        /\breply\s+to\s+customer\b/i
      ],
      requires_runner: true,
      description: 'Support inbox workflow',
      runner_command: 'ruby scripts/SaneMaster.rb check_inbox',
      runner_patterns: [
        %r{SaneMaster\.rb\s+check_inbox\b}i,
        %r{check-inbox\.sh\s+check\b}i
      ]
    },
    outreach: {
      patterns: [
        /\b(outreach|\/outreach)\b/i,
        /\bcompetitor\s+(monitoring|analysis)\b/i,
        /\bgithub\s+opportunities\b/i
      ],
      description: 'GitHub competitor monitoring'
    }
  }.freeze

  def self.skill_triggers
    WORKFLOWS.transform_values do |config|
      {
        patterns: config[:patterns],
        requires_subagents: config[:requires_subagents],
        min_subagents: config[:min_subagents] || 0,
        description: config[:description]
      }
    end
  end

  def self.skill_requirements
    WORKFLOWS.transform_values do |config|
      {
        min_subagents: config[:min_subagents] || 0,
        requires_runner: config[:requires_runner] || false,
        description: config[:description],
        runner_command: config[:runner_command]
      }
    end
  end

  def self.runner_patterns_for(name)
    Array(WORKFLOWS.dig(name.to_sym, :runner_patterns))
  end

  def self.runner_command_for(name)
    WORKFLOWS.dig(name.to_sym, :runner_command)
  end
end
