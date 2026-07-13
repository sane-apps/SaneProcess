# frozen_string_literal: true

# ==============================================================================
# Hammer Watch — detect re-hitting a gate without doing the work
# ==============================================================================
# The mirror of the unfair-gate detector (gate_override.rb). The unfair detector
# catches "the GATE is wrong" (repeated certifier overrides). This catches "the
# AGENT is lazy" (repeated blocks with no new work between them) — the pattern of
# hammering a gate until it passes instead of reading it and doing what it says.
#
# How: each time a gate blocks, we fingerprint the *work state* — the research
# tool-call completion timestamps (.claude/state.json) plus the working-tree diff.
# If the SAME gate blocks again with an IDENTICAL fingerprint, nothing was done
# between attempts: no fresh research, no code change, no certifier verdict. That
# is a hammer. A CHANGING fingerprint means real iteration and is never flagged,
# so legitimate work (edit -> re-run -> edit -> re-run) never trips it.
#
# After HAMMER_THRESHOLD no-progress hits the gate is flagged and the block
# message shouts it, with a signed, tamper-evident record (gate-hits.json) and an
# append-only audit log so the user has a mechanical signal — they do not have to
# watch the agent to know it is hammering.
# ==============================================================================

require 'json'
require 'time'
require 'fileutils'
require 'digest'
require 'open3'
require_relative '../hooks/state_signer'

module SaneMasterModules
  module HammerWatch
    HITS_FILE = '.claude/gate-hits.json'
    HAMMER_LOG = '.claude/gate-hammer-log.jsonl'
    HAMMER_THRESHOLD = 3 # blocked this many times with zero new work between = hammering

    module_function

    # Record a block on `gate` with a fingerprint of the current work state.
    # Returns the consecutive no-progress streak (1 = first hit, or first after
    # real progress). An empty/nil fingerprint is treated as "could not measure"
    # and never accrues a streak (fail-safe: never accuse on missing data).
    def record_block(gate:, fingerprint:, now: Time.now)
      gate = gate.to_s
      store = load_store
      entry = store[gate] || {}

      if fingerprint.to_s.empty?
        entry['streak'] = 0
      elsif entry['fingerprint'] == fingerprint
        entry['streak'] = entry['streak'].to_i + 1
      else
        entry['streak'] = 1
        entry['fingerprint'] = fingerprint
        entry['streak_started_at'] = now.utc.iso8601
      end

      entry['last_hit_at'] = now.utc.iso8601
      entry['total_hits'] = entry['total_hits'].to_i + 1
      store[gate] = entry
      write_store(store)
      append_log('gate' => gate, 'streak' => entry['streak'], 'fingerprint' => fingerprint, 'at' => entry['last_hit_at'])
      entry['streak'].to_i
    rescue StandardError
      0
    end

    # Reset the streak when the gate is passed — progress was made, so any prior
    # hammering is resolved.
    def clear(gate:, now: Time.now)
      gate = gate.to_s
      store = load_store
      return unless store.key?(gate)

      store[gate]['streak'] = 0
      store[gate]['cleared_at'] = now.utc.iso8601
      write_store(store)
    rescue StandardError
      nil
    end

    def hammering?(gate:)
      (load_store[gate.to_s] || {})['streak'].to_i >= HAMMER_THRESHOLD
    rescue StandardError
      false
    end

    def banner(gate:)
      entry = load_store[gate.to_s]
      return nil unless entry && entry['streak'].to_i >= HAMMER_THRESHOLD

      "🔁 HAMMERING DETECTED: '#{gate}' has been hit #{entry['streak']}× with NO new work between " \
        "attempts (no fresh research tool-calls, no diff change, no certifier verdict since " \
        "#{entry['streak_started_at']}). Re-running will NOT help — READ THE GATE and either DO the " \
        'prescribed work or run the certifier (ARCHITECTURE.md ADR-011). This is logged.'
    rescue StandardError
      nil
    end

    # Fingerprint of "did real work happen": research completion timestamps +
    # the working-tree diff. Stable across a no-op re-run; changes the moment any
    # research tool-call fires or any file changes.
    def current_fingerprint
      diff, = Open3.capture2('git', 'diff', '--stat')
      Digest::SHA256.hexdigest("#{research_completed_digest}\n#{diff}")
    rescue StandardError
      nil
    end

    # --- internals -----------------------------------------------------------

    def research_completed_digest
      path = File.join('.claude', 'state.json')
      return '' unless File.exist?(path)

      data = JSON.parse(File.read(path, encoding: Encoding::UTF_8), symbolize_names: true)
      research = data[:research] || data.dig(:data, :research) || {}
      return '' unless research.is_a?(Hash)

      %i[web docs local github].map do |category|
        entry = research[category]
        entry.is_a?(Hash) ? "#{category}:#{entry[:completed_at] || entry['completed_at']}" : "#{category}:nil"
      end.join('|')
    rescue StandardError
      ''
    end

    def load_store
      data = StateSigner.read_verified(HITS_FILE)
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_store(store)
      StateSigner.write_signed(HITS_FILE, store)
    rescue StandardError
      nil
    end

    def append_log(entry)
      FileUtils.mkdir_p(File.dirname(HAMMER_LOG))
      File.open(HAMMER_LOG, 'a') { |file| file.puts(JSON.generate(entry)) }
    rescue StandardError
      nil
    end
  end
end
