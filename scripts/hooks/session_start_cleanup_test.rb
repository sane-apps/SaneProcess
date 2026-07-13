#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests the dev-server reaper's ALLOWLIST classifier (the risk surface). It must match only ephemeral agent
# test-harness servers and NEVER a build or a user's own server. Pure — spawns no processes.
require 'minitest/autorun'
require_relative 'session_start_cleanup'

class DevServerReapClassifierTest < Minitest::Test
  class Host
    include SessionStartCleanup
    def log_debug(*); end
  end

  def setup
    @h = Host.new
  end

  def test_matches_only_ephemeral_agent_test_servers
    matches = [
      'node /Users/sj/SaneApps/websites/sanecite-saas/dev/mockserver.mjs',
      'node /Users/sj/SaneApps/websites/sanecite-saas/dev/entserver.mjs',
      'node /Users/sj/SaneApps/websites/otherapp/dev/qaserver.mjs',
      # the REAL macOS framework-Python command form (capital P, no version digits) — must still match
      '/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -m http.server 8898',
      'python3 -m http.server 8823 --directory /Users/sj/SaneApps/websites/sanecite.com',
      'python3 -m http.server 8899'
    ]
    matches.each { |cmd| assert @h.dev_server_candidate?(cmd), "should MATCH: #{cmd}" }
  end

  def test_never_matches_builds_or_user_servers
    safe = [
      'wrangler dev',
      'npx wrangler dev --local',
      'npm run dev',
      'node /Users/sj/project/node_modules/.bin/next dev',
      'node vite',
      'python3 -m http.server 8000',    # outside the 8800-8899 QA range
      'python3 -m http.server 3000',
      'python3 -m http.server',         # no port
      'node /Users/sj/myproject/server.js',
      'node /Users/sj/SaneApps/websites/app/src/index.js',  # a worker, not a dev/*server*.mjs
      'xcodebuild -scheme SaneBar build',
      '/Applications/Docker.app/Contents/MacOS/com.docker.build',
      'ruby session_start_cleanup_test.rb',
      'grep -nE http.server 8823',      # a grep line
      'bash reap-dev-servers.sh --kill', # the reaper itself
      nil,
      ''
    ]
    safe.each { |cmd| refute @h.dev_server_candidate?(cmd), "should NOT match: #{cmd.inspect}" }
  end
end
