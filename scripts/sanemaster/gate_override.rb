# frozen_string_literal: true

# ==============================================================================
# Gate Override + Unfair-Gate Self-Improvement
# ==============================================================================
# The deterministic research/verify gates (sop_loop.rb) are the FLOOR — they
# cannot be cleared by gaming (a research.md touch no longer counts; real
# tool-call evidence is required). This module is the OVERRIDE PATH: an
# evidence-grounded certifier (a fixed-prompt subagent — see gate_certifier.md)
# can certify that a block is genuinely UNFAIR and mint a signed override token.
# Certifier protocol: ARCHITECTURE.md ADR-011 (Gate Certifier).
#
# Anti-gaming properties:
#   - Tokens are HMAC-signed (StateSigner). A hand-edited overrides file fails
#     verification and grants nothing — only `gate_cert.rb` can mint one.
#   - The certifier's job for a LAZY block is to DO the missing research itself,
#     which satisfies the deterministic gate naturally (no token). So the only
#     thing that ever mints a token — and increments the unfair counter — is a
#     genuine false block.
#   - Every certification is logged (append-only) for audit.
#
# Self-improvement: each override is a vote that the gate is unfair. Once a gate
# crosses UNFAIR_THRESHOLD overrides it is auto-flagged in unfair-gates.json and
# the block message shouts "FIX THE GATE" — so unfair gates get fixed, not
# endlessly overridden, with no human having to watch for it.
# ==============================================================================

require 'json'
require 'time'
require 'fileutils'
require 'open3'
require 'securerandom'
require_relative '../hooks/state_signer'

module SaneMasterModules
  module GateOverride
    OVERRIDES_FILE = '.claude/gate-overrides.json'
    OVERRIDE_LOG = '.claude/gate-override-log.jsonl'
    UNFAIR_FILE = '.claude/unfair-gates.json'
    UNFAIR_THRESHOLD = 3          # overrides for one gate before it is flagged unfair
    DEFAULT_TTL_SECONDS = 7200    # an override clears the block for 2h, then must be re-earned
    # Verdicts that mint a clearing token. 'override' = the gate was WRONG (feeds
    # the unfair counter). 'resolved' = the gate armed CORRECTLY and the root
    # cause is since fixed+verified (clears the block but does NOT feed the
    # counter — merited post-fix clears must not pollute the self-improvement
    # signal; live 2026-07-07 the flag hit 5x with several merited clears).
    CLEARING_VERDICTS = %w[override resolved].freeze

    module_function

    # Record a certifier verdict. 'override' and 'resolved' mint a clearing
    # token; 'uphold' (block was fair) and 'fill' (certifier did the missing
    # work) are logged for audit but grant nothing. Only 'override' feeds the
    # unfair counter. 'resolved' must cite the fix commit (an existing sha) in
    # its note or it raises ArgumentError. Returns the recorded entry.
    def record(gate:, slug:, verdict:, note:, evidence_sha: nil,
               certified_by: 'gate-certifier', now: Time.now, ttl_seconds: DEFAULT_TTL_SECONDS)
      if verdict.to_s == 'resolved' && !resolved_note_cites_fix_commit?(note)
        raise ArgumentError,
              'resolved verdict requires the note to cite the fix commit (a sha that exists in this repo)'
      end

      entry = {
        'id' => SecureRandom.hex(8),
        'gate' => gate.to_s,
        'slug' => slug.to_s,
        'verdict' => verdict.to_s,
        'note' => note.to_s,
        'evidence_sha' => evidence_sha,
        'certified_by' => certified_by.to_s,
        'certified_at' => now.utc.iso8601,
        'ttl_seconds' => ttl_seconds.to_i
      }
      append_log(entry)

      if CLEARING_VERDICTS.include?(entry['verdict'])
        store = load_store
        store['overrides'] = prune(store['overrides'], now: now)
        store['overrides'] << entry
        write_store(store)
        # Only 'override' is a vote that the gate is unfair; a 'resolved' clear
        # affirms the gate was right and the underlying problem got fixed.
        refresh_unfair(gate: entry['gate'], now: now) if entry['verdict'] == 'override'
      end

      entry
    end

    # A 'resolved' clear is a stronger claim than an override — "the gate was
    # right, and HERE is the fix" — so it must cite at least one commit sha
    # that actually exists in this repo. Fails closed: unverifiable citations
    # (no sha, unknown sha, not a git repo) reject the verdict.
    def resolved_note_cites_fix_commit?(note)
      # map+compact-free scan; must stay Ruby 2.6-compatible.
      note.to_s.scan(/\b[0-9a-f]{7,40}\b/i).any? do |sha|
        _out, status = Open3.capture2e('git', 'cat-file', '-e', "#{sha}^{commit}")
        status.success?
      end
    rescue StandardError
      false
    end

    # True when a valid, unexpired, signed clearing token (override OR resolved)
    # covers this gate+slug and is fresh relative to this block's trigger.
    # Read-only (no consume), so it is safe to call from status/display paths
    # as well as the gate.
    def clears?(gate:, slug:, trigger_time:, now: Time.now)
      gate = gate.to_s
      slug = slug.to_s
      load_store['overrides'].any? do |override|
        next false unless override['gate'] == gate && override['slug'] == slug
        next false unless CLEARING_VERDICTS.include?(override['verdict'])

        certified = parse_time(override['certified_at'])
        next false if certified.nil?
        next false if now < certified                  # future-dated → forged / clock skew
        next false if now - certified > ttl_for(override) # expired

        trigger_time.nil? || certified > trigger_time  # must post-date the block it clears
      end
    rescue StandardError
      false
    end

    def unfair?(gate:)
      entry = load_unfair[gate.to_s]
      !entry.nil? && entry['count'].to_i >= UNFAIR_THRESHOLD
    rescue StandardError
      false
    end

    # One-line banner for the block message / status when a gate is flagged unfair.
    def unfair_banner(gate:)
      entry = load_unfair[gate.to_s]
      return nil unless entry && entry['count'].to_i >= UNFAIR_THRESHOLD

      "⚠️  GATE FLAGGED UNFAIR: '#{gate}' was certifier-overridden #{entry['count']}× " \
        "(last #{entry['last_at']}). Self-improvement signal — FIX THE GATE, do not keep " \
        "overriding it. Affected: #{Array(entry['slugs']).uniq.join(', ')}."
    rescue StandardError
      nil
    end

    # --- internals -----------------------------------------------------------

    def ttl_for(override)
      ttl = override['ttl_seconds'].to_i
      ttl.positive? ? ttl : DEFAULT_TTL_SECONDS
    end

    def load_store
      data = StateSigner.read_verified(OVERRIDES_FILE)
      data = {} unless data.is_a?(Hash)
      data['overrides'] = [] unless data['overrides'].is_a?(Array)
      data
    rescue StandardError
      { 'overrides' => [] }
    end

    def write_store(store)
      StateSigner.write_signed(OVERRIDES_FILE, store)
    end

    def prune(overrides, now:)
      Array(overrides).select do |override|
        certified = parse_time(override['certified_at'])
        certified && (now - certified) <= ttl_for(override)
      end
    end

    def append_log(entry)
      FileUtils.mkdir_p(File.dirname(OVERRIDE_LOG))
      File.open(OVERRIDE_LOG, 'a') { |file| file.puts(JSON.generate(entry)) }
    rescue StandardError
      nil
    end

    def refresh_unfair(gate:, now:)
      # Count only true 'override' votes — 'resolved' clears affirm the gate.
      overrides = load_store['overrides'].select do |override|
        override['gate'] == gate && override['verdict'] == 'override'
      end
      return if overrides.length < UNFAIR_THRESHOLD

      timestamps = overrides.map { |override| override['certified_at'] }.compact
      data = load_unfair
      data[gate] = {
        'count' => overrides.length,
        'first_at' => timestamps.min,
        'last_at' => timestamps.max,
        'slugs' => overrides.map { |override| override['slug'] }.uniq,
        'flagged_at' => now.utc.iso8601
      }
      FileUtils.mkdir_p(File.dirname(UNFAIR_FILE))
      File.write(UNFAIR_FILE, JSON.pretty_generate(data))
    rescue StandardError
      nil
    end

    def load_unfair
      return {} unless File.exist?(UNFAIR_FILE)

      parsed = JSON.parse(File.read(UNFAIR_FILE))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def parse_time(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
