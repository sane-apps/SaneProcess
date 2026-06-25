#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneProjectRoot - Single Source of Truth for State Path Resolution
# ==============================================================================
# THE STATE SPLIT-BRAIN FIX.
#
# The shell hook-activation gates in .claude/settings.json fire a hook only when
# the tool's CURRENT WORKING DIRECTORY contains a `.saneprocess` file:
#
#     if ... [ -f .saneprocess ] ...; then ruby .../session_start.rb; fi
#
# But the Ruby hooks historically keyed ALL state to
# `ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd`. When a session's CLAUDE_PROJECT_DIR is
# an umbrella directory like /Users/sj/SaneApps (which has NO `.saneprocess`),
# `session_start` never runs there (no reset, no log rotation) — yet PreToolUse
# hooks still WROTE state to /Users/sj/SaneApps/.claude/state.json. A circuit-
# breaker trip recorded in that shared umbrella file then blocked unrelated
# sessions working in *different* repos, and the breaker-recovery loop (a green
# verify / `rb-` reset) operated on a *different* file than the one that tripped.
# Result: repeated cross-repo "ghost trips".
#
# THE FIX: every Ruby state/bypass/research/deployment path derivation resolves
# the project root through this ONE function, which walks up to the nearest
# ancestor directory containing a `.saneprocess` file — exactly the directory the
# shell gates key on. Ruby state resolution and shell gate activation now agree.
#
# Resolution order (first match wins):
#   1. The nearest `.saneprocess` ancestor of `start` (default Dir.pwd) — exactly
#      the directory the shell hook gate keys on. This is the branch that fixes
#      the umbrella split-brain: cwd is the real repo, CLAUDE_PROJECT_DIR is the
#      marker-less umbrella, so state lands in the repo. It also keeps deep
#      subdirectory cwds anchored to the same root the shell gate would find.
#   2. CLAUDE_PROJECT_DIR's nearest `.saneprocess` ancestor, when set AND when
#      that env dir actually sits under a `.saneprocess` root. This supports
#      test harnesses and non-repo cwd callers without letting env state steal
#      a hook that fired in another marked repo.
#   3. CLAUDE_PROJECT_DIR (if set, even without a marker) — historical fallback
#      for non-SaneProcess projects, unchanged.
#   4. Dir.pwd.
#
# Usage:
#   require_relative 'core/project_root'
#   SaneProjectRoot.resolve                  # => "/path/to/repo-with-.saneprocess"
#   SaneProjectRoot.resolve('/some/other')   # explicit start dir (rarely needed)
#   SaneProjectRoot.claude_dir               # => "<root>/.claude"
#
# Zero heavy deps (no JSON, no state, no network). Safe to require from any hook.
# ==============================================================================

module SaneProjectRoot
  MARKER = '.saneprocess'

  # The SaneProcess repo that OWNS these running hooks. project_root.rb lives at
  # <repo>/scripts/hooks/core/, so three levels up is the repo root. Used to
  # detect "we are developing SaneProcess itself" — you cannot meaningfully gate
  # the repo that defines the gates (the startup/research/MCP gates would just
  # fight every edit to the hooks). Resolved once at load; never changes.
  HOOKS_REPO_ROOT = File.expand_path('../../..', __dir__)

  class << self
    # Resolve the canonical project root for state-path derivation.
    #
    # Memoized per-process keyed by the resolved start directory so that the
    # common no-arg call is computed once. Pass `start` explicitly only when a
    # caller needs to resolve relative to a directory other than the process cwd.
    def resolve(start = nil)
      origin = normalize_start(start)
      @cache ||= {}
      @cache[origin] ||= compute(origin)
    end

    # Convenience: "<root>/.claude"
    def claude_dir(start = nil)
      File.join(resolve(start), '.claude')
    end

    # True when the resolved root actually carries a `.saneprocess` marker.
    # Lets SaneApps-only gates (deployment, MCP, startup) stay scoped to real
    # SaneProcess projects without re-deriving the path inline.
    def saneprocess_project?(start = nil)
      File.exist?(File.join(resolve(start), MARKER))
    end

    # True when the active session is editing the SaneProcess repo that owns
    # these very hooks. The workflow/context gates (startup, research-before-edit,
    # MCP verification, subagent-research) are bypassed in this case: bootstrapping
    # gates onto the repo that DEFINES them only fights development. Safety guards
    # (blocked paths, secrets, release/email/security, mini-first) still apply.
    # Apps that merely carry a `.saneprocess` marker are NOT self-development —
    # only the hooks' own repo matches.
    def self_development?(start = nil)
      resolve(start) == HOOKS_REPO_ROOT
    end

    # Test/maintenance hook: drop the per-process memo. Production code never
    # needs this (cwd is stable within a hook invocation); tests that simulate
    # multiple project roots in one process call it between scenarios.
    def reset!
      @cache = {}
    end

    private

    def normalize_start(start)
      candidate = start
      candidate = candidate.to_s if candidate
      candidate = nil if candidate&.empty?
      # Expand so the memo key and the walk both use an absolute, symlink-stable
      # path. File.expand_path never raises here (no filesystem access).
      File.expand_path(candidate || Dir.pwd)
    rescue StandardError
      Dir.pwd
    end

    def compute(origin)
      env_dir = env_project_dir

      # 1. Walk up from the cwd-origin to the nearest `.saneprocess` ancestor —
      #    exactly the directory the shell hook gate keys on. This must win over
      #    CLAUDE_PROJECT_DIR when both point at marked but different repos,
      #    because the hook fired in cwd, not in the env-selected repo.
      if (root = nearest_marker_ancestor(origin))
        return root
      end

      # 2. No marked cwd: honor a declared env project when it has a marker.
      #    This keeps test harnesses and explicit non-repo callers working while
      #    avoiding cross-repo state theft for real hook invocations.
      if env_dir && (root = nearest_marker_ancestor(env_dir))
        return root
      end

      # 3. No `.saneprocess` anywhere: preserve the historical fallback so
      #    behavior is unchanged for non-SaneProcess projects
      #    (CLAUDE_PROJECT_DIR if set, else the process cwd).
      env_dir || origin
    end

    # Walk from `dir` up to '/' returning the first directory that contains a
    # `.saneprocess` file, or nil if none is found. Pure path + File.exist?
    # checks; no file contents are read.
    def nearest_marker_ancestor(dir)
      current = File.expand_path(dir)
      loop do
        return current if File.exist?(File.join(current, MARKER))

        parent = File.dirname(current)
        break if parent == current # reached filesystem root

        current = parent
      end
      nil
    rescue StandardError
      nil
    end

    def env_project_dir
      value = ENV['CLAUDE_PROJECT_DIR']
      return nil if value.nil? || value.empty?

      File.expand_path(value)
    rescue StandardError
      nil
    end
  end
end

# === SELF-TEST / CLI ===
if __FILE__ == $PROGRAM_NAME
  if ARGV.include?('--self-test')
    require 'fileutils'
    require 'tmpdir'

    passed = 0
    failed = 0
    check = lambda do |name, ok|
      if ok
        passed += 1
        warn "  PASS: #{name}"
      else
        failed += 1
        warn "  FAIL: #{name}"
      end
    end

    warn 'SaneProjectRoot Self-Test'
    warn '=' * 40

    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, 'repo')
      nested = File.join(repo, 'a', 'b', 'c')
      umbrella = File.join(tmp, 'umbrella')
      sibling = File.join(tmp, 'umbrella', 'other-repo')
      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(sibling)
      File.write(File.join(repo, SaneProjectRoot::MARKER), "schema: 1\n")
      File.write(File.join(sibling, SaneProjectRoot::MARKER), "schema: 1\n")

      # 1. Nested cwd resolves UP to the repo that has the marker.
      SaneProjectRoot.reset!
      check.call('nested cwd resolves to .saneprocess root',
                 SaneProjectRoot.resolve(nested) == File.expand_path(repo))

      # 2. Marker root resolves to itself.
      SaneProjectRoot.reset!
      check.call('marker dir resolves to itself',
                 SaneProjectRoot.resolve(repo) == File.expand_path(repo))

      # 3. THE SPLIT-BRAIN CASE: cwd is an umbrella dir with no marker, but
      #    CLAUDE_PROJECT_DIR points at a real repo → resolve to the repo, not
      #    the umbrella. (Historically wrote state to the umbrella.)
      SaneProjectRoot.reset!
      old = ENV['CLAUDE_PROJECT_DIR']
      ENV['CLAUDE_PROJECT_DIR'] = sibling
      check.call('umbrella cwd + repo CLAUDE_PROJECT_DIR resolves to repo',
                 SaneProjectRoot.resolve(umbrella) == File.expand_path(sibling))
      ENV['CLAUDE_PROJECT_DIR'] = old

      # 4. No marker anywhere + CLAUDE_PROJECT_DIR set → historical fallback.
      SaneProjectRoot.reset!
      plain = File.join(tmp, 'plain', 'deep')
      FileUtils.mkdir_p(plain)
      old = ENV['CLAUDE_PROJECT_DIR']
      ENV['CLAUDE_PROJECT_DIR'] = File.join(tmp, 'plain')
      check.call('no marker falls back to CLAUDE_PROJECT_DIR',
                 SaneProjectRoot.resolve(plain) == File.expand_path(File.join(tmp, 'plain')))
      ENV['CLAUDE_PROJECT_DIR'] = old

      # 5. No marker + no env → Dir.pwd-style origin.
      SaneProjectRoot.reset!
      old = ENV['CLAUDE_PROJECT_DIR']
      ENV.delete('CLAUDE_PROJECT_DIR')
      check.call('no marker + no env falls back to start dir',
                 SaneProjectRoot.resolve(plain) == File.expand_path(plain))
      ENV['CLAUDE_PROJECT_DIR'] = old if old

      # 6. saneprocess_project? reflects the resolved root.
      SaneProjectRoot.reset!
      check.call('saneprocess_project? true under marker',
                 SaneProjectRoot.saneprocess_project?(nested) == true)
      SaneProjectRoot.reset!
      old = ENV['CLAUDE_PROJECT_DIR']
      ENV.delete('CLAUDE_PROJECT_DIR')
      check.call('saneprocess_project? false without marker',
                 SaneProjectRoot.saneprocess_project?(plain) == false)
      ENV['CLAUDE_PROJECT_DIR'] = old if old

      # 7. If env and cwd are different marked repos, cwd wins because that is
      #    the repo whose .saneprocess shell gate fired.
      SaneProjectRoot.reset!
      repo_a = File.join(tmp, 'repo-a')
      repo_b = File.join(tmp, 'repo-b')
      FileUtils.mkdir_p([repo_a, repo_b])
      File.write(File.join(repo_a, SaneProjectRoot::MARKER), "schema: 1\n")
      File.write(File.join(repo_b, SaneProjectRoot::MARKER), "schema: 1\n")
      old = ENV['CLAUDE_PROJECT_DIR']
      ENV['CLAUDE_PROJECT_DIR'] = repo_a
      check.call('marked cwd beats different marked CLAUDE_PROJECT_DIR',
                 SaneProjectRoot.resolve(repo_b) == File.expand_path(repo_b))
      ENV['CLAUDE_PROJECT_DIR'] = old if old

      # 8. self_development? is true only for the hooks' own repo, false for a
      #    different marked repo (e.g. an app that merely carries .saneprocess).
      SaneProjectRoot.reset!
      check.call('self_development? false for a different marked repo',
                 SaneProjectRoot.self_development?(repo_a) == false)
      SaneProjectRoot.reset!
      check.call('self_development? true for the hooks own repo root',
                 SaneProjectRoot.self_development?(SaneProjectRoot::HOOKS_REPO_ROOT) == true)
    end

    warn ''
    warn "#{passed}/#{passed + failed} tests passed"
    warn(failed.zero? ? 'ALL TESTS PASSED' : "#{failed} TESTS FAILED")
    exit(failed.zero? ? 0 : 1)
  elsif ARGV.include?('--show')
    warn "resolve:           #{SaneProjectRoot.resolve}"
    warn "claude_dir:        #{SaneProjectRoot.claude_dir}"
    warn "saneprocess_project?: #{SaneProjectRoot.saneprocess_project?}"
  else
    warn 'Usage: ruby project_root.rb [--self-test|--show]'
  end
end
