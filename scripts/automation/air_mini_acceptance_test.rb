#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'air_mini_acceptance'
require 'json'
require 'open3'

include TestFramework

SCRIPT = File.expand_path('air_mini_acceptance.rb', __dir__)

exit(run_tests('Air Mini Acceptance Tests') do
  test_category('pure validators') do
    test('accepts the converged runtime versions and rejects stale ones') do
      current = <<~TEXT
        node=v24.18.0
        npm=11.16.0
        ruby=ruby 4.0.6
        python=Python 3.14.6
        tailscale=1.98.8
        codex=codex-cli 0.144.4
        claude=2.1.209 (Claude Code)
      TEXT
      assert(SaneAppsAirMiniAcceptance::Validators.versions_current?(current))
      assert(!SaneAppsAirMiniAcceptance::Validators.versions_current?(current.sub('v24.', 'v25.')))
      true
    end

    test('requires the complete always-on power contract') do
      current = " sleep 0\n displaysleep 0\n disksleep 0\n autorestart 1\n"
      assert(SaneAppsAirMiniAcceptance::Validators.power_current?(current))
      assert(!SaneAppsAirMiniAcceptance::Validators.power_current?(current.sub('sleep 0', 'sleep 1')))
      true
    end

    test('requires healthy AgentMemory with the preserved corpus') do
      current = "Connected — v0.9.27\nHealth: ✓ healthy\nMemories: 1,201\nEmbeddings: ✓ embeddings\n"
      assert(SaneAppsAirMiniAcceptance::Validators.agentmemory_healthy?(current))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_healthy?(current.sub('1,201', '1,200')))
      true
    end

    test('requires exact Air Mini origin repository parity') do
      sha = 'a' * 40
      assert(SaneAppsAirMiniAcceptance::Validators.repo_parity?([sha, sha, sha].join("\n")))
      assert(!SaneAppsAirMiniAcceptance::Validators.repo_parity?([sha, 'b' * 40, sha].join("\n")))
      true
    end
  end

  test_category('safe deterministic plan') do
    test('covers restart, private routes, sync, dependencies, and parity without production mutation') do
      stdout, stderr, status = Open3.capture3('/opt/homebrew/opt/ruby/bin/ruby', SCRIPT, '--plan')
      assert(status.success?, stderr)
      plan = JSON.parse(stdout)
      ids = plan.map { |entry| entry.fetch('id') }
      %w[air-process-access air-mini-lan air-mini-tailscale mini-air-return mini-dependencies
         mini-power mini-weekly-restart mini-agentmemory-health mini-retired-training
         saneprocess-parity sanecite-parity memory-checksum-parity acceptance-contracts].each do |id|
        assert(ids.include?(id), "missing plan check #{id}")
      end
      serialized = JSON.generate(plan)
      %w[shutdown reboot upload deploy release notarize rm\ -rf].each do |forbidden|
        assert(!serialized.match?(/#{Regexp.escape(forbidden)}/i), "unsafe plan token: #{forbidden}")
      end
      true
    end
  end
end)
