#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

include TestFramework

exit(run_tests('SaneMaster Command Registry Tests') do
  test_category('registry metadata') do
    test('registry review exposes commands, gates, aliases, and route metadata') do
      result = SaneMaster.new.send(:build_registry_review)

      assert(result.dig(:summary, :command_count).positive?, 'expected commands in registry')
      assert(result.dig(:summary, :gate_count) >= 5, 'expected gate registry entries')
      assert(result.dig(:summary, :route_metadata_count).positive?, 'expected route metadata entries')
      assert(result[:commands].key?('verify'), 'expected verify command')
      assert_eq(result.dig(:commands, 'verify', :route_guard), 'proof_scope_sensitive')
      assert_eq(result.dig(:commands, 'release_preflight', :route_guard), 'release_only')
      assert(result[:commands].key?('release_readiness'), 'expected release_readiness command')
      assert(result[:commands].key?('context_bundle'), 'expected context_bundle command')
      assert_eq(result.dig(:commands, 'registry_review', :aliases), ['registry-review'])
      assert_eq(result.dig(:commands, 'context_bundle', :aliases), ['context-bundle'])
      assert(result[:gates].key?(:startup_gate), 'expected startup_gate registry')
      assert(result[:gates].key?(:visual_proof), 'expected visual_proof registry')
      assert(result.dig(:summary, :large_owner_count) >= 3, 'expected large owner registry entries')
      assert(result.dig(:summary, :must_split_owner_count).positive?, 'expected active must-split owners to stay visible')
      assert(result[:large_owners].key?('scripts/SaneMaster.rb'), 'expected SaneMaster router owner entry')
      assert_includes(result.dig(:large_owners, 'scripts/SaneMaster.rb', :split_target), 'dispatch')
      assert(result[:warnings].any? { |item| item.include?('scripts/SaneMaster.rb') }, result[:warnings].inspect)
      assert(result[:issues].empty?, result[:issues].inspect)
      true
    end

    test('registry aliases resolve through one canonical helper') do
      master = SaneMaster.new

      assert_eq(master.send(:canonical_command_name, 'registry-review'), 'registry_review')
      assert_eq(master.send(:canonical_command_name, 'context-bundle'), 'context_bundle')
      assert_eq(master.send(:canonical_command_name, 'crash_report'), 'crashes')
      assert_eq(master.send(:canonical_command_name, 'release-readiness'), 'release_readiness')
      assert_eq(master.send(:canonical_command_name, 'tool-receipt'), 'tool_discovery')
      assert_eq(master.send(:canonical_command_name, 'verify'), 'verify')
      true
    end

    test('dead memory commands are not advertised') do
      result = SaneMaster.new.send(:build_registry_review)
      dead_commands = %w[mc mr mp mh msync mcompact mcleanup]
      live_session_commands = %w[
        github_post_approval email_force_approval session_end reset_breaker
        breaker_status breaker_errors research_status research_lock
        research_unlock saneloop
      ]

      assert(!SaneMaster::COMMANDS.key?(:memory), 'memory category should not be advertised')
      assert(SaneMaster::COMMANDS.key?(:session), 'session category should own live state commands')
      dead_commands.each do |command|
        assert(!result[:commands].key?(command), "dead memory command still advertised: #{command}")
        assert(!SaneMaster::COMMAND_DETAILS.key?(command), "dead memory command has detailed help: #{command}")
      end
      live_session_commands.each do |command|
        assert_eq(result.dig(:commands, command, :category), 'session', "#{command} should be in session category")
      end
      true
    end

    test('help shows session commands without legacy memory sync') do
      stdout, stderr, status = Open3.capture3(
        { 'SANEMASTER_DISABLE_MINI_ROUTING' => '1' },
        'ruby',
        File.expand_path('../SaneMaster.rb', __dir__),
        'help',
        'session'
      )

      assert_eq(status.exitstatus, 0)
      assert_eq(stderr, '')
      assert_includes(stdout, 'session_end')
      assert_includes(stdout, 'saneloop')
      assert(!stdout.include?('msync'), 'session help should not advertise legacy memory sync')
      assert(!stdout.include?('mcompact'), 'session help should not advertise legacy memory compact')

      unknown_stdout, unknown_stderr, unknown_status = Open3.capture3(
        { 'SANEMASTER_DISABLE_MINI_ROUTING' => '1' },
        'ruby',
        File.expand_path('../SaneMaster.rb', __dir__),
        'help',
        'memory'
      )
      assert_eq(unknown_status.exitstatus, 0)
      assert_eq(unknown_stderr, '')
      assert_includes(unknown_stdout, "No detailed help available for 'memory'")
      assert(!unknown_stdout.include?('msync'), 'memory detail fallback should not advertise legacy memory sync')

      msync_stdout, msync_stderr, msync_status = Open3.capture3(
        { 'SANEMASTER_DISABLE_MINI_ROUTING' => '1' },
        'ruby',
        File.expand_path('../SaneMaster.rb', __dir__),
        'msync'
      )
      assert_eq(msync_status.exitstatus, 0)
      assert_includes("#{msync_stdout}\n#{msync_stderr}", 'Unknown command: msync')
      true
    end

    test('registry_review command prints JSON without expensive workflow execution') do
      stdout, stderr, status = Open3.capture3(
        { 'SANEMASTER_DISABLE_MINI_ROUTING' => '1' },
        'ruby',
        File.expand_path('../SaneMaster.rb', __dir__),
        'registry_review',
        '--json'
      )

      assert_eq(status.exitstatus, 0)
      assert_eq(stderr, '')
      payload = JSON.parse(stdout)
      assert(payload.dig('summary', 'command_count').positive?, 'expected registry summary')
      assert(payload.dig('summary', 'large_owner_count').positive?, 'expected large owner summary')
      assert(payload['issues'].empty?, payload['issues'].inspect)
      true
    end
  end
end)
