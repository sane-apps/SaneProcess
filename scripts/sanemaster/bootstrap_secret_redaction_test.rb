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

  test('updates stale project ruby-version pins during bootstrap fix mode') do
    Dir.mktmpdir('sanemaster-ruby-version-') do |dir|
      old_pwd = Dir.pwd
      begin
        Dir.chdir(dir)
        File.write('.ruby-version', "3.4.7\n")
        BootstrapSecretRedactionHarness.new.send(:check_ruby_version_file, false, 'ruby 4.0.5 (2026-05-20)')

        assert_eq(File.read('.ruby-version'), "4.0.5\n")
      ensure
        Dir.chdir(old_pwd)
      end
    end
    true
  end

  test('check-only mode warns but does not change stale ruby-version pins') do
    Dir.mktmpdir('sanemaster-ruby-version-check-') do |dir|
      old_pwd = Dir.pwd
      begin
        Dir.chdir(dir)
        File.write('.ruby-version', "3.4.7\n")
        BootstrapSecretRedactionHarness.new.send(:check_ruby_version_file, true, 'ruby 4.0.5 (2026-05-20)')

        assert_eq(File.read('.ruby-version'), "3.4.7\n")
      ensure
        Dir.chdir(old_pwd)
      end
    end
    true
  end

  test('homebrew tool check treats missing tools as dependency issues') do
    source = File.read(File.expand_path('bootstrap.rb', __dir__), encoding: Encoding::UTF_8)

    assert_includes(source, 'missing = []')
    assert_includes(source, 'missing << tool if status == :missing')
    assert_includes(source, 'repair_tools = (missing + outdated).uniq')
    assert_includes(source, 'repair_tools.empty? ? :ok : (check_only ? :missing : :updated)')
    true
  end

  test('bundle check skips cleanly when the current directory has no Gemfile') do
    source = File.read(File.expand_path('bootstrap.rb', __dir__), encoding: Encoding::UTF_8)

    assert_includes(source, "unless File.exist?('Gemfile')")
    assert_includes(source, "Bundle: no Gemfile, skipped")
    true
  end

  test('required Ruby gems are checked even when there is no Gemfile') do
    source = File.read(File.expand_path('bootstrap.rb', __dir__), encoding: Encoding::UTF_8)
    base_source = File.read(File.expand_path('base.rb', __dir__), encoding: Encoding::UTF_8)

    assert_includes(base_source, 'REQUIRED_RUBY_GEMS')
    assert_includes(base_source, "'jwt' => 'App Store Connect submission helpers'")
    assert_includes(source, 'ruby_gems: check_required_ruby_gems(check_only)')
    assert_includes(source, 'def check_required_ruby_gems(check_only)')
    assert_includes(source, "'-S', 'gem', 'install', gem_name, '--no-document'")
    true
  end
end)
