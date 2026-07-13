#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

include TestFramework

exit(run_tests('SaneMaster Command Alias Tests') do
  test_category('aliases') do
    test('aliases resolve through one canonical helper') do
      master = SaneMaster.new

      assert_eq(master.send(:canonical_command_name, 'context-bundle'), 'context_bundle')
      assert_eq(master.send(:canonical_command_name, 'crash_report'), 'crashes')
      assert_eq(master.send(:canonical_command_name, 'operator-brief'), 'operator_brief')
      assert_eq(master.send(:canonical_command_name, 'appointment'), 'business_appointment')
      assert_eq(master.send(:canonical_command_name, 'business-appointment'), 'business_appointment')
      assert_eq(master.send(:canonical_command_name, 'release-readiness'), 'release_readiness')
      assert_eq(master.send(:canonical_command_name, 'upgrade-path-proof'), 'upgrade_path_proof')
      assert_eq(master.send(:canonical_command_name, 'tool-receipt'), 'tool_discovery')
      assert_eq(master.send(:canonical_command_name, 'verify'), 'verify')
      true
    end

    test('upgrade proof is advertised and Mini-first') do
      assert(SaneMaster::COMMANDS.fetch(:build).fetch(:commands).key?('upgrade_path_proof'))
      assert(SaneMaster::MINI_FIRST_COMMANDS.include?('upgrade_path_proof'))
      true
    end

    test('removed registry review command is not advertised') do
      assert(!SaneMaster::COMMANDS.fetch(:check).fetch(:commands).key?('registry_review'))
      assert(!SaneMaster::COMMAND_DETAILS.key?('registry_review'))
      assert_eq(SaneMaster.new.send(:canonical_command_name, 'registry-review'), 'registry-review')
      true
    end
  end
end)
