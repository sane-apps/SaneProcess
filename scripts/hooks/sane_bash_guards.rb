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
  sane_catastrophic_guard.rb
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

def remote_peekaboo_screen_capture?(remote_text)
  %w[image capture list].any? do |sub|
    command_text_invokes?(remote_text, 'peekaboo', subcommand: sub)
  end
end

def remote_ffmpeg_screen_capture?(remote_text)
  command_text_invokes?(remote_text, 'ffmpeg') && remote_text.include?('avfoundation')
end

# Any screen-capture/video tool invoked DIRECTLY on the Mini over ssh. macOS
# attributes the TCC screen-recording check to the ssh session's process, so a
# direct capture fails even when the tool's own binary is granted. The reliable
# path is the Mini's already-granted Terminal session via mini-gui-run.sh (which
# capture-mini-screenshot.sh uses internally). A tool nested inside a
# `mini-gui-run.sh -- "…"` argument is not a top-level invocation, so it is not
# flagged here — but a raw tool run alongside the wrapper name (e.g. after `;`)
# still is, which closes the mention-the-wrapper evasion.
def raw_remote_screen_tool?(remote)
  return false if remote.empty?

  remote_text = remote.join(' ')

  command_text_invokes?(remote_text, 'screencapture') ||
    remote_peekaboo_screen_capture?(remote_text) ||
    remote_ffmpeg_screen_capture?(remote_text)
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
  mini_ssh_remote_matches?(command) { |remote| raw_remote_screen_tool?(remote) }
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
    🔴 BLOCKED: raw Mini screen capture over ssh (screenshot / video / peekaboo / ffmpeg).

    Direct ssh screen capture fails via macOS TCC even when the tool's own binary
    is granted — the screen-recording check is attributed to the ssh session, not
    the tool. The reliable path is the Mini's already-granted Terminal session.

    Screenshot:
      ~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop
      ~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh --app "SaneClip" --mode temp
    Screen recording (video):
      ~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh --video --duration 5 --copy-to /tmp/rec
    Any other screen tool (peekaboo, ffmpeg -f avfoundation, …):
      ssh mini 'bash ~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh --close-window -- "<your screen command>"'

    Note: cliclick and other Accessibility-only tools work over plain ssh already.
    If the canonical wrapper is genuinely broken or missing, fix that tool first.
  MESSAGE
  exit 2
end

# Destructive `security` keychain mutations: overwrite an existing item
# (add-*-password -U), delete an item, or rewrite its ACL/partition list. These
# cause irrecoverable credential loss (a real license_key was clobbered this way).
# Scoped reads (find-*, find-identity, show-keychain-info, cms) stay allowed.
# Whole-keychain enumeration is blocked separately because it can trigger one
# SecurityAgent authorization dialog per protected item.
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
    show-keychain-info / cms -D. Whole-keychain dumps are not allowed.

    If a destructive keychain change is genuinely required, the USER must run it
    in their own terminal. Never overwrite, delete, or change the partition
    list / ACL of a keychain item from the agent.
  MESSAGE
  exit 2
end

def unsafe_keychain_enumeration_command?(command)
  return false unless command

  command_text_invokes?(command, 'security', subcommand: 'dump-keychain') ||
    mini_ssh_remote_matches?(command) do |remote|
      command_text_invokes?(remote.join(' '), 'security', subcommand: 'dump-keychain')
    end
end

def block_keychain_enumeration_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless unsafe_keychain_enumeration_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: whole-keychain enumeration

    `security dump-keychain` can generate one macOS authorization dialog per
    protected item. It is never an approved AI secret-discovery path.

    Use ~/.config/nv/env first. If a secret is absent, make one explicitly
    scoped `security find-generic-password -s <service> -a <account> -w`
    lookup and reuse the returned value.
  MESSAGE
  exit 2
end

# Safari and Google Chrome are banned for agent browser work. The authenticated
# Brave session on the Mini is the only browser lane. Match direct, absolute,
# shell-wrapped, and ssh-wrapped invocations without blocking source/docs text.
PROHIBITED_BROWSER_NAME = /\A(?:Safari|Google Chrome|Chrome|com\.apple\.Safari|com\.google\.Chrome(?:\..*)?)\z/i.freeze

def direct_prohibited_browser_open?(tokens)
  command_start = true
  tokens.each_with_index do |token, index|
    text = token.to_s
    if command_start
      if environment_assignment?(text) || command_wrapper_token?(text)
        next
      end
      if File.basename(text) == 'open'
        cursor = index + 1
        while cursor < tokens.length && !shell_command_separator?(tokens[cursor])
          flag = tokens[cursor].to_s
          if %w[-a -b].include?(flag)
            return true if tokens[cursor + 1].to_s.match?(PROHIBITED_BROWSER_NAME)
            cursor += 2
            next
          end
          cursor += 1
        end
      end
      command_start = false
    end
    command_start = true if shell_command_separator?(text)
  end
  false
end

def ssh_remote_payloads(tokens)
  payloads = []
  tokens.each_with_index do |token, index|
    next unless ssh_binary_token?(token)

    cursor = index + 1
    while cursor < tokens.length
      arg = tokens[cursor].to_s
      if arg == '--'
        cursor += 1
        break
      end
      if arg.start_with?('-')
        cursor += SSH_OPTION_WITH_VALUE.include?(arg) ? 2 : 1
        next
      end
      cursor += 1 # destination
      payloads << (tokens[cursor..] || []).join(' ') unless cursor >= tokens.length
      break
    end
  end
  payloads
end

def prohibited_browser_automation_command?(command, depth = 0)
  return false if command.to_s.empty? || depth > MAX_SHELL_INSPECTION_DEPTH

  legacy_wrapper = /(?:\A|[;&|(){}\n]|&&|\|\|)\s*(?:\S*\/)?mini-safari\.sh(?:\s|$)/
  return true if command.match?(legacy_wrapper)

  tokens = Shellwords.shellsplit(command)
  return true if direct_prohibited_browser_open?(tokens)

  tells_browser = /tell\s+app(?:lication)?\s+(?:\\?["'])?(?:Safari|Google Chrome|Chrome)(?:\\?["'])?(?=\s|$)/i
  return true if command_tokens_invoke?(tokens, 'osascript') && command.match?(tells_browser)

  nested = shell_command_payloads(tokens) + ssh_remote_payloads(tokens)
  nested.any? { |payload| prohibited_browser_automation_command?(payload, depth + 1) }
rescue ArgumentError
  command.match?(/(?:\A|[;&|(){}\n])\s*(?:\S*\/)?open\s+-(?:a|b)\s+["']?(?:Safari|Google Chrome|Chrome|com\.apple\.Safari|com\.google\.Chrome)/i)
end

def block_prohibited_browser_automation_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless prohibited_browser_automation_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: Safari/Chrome automation (Brave only)

    Safari and Google Chrome are banned for agent browser work. Use the existing
    authenticated Brave session on the Mini so sessions and reviewer state stay
    consistent.

    Use Brave instead:
      • Claude: the Claude-in-Chrome widget connected to Brave on the Mini
        (list_connected_browsers → select_browser → tabs_context_mcp → navigate)
      • Codex/Cursor: the attached Brave lane or Mini GUI wrapper
      • Portal tokens (e.g. Setapp): sign in at the portal in Brave on the Mini,
        or set the stored token (SETAPP_PORTAL_TOKEN) — the scripts read Brave.

    App Store Connect and Apple ID portals also run through Brave
    (owner retired the ASC Safari exception 2026-07-15; mini-safari.sh is legacy).
  MESSAGE
  exit 2
end

def prophecy_ledger_adhoc_click_command?(command)
  return false if command.to_s.strip.empty?
  return false if command.match?(/SaneMaster\.rb\s+prophecy[_-]reviewer[_-]click|npm\s+run\s+e2e:reviewer/)

  # Hard-blocked leftover paths from the Access OTP / Brave spam era
  hard = [
    %r{/tmp/cf-access-login},
    %r{/tmp/admin-brave-(?:e2e|claim-e2e|local-e2e)},
    %r{/tmp/brave-access-login},
    %r{/tmp/admin-agree-charles},
    %r{/tmp/admin-live-(?:e2e|audit)},
    %r{/tmp/admin-feedback-e2e}
  ]
  return true if hard.any? { |rx| command.match?(rx) }
  soft = [
    %r{prophecy-ledger/tmp/(?:reviewer-ui-e2e|simple-flow-e2e|e2e-full-flow|e2e-)}
  ]
  soft.any? { |rx| command.match?(rx) }
end

def block_prophecy_adhoc_reviewer_click_if_needed(payload)
  command = bash_command_from_payload(payload)
  return unless prophecy_ledger_adhoc_click_command?(command)

  warn <<~MESSAGE
    🔴 BLOCKED: ad-hoc Prophecy Ledger reviewer click / Access OTP script

    Owner rule 2026-08-01: use the durable tool path, not /tmp Brave login spam.

    Canonical:
      ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb prophecy_reviewer_click
      ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb prophecy_reviewer_click --mode live
      ALLOW_LIVE_SUBMIT=1 … prophecy_reviewer_click --live --allow-live-submit

    Repo doc (Mini): websites/prophecy-ledger/docs/REVIEWER_CLICK_E2E.md
    npm (on Mini only): npm run e2e:reviewer | e2e:reviewer:live

    Do not invent OTP scrapers or make-new-tab Brave scripts for this.
  MESSAGE
  exit 2
end

payload = $stdin.read.force_encoding(Encoding::UTF_8)
original_stdin = $stdin

block_destructive_keychain_if_needed(payload)
block_keychain_enumeration_if_needed(payload)
block_raw_mini_screenshot_if_needed(payload)
block_detached_mini_qa_if_needed(payload)
block_prohibited_browser_automation_if_needed(payload)
block_prophecy_adhoc_reviewer_click_if_needed(payload)

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
