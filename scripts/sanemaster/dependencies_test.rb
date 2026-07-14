#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'dependencies'
require 'open3'

class DependenciesHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Dependencies
end

include TestFramework

CODEX_APP_SERVER = '/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled'

def process_row(pid:, ppid:, etimes:, command:, cpu: 0.0, state: 'S')
  {
    pid: pid,
    ppid: ppid,
    etimes: etimes,
    cpu: cpu,
    state: state,
    command: command
  }
end

def build_analysis(subject, rows, max_per_server: 4, per_codex_server_cap: 1)
  process_index = rows.each_with_object({}) do |row, memo|
    memo[row[:pid]] = row.dup
  end

  snapshot = subject.send(:build_mcp_process_snapshot, process_index)
  subject.send(
    :analyze_mcp_processes,
    snapshot,
    max_per_server,
    per_codex_server_cap: per_codex_server_cap
  )
end

def build_cleanup_plan(subject, analysis, max_per_server: 4, duplicate_grace_seconds: 90)
  subject.send(
    :plan_mcp_cleanup,
    analysis,
    max_per_server,
    duplicate_grace_seconds: duplicate_grace_seconds
  )
end

exit(run_tests('SaneMaster MCP Watchdog Tests') do
  subject = DependenciesHarness.new

  test_category('Per-Codex MCP dedupe') do
    test('trims duplicate memory backends but keeps one Serena tree') do
      rows = [
        process_row(pid: 100, ppid: 1, etimes: 600, command: CODEX_APP_SERVER),
        process_row(pid: 200, ppid: 100, etimes: 400, command: '/usr/local/bin/node /Users/sj/SaneApps/infra/SaneProcess/scripts/mcp-memory-enhanced/server.mjs'),
        process_row(pid: 201, ppid: 100, etimes: 40, command: '/usr/local/bin/node /Users/sj/SaneApps/infra/SaneProcess/scripts/mcp-memory-enhanced/server.mjs'),
        process_row(pid: 210, ppid: 100, etimes: 300, command: '/Users/sj/.local/bin/uv tool uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code --project-from-cwd'),
        process_row(pid: 211, ppid: 210, etimes: 295, command: '/Users/sj/.cache/uv/archive-v0/bin/python /Users/sj/.cache/uv/archive-v0/bin/serena start-mcp-server --context claude-code --project-from-cwd')
      ]

      analysis = build_analysis(subject, rows)
      memory_group = analysis[:duplicate_codex_groups].find { |group| group[:server] == 'memory' }

      assert(memory_group, 'expected duplicate memory instances under one Codex session')
      assert_eq(memory_group[:count], 2, 'expected two memory backend instances')
      assert_eq(
        analysis[:duplicate_codex_groups].count { |group| group[:server] == 'serena' },
        0,
        'single Serena backend tree should not count as a duplicate'
      )

      cleanup = build_cleanup_plan(subject, analysis)
      assert_includes(cleanup[:pids], 200, 'older duplicate memory instance should be trimmed')
      assert(!cleanup[:pids].include?(201), 'newest memory instance should survive')
      assert(!cleanup[:pids].include?(210), 'single Serena launcher should survive')
      assert(!cleanup[:pids].include?(211), 'single Serena child should survive')
      true
    end
  end

  test_category('Cross-session tolerance') do
    test('allows one backend per session across multiple Codex roots') do
      rows = [
        process_row(pid: 100, ppid: 1, etimes: 600, command: CODEX_APP_SERVER),
        process_row(pid: 101, ppid: 1, etimes: 500, command: CODEX_APP_SERVER),
        process_row(pid: 220, ppid: 100, etimes: 120, command: '/usr/local/bin/node /Users/sj/Dev/apple-docs-mcp-local/dist/index.js'),
        process_row(pid: 221, ppid: 101, etimes: 140, command: '/usr/local/bin/node /Users/sj/Dev/apple-docs-mcp-local/dist/index.js')
      ]

      analysis = build_analysis(subject, rows)
      cleanup = build_cleanup_plan(subject, analysis)

      assert_eq(analysis[:duplicate_codex_groups].length, 0, 'one backend per session should be allowed')
      assert_eq(cleanup[:pids], [], 'cross-session backends should not be trimmed')
      true
    end

    test('ignores singleton bridge wrappers and tracks only their backends') do
      rows = [
        process_row(pid: 500, ppid: 1, etimes: 600, command: '/usr/local/bin/node /Users/sj/SaneApps/infra/SaneProcess/scripts/mcp_singleton_bridge.cjs serve apple-docs'),
        process_row(pid: 501, ppid: 500, etimes: 590, command: '/usr/local/bin/node /Users/sj/Dev/apple-docs-mcp-local/dist/index.js'),
        process_row(pid: 510, ppid: 1, etimes: 600, command: '/usr/local/bin/node /Users/sj/SaneApps/infra/SaneProcess/scripts/mcp_singleton_bridge.cjs serve macos-automator'),
        process_row(pid: 511, ppid: 510, etimes: 590, command: '/usr/local/bin/node /Users/sj/.npm-global/lib/node_modules/@steipete/macos-automator-mcp/dist/server.js')
      ]

      analysis = build_analysis(subject, rows)

      assert_eq(analysis[:orphan_instances].length, 0, 'bridge wrappers should not create orphan MCP instances')
      assert_eq(analysis[:by_server]['apple-docs'], 1, 'only the apple-docs backend should be counted')
      assert_eq(analysis[:by_server]['macos-automator'], 1, 'only the macos-automator backend should be counted')
      true
    end
  end

  test_category('Codex sidecar cleanup') do
    test('detects stale thermlog and idle release sidecars conservatively') do
      rows = [
        process_row(pid: 100, ppid: 1, etimes: 600, command: CODEX_APP_SERVER),
        process_row(pid: 300, ppid: 100, etimes: 180, command: '/bin/zsh -lc pmset -g thermlog | tail -n 40'),
        process_row(pid: 301, ppid: 1, etimes: 180, command: '/bin/zsh -lc pmset -g thermlog | tail -n 40'),
        process_row(pid: 400, ppid: 100, etimes: 3700, cpu: 0.0, command: 'ruby /Users/sj/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb release --full --version 2.2.9'),
        process_row(pid: 401, ppid: 400, etimes: 3600, cpu: 0.0, command: 'ssh mini ruby /Users/stephansmac/.sanemaster/routed-workspaces/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb release --full --version 2.2.9'),
        process_row(pid: 402, ppid: 100, etimes: 3700, cpu: 2.4, command: 'ruby /Users/sj/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb release --full --version 2.2.10')
      ]

      analysis = build_analysis(subject, rows)
      cleanup = build_cleanup_plan(subject, analysis)
      eligible_sidecars = analysis[:codex_sidecars].select { |sidecar| sidecar[:cleanup_eligible] }

      assert_includes(eligible_sidecars.map { |sidecar| sidecar[:pid] }, 300, 'Codex-owned thermlog watcher should be eligible')
      assert_includes(eligible_sidecars.map { |sidecar| sidecar[:pid] }, 400, 'idle stale release parent should be eligible')
      assert_includes(eligible_sidecars.map { |sidecar| sidecar[:pid] }, 401, 'idle stale release ssh child should be eligible')
      assert(!eligible_sidecars.any? { |sidecar| sidecar[:pid] == 301 }, 'non-Codex thermlog watcher should be ignored')
      assert(!eligible_sidecars.any? { |sidecar| sidecar[:pid] == 402 }, 'active release should not be auto-killed')

      assert_includes(cleanup[:pids], 300, 'cleanup should trim Codex thermlog watcher')
      assert_includes(cleanup[:pids], 400, 'cleanup should trim stale release parent')
      assert_includes(cleanup[:pids], 401, 'cleanup should trim stale release ssh child')
      assert(!cleanup[:pids].include?(402), 'cleanup should not kill active release jobs')
      true
    end
  end

  test_category('Ruby subprocess env') do
    test('compares Ruby versions semantically for toolchain gates') do
      assert(subject.send(:ruby_version_at_least?, '4.0.5', '4.0.0'), '4.0.5 should satisfy 4.0.0')
      assert(subject.send(:ruby_version_at_least?, '4.1.0', '4.0.5'), '4.1.0 should satisfy 4.0.5')
      assert(!subject.send(:ruby_version_at_least?, '3.4.7', '4.0.0'), '3.4.7 should not satisfy 4.0.0')
      assert(!subject.send(:ruby_version_at_least?, '4.0.0', '4.0.1'), '4.0.0 should not satisfy 4.0.1')
      true
    end

    test('prepends the Homebrew Ruby bin to subprocess PATH once') do
      Dir.mktmpdir('ruby-env-') do |dir|
        ruby_bin = File.join(dir, 'ruby')
        bundle_bin = File.join(dir, 'bundle')
        File.write(ruby_bin, "#!/bin/sh\nexit 0\n")
        File.write(bundle_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, ruby_bin)
        FileUtils.chmod(0o755, bundle_bin)

        subject.define_singleton_method(:homebrew_ruby_path) { ruby_bin }
        subject.define_singleton_method(:homebrew_bundle_path) { bundle_bin }

        env = subject.send(:ruby_tool_env, { 'PATH' => '/usr/bin:/bin' })
        entries = env.fetch('PATH').split(File::PATH_SEPARATOR)

        assert_eq(entries.first, dir)
        assert_eq(entries.count(dir), 1)
      end
      true
    end

    test('prepends the Homebrew Ruby gem bin when gem-installed tools are present') do
      Dir.mktmpdir('ruby-env-gems-') do |dir|
        gem_bin = File.join(dir, 'gems', 'bin')
        FileUtils.mkdir_p(gem_bin)
        ruby_bin = File.join(dir, 'ruby')
        bundle_bin = File.join(dir, 'bundle')
        File.write(ruby_bin, "#!/bin/sh\nexit 0\n")
        File.write(bundle_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, ruby_bin)
        FileUtils.chmod(0o755, bundle_bin)

        subject.define_singleton_method(:homebrew_ruby_path) { ruby_bin }
        subject.define_singleton_method(:homebrew_bundle_path) { bundle_bin }
        subject.define_singleton_method(:homebrew_ruby_gem_bin) { gem_bin }

        env = subject.send(:ruby_tool_env, { 'PATH' => '/usr/bin:/bin' })
        entries = env.fetch('PATH').split(File::PATH_SEPARATOR)

        assert_eq(entries[0], dir)
        assert_eq(entries[1], gem_bin)
        assert_eq(entries.count(dir), 1)
        assert_eq(entries.count(gem_bin), 1)
      end
      true
    end

    test('runs bundle-like subprocesses with the Homebrew Ruby bin first in PATH') do
      Dir.mktmpdir('ruby-env-capture-') do |dir|
        ruby_bin = File.join(dir, 'ruby')
        bundle_bin = File.join(dir, 'bundle')
        File.write(ruby_bin, "#!/bin/sh\nexit 0\n")
        File.write(bundle_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, ruby_bin)
        FileUtils.chmod(0o755, bundle_bin)

        subject.define_singleton_method(:homebrew_ruby_path) { ruby_bin }
        subject.define_singleton_method(:homebrew_bundle_path) { bundle_bin }

        output, status = subject.send(:capture2e_with_ruby_env, '/bin/sh', '-c', 'printf %s "$PATH"')

        assert(status.success?, 'expected PATH probe command to succeed')
        assert_eq(output.split(File::PATH_SEPARATOR).first, dir)
      end
      true
    end

    test('merges extra env without dropping the Homebrew Ruby PATH') do
      Dir.mktmpdir('ruby-env-extra-') do |dir|
        ruby_bin = File.join(dir, 'ruby')
        bundle_bin = File.join(dir, 'bundle')
        File.write(ruby_bin, "#!/bin/sh\nexit 0\n")
        File.write(bundle_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, ruby_bin)
        FileUtils.chmod(0o755, bundle_bin)

        subject.define_singleton_method(:homebrew_ruby_path) { ruby_bin }
        subject.define_singleton_method(:homebrew_bundle_path) { bundle_bin }

        output, status = subject.send(
          :capture2e_with_ruby_env,
          '/bin/sh',
          '-c',
          'printf "%s\n%s" "$BUNDLE_PATH" "$PATH"',
          extra_env: { 'BUNDLE_PATH' => 'vendor/bundle' }
        )

        lines = output.lines.map(&:strip)
        assert(status.success?, 'expected env probe command to succeed')
        assert_eq(lines[0], 'vendor/bundle')
        assert_eq(lines[1].split(File::PATH_SEPARATOR).first, dir)
      end
      true
    end

    test('defaults bundle subprocesses to vendor bundle path') do
      Dir.mktmpdir('ruby-env-bundle-') do |dir|
        ruby_bin = File.join(dir, 'ruby')
        bundle_bin = File.join(dir, 'bundle')
        File.write(ruby_bin, "#!/bin/sh\nexit 0\n")
        File.write(bundle_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, ruby_bin)
        FileUtils.chmod(0o755, bundle_bin)

        subject.define_singleton_method(:homebrew_ruby_path) { ruby_bin }
        subject.define_singleton_method(:homebrew_bundle_path) { bundle_bin }

        output, status = subject.send(:capture2e_with_bundle_env, '/bin/sh', '-c', 'printf %s "$BUNDLE_PATH"')

        assert(status.success?, 'expected bundle env probe command to succeed')
        assert_eq(output, 'vendor/bundle')
      end
      true
    end

    test('SaneMaster re-execs through Homebrew Ruby before loading modules') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__), encoding: Encoding::UTF_8)
      require_index = source.index("require_relative 'sanemaster/base'")
      reexec_index = source.index('exec(SANEMASTER_HOMEBREW_RUBY, $PROGRAM_NAME, *ARGV)')

      assert(reexec_index, 'expected SaneMaster to re-exec through Homebrew Ruby')
      assert(require_index && reexec_index < require_index, 'Ruby re-exec must happen before module loading')
      assert_includes(source, "SANEMASTER_REQUIRED_RUBY_VERSION = ENV.fetch('SANEPROCESS_REQUIRED_RUBY_VERSION', '4.0.0')")
      assert_includes(source, "ENV['SANEMASTER_SKIP_RUBY_REEXEC'] != '1'")
      true
    end

    test('installer prompts for Ruby and bundle dependency repairs') do
      source = File.read(File.expand_path('../init.sh', __dir__), encoding: Encoding::UTF_8)

      assert_includes(source, 'REQUIRED_RUBY_VERSION="${SANEPROCESS_REQUIRED_RUBY_VERSION:-4.0.0}"')
      assert_includes(source, 'REQUIRED_RUBY_GEMS="${SANEPROCESS_REQUIRED_RUBY_GEMS:-jwt}"')
      assert_includes(source, 'prompt_dependency_update "Homebrew Ruby $ruby_version is older than required ${REQUIRED_RUBY_VERSION}+." "brew update && brew upgrade ruby"')
      assert_includes(source, 'prompt_dependency_update "Ruby gem \'$gem_name\' is required for SaneProcess automation." "$RUBY_CMD -S gem install $gem_name --no-document"')
      assert_includes(source, 'prompt_dependency_update "Ruby gems are missing or stale for this project." "$BUNDLE_CMD install"')
      assert_includes(source, '"$RUBY_CMD" -c "scripts/hooks/$hook"')
      true
    end
  end

  test_category('Configured MCP discovery') do
    test('unions project and active-client MCP config surfaces') do
      Dir.mktmpdir('mcp-config-surfaces-') do |dir|
        File.write(File.join(dir, '.mcp.json'), '{"mcpServers":{"apple-docs":{}}}')
        File.write(File.join(dir, 'claude-settings.json'), '{"permissions":{"allow":["mcp__github__search_repositories"]}}')
        File.write(File.join(dir, 'codex.toml'), "[mcp_servers.context7]\ncommand = \"context7\"\n")
        File.write(File.join(dir, 'grok.toml'), "[mcp_servers.memory]\ncommand = \"memory\"\n[mcp_servers.memory.env]\nTOKEN = \"redacted\"\n")

        subject.define_singleton_method(:mcp_config_paths) do
          [
            File.join(dir, '.mcp.json'),
            File.join(dir, 'claude-settings.json'),
            File.join(dir, 'codex.toml'),
            File.join(dir, 'grok.toml')
          ]
        end

        servers = subject.send(:configured_mcp_servers)
        assert_includes(servers, 'apple-docs')
        assert_includes(servers, 'github')
        assert_includes(servers, 'context7')
        assert_includes(servers, 'memory')
        assert(!servers.include?('memory.env'), 'TOML env subsections must not become MCP servers')
      end
      true
    end
  end

  test_category('MCP singleton bridge') do
    test('generates LaunchAgent plists with the current Node executable') do
      bridge = File.expand_path('../mcp_singleton_bridge.cjs', __dir__)
      node = '/opt/homebrew/opt/node@24/bin/node'
      assert(File.executable?(node), "expected Node executable at #{node}")

      output, status = Open3.capture2e(node, bridge, 'plist', 'apple-docs')
      assert(status.success?, output)
      assert_includes(output, node)
      assert(!output.include?('/opt/homebrew/bin/node'), 'singleton plists must not pin the removed unversioned Homebrew Node path')
      assert(!output.include?('/usr/local/bin/node'), 'singleton plists must not pin the removed Intel Homebrew Node path')
      true
    end

    test('doctor reports live Codex probe failures even when MCP processes exist') do
      rows = [
        process_row(pid: 100, ppid: 1, etimes: 600, command: '/opt/homebrew/bin/node /Users/sj/SaneApps/infra/SaneProcess/scripts/mcp_singleton_bridge.cjs serve serena'),
        process_row(pid: 101, ppid: 100, etimes: 590, command: '/Users/sj/.local/bin/uv tool uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code --project-from-cwd')
      ]

      subject.define_singleton_method(:configured_mcp_servers) { ['serena'] }
      subject.define_singleton_method(:mcp_live_probe_snapshot) do
        {
          available: true,
          command: '/Users/sj/.codex/bin/check-mcps',
          results: [
            { status: 'FAIL', name: 'serena', detail: 'fetch failed' }
          ]
        }
      end

      analysis = build_analysis(subject, rows)
      doctor = subject.send(:mcp_watchdog_doctor, analysis, 6)

      assert_includes(doctor[:running_servers], 'serena')
      assert_eq(doctor[:live_probe_failures].length, 1)
      assert_eq(doctor[:live_probe_failures].first[:name], 'serena')
      true
    end
  end

  test_category('LaunchAgent defaults') do
    test('mcp watchdog install defaults to a five minute interval') do
      source = File.read(File.expand_path('dependencies.rb', __dir__))
      assert_includes(source, 'interval_seconds = 300')
      true
    end
  end
end)
