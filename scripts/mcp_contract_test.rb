#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'

include TestFramework

ROOT = File.expand_path('..', __dir__)

def server_source(relative_path)
  File.read(File.join(ROOT, relative_path))
end

def repo_path(relative_path)
  File.join(ROOT, relative_path)
end

exit(run_tests('SaneProcess MCP contract tests') do
  test_category('structured output') do
    test('central memory tools declare output schemas') do
      source = server_source('scripts/mcp-central-memory/server.mjs')

      %w[remember recall recent stats delete_by_external_id import_knowledge_graph].each do |tool_name|
        tool_index = source.index("name: '#{tool_name}'")
        assert(tool_index, "missing central-memory tool #{tool_name}")
        next_tool_index = source.index("\n  {\n    name:", tool_index + 1) || source.index("\n];", tool_index)
        tool_block = source[tool_index...next_tool_index]
        assert_includes(tool_block, 'outputSchema:')
      end
      true
    end

    test('central memory responses include structuredContent') do
      source = server_source('scripts/mcp-central-memory/server.mjs')

      assert_includes(source, 'structuredContent: payload')
      true
    end

    test('graph memory tools keep output schemas and structuredContent') do
      source = server_source('scripts/mcp-memory-enhanced/server.mjs')

      assert(source.scan('outputSchema:').length >= 8, 'expected graph-memory tools to declare output schemas')
      assert_includes(source, 'structuredContent:')
      true
    end
  end

  test_category('standard MCP surface') do
    test('check-mcps keeps central-memory optional and blocks legacy providers') do
      source = server_source('scripts/codex-bin/check-mcps')

      assert_includes(source, '"central-memory":')
      assert_match(source, /"central-memory": \{.*?optional: true/m, 'central-memory should not fail the standard MCP baseline when local Postgres is off')
      assert_includes(source, 'new Set(["nvidia-build", "gemini", "google", "google-gemini"])')
      assert_includes(source, 'legacy provider disabled for SaneApps')
      true
    end

    test('github bridge forwards json-line requests to server-github') do
      source = server_source('scripts/codex-bin/github-mcp-bridge.mjs')

      assert_includes(source, 'child.stdin.write(`${normalized}\\n`);')
      assert(!source.include?('child.stdin.write(encodeFramed(normalized));'), 'server-github hangs when parent JSON is forwarded as content-length frames')
      assert(!source.include?('GITHUB_SERVER_NPX_PKG'), 'GitHub bridge must not keep an npx package fallback')
      assert(!source.include?('command: "npx"'), 'GitHub bridge must not dynamically fetch server-github while carrying a GitHub token')
      assert_includes(source, 'GITHUB_SERVER_VERSION = "2025.4.8"')
      true
    end

    test('singleton bridge uses host home, stable node launch path, and minimal backend env') do
      source = server_source('scripts/mcp_singleton_bridge.cjs')

      assert_includes(source, 'const HOME = os.homedir();')
      assert_includes(source, 'function backendEnv(spec)')
      assert_includes(source, 'PATH: BACKEND_PATH')
      assert_includes(source, 'NODE_LAUNCH_EXECUTABLE')
      assert(!source.include?('...process.env'), 'singleton backends must not inherit unrelated parent secrets')
      assert(!source.include?('<string>${process.execPath}</string>'), 'LaunchAgents should not pin Homebrew Cellar node paths')
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
      bootstrap_guidance = [
        server_source('templates/NEW_PROJECT_TEMPLATE.md'),
        server_source('templates/FULL_PROJECT_BOOTSTRAP.md'),
        server_source('scripts/init.sh')
      ].join("\n")
      assert(!gitignore.include?('.gemini'), 'new projects should not ignore Gemini provider state as standard tooling')
      assert(!contamination.include?('.gemini/'), 'Gemini provider state should not be excluded from contamination checks')
      assert(!secret_scan.include?('.gemini/oauth_creds.json'), 'Gemini credentials should not be an active-access allowlist path')
      assert(!server_source('scripts/scaffold.rb').include?('Codex, Claude, Gemini'), 'new project instructions should not present Gemini as a standard agent')
      assert(!bootstrap_guidance.include?('npx -y @modelcontextprotocol/server-github'), 'bootstrap guidance must not teach dynamic GitHub MCP npx with token')
      assert(!bootstrap_guidance.match?(/"command":\s*"npx".{0,180}@modelcontextprotocol\/server-github/m), 'project templates must not configure GitHub MCP through npx')
      true
    end
  end
end)
