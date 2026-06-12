#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'bootstrap'

class BootstrapSecretRedactionHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Bootstrap
end

include TestFramework

exit(run_tests('SaneMaster Bootstrap Secret Redaction Tests') do
  test('redacts secrets from mcp config snapshots') do
    Dir.mktmpdir('sanemaster-secret-snapshot-') do |dir|
      src = File.join(dir, '.mcp.json')
      dest = File.join(dir, 'snapshot', '.mcp.json')
      FileUtils.mkdir_p(File.dirname(dest))

      fake_token = ['github', '_pat_', 'fake_token_for_snapshot_redaction'].join
      private_key_header = ['-----BEGIN RSA', 'PRIVATE KEY-----'].join(' ')
      private_key_footer = ['-----END RSA', 'PRIVATE KEY-----'].join(' ')
      fake_private_key = [private_key_header, 'fake-key-body', private_key_footer].join("\n")

      File.write(
        src,
        JSON.pretty_generate(
          'mcpServers' => {
            'github' => {
              'env' => {
                'GITHUB_PERSONAL_ACCESS_TOKEN' => fake_token
              }
            },
            'signing' => {
              'env' => {
                'PRIVATE_KEY' => fake_private_key
              }
            }
          }
        )
      )

      BootstrapSecretRedactionHarness.new.send(:write_redacted_config_snapshot, src, dest)
      redacted = File.read(dest)
      parsed = JSON.parse(redacted)

      assert(!redacted.include?(fake_token), 'snapshot retained token literal')
      assert(!redacted.include?(private_key_header), 'snapshot retained private-key header')
      assert(!parsed.dig('mcpServers', 'github', 'env').key?('GITHUB_PERSONAL_ACCESS_TOKEN'),
             'snapshot retained token key')
      assert(!parsed.dig('mcpServers', 'signing', 'env').key?('PRIVATE_KEY'),
             'snapshot retained private-key key')
    end
    true
  end
end)
