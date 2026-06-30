#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# gate_cert.rb — record a gate certifier verdict
# ==============================================================================
# Run by the GATE CERTIFIER subagent (protocol: ARCHITECTURE.md ADR-011) after it examines a
# blocked gate. Only `--verdict override` mints a signed clearing token. A
# research/verify `fill` records signed research evidence after the certifier has
# done the missing work, but still grants no override token. Every override is a
# recorded vote that the gate is unfair (see gate_override.rb).
#
#   ruby scripts/sanemaster/gate_cert.rb --gate research --slug <lock-slug> \
#        --verdict fill --note "read code, searched web, updated .claude/research.md"
#
# Rare false-block override:
#   ruby scripts/sanemaster/gate_cert.rb --gate research --slug <lock-slug> \
#        --verdict override --note "web+local were done; gate used stale trigger"
# ==============================================================================

require 'optparse'
require 'digest'
require 'open3'
require_relative 'gate_override'
require_relative '../hooks/core/state_manager'
require_relative '../hooks/sanetools_research'

options = { gate: nil, slug: nil, verdict: nil, note: '' }
OptionParser.new do |parser|
  parser.banner = 'Usage: gate_cert.rb --gate G --slug S --verdict {override|uphold|fill} --note "..."'
  parser.on('--gate GATE', 'Gate id (e.g. research, verify-escalation)') { |v| options[:gate] = v }
  parser.on('--slug SLUG', 'Block slug (lock slug, or "verify")') { |v| options[:slug] = v }
  parser.on('--verdict V', %w[override uphold fill], 'override | uphold | fill') { |v| options[:verdict] = v }
  parser.on('--note NOTE', 'Why (audit trail; be specific)') { |v| options[:note] = v }
end.parse!(ARGV)

missing = %i[gate slug verdict].reject { |key| options[key] }
abort("gate_cert: missing required option(s): #{missing.join(', ')}") if missing.any?

# Bind the certification to the real working state for the audit trail (recorded,
# not used as a hard gate match).
def evidence_sha
  diff, = Open3.capture2('git', 'diff', '--stat')
  state = File.exist?('.claude/state.json') ? File.read('.claude/state.json') : ''
  Digest::SHA256.hexdigest("#{diff}\n#{state}")
rescue StandardError
  nil
end

def research_fill_categories(gate)
  return [] unless %w[research verify-escalation].include?(gate.to_s)

  categories = %i[web local]
  probe = Class.new { include SaneToolsResearch }.new
  categories << :docs if probe.configured_mcp_keys.include?(:apple_docs)
  categories
rescue StandardError
  %i[web local]
end

def record_research_fill_evidence!(gate:, slug:, note:)
  categories = research_fill_categories(gate)
  return [] if categories.empty?

  now = Time.now.iso8601
  note_sha = Digest::SHA256.hexdigest(note.to_s)[0, 16]
  StateManager.update(:research) do |research|
    categories.each do |category|
      research[category] = {
        completed_at: now,
        tool: 'gate_cert:fill',
        via_task: true,
        slug: slug.to_s,
        note_sha: note_sha
      }
    end
    research
  end

  categories
end

entry = SaneMasterModules::GateOverride.record(
  gate: options[:gate],
  slug: options[:slug],
  verdict: options[:verdict],
  note: options[:note],
  evidence_sha: evidence_sha
)

filled_categories = if options[:verdict] == 'fill'
                      record_research_fill_evidence!(
                        gate: options[:gate],
                        slug: options[:slug],
                        note: options[:note]
                      )
                    else
                      []
                    end

if options[:verdict] == 'override'
  hours = SaneMasterModules::GateOverride::DEFAULT_TTL_SECONDS / 3600
  puts "✅ Override recorded for #{options[:gate]}/#{options[:slug]} (id #{entry['id']}). " \
       "The gate will clear on the next run, for up to #{hours}h."
  banner = SaneMasterModules::GateOverride.unfair_banner(gate: options[:gate])
  puts banner if banner
else
  detail = if filled_categories.any?
             "signed research evidence recorded for #{filled_categories.join(', ')}; "
           else
             ''
           end
  puts "📝 Logged '#{options[:verdict]}' verdict for #{options[:gate]}/#{options[:slug]} " \
       "(#{detail}no override token minted; the deterministic gate still governs)."
end
