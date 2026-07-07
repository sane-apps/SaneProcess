#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# gate_cert.rb — record a gate certifier verdict
# ==============================================================================
# Run by the GATE CERTIFIER subagent (protocol: ARCHITECTURE.md ADR-011) after it examines a
# blocked gate. Only `--verdict override` mints a signed clearing token; uphold
# and fill are logged for audit but grant nothing. Every override is a recorded
# vote that the gate is unfair (see gate_override.rb).
#
#   ruby scripts/sanemaster/gate_cert.rb --gate research --slug <lock-slug> \
#        --verdict override --note "apple-docs MCP is down; web+local done, gate failed to degrade"
# ==============================================================================

require 'optparse'
require 'digest'
require 'open3'
require_relative 'gate_override'

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

entry = SaneMasterModules::GateOverride.record(
  gate: options[:gate],
  slug: options[:slug],
  verdict: options[:verdict],
  note: options[:note],
  evidence_sha: evidence_sha
)

if options[:verdict] == 'override'
  hours = SaneMasterModules::GateOverride::DEFAULT_TTL_SECONDS / 3600
  puts "✅ Override recorded for #{options[:gate]}/#{options[:slug]} (id #{entry['id']}). " \
       "The gate will clear on the next run, for up to #{hours}h."
  banner = SaneMasterModules::GateOverride.unfair_banner(gate: options[:gate])
  puts banner if banner
else
  puts "📝 Logged '#{options[:verdict]}' verdict for #{options[:gate]}/#{options[:slug]} " \
       '(no override token minted; the deterministic gate still governs).'
end
