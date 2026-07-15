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

    test('requires AgentMemory to run through the self-healing supervisor') do
      supervised = <<~TEXT
        gui/501/com.saneapps.agentmemory = {
          state = running
          program = /Users/stephansmac/.local/libexec/sane-agentmemory-supervisor
        }
      TEXT
      assert(SaneAppsAirMiniAcceptance::Validators.agentmemory_service_supervised?(supervised))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_service_supervised?(supervised.sub('sane-agentmemory-supervisor', 'agentmemory')))
      true
    end

    test('requires the Air tunnel to be launchd-owned in foreground mode') do
      supervised = <<~TEXT
        gui/501/com.saneapps.agentmemory-tunnel = {
          state = running
          program = /Users/sj/SaneApps/infra/SaneProcess/scripts/automation/agentmemory-mcp-air.sh
          arguments = { --tunnel }
        }
      TEXT
      assert(SaneAppsAirMiniAcceptance::Validators.agentmemory_tunnel_supervised?(supervised))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_tunnel_supervised?(supervised.sub('state = running', 'state = exited')))
      true
    end

    test('requires healthy Air REST and a real search response') do
      health = "{\"service\":\"agentmemory\",\"status\":\"healthy\"}\nhttp=200\n"
      search = "{\"format\":\"compact\",\"results\":[{\"title\":\"SaneApps memory durability\"}]}\nhttp=200\n"
      assert(SaneAppsAirMiniAcceptance::Validators.agentmemory_rest_health?(health))
      assert(SaneAppsAirMiniAcceptance::Validators.agentmemory_search_response?(search))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_rest_health?(health.sub('healthy', 'degraded')))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_search_response?("{\"results\":[]}\nhttp=200\n"))
      assert(!SaneAppsAirMiniAcceptance::Validators.agentmemory_search_response?(search.sub('http=200', 'http=503')))
      true
    end

    test('accepts only redacted usable credential receipts') do
      receipt = "github-credential=available\nSummary: PASS=14 FAIL=0\n"
      assert(SaneAppsAirMiniAcceptance::Validators.credential_consumers_healthy?(receipt))
      assert(!SaneAppsAirMiniAcceptance::Validators.credential_consumers_healthy?(receipt.sub('FAIL=0', 'FAIL=1')))
      true
    end

    test('requires a real MCP initialize response') do
      response = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1}\nhttp=200\n"
      assert(SaneAppsAirMiniAcceptance::Validators.mcp_endpoint_healthy?(response))
      assert(!SaneAppsAirMiniAcceptance::Validators.mcp_endpoint_healthy?(response.sub('http=200', 'http=503')))
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
      %w[air-process-access air-agentmemory-tunnel air-agentmemory-health air-agentmemory-search
         air-mini-lan air-mini-tailscale mini-air-return mini-dependencies
         mini-power mini-weekly-restart mini-agentmemory-health air-github-credential
         mini-credential-consumers mini-mcp-apple-docs mini-mcp-macos-automator mini-mcp-serena mini-retired-training
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
