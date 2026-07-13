#!/usr/bin/env ruby
# frozen_string_literal: true

# Installs/updates Codex automations on the Mac Mini from a JSON (or TOML) spec.
# The live store is ~/.codex/automations/<id>/automation.toml.
#
#   ruby codex-automation-mini.rb install /path/to/spec.json
#   ruby codex-automation-mini.rb list
#   ruby codex-automation-mini.rb validate
#
# Policy (enforced via scripts/hooks/sane_automation_guard.rb): cron specs need
# id/kind/name/prompt/status/rrule + model gpt-5.5+ with reasoning_effort
# medium+ and Mini-local cwds; heartbeats need target_thread_id. Installs are
# refused on non-Mini hosts — run from the Air via `ssh mini '...'`.

require 'json'
require 'socket'
require_relative '../hooks/sane_automation_guard'

STORE = File.expand_path(ENV.fetch('SANE_AUTOMATION_STORE', '~/.codex/automations'))
FIELD_ORDER = %w[version id kind name prompt status rrule model reasoning_effort
                 execution_environment cwds target_thread_id created_at updated_at].freeze

def toml_escape(str)
  str.gsub('\\', '\\\\\\\\').gsub('"', '\"').gsub("\n", '\n').gsub("\t", '\t')
end

def toml_value(val)
  case val
  when Integer then val.to_s
  when Array then "[#{val.map { |x| %("#{toml_escape(x.to_s)}") }.join(', ')}]"
  else %("#{toml_escape(val.to_s)}")
  end
end

def write_toml(path, auto)
  lines = FIELD_ORDER.map do |key|
    next unless auto.key?(key)

    "#{key} = #{toml_value(auto[key])}"
  end.compact
  File.write(path, lines.join("\n") + "\n")
end

def load_spec(path)
  # Force UTF-8: hook/automation shells may run under a C locale, which tags
  # reads US-ASCII and crashes JSON/TOML parsing on em dashes etc.
  text = File.read(path, encoding: 'UTF-8')
  return JSON.parse(text) if path.end_with?('.json')

  SaneAutomationGuard.parse_toml(text)
end

def require_mini_host!
  return if SaneAutomationGuard.mini_host?
  return if ENV['SANE_AUTOMATION_STORE'] # test/sandbox stores may live anywhere

  warn 'codex-automation-mini: refusing to modify the automation store from a '\
       "non-Mini host (#{Socket.gethostname}). Run via: ssh mini '...'"
  exit 1
end

def cmd_install(spec_path)
  unless spec_path && File.file?(spec_path)
    warn "codex-automation-mini: spec not found: #{spec_path}"
    exit 1
  end
  require_mini_host!

  auto = load_spec(spec_path)
  auto['version'] ||= 1
  id = auto['id'].to_s
  problems = SaneAutomationGuard.validate_automation(auto, dir_id: id, host_is_mini: true)
  unless problems.empty?
    warn "codex-automation-mini: spec rejected for `#{id}`:"
    problems.each { |p| warn "  - #{p}" }
    exit 1
  end

  dir = File.join(STORE, id)
  toml_path = File.join(dir, 'automation.toml')
  now_ms = (Time.now.to_f * 1000).to_i
  if File.file?(toml_path)
    existing = SaneAutomationGuard.parse_toml(File.read(toml_path, encoding: 'UTF-8'))
    auto['created_at'] = existing['created_at'] || now_ms
  else
    auto['created_at'] ||= now_ms
  end
  auto['updated_at'] = now_ms

  Dir.mkdir(dir) unless File.directory?(dir)
  write_toml(toml_path, auto)
  warn "codex-automation-mini: installed `#{id}` (#{auto['kind']}, #{auto['status']})"

  report = SaneAutomationGuard.validate_store(STORE)
  if report[:violations].empty?
    warn "codex-automation-mini: store OK — #{report[:checked]} automation(s) valid"
    puts toml_path
    exit 0
  else
    warn 'codex-automation-mini: WARNING — store has pre-existing violations:'
    report[:violations].each { |vid, ps| ps.each { |p| warn "  - #{vid}: #{p}" } }
    puts toml_path
    exit 1
  end
end

def cmd_list
  Dir.glob(File.join(STORE, '*/automation.toml')).sort.each do |path|
    auto = SaneAutomationGuard.parse_toml(File.read(path, encoding: 'UTF-8'))
    puts format('%-45s %-10s %-7s %s', auto['id'], auto['kind'], auto['status'], auto['rrule'])
  end
end

case ARGV[0]
when 'install' then cmd_install(ARGV[1])
when 'list' then cmd_list
when 'validate'
  exec('ruby', File.expand_path('../hooks/sane_automation_guard.rb', __dir__), '--validate', STORE)
else
  warn 'usage: codex-automation-mini.rb install <spec.json>|list|validate'
  exit 1
end
