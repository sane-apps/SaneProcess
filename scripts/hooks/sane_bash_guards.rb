#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_bash_guards.rb — ungated PreToolUse Bash guard dispatcher
#
# Runs the high-risk Bash guards in-process so Claude invokes one hook instead
# of four subprocesses on every Bash call. Order matters: first block wins and
# each guard's existing stderr/exit behavior is preserved.

require 'stringio'
require 'json'
require 'shellwords'

GUARDS = %w[
  sane_launch_guard.rb
  sane_release_guard.rb
  sane_ship_guard.rb
  sane_email_guard.rb
].map { |name| File.expand_path(name, __dir__) }.freeze

SSH_OPTION_WITH_VALUE = %w[
  -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w
].freeze

MINI_HOST_PATTERN = /\A(?:[^@\s]+@)?(?:mini(?:\..*)?|.*mac-mini.*|.*stephans-mac-mini.*|.*stephens-mac-mini.*)\z/i.freeze
SHELL_BASENAMES = %w[sh bash zsh].freeze
SHELL_OPTION_WITH_VALUE = %w[
  --rcfile --init-file
].freeze
MAX_SHELL_INSPECTION_DEPTH = 4

def bash_command_from_payload(payload)
  data = JSON.parse(payload)
  return nil unless data['tool_name'] == 'Bash'

  tool_input = data['tool_input'] || {}
  tool_input['command'].to_s
rescue JSON::ParserError
  nil
end

def ssh_binary_token?(token)
  File.basename(token.to_s) == 'ssh'
end

def mini_host_token?(token)
  token.to_s.match?(MINI_HOST_PATTERN)
end

def shell_option_with_value?(arg)
  return true if SHELL_OPTION_WITH_VALUE.include?(arg)
  return true if arg.match?(/\A(?:--rcfile|--init-file)=/)

  false
end

def raw_remote_screencapture?(remote)
  return false if remote.empty?

  remote_text = remote.join(' ')

  command_text_invokes?(remote_text, 'screencapture')
end

def detached_remote_saneapps_qa?(remote)
  return false if remote.empty?

  remote_text = remote.join(' ')
  return false unless command_text_invokes?(remote_text, 'launchctl', subcommand: 'submit')

  remote_text.include?('run_sanebar_qa') ||
    remote_text.include?('Scripts/qa.rb') ||
    remote_text.include?('SANEBAR_RUN_RUNTIME_SMOKE') ||
    remote_text.include?('SaneMaster.rb release_preflight')
end

def shell_command_separator?(token)
  text = token.to_s
  %w[; && || |].include?(text) || text.end_with?(';')
end

def environment_assignment?(token)
  token.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
end

def command_wrapper_token?(token)
  %w[env sudo command builtin time].include?(File.basename(token.to_s))
end

def command_tokens_invoke?(tokens, command_name, subcommand: nil)
  command_start = true

  tokens.each_with_index do |token, index|
    text = token.to_s

    if command_start
      if environment_assignment?(text) || command_wrapper_token?(text)
        # Keep scanning; the next token is still the command invocation.
      else
        basename = File.basename(text)
        if basename == command_name
          return true if subcommand.nil? || tokens[index + 1].to_s == subcommand
        end
        command_start = false
      end
    end

    command_start = true if shell_command_separator?(text)
  end

  false
end

def command_text_invokes?(command_text, command_name, subcommand: nil, depth: 0)
  return false if command_text.to_s.empty? || depth > MAX_SHELL_INSPECTION_DEPTH

  tokens = Shellwords.shellsplit(command_text)
  return true if command_tokens_invoke?(tokens, command_name, subcommand: subcommand)

  shell_command_payloads(tokens).any? do |payload|
    command_text_invokes?(payload, command_name, subcommand: subcommand, depth: depth + 1)
  end
rescue ArgumentError
  if subcommand
    command_text.match?(/(?:\A|[\s;&|()])#{Regexp.escape(command_name)}\s+#{Regexp.escape(subcommand)}(?:\s|\z)/)
  else
    command_text.match?(/(?:\A|[\s;&|()\/])#{Regexp.escape(command_name)}(?:\s|\z)/)
  end
end

def shell_command_payloads(tokens)
  payloads = []

  tokens.each_with_index do |token, index|
    next unless SHELL_BASENAMES.include?(File.basename(token.to_s))

    cursor = index + 1
    while cursor < tokens.length
      arg = tokens[cursor]

      if arg == '-c' || arg.match?(/\A-[^-]*c/)
        payloads << tokens[cursor + 1].to_s if tokens[cursor + 1]
        break
      end

      break unless arg.start_with?('-')

      cursor += shell_option_with_value?(arg) && !arg.include?('=') ? 2 : 1
    end
  end

  payloads
end

def mini_ssh_remote_matches?(command, depth = 0, &remote_matcher)
  return false if command.to_s.empty? || depth > MAX_SHELL_INSPECTION_DEPTH

  tokens = Shellwords.shellsplit(command)

  shell_command_payloads(tokens).any? do |payload|
    mini_ssh_remote_matches?(payload, depth + 1, &remote_matcher)
  end || tokens.each_with_index.any? do |token, index|
    next false unless ssh_binary_token?(token)

    cursor = index + 1
    while cursor < tokens.length
      arg = tokens[cursor]

      if arg == '--'
        cursor += 1
        break
      end

      if arg.start_with?('-')
        cursor += SSH_OPTION_WITH_VALUE.include?(arg) ? 2 : 1
        next
      end

      host = arg
      cursor += 1
      next false unless mini_host_token?(host)

      break remote_matcher.call(tokens[cursor..] || [])
    end
  end
rescue ArgumentError
  yield([command])
end

def raw_mini_screenshot_command?(command)
  mini_ssh_remote_matches?(command) { |remote| raw_remote_screencapture?(remote) }
end

def detached_mini_saneapps_qa_command?(command)
  mini_ssh_remote_matches?(command) { |remote| detached_remote_saneapps_qa?(remote) }
end

def block_detached_mini_qa_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless command && detached_mini_saneapps_qa_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: detached Mini SaneApps QA command.

    This bypasses foreground canonical release/runtime receipts and can leave
    stale launchctl jobs, shifting PIDs, and ambiguous logs.

    Use:
      ssh mini 'cd ~/SaneApps/apps/SaneBar && ./scripts/SaneMaster.rb release_preflight'
      ssh mini 'cd ~/SaneApps/apps/SaneBar && SANEBAR_RUN_RUNTIME_SMOKE=1 SANEBAR_RELEASE_SMOKE_SCREENSHOTS=1 ruby Scripts/qa.rb'

    If a foreground canonical command is unreliable, fix that command or SaneProcess.
  MESSAGE
  exit 2
end

def legacy_raw_mini_screenshot_command?(command)
  tokens = Shellwords.shellsplit(command)

  tokens.each_with_index do |token, index|
    next unless ssh_binary_token?(token)

    cursor = index + 1
    while cursor < tokens.length
      arg = tokens[cursor]

      if arg == '--'
        cursor += 1
        break
      end

      if arg.start_with?('-')
        cursor += SSH_OPTION_WITH_VALUE.include?(arg) ? 2 : 1
        next
      end

      host = arg
      cursor += 1
      next unless mini_host_token?(host)

      return true if raw_remote_screencapture?(tokens[cursor..] || [])
      break
    end
  end

  false
rescue ArgumentError
  command.match?(/\b(?:\/usr\/bin\/)?ssh\b.*\bmini\b.*\bscreencapture\b/) &&
    !command.include?('capture-mini-screenshot.sh')
end

def block_raw_mini_screenshot_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless command && raw_mini_screenshot_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: raw Mini screenshot command.

    This bypasses the canonical Mini GUI-session screenshot wrapper and has
    repeatedly produced false failures.

    Use:
      ~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop
      ~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh --app "SaneBar" --mode temp

    If the canonical wrapper is genuinely broken or missing, fix that tool first.
  MESSAGE
  exit 2
end

# Destructive `security` keychain mutations: overwrite an existing item
# (add-*-password -U), delete an item, or rewrite its ACL/partition list. These
# cause irrecoverable credential loss (a real license_key was clobbered this way).
# Reads (find-*, find-identity, show-keychain-info, cms, dump) stay allowed.
# Matches local and ssh-wrapped/quoted forms.
DESTRUCTIVE_KEYCHAIN_SUBCOMMAND = Regexp.union(
  /add-(?:generic|internet)-password\b[^;&|\n'"]*?\s-U\b/,
  /delete-(?:generic|internet)-password\b/,
  /delete-(?:certificate|identity|keychain)\b/,
  /set-(?:generic|internet)-password-partition-list\b/,
  /set-key-partition-list\b/
).freeze

# Only fire when `security <destructive-subcommand>` is actually INVOKED, i.e.
# `security` sits at a command position — start of the command, after a shell
# separator, or as the remote command of `ssh <host> '...'`. Merely MENTIONING
# the text (a commit message, echo arg, grep pattern, comment) does not match,
# so committing/documenting this very guard is not self-blocked.
def destructive_keychain_command?(command)
  return false unless command

  sub = DESTRUCTIVE_KEYCHAIN_SUBCOMMAND.source
  local  = /(?:\A|[;&|(){}\n]|&&|\|\|)\s*security\s+(?:#{sub})/
  remote = /\bssh\s+\S+\s+["']\s*security\s+(?:#{sub})/
  command.match?(local) || command.match?(remote)
end

def block_destructive_keychain_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless destructive_keychain_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: destructive keychain mutation

    This `security` command overwrites (add … -U), deletes, or re-ACLs a keychain
    item. Keychain items hold the user's real credentials — licenses, API keys,
    signing keys. Losing/altering one is irrecoverable data loss, and it already
    clobbered a real license_key once.

    Allowed (read-only): security find-generic-password / find-identity /
    show-keychain-info / cms -D / dump-keychain.

    If a destructive keychain change is genuinely required, the USER must run it
    in their own terminal. Never overwrite, delete, or change the partition
    list / ACL of a keychain item from the agent.
  MESSAGE
  exit 2
end

payload = $stdin.read.force_encoding(Encoding::UTF_8)
original_stdin = $stdin

block_destructive_keychain_if_needed(payload)
block_raw_mini_screenshot_if_needed(payload)
block_detached_mini_qa_if_needed(payload)

GUARDS.each do |guard|
  $stdin = StringIO.new(payload)
  begin
    load guard, true
  rescue SystemExit => e
    status = e.status.is_a?(Integer) ? e.status : (e.success? ? 0 : 1)
    exit status unless status.zero?
  ensure
    $stdin = original_stdin
  end
end

exit 0
