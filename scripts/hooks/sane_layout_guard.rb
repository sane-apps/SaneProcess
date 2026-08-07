#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_layout_guard.rb — PreToolUse hook + reusable module
# Blocks Mini path fragmentation: fake Air trees, nested Users/, literal $HOME,
# Desktop project dumps, and SaneApps products under ~/Dev.
#
# BLOCKS (Write/Edit paths and bash mkdir/clone/cp/mv/touch/install targets):
#   - /Users/sj/ on Mini (or any nested fake Air tree)
#   - ~/SaneApps/Users/ (nested fake)
#   - literal $HOME path segments
#   - ~/Desktop/** except Screenshots + LemonSqueezy-Uploads
#   - mkdir/git clone project roots on Desktop, Documents, or home top-level
#   - Sane* / saneapps projects under ~/Dev (Dev is third-party forks only)
#
# ALLOWS:
#   - ~/SaneApps/**, ~/SaneApps-automation/**
#   - ~/Desktop/Screenshots/**, ~/Desktop/LemonSqueezy-Uploads/**
#   - /tmp, DerivedData, Library/Caches, .Trash
#   - ~/Dev/** when not a SaneApps product name
#   - Reads (hook only checks Write/Edit/Bash mutations)

require 'json'
require 'shellwords'
require 'socket'

module SaneLayoutGuard
  module_function

  BLOCK_HINT =
    'Use ~/SaneApps/<bucket>/... (apps, websites, infra, mcp, meta, clients). ' \
    'Never /Users/sj on Mini. Desktop only Screenshots + LemonSqueezy-Uploads.'.freeze

  DESKTOP_ALLOW = %w[Screenshots LemonSqueezy-Uploads].freeze

  HOME_TOP_ALLOW = %w[
    Applications Desktop Documents Downloads Library Movies Music Pictures Public
    Sites Dev SaneApps SaneApps-automation
  ].freeze

  SANE_PRODUCT_NAME = /
    \A
    (?:
      Sane[A-Za-z0-9._-]*
      |saneapps(?:-[A-Za-z0-9._-]+)?
      |sane-[A-Za-z0-9._-]+
    )
    \z
  /ix.freeze

  EDIT_TOOL_PATTERN = /\A(?:Write|Edit|NotebookEdit)\z/i.freeze
  SHELLS = %w[sh bash zsh].freeze
  WRAPPERS = %w[env sudo command builtin time nice].freeze
  SSH_OPTIONS_WITH_VALUE = %w[
    -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w
  ].freeze
  MAX_DEPTH = 4

  def violation_for_path(path)
    raw = path.to_s.strip
    return nil if raw.empty?

    return format_reason('literal $HOME path segment') if literal_home_segment?(raw)
    return format_reason('nested fake Users/ tree') if nested_users_tree?(raw)
    return format_reason('~/SaneApps/Users nested fake tree') if saneapps_users_nested?(raw)
    return format_reason('/Users/sj path on Mini (or non-Air host)') if users_sj_forbidden?(raw)
    return format_reason('Desktop write outside Screenshots / LemonSqueezy-Uploads') if desktop_forbidden?(raw)
    return format_reason('SaneApps product under ~/Dev (Dev is third-party forks only)') if sane_under_dev?(raw)

    nil
  end

  def violation_for_bash(command)
    cmd = command.to_s
    return nil if cmd.empty?

    # Only inspect mutation targets — do not block echo/rg that merely mention /Users/sj.
    targets_with_context(cmd).each do |target, kind|
      if (reason = violation_for_path(target))
        return reason
      end
      if (reason = project_root_violation(target, kind))
        return reason
      end
    end

    nil
  end

  def format_reason(detail)
    "LAYOUT BLOCKED: #{detail}. #{BLOCK_HINT}"
  end

  def mini_like_host?
    host = Socket.gethostname.to_s.downcase
    user = current_user
    home = Dir.home.to_s
    host.match?(/mini|stephans-mac-mini|stephens-mac-mini/) ||
      user == 'stephansmac' ||
      home.include?('/stephansmac')
  end

  def air_like_host?
    current_user == 'sj' || Dir.home.to_s.end_with?('/sj')
  end

  def current_user
    ENV['USER'].to_s.empty? ? ENV.fetch('LOGNAME', '') : ENV['USER']
  end

  def literal_home_segment?(path)
    # Only the filesystem nest named "$HOME" under the real home (or ~/\$HOME).
    # Do NOT flag shell env expansion like `$HOME/SaneApps/...`.
    text = path.to_s
    return true if text.match?(%r{\A~/\$HOME(?:/|\z)})
    return true if text.match?(%r{\A#{Regexp.escape(Dir.home)}/\$HOME(?:/|\z)})

    expanded = expand_loose(text)
    expanded.match?(%r{\A#{Regexp.escape(Dir.home)}/\$HOME(?:/|\z)})
  end

  def nested_users_tree?(path)
    # ~/Users/... (fake) or /Users/<someone>/Users/... (nested fake Air tree)
    return true if path.match?(%r{\A~/Users(?:/|\z)})
    return true if path.match?(%r{/Users/[^/]+/Users(?:/|\z)})

    expand_loose(path).match?(%r{/Users/[^/]+/Users(?:/|\z)})
  end

  def users_sj_forbidden?(path)
    raw = path.to_s
    # Match real Air-home shapes only — not ".../SaneApps/Users/sj" (handled above).
    has_sj = raw.match?(%r{\A/Users/sj(?:/|\z)}) ||
             raw.match?(%r{\A~/Users/sj(?:/|\z)}) ||
             raw.match?(%r{\AUsers/sj(?:/|\z)}) ||
             raw.match?(%r{/Users/[^/]+/Users/sj(?:/|\z)}) ||
             expand_loose(raw).match?(%r{\A/Users/sj(?:/|\z)})
    return false unless has_sj
    return false if air_like_host? && real_air_home_path?(raw)

    true
  end

  def real_air_home_path?(path)
    expanded = expand_loose(path)
    expanded == '/Users/sj' || expanded.start_with?('/Users/sj/')
  end

  def saneapps_users_nested?(path)
    raw = path.to_s
    return true if raw.match?(%r{(?:^|/)SaneApps/Users(?:/|\z)})

    expand_loose(raw).match?(%r{/SaneApps/Users(?:/|\z)})
  end

  def desktop_forbidden?(path)
    expanded = expand_loose(path)
    desktop = File.join(Dir.home, 'Desktop')
    return false unless under?(expanded, desktop)

    DESKTOP_ALLOW.any? { |name| under?(expanded, File.join(desktop, name)) } ? false : true
  end

  def sane_under_dev?(path)
    expanded = expand_loose(path)
    dev = File.join(Dir.home, 'Dev')
    return false unless under?(expanded, dev)

    rel = expanded.delete_prefix(dev + '/')
    rel.split('/').any? { |part| part.match?(SANE_PRODUCT_NAME) }
  end

  def project_root_violation(target, kind)
    return nil unless %i[mkdir clone redirect copy touch].include?(kind)

    expanded = expand_loose(target)
    home = Dir.home
    desktop = File.join(home, 'Desktop')
    documents = File.join(home, 'Documents')

    if under?(expanded, desktop)
      return nil unless desktop_forbidden?(target)

      return format_reason('new project root on Desktop')
    end

    if under?(expanded, documents) && %i[mkdir clone].include?(kind)
      return format_reason('new project root under Documents')
    end

    # Home top-level outside allowlist (e.g. mkdir ~/MyApp)
    if %i[mkdir clone].include?(kind) && expanded.start_with?(home + '/')
      first = expanded.delete_prefix(home + '/').split('/').first.to_s
      unless first.empty? || first.start_with?('.') || HOME_TOP_ALLOW.include?(first)
        return format_reason("new project root at home top-level (~/#{first})")
      end
    end

    nil
  end

  def under?(path, root)
    path == root || path.start_with?(root + '/')
  end

  def expand_loose(path)
    text = path.to_s.strip
    return text if text.empty?
    # Keep literal nest named "$HOME" under real home — do not File.expand_path it away.
    if text.match?(%r{\A~/\$HOME(?:/|\z)}) || text.match?(%r{\A#{Regexp.escape(Dir.home)}/\$HOME(?:/|\z)})
      return text.sub(/\A~(?=\/|\z)/, Dir.home)
    end

    expanded = text.sub(/\A~(?=\/|\z)/, Dir.home)
    # Shell env `$HOME/...` → real home
    expanded = expanded.sub(/\A\$HOME(?=\/|\z)/, Dir.home)
    File.expand_path(expanded)
  rescue StandardError
    text
  end

  def targets_with_context(command, depth = 0)
    return [] if command.to_s.empty? || depth > MAX_DEPTH

    found = []
    cwd = nil
    split_shell_segments(command).each do |segment|
      extract_redirect_targets(segment).each { |t| found << [t, :redirect] }

      tokens = tokens_for(segment)
      next if tokens.empty?

      index = command_index(tokens)
      base = File.basename(tokens[index].to_s)
      args = tokens[(index + 1)..] || []

      if base == 'cd' && args.first && !args.first.start_with?('-')
        cwd = expand_loose(args.first)
      end

      case base
      when 'mkdir'
        mkdir_targets(args).each { |t| found << [t, :mkdir] }
      when 'git'
        clone_targets(args, cwd).each { |t| found << [t, :clone] }
      when 'cp', 'mv', 'install', 'ditto', 'rsync', 'ln'
        dest = last_non_option(args)
        found << [dest, :copy] if dest
      when 'touch'
        touch_targets(args).each { |t| found << [t, :touch] }
      when 'tee'
        tee_targets(args).each { |t| found << [t, :redirect] }
      when 'curl', 'wget'
        curl_output_targets(args).each { |t| found << [t, :copy] }
      end

      nested_commands(tokens).each do |nested|
        found.concat(targets_with_context(nested, depth + 1))
      end
    end
    found
  end

  def mkdir_targets(args)
    args.reject { |a| a.start_with?('-') }
  end

  def touch_targets(args)
    args.reject { |a| a.start_with?('-') }
  end

  def tee_targets(args)
    args.reject { |a| a.start_with?('-') }
  end

  def curl_output_targets(args)
    out = []
    args.each_with_index do |arg, i|
      if arg == '-o' || arg == '--output' || arg == '-O'
        dest = args[i + 1]
        out << dest if dest && !dest.start_with?('-')
      elsif arg.start_with?('--output=')
        out << arg.split('=', 2).last
      end
    end
    out
  end

  def extract_redirect_targets(segment)
    targets = []
    segment.to_s.scan(/(?:^|[^0-9])>{1,2}\s*([^\s|;]+)/) do |match|
      targets << match[0]
    end
    targets
  end

  def clone_targets(args, cwd = nil)
    return [] unless args.first == 'clone'

    positional = args[1..].to_a.reject { |a| a.start_with?('-') }
    return [] if positional.empty?

    if positional.length >= 2
      return [positional.last]
    end

    # git clone <url> with no dest → basename into cwd when cwd is Desktop/Documents.
    url = positional.first.to_s
    base = File.basename(url.sub(/\.git\z/, ''))
    return [] if base.empty? || base == '.' || base == '/'
    return [] if cwd.nil? || cwd.empty?

    desktop = File.join(Dir.home, 'Desktop')
    documents = File.join(Dir.home, 'Documents')
    if under?(cwd, desktop)
      return [File.join(cwd == desktop ? desktop : cwd, base)]
    end
    if under?(cwd, documents)
      return [File.join(cwd == documents ? documents : cwd, base)]
    end

    []
  end

  def last_non_option(args)
    args.reverse.find { |a| !a.start_with?('-') }
  end

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

  def command_index(tokens)
    index = 0
    while index < tokens.length
      token = tokens[index].to_s
      if token.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/) || WRAPPERS.include?(File.basename(token))
        index += 1
        next
      end
      break
    end
    index
  end

  def nested_commands(tokens)
    commands = []
    tokens.each_with_index do |token, index|
      base = File.basename(token.to_s)
      if SHELLS.include?(base)
        option_index = tokens[(index + 1)..]&.index { |item| item == '-c' || item.match?(/\A-[^-]*c/) }
        commands << tokens[index + 2 + option_index].to_s if option_index && tokens[index + 2 + option_index]
      elsif base == 'ssh'
        cursor = index + 1
        while tokens[cursor]&.start_with?('-')
          option = tokens[cursor]
          cursor += SSH_OPTIONS_WITH_VALUE.include?(option) ? 2 : 1
        end
        cursor += 1 # host
        commands << tokens[cursor..].join(' ') if tokens[cursor]
      end
    end
    commands
  end

  def run_stdin_hook!
    begin
      input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, Errno::ENOENT
      exit 0
    end

    tool_name = input['tool_name'].to_s
    tool_input = input['tool_input'] || {}

    if tool_name.match?(EDIT_TOOL_PATTERN)
      path = tool_input['file_path'] || tool_input['path']
      if (reason = violation_for_path(path))
        warn "🔴 BLOCKED: Project layout violation"
        warn "   #{reason}"
        warn ''
        warn "   ✅ #{BLOCK_HINT}"
        exit 2
      end
      exit 0
    end

    exit 0 unless tool_name == 'Bash'

    command = tool_input['command'].to_s
    exit 0 if command.empty?

    if (reason = violation_for_bash(command))
      warn "🔴 BLOCKED: Project layout violation"
      warn "   Command: #{command}"
      warn "   #{reason}"
      warn ''
      warn "   ✅ #{BLOCK_HINT}"
      exit 2
    end

    exit 0
  end

  def hook_invocation?
    return true if $PROGRAM_NAME == __FILE__

    File.basename($PROGRAM_NAME.to_s) == 'sane_bash_guards.rb'
  end
end

SaneLayoutGuard.run_stdin_hook! if SaneLayoutGuard.hook_invocation?
