#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

INSTALLER = File.expand_path('mini-install-agentmemory.sh', __dir__)

exit(run_tests('Mini AgentMemory Tests') do
  test_category('restart durability') do
    test('generates a private user LaunchAgent with restart guarantees') do
      Dir.mktmpdir('agentmemory-agent') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        plist = File.join(dir, 'com.saneapps.agentmemory.plist')
        log_dir = File.join(dir, 'logs')
        File.write(fake_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, fake_bin)
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => log_dir
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(status.success?, err)
        source = File.read(plist)
        assert_includes(source, '<string>com.saneapps.agentmemory</string>')
        assert_includes(source, '<string>/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>')
        assert_includes(source, '<key>RunAtLoad</key>')
        assert_includes(source, '<key>KeepAlive</key>')
        assert_includes(source, '<key>SuccessfulExit</key>')
        assert_includes(source, '<key>ThrottleInterval</key>')
        assert_includes(source, '<integer>30</integer>')
        assert_includes(source, '<key>WorkingDirectory</key>')
        assert_includes(source, "<string>#{dir}</string>")
        assert_includes(File.read(INSTALLER), "grep -Eq 'Health:[[:space:]].*healthy'")
        true
      end
    end
  end
end)
