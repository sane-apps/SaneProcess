#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the Codex automation store (~/.codex/automations/<id>/automation.toml)
# against the SaneApps automation policy in ~/AGENTS.md:
#   - cron automations must use gpt-5.5 or newer with reasoning_effort medium+
#   - cron cwds must be non-empty absolute Mini-local paths
#   - heartbeats must target an existing Mini-local thread (presence checked)
#   - on any non-Mini host (e.g. the Air), every automation must stay PAUSED
#
# CLI: ruby sane_automation_guard.rb --validate ~/.codex/automations
# Exit 0 = store passes, 1 = violations (listed on stderr).

require 'socket'

module SaneAutomationGuard
  DEFAULT_STORE = File.expand_path('~/.codex/automations')
  REQUIRED_FIELDS = %w[id kind name prompt status rrule].freeze
  EFFORT_OK = %w[medium high xhigh].freeze
  MIN_GPT_VERSION = 5.5

  module_function

  def mini_host?(hostname = Socket.gethostname)
    hostname.to_s.downcase.include?('mini')
  end

  # Minimal flat-TOML reader for the automation schema:
  # key = "string" | key = 123 | key = ["a", "b"]
  # Input is force-tagged UTF-8: C-locale shells hand us US-ASCII strings that
  # crash gsub on em dashes (the known SaneProcess encoding-wipe disease).
  def parse_toml(text)
    text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
    result = {}
    text.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, _, raw = line.partition('=')
      key = key.strip
      raw = raw.strip
      next if key.empty? || raw.empty?

      result[key] =
        if raw.start_with?('[')
          raw[1..-2].to_s.scan(/"((?:\\.|[^"\\])*)"/).flatten.map { |s| unescape(s) }
        elsif raw.start_with?('"')
          unescape(raw[/\A"((?:\\.|[^"\\])*)"/, 1].to_s)
        elsif raw =~ /\A-?\d+\z/
          raw.to_i
        else
          raw
        end
    end
    result
  end

  def unescape(str)
    str.gsub(/\\(["\\nt])/) { { '"' => '"', '\\' => '\\', 'n' => "\n", 't' => "\t" }[Regexp.last_match(1)] }
  end

  def gpt_version_ok?(model)
    m = model.to_s.match(/\Agpt-(\d+(?:\.\d+)?)/)
    return false unless m

    m[1].to_f >= MIN_GPT_VERSION
  end

  # Returns an array of violation strings (empty = valid).
  def validate_automation(auto, dir_id:, host_is_mini: mini_host?)
    v = []
    REQUIRED_FIELDS.each do |f|
      v << "missing required field `#{f}`" if auto[f].to_s.strip.empty?
    end
    v << "id `#{auto['id']}` does not match directory `#{dir_id}`" if auto['id'] && auto['id'] != dir_id
    v << "status `#{auto['status']}` must be ACTIVE or PAUSED" unless %w[ACTIVE PAUSED].include?(auto['status'])
    v << "kind `#{auto['kind']}` must be cron or heartbeat" unless %w[cron heartbeat].include?(auto['kind'])
    v << 'must stay PAUSED on non-Mini hosts (Air copies stay paused)' if !host_is_mini && auto['status'] == 'ACTIVE'

    case auto['kind']
    when 'cron'
      v << "cron model `#{auto['model']}` must be gpt-#{MIN_GPT_VERSION} or newer" unless gpt_version_ok?(auto['model'])
      unless EFFORT_OK.include?(auto['reasoning_effort'].to_s)
        v << "cron reasoning_effort `#{auto['reasoning_effort']}` must be one of #{EFFORT_OK.join('/')}"
      end
      cwds = auto['cwds']
      if !cwds.is_a?(Array) || cwds.empty?
        v << 'cron must declare non-empty `cwds`'
      else
        cwds.each do |c|
          v << "cron cwd `#{c}` must be an absolute path" unless c.to_s.start_with?('/')
        end
      end
    when 'heartbeat'
      v << 'heartbeat must declare `target_thread_id`' if auto['target_thread_id'].to_s.strip.empty?
    end
    v
  end

  # Returns { checked:, skipped:, violations: { "<id>" => [..] } }
  def validate_store(store_dir, host_is_mini: mini_host?)
    checked = 0
    skipped = 0
    violations = {}
    Dir.glob(File.join(store_dir, '*')).sort.each do |dir|
      next unless File.directory?(dir)

      toml_path = File.join(dir, 'automation.toml')
      unless File.file?(toml_path)
        skipped += 1 # runtime artifact dirs (manual-review, run logs, ...) carry no spec
        next
      end
      checked += 1
      dir_id = File.basename(dir)
      begin
        # UTF-8 forced: C-locale shells tag reads US-ASCII and break on em dashes
        auto = parse_toml(File.read(toml_path, encoding: 'UTF-8'))
      rescue StandardError => e
        violations[dir_id] = ["automation.toml unreadable: #{e.message}"]
        next
      end
      problems = validate_automation(auto, dir_id: dir_id, host_is_mini: host_is_mini)
      violations[dir_id] = problems unless problems.empty?
    end
    { checked: checked, skipped: skipped, violations: violations }
  end
end

if __FILE__ == $PROGRAM_NAME
  args = ARGV.dup
  store = SaneAutomationGuard::DEFAULT_STORE
  if (i = args.index('--validate'))
    store = File.expand_path(args[i + 1]) if args[i + 1]
  end
  unless File.directory?(store)
    warn "sane_automation_guard: store not found: #{store}"
    exit 1
  end

  report = SaneAutomationGuard.validate_store(store)
  if report[:violations].empty?
    warn "sane_automation_guard: OK — #{report[:checked]} automation(s) valid, #{report[:skipped]} non-spec dir(s) skipped"
    exit 0
  end

  warn "sane_automation_guard: VIOLATIONS in #{store}"
  report[:violations].each do |id, problems|
    problems.each { |p| warn "  - #{id}: #{p}" }
  end
  warn "sane_automation_guard: #{report[:violations].size} automation(s) failed of #{report[:checked]} checked"
  exit 1
end
