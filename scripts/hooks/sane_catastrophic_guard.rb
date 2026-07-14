#!/usr/bin/env ruby
# frozen_string_literal: true

# Hard boundary for actions whose blast radius is too large for unattended
# agents. This hook has no approval-token bypass: the user runs an exact
# catastrophic command manually when it is genuinely required.

require 'json'
require 'shellwords'

MAX_INSPECTION_DEPTH = 4
SHELLS = %w[sh bash zsh].freeze
WRAPPERS = %w[env sudo command builtin time].freeze
SSH_OPTIONS_WITH_VALUE = %w[-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w].freeze
CATASTROPHIC_RESOURCES = /(?:repo(?:sitory)?|project|bucket|database|account|organization|org|zone|domain|token|credential|secret|role|owner(?:ship)?|namespace)/i.freeze
DESTRUCTIVE_TOOL_VERBS = /(?:delete|destroy|transfer|revoke|remove|drop|truncate|disable)/i.freeze
REVERSIBLE_TOOL_RESOURCES = /(?:file|symbol|message|email|event|thread|draft|comment|memory|observation|relation|entity|automation)/i.freeze
PROTECTED_DELETE_ROOTS = %w[/ /System /Library /Applications /Users].freeze
CWD_WIDE_DELETE_TARGETS = %w[
  . ./ * ./* .* ./.* .[!.]* ./.[!.]* ..?* ./..?* {*,.*} ./{*,.*}
].freeze

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

def destructive_git?(args)
  operation = args.first
  return true if operation == 'push' && args.any? { |arg| arg == '-f' || arg.start_with?('--force') || arg == '--delete' || arg.start_with?('+') || arg.match?(/\A:[^:]/) }
  return true if operation == 'reset' && args.include?('--hard')
  return true if operation == 'clean' && args.any? { |arg| arg.start_with?('-') && arg.include?('f') && arg.include?('d') }
  return true if %w[filter-branch filter-repo].include?(operation)

  false
end

def destructive_github?(args)
  return true if args[0, 2] == %w[repo delete]
  return false unless args.first == 'api'

  method_delete = args.each_with_index.any? do |arg, index|
    arg.match?(/\A-XDELETE\z/i) || (arg == '-X' && args[index + 1].to_s.casecmp('DELETE').zero?) || arg.match?(/\A--method=DELETE\z/i)
  end
  method_delete && args.join(' ').match?(%r{(?:\A|/)(?:repos|orgs|organizations|projects|actions/secrets|environments)(?:/|\b)}i)
end

def destructive_wrangler?(args)
  joined = args.join(' ').downcase
  joined.match?(/\bpages project delete\b/) ||
    joined.match?(/\br2 bucket delete\b/) ||
    joined.match?(/\bd1 (?:database )?delete\b/) ||
    joined.match?(/\bkv namespace delete\b/) ||
    joined.match?(/\b(?:workers?|deployments?) delete\b/) ||
    joined.match?(/\bsecret delete\b/) ||
    args.first == 'delete'
end

def destructive_http?(args)
  method_delete = args.each_with_index.any? do |arg, index|
    arg.match?(/\A-XDELETE\z/i) || (arg == '-X' && args[index + 1].to_s.casecmp('DELETE').zero?) || arg.match?(/\A--request=DELETE\z/i)
  end
  return false unless method_delete

  args.join(' ').match?(%r{/(?:repos|organizations|orgs|projects|buckets|databases|accounts|zones|domains|tokens|credentials|roles|owners?)(?:/|\b)}i)
end

def destructive_sql?(base, args)
  return false unless %w[psql mysql sqlite sqlite3].include?(base) || (base == 'wrangler' && args.first == 'd1')

  sql = args.join(' ')
  return true if sql.match?(/\b(?:DROP|TRUNCATE)\s+(?:TABLE|DATABASE|SCHEMA)?\s*\w+/i)
  return true if sql.match?(/\bDELETE\s+FROM\s+\w+\s*(?:;|\z)/i) && !sql.match?(/\bWHERE\b/i)

  false
end

def destructive_business_operation?(base, args)
  joined = ([base] + args).join(' ')
  return false unless joined.include?('SaneMaster.rb') || joined.include?('ls-sales.py')

  joined.match?(/--(?:refund|issue-refund|disable-license-key|revoke-license)\b/) ||
    joined.match?(/\bsales\s+(?:refund|disable-license)\b/)
end

def recursive_rm?(args)
  args.any? { |arg| arg == '--recursive' || arg.match?(/\A-[^-]*[rR]/) }
end

def deletion_targets(args)
  positional = false
  args.filter_map do |arg|
    if arg == '--'
      positional = true
      next
    end
    next if !positional && arg.start_with?('-')

    arg
  end
end

def expand_delete_target(target, cwd)
  base = cwd.to_s.empty? ? Dir.pwd : File.expand_path(cwd.to_s)
  expanded = target.to_s
                   .sub(/\A~(?=\/|\z)/, Dir.home)
                   .sub(/\A(?:\$HOME|\$\{HOME\})(?=\/|\z)/, Dir.home)
                   .sub(/\A(?:\$PWD|\$\{PWD\}|\$\(pwd\))(?=\/|\z)/, base)
  File.expand_path(expanded, base)
rescue ArgumentError
  target.to_s
end

def delete_target_root(target)
  target.to_s.sub(%r{/(?:\*|\.\*|\{\*,\.\*\})\z}, '')
end

def repo_root_path?(path)
  File.directory?(path) && File.exist?(File.join(path, '.git'))
end

def protected_delete_target?(target, cwd)
  raw = target.to_s
  return true if CWD_WIDE_DELETE_TARGETS.include?(raw)

  expanded = expand_delete_target(raw, cwd)
  root = expand_delete_target(delete_target_root(raw), cwd)
  normalized = expanded == '/' ? expanded : expanded.sub(%r{/+\z}, '')
  normalized_root = root == '/' ? root : root.sub(%r{/+\z}, '')
  protected_roots = PROTECTED_DELETE_ROOTS + [Dir.home, File.join(Dir.home, 'SaneApps')]

  protected_roots.include?(normalized) ||
    protected_roots.include?(normalized_root) ||
    normalized.match?(%r{\A/Users/[^/]+(?:/SaneApps)?\z}) ||
    normalized_root.match?(%r{\A/Users/[^/]+(?:/SaneApps)?\z}) ||
    File.basename(normalized) == '.git' ||
    repo_root_path?(normalized) ||
    repo_root_path?(normalized_root)
end

def destroys_protected_path?(base, args, cwd)
  destructive_rm = base == 'rm' && recursive_rm?(args)
  destructive_trash = base == 'trash'
  return false unless destructive_rm || destructive_trash

  deletion_targets(args).any? { |target| protected_delete_target?(target, cwd) }
end

def catastrophic_segment?(segment, cwd)
  tokens = tokens_for(segment)
  return false if tokens.empty?

  index = command_index(tokens)
  base = File.basename(tokens[index].to_s)
  args = tokens[(index + 1)..] || []

  return true if base == 'gh' && destructive_github?(args)
  return true if base == 'git' && destructive_git?(args)
  return true if base == 'wrangler' && destructive_wrangler?(args)
  return true if %w[terraform pulumi].include?(base) && args.first == 'destroy'
  return true if base == 'aws' && args[0, 2] == %w[cloudformation delete-stack]
  return true if base == 'gcloud' && args[0, 2] == %w[projects delete]
  return true if base == 'kubectl' && args[0, 2] == %w[delete namespace]
  return true if %w[curl wget http].include?(base) && destructive_http?(args)
  return true if destructive_sql?(base, args)
  return true if destructive_business_operation?(base, args)
  return true if destroys_protected_path?(base, args, cwd)

  nested_commands(tokens).any? { |command| catastrophic_command?(command, cwd, 1) }
end

def catastrophic_command?(command, cwd = nil, depth = 0)
  return false if command.to_s.empty? || depth > MAX_INSPECTION_DEPTH

  split_shell_segments(command).any? { |segment| catastrophic_segment?(segment, cwd) }
end

def catastrophic_tool?(tool_name)
  name = tool_name.to_s
  return false if name.empty? || name == 'Bash'
  return false if name.match?(REVERSIBLE_TOOL_RESOURCES) && !name.match?(CATASTROPHIC_RESOURCES)

  name.match?(DESTRUCTIVE_TOOL_VERBS) && name.match?(CATASTROPHIC_RESOURCES)
end

def block_reason(payload)
  data = JSON.parse(payload)
  tool_name = data['tool_name'].to_s
  tool_input = data['tool_input'] || {}
  return 'catastrophic external resource operation' if catastrophic_tool?(tool_name)
  return nil unless tool_name == 'Bash'

  command = tool_input['command'].to_s
  cwd = tool_input['cwd'] || data['cwd']
  catastrophic_command?(command, cwd) ? 'catastrophic shell operation' : nil
rescue JSON::ParserError
  nil
end

payload = $stdin.read.force_encoding(Encoding::UTF_8)
reason = block_reason(payload)
if reason
  warn <<~MESSAGE
    🔴 BLOCKED: #{reason}

    This action can irreversibly destroy repositories, history, production
    infrastructure, data, credentials, ownership, licenses, or money. It is a
    manual user-only action and has no unattended-agent override.

    If it is genuinely required, review and run the exact command yourself in
    your own terminal. Ordinary edits, tests, commits, feature pushes, PRs,
    deploys, uploads, and reversible operations remain available to agents.
  MESSAGE
  exit 2
end

exit 0
