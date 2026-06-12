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
      assert_eq(result.dig(:commands, 'registry_review', :aliases), ['registry-review'])
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
      assert_eq(master.send(:canonical_command_name, 'crash_report'), 'crashes')
      assert_eq(master.send(:canonical_command_name, 'tool-receipt'), 'tool_discovery')
      assert_eq(master.send(:canonical_command_name, 'verify'), 'verify')
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
