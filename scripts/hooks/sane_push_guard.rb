#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_push_guard.rb — PreToolUse hook
# Blocks a plain `git push` when the local branch is behind its upstream, so
# agents stop discovering a moved remote only after the push is rejected.
# The recurring failure this prevents: push, non-fast-forward rejection,
# manual fetch, rebase, re-verify, push again — across sessions and repos.
#
# BLOCKS (exit 2):
#   - `git push` (including `git -C <dir> push ...`) when the tracking branch
#     is behind its upstream by 1+ commits.
#
# ALLOWS (exit 0):
#   - pushes that are up to date with upstream
#   - force-family pushes (-f/--force/--delete/+refspec/:refspec): owned by
#     sane_catastrophic_guard.rb, never double-blocked here
#   - pushes with no resolvable repo (no -C/--git-dir flag), no upstream,
#     detached HEAD, or unreachable remote: the guard cannot verify, so it
#     fails open and git reports the real error itself
#
# LIMITS: without a hook working-directory field, a bare `git push` run from
# an unknown shell cwd cannot be mapped to a repo — only pushes that name
# their repo explicitly (-C <dir> / --git-dir=<dir>) are checked. Prefer
# `git -C <repo> push` in agent commands so this guard can see them.

require 'json'
require 'open3'
require 'shellwords'

FETCH_TIMEOUT_SECONDS = 30
PLUMBING_TIMEOUT_SECONDS = 10
WRAPPERS = %w[env sudo command builtin time].freeze

def split_shell_segments(text)
  segments = []
  current = +''
  quote = nil
  escaped = false
  index = 0
  while index < text.length
    char = text[index]
    if escaped
      current << char
      escaped = false
    elsif char == '\\' && quote != "'"
      current << char
      escaped = true
    elsif quote
      current << char
      quote = nil if char == quote
    elsif char == "'" || char == '"'
      current << char
      quote = char
    elsif char == ';' || char == "\n" || char == '|' || (char == '&' && text[index + 1] == '&')
      segments << current.strip unless current.strip.empty?
      current = +''
      index += 1 if (char == '|' && text[index + 1] == '|') || (char == '&' && text[index + 1] == '&')
    else
      current << char
    end
    index += 1
  end
  segments << current.strip unless current.strip.empty?
  segments
end

def tokens_for(segment)
  Shellwords.shellsplit(segment)
rescue ArgumentError
  []
end

# Runs argv with process-level control: join timeout plus TERM/KILL
# escalation. Never blocks the hook longer than timeout + 2s.
def run_bounded(argv, timeout_seconds)
  output = +''
  success = false
  Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }
    unless wait_thr.join(timeout_seconds)
      begin
        Process.kill('TERM', wait_thr.pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      unless wait_thr.join(2)
        begin
          Process.kill('KILL', wait_thr.pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        wait_thr.join
      end
      output = [stdout_reader.value, stderr_reader.value].join
      return [output, false]
    end
    output = [stdout_reader.value, stderr_reader.value].join
    success = wait_thr.value.success?
  end
  [output, success]
rescue StandardError
  ['', false]
end

def git(argv, repo_dir, timeout_seconds)
  run_bounded(['git', '-C', repo_dir] + argv, timeout_seconds)
end

def force_family?(push_args)
  push_args.any? do |arg|
    arg == '-f' || arg.start_with?('--force') || arg == '--delete' ||
      arg.start_with?('+') || arg.match?(/\A:[^:]/)
  end
end

# Returns [repo_dir, push_args] for the first plain `git push` segment found,
# or nil when no segment is a plain push.
def plain_push_in(command)
  split_shell_segments(command.to_s).each do |segment|
    tokens = tokens_for(segment)
    index = 0
    index += 1 while tokens[index].to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/) ||
                      WRAPPERS.include?(File.basename(tokens[index].to_s))
    next unless File.basename(tokens[index].to_s) == 'git'

    repo_dir = nil
    cursor = index + 1
    while cursor < tokens.length && tokens[cursor].to_s.start_with?('-')
      token = tokens[cursor].to_s
      if token == '-C' && tokens[cursor + 1]
        repo_dir = tokens[cursor + 1].to_s
        cursor += 2
      elsif token.start_with?('-C') && token.length > 2
        repo_dir = token[2..]
        cursor += 1
      elsif token.start_with?('--git-dir=')
        repo_dir = File.dirname(token.sub(/\A--git-dir=/, ''))
        cursor += 1
      elsif token == '--git-dir' && tokens[cursor + 1]
        repo_dir = File.dirname(tokens[cursor + 1].to_s)
        cursor += 2
      else
        cursor += 1
      end
    end
    next unless tokens[cursor].to_s == 'push'

    push_args = tokens[(cursor + 1)..] || []
    return nil if force_family?(push_args)

    return [repo_dir, push_args]
  end
  nil
end

def payload_command(payload)
  data = JSON.parse(payload)
  tool_input = data['tool_input'] || {}
  tool_input['command'].to_s
rescue JSON::ParserError, TypeError
  ''
end

command = payload_command($stdin.read.force_encoding(Encoding::UTF_8))
found = plain_push_in(command)
exit 0 if found.nil?

repo_dir, _push_args = found
# No explicit repo: unresolvable without a hook cwd — fail open.
exit 0 if repo_dir.nil? || repo_dir.empty?
exit 0 unless Dir.exist?(File.join(repo_dir, '.git')) || File.file?(File.join(repo_dir, 'HEAD'))

branch_out, ok = git(['rev-parse', '--abbrev-ref', 'HEAD'], repo_dir, PLUMBING_TIMEOUT_SECONDS)
exit 0 unless ok
branch = branch_out.strip
exit 0 if branch.empty? || branch == 'HEAD'

upstream_out, ok = git(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], repo_dir, PLUMBING_TIMEOUT_SECONDS)
exit 0 unless ok
upstream = upstream_out.strip
exit 0 if upstream.empty?
remote = upstream.split('/').first
exit 0 if remote.nil? || remote.empty?

_fetch_out, ok = git(['fetch', remote], repo_dir, FETCH_TIMEOUT_SECONDS)
# Unreachable remote: fail open; the real push reports the transport error.
exit 0 unless ok

count_out, ok = git(['rev-list', '--count', 'HEAD..@{u}'], repo_dir, PLUMBING_TIMEOUT_SECONDS)
exit 0 unless ok
behind = count_out.strip.to_i
exit 0 if behind <= 0

log_out, _ok = git(['log', '--oneline', 'HEAD..@{u}'], repo_dir, PLUMBING_TIMEOUT_SECONDS)
warn "🔴 BLOCKED: #{repo_dir} is #{behind} commit(s) behind #{upstream} — a direct push would be rejected."
warn "   Remote tip moved since your last fetch. Inspect it first:"
warn "   git -C #{repo_dir} log --oneline HEAD..@{u}"
log_out.to_s.lines.first(5).each { |line| warn "   #{line.strip}" }
warn ''
warn "   Then: git -C #{repo_dir} pull --rebase, re-run the affected suites, and push again."
exit 2
