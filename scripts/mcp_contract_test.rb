#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'automation/dependency_baseline'
require 'json'
require 'open3'
require 'yaml'

include TestFramework

ROOT = File.expand_path('..', __dir__)

def server_source(relative_path)
  File.read(File.join(ROOT, relative_path))
end

def repo_path(relative_path)
  File.join(ROOT, relative_path)
end

exit(run_tests('SaneProcess MCP contract tests') do
  test_category('standard MCP surface') do
    test('project GitHub MCP uses the Node 24 credential bridge') do
      source = server_source('.mcp.json')
      config = JSON.parse(source)
      github = config.fetch('mcpServers').fetch('github')

      assert_eq(github.fetch('command'), '/opt/homebrew/opt/node@24/bin/node')
      assert_eq(github.fetch('args'), ['scripts/codex-bin/github-mcp-bridge.mjs'])
      assert(!github.key?('env'), 'project config must not inject raw GitHub credentials')
      assert(!source.include?('${GITHUB_TOKEN}'), 'project config must not reference a raw GitHub token')
      assert(File.executable?(github.fetch('command')), 'configured Node 24 command must be executable')
      assert(File.file?(repo_path(github.fetch('args').first)), 'configured GitHub bridge must exist')
      true
    end

    test('project manifest advertises canonical commands and actual MCPs') do
      project_mcp = JSON.parse(server_source('.mcp.json')).fetch('mcpServers').keys.sort
      manifest = YAML.safe_load(server_source('.saneprocess'))

      assert_eq(manifest.dig('commands', 'verify'), 'ruby scripts/SaneMaster.rb verify')
      assert_eq(manifest.dig('commands', 'test'), 'ruby scripts/qa.rb')
      assert_eq(manifest.fetch('mcps').sort, project_mcp)
      manifest.fetch('commands').values.each do |command|
        script = command.split.find { |part| part.start_with?('scripts/') }
        assert(File.file?(repo_path(script)), "manifest command target must exist: #{script}") if script
      end
      true
    end

    test('configured executable paths and singleton endpoints resolve') do
      servers = JSON.parse(server_source('.mcp.json')).fetch('mcpServers')
      servers.each do |name, config|
        command = config['command']
        next unless command

        if command.start_with?('/')
          assert(File.executable?(command), "#{name} command is not executable: #{command}")
        else
          resolved, status = Open3.capture2e('/usr/bin/which', command)
          assert(status.success? && File.executable?(resolved.strip), "#{name} command does not resolve: #{command}")
        end
      end

      node = '/opt/homebrew/opt/node@24/bin/node'
      bridge = repo_path('scripts/mcp_singleton_bridge.cjs')
      output, status = Open3.capture2e(node, bridge, 'list')
      assert(status.success?, output)
      %w[apple-docs macos-automator xcode].each do |name|
        assert_includes(output, "#{name}\thttp://127.0.0.1:")
        assert_includes(output, servers.fetch(name).fetch('url'))
      end
      true
    end

    test('Xcode MCP uses the Mini HTTP singleton, not a fresh Air SSH') do
      servers = JSON.parse(server_source('.mcp.json')).fetch('mcpServers')
      xcode = servers.fetch('xcode')
      assert_eq(xcode.fetch('type'), 'http')
      assert_eq(xcode.fetch('url'), 'http://127.0.0.1:37915/mcp')
      assert(!xcode.key?('command'), 'Air/project xcode MCP must not spawn local mcpbridge')

      wrapper = server_source('scripts/grok-bin/xcode-mcp.sh')
      assert_includes(wrapper, '--framed')
      assert_includes(wrapper, '127.0.0.1:37915')
      assert_includes(wrapper, 'xcode-mcp.sh" --framed')

      frame = repo_path('scripts/grok-bin/xcode-mcp-frame.py')
      output, status = Open3.capture2e('/usr/bin/python3', frame, '--self-test')
      assert(status.success?, output)

      bridge = server_source('scripts/mcp_singleton_bridge.cjs')
      assert_includes(bridge, 'port: 37915')
      assert_includes(bridge, "homePath('.grok', 'bin', 'xcode-mcp.sh')")
      assert_includes(bridge, 'args: []')
      true
    end

    test('singleton LaunchAgents use Node 24 and bounded failure recovery') do
      node = '/opt/homebrew/opt/node@24/bin/node'
      bridge = repo_path('scripts/mcp_singleton_bridge.cjs')
      output, status = Open3.capture2e(node, bridge, 'plist', 'macos-automator')

      assert(status.success?, output)
      assert_includes(output, '<string>/opt/homebrew/opt/node@24/bin/node</string>')
      assert_match(output, %r{<key>KeepAlive</key>\s*<dict>\s*<key>SuccessfulExit</key>\s*<false/>\s*</dict>})
      assert_match(output, %r{<key>ThrottleInterval</key>\s*<integer>60</integer>})
      assert_includes(server_source('scripts/mcp_singleton_bridge.cjs'), '@steipete/macos-automator-mcp@0.4.6')
      true
    end

    test('MCP package pins agree across dependency consumers') do
      pins = SaneAppsDependencyBaseline::NPM_VERSIONS
      expectations = {
        'scripts/mcp_singleton_bridge.cjs' => %w[@mweinbach/apple-docs-mcp @steipete/macos-automator-mcp],
        'scripts/sanemaster/dependencies.rb' => %w[@mweinbach/apple-docs-mcp @modelcontextprotocol/server-github @upstash/context7-mcp @steipete/macos-automator-mcp],
        'scripts/init.sh' => %w[@mweinbach/apple-docs-mcp @modelcontextprotocol/server-github @upstash/context7-mcp @steipete/macos-automator-mcp]
      }

      expectations.each do |path, packages|
        source = server_source(path)
        packages.each do |package|
          assert_includes(source, "#{package}@#{pins.fetch(package)}")
        end
      end
      true
    end

    test('check-mcps does not revive retired memory servers and blocks legacy providers') do
      source = server_source('scripts/codex-bin/check-mcps')

      assert(!source.include?('"central-memory":'), 'central-memory must not be a default health probe')
      assert_includes(source, 'if (configured[name]?.enabled === false) continue;')
      assert(!source.match?(/^\s+memory:\s*\{/), 'knowledge-graph memory must not be a default health probe')
      assert_includes(source, 'new Set(["nvidia-build", "gemini", "google", "google-gemini"])')
      assert_includes(source, 'legacy provider disabled for SaneApps')
      true
    end

    test('singleton inventory excludes the retired knowledge-graph server') do
      source = server_source('scripts/mcp_singleton_bridge.cjs')
      baseline = server_source('scripts/automation/dependency_baseline.rb')

      assert(!source.match?(/^\s+memory:\s*\{/), 'retired memory singleton remains active')
      assert_includes(baseline, '@modelcontextprotocol/server-memory')
      assert_match(baseline, /FORBIDDEN_GLOBAL_NPM.*@modelcontextprotocol\/server-memory/)
      true
    end

    test('github bridge forwards json-line requests to server-github') do
      source = server_source('scripts/codex-bin/github-mcp-bridge.mjs')

      assert_includes(source, 'child.stdin.write(`${normalized}\\n`);')
      assert(!source.include?('child.stdin.write(encodeFramed(normalized));'), 'server-github hangs when parent JSON is forwarded as content-length frames')
      assert_includes(source, 'GITHUB_SERVER_VERSION = "2025.4.8"')
      assert_includes(source, '"/opt/homebrew/lib/node_modules"')
      true
    end

    test('singleton bridge uses host home and launch-safe backend PATH') do
      source = server_source('scripts/mcp_singleton_bridge.cjs')

      assert_includes(source, 'const HOME = os.homedir();')
      assert_includes(source, 'function backendEnv(spec)')
      assert_includes(source, 'PATH: BACKEND_PATH')
      assert(!source.include?('/Users/sj'), 'singleton bridge must not hardcode the Air home path')
      assert(!source.include?('/Users/stephansmac'), 'singleton bridge must not hardcode the Mini home path')
      true
    end

    test('legacy NVIDIA and Google provider paths are not shipped as active helpers') do
      forbidden_paths = %w[
        scripts/automation/nv-audit.sh
        scripts/automation/nv-buildlog.sh
        scripts/automation/nv-readme-check.sh
        scripts/automation/nv-relnotes.sh
        scripts/automation/nv-tests.sh
        scripts/git-hooks/pre-commit-review
        scripts/git-hooks/install-hooks
      ]

      forbidden_paths.each do |path|
        assert(!File.exist?(repo_path(path)), "#{path} should not exist in the standard SaneApps tooling surface")
      end

      gitignore = server_source('templates/gitignore')
      contamination = server_source('scripts/contamination_check.rb')
      secret_scan = server_source('scripts/sanemaster/secret_scan.rb')
      assert(!gitignore.include?('.gemini'), 'new projects should not ignore Gemini provider state as standard tooling')
      assert(!contamination.include?('.gemini/'), 'Gemini provider state should not be excluded from contamination checks')
      assert(!secret_scan.include?('.gemini/oauth_creds.json'), 'Gemini credentials should not be an active-access allowlist path')
      true
    end
  end
end)
