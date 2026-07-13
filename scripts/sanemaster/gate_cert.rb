#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# gate_cert.rb — record a gate certifier verdict
# ==============================================================================
# Run by the GATE CERTIFIER subagent (protocol: ARCHITECTURE.md ADR-011) after it examines a
# blocked gate. `--verdict override` and `--verdict resolved` mint a signed
# clearing token; uphold and fill are logged for audit but grant nothing.
# Every OVERRIDE is a recorded vote that the gate is unfair; RESOLVED affirms
# the gate armed correctly and the root cause is since fixed — it clears the
# block without feeding the unfair counter, and its note MUST cite the fix
# commit (a sha that exists in this repo). See gate_override.rb.
#
#   ruby scripts/sanemaster/gate_cert.rb --gate research --slug <lock-slug> \
#        --verdict override --note "apple-docs MCP is down; web+local done, gate failed to degrade"
#   ruby scripts/sanemaster/gate_cert.rb --gate verify-escalation --slug verify \
#        --verdict resolved --note "both strikes were the release_route kwargs bug, fixed in 9debc41"
# ==============================================================================

require 'optparse'
require 'digest'
require 'open3'
require_relative 'gate_override'

options = { gate: nil, slug: nil, verdict: nil, note: '' }
OptionParser.new do |parser|
  parser.banner = 'Usage: gate_cert.rb --gate G --slug S --verdict {override|uphold|fill|resolved} --note "..."'
  parser.on('--gate GATE', 'Gate id (e.g. research, verify-escalation)') { |v| options[:gate] = v }
  parser.on('--slug SLUG', 'Block slug (lock slug, or "verify")') { |v| options[:slug] = v }
  parser.on('--verdict V', %w[override uphold fill resolved],
            'override | uphold | fill | resolved (resolved = gate was right, root cause fixed; note must cite the fix commit)') { |v| options[:verdict] = v }
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

begin
  entry = SaneMasterModules::GateOverride.record(
    gate: options[:gate],
    slug: options[:slug],
    verdict: options[:verdict],
    note: options[:note],
    evidence_sha: evidence_sha
  )
rescue ArgumentError => e
  abort("gate_cert: #{e.message}")
end

hours = SaneMasterModules::GateOverride::DEFAULT_TTL_SECONDS / 3600
case options[:verdict]
when 'override'
  puts "✅ Override recorded for #{options[:gate]}/#{options[:slug]} (id #{entry['id']}). " \
       "The gate will clear on the next run, for up to #{hours}h."
  banner = SaneMasterModules::GateOverride.unfair_banner(gate: options[:gate])
  puts banner if banner
when 'resolved'
  puts "✅ Resolved-clear recorded for #{options[:gate]}/#{options[:slug]} (id #{entry['id']}). " \
       "The gate will clear on the next run, for up to #{hours}h. " \
       'Gate armed correctly and the cited fix is in; this does NOT feed the unfair counter.'
else
  puts "📝 Logged '#{options[:verdict]}' verdict for #{options[:gate]}/#{options[:slug]} " \
       '(no override token minted; the deterministic gate still governs).'
end
