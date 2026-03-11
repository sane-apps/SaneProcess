#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'dependencies'

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
end)
