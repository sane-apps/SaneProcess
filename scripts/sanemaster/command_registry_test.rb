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
      assert_eq(master.send(:canonical_command_name, 'wsp'), 'webstore_preflight')
      assert_eq(master.send(:canonical_command_name, 'verify'), 'verify')
      true
    end

    test('upgrade proof is advertised and Mini-first') do
      assert(SaneMaster::COMMANDS.fetch(:build).fetch(:commands).key?('upgrade_path_proof'))
      assert(SaneMaster::MINI_FIRST_COMMANDS.include?('upgrade_path_proof'))
      true
    end

    test('customer UI sweep advertises routed execution evidence') do
      summary = SaneMaster::COMMANDS.fetch(:debug).fetch(:commands).fetch('customer_ui_sweep')
      detail = SaneMaster::COMMAND_DETAILS.fetch('customer_ui_sweep')
      assert_includes(summary[:args], '--execution-evidence PATH')
      assert_includes(detail[:usage], '--execution-evidence PATH')
      assert(detail[:examples].any? { |example| example.include?('--execution-evidence') })
      true
    end

    test('App Store help requires a fresh local package and retires remote build reuse') do
      summary = SaneMaster::COMMANDS.fetch(:build).fetch(:commands).fetch('appstore_preflight')
      detail = SaneMaster::COMMAND_DETAILS.fetch('appstore_preflight')
      assert_includes(summary[:args], '--pkg PATH')
      assert_includes(detail[:description], 'reuse is retired')
      assert(!detail[:examples].any? { |example| example.include?('--asc-build-id') })
      true
    end

    test('Chrome Web Store help binds package, listing, media, privacy, and reviewer evidence') do
      summary = SaneMaster::COMMANDS.fetch(:build).fetch(:commands).fetch('webstore_preflight')
      detail = SaneMaster::COMMAND_DETAILS.fetch('webstore_preflight')
      %w[--package --listing --media-dir --privacy-url].each do |flag|
        assert_includes(summary[:args], flag)
        assert_includes(detail[:usage], flag)
      end
      assert_includes(detail[:usage], '--review-instructions')
      true
    end

    test('actual App Store preflight CLI rejects retired ASC reuse before receipt signing') do
      output, status = Open3.capture2e(
        {
          'SANEMASTER_DISABLE_MINI_ROUTING' => '1',
          'SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT' => '1'
        },
        RbConfig.ruby,
        File.expand_path('../SaneMaster.rb', __dir__),
        'appstore_preflight',
        '--asc-build-id=build-123',
        '--build-number', '100'
      )

      assert(!status.success?, 'retired ASC reuse must fail before the canonical signer runs')
      assert_includes(output, 'Retired App Store preflight option(s): --asc-build-id, --build-number')
      assert_includes(output, 'exact remote bytes cannot be proven')
      assert_includes(output, 'create a fresh package')
      assert(!output.include?('unsupported canonical producer option'), 'operator must receive the actionable tombstone')
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
