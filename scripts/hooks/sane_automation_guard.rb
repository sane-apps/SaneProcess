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

require 'json'
require 'open3'
require 'pathname'
require 'socket'

module SaneAutomationGuard
  DEFAULT_STORE = File.expand_path('~/.codex/automations')
  DEFAULT_STATE_DB = File.expand_path(ENV.fetch('SANE_AUTOMATION_STATE_DB', '~/.codex/state_5.sqlite'))
  DEFAULT_SESSIONS_ROOT = File.expand_path(ENV.fetch('SANE_AUTOMATION_SESSIONS_ROOT', '~/.codex/sessions'))
  DEFAULT_ALLOWED_CWD_ROOTS = ENV.fetch('SANE_AUTOMATION_ALLOWED_CWD_ROOTS', '/Users/stephansmac/SaneApps')
                                 .split(File::PATH_SEPARATOR).map { |path| File.expand_path(path) }.freeze
  REQUIRED_FIELDS = %w[id kind name prompt status rrule].freeze
  EFFORT_OK = %w[medium high xhigh max ultra].freeze
  MIN_GPT_VERSION = [5, 5].freeze
  MIN_GPT_LABEL = MIN_GPT_VERSION.join('.').freeze
  CANONICAL_UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
  THREAD_COLUMNS = %w[id archived cwd rollout_path model reasoning_effort].freeze

  class SqliteThreadStore
    def initialize(sqlite_command: ENV.fetch('SQLITE3', 'sqlite3'))
      @sqlite_command = sqlite_command
    end

    def fetch_thread(db_path, thread_id)
      raise "state DB is not a readable regular file: #{db_path}" unless File.file?(db_path) && File.readable?(db_path)

      columns = query(db_path, 'PRAGMA table_info(threads)').map { |column| column['name'] }
      missing = THREAD_COLUMNS - columns
      raise "threads schema missing columns: #{missing.join(', ')}" unless missing.empty?

      query(db_path, <<~SQL)
        SELECT id, archived, cwd, rollout_path, model, reasoning_effort
        FROM threads
        WHERE id = '#{thread_id}'
      SQL
    end

    private

    def query(db_path, sql)
      stdout, stderr, status = Open3.capture3(@sqlite_command, '-readonly', '-json', db_path, sql)
      raise "read-only SQLite query failed: #{stderr.strip}" unless status.success?

      JSON.parse(stdout.empty? ? '[]' : stdout)
    rescue JSON::ParserError => e
      raise "invalid SQLite JSON output: #{e.message}"
    end
  end

  class HeartbeatTargetResolver
    def initialize(state_db: DEFAULT_STATE_DB, sessions_root: DEFAULT_SESSIONS_ROOT,
                   allowed_cwd_roots: DEFAULT_ALLOWED_CWD_ROOTS, thread_store: SqliteThreadStore.new)
      @state_db = File.expand_path(state_db)
      @sessions_root = File.expand_path(sessions_root)
      @allowed_cwd_roots = allowed_cwd_roots.map { |path| File.expand_path(path) }
      @thread_store = thread_store
    end

    def validate(thread_id, automation: {})
      return ['heartbeat target_thread_id must be a canonical lowercase UUID'] unless CANONICAL_UUID.match?(thread_id.to_s)

      rows = @thread_store.fetch_thread(@state_db, thread_id)
      return ["heartbeat target `#{thread_id}` has no thread row in the current state DB"] if rows.empty?
      return ["heartbeat target `#{thread_id}` has #{rows.size} thread rows; expected exactly one"] unless rows.size == 1

      row = rows.first
      violations = []
      violations << "heartbeat target `#{thread_id}` is archived" unless row['archived'].to_i.zero?

      cwd = row['cwd'].to_s
      violations << "heartbeat target cwd `#{cwd}` is not an allowed Mini-local directory" unless allowed_cwd?(cwd)

      metadata = rollout_metadata(row['rollout_path'].to_s, violations)
      if metadata
        violations << "rollout session_meta id `#{metadata['id']}` does not match target `#{thread_id}`" unless metadata['id'] == thread_id
        unless normalized_path(metadata['cwd']) == normalized_path(cwd)
          violations << "rollout cwd `#{metadata['cwd']}` does not agree with thread cwd `#{cwd}`"
        end
      end

      unless model_effort_compliant?(row['model'], row['reasoning_effort'])
        violations << "heartbeat thread row model/reasoning must be gpt-#{MIN_GPT_LABEL}+ with #{EFFORT_OK.join('/')} effort"
      end
      violations
    rescue StandardError => e
      ["heartbeat target validation failed closed: #{e.message}"]
    end

    private

    def normalized_path(path)
      return nil unless Pathname.new(path.to_s).absolute?

      File.expand_path(path)
    end

    def contained_path?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end

    def allowed_cwd?(cwd)
      return false unless Pathname.new(cwd).absolute? && File.directory?(cwd)

      real_cwd = File.realpath(cwd)
      @allowed_cwd_roots.any? do |root|
        File.directory?(root) && contained_path?(real_cwd, File.realpath(root))
      end
    rescue SystemCallError
      false
    end

    def rollout_metadata(rollout_path, violations)
      unless File.file?(rollout_path)
        violations << "heartbeat rollout is missing or not a regular file: #{rollout_path}"
        return nil
      end

      real_root = File.realpath(@sessions_root)
      real_rollout = File.realpath(rollout_path)
      unless contained_path?(real_rollout, real_root)
        violations << "heartbeat rollout escapes the current sessions root: #{rollout_path}"
        return nil
      end

      File.foreach(real_rollout, encoding: 'UTF-8') do |line|
        next if line.strip.empty?

        entry = JSON.parse(line)
        return entry['payload'] if entry['type'] == 'session_meta' && entry['payload'].is_a?(Hash)
      end
      violations << "heartbeat rollout has no session_meta record: #{rollout_path}"
      nil
    rescue JSON::ParserError => e
      violations << "heartbeat rollout contains invalid JSON before session_meta: #{e.message}"
      nil
    rescue SystemCallError => e
      violations << "heartbeat rollout is unreadable: #{e.message}"
      nil
    end

    def model_effort_compliant?(model, effort)
      SaneAutomationGuard.gpt_version_ok?(model) && EFFORT_OK.include?(effort.to_s)
    end
  end

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
    m = model.to_s.match(/\Agpt-(\d+)(?:\.(\d+))?(?:-|$)/)
    return false unless m

    ([m[1].to_i, m[2].to_i] <=> MIN_GPT_VERSION) >= 0
  end

  # Returns an array of violation strings (empty = valid).
  def validate_automation(auto, dir_id:, host_is_mini: mini_host?, target_resolver: HeartbeatTargetResolver.new)
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
      v << "cron model `#{auto['model']}` must be gpt-#{MIN_GPT_LABEL} or newer" unless gpt_version_ok?(auto['model'])
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
      # PAUSED specs are safe storage. Activation is the boundary that requires
      # a real current-session target, so stale targets cannot become ACTIVE.
      if auto['status'] == 'ACTIVE'
        v.concat(target_resolver.validate(auto['target_thread_id'].to_s, automation: auto))
      end
    end
    v
  end

  # Returns { checked:, skipped:, violations: { "<id>" => [..] } }
  def validate_store(store_dir, host_is_mini: mini_host?, target_resolver: HeartbeatTargetResolver.new)
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
      problems = validate_automation(auto, dir_id: dir_id, host_is_mini: host_is_mini,
                                    target_resolver: target_resolver)
      violations[dir_id] = problems unless problems.empty?
    end
    live_targets_checked = Dir.glob(File.join(store_dir, '*/automation.toml')).count do |path|
      auto = parse_toml(File.read(path, encoding: 'UTF-8'))
      auto['kind'] == 'heartbeat' && auto['status'] == 'ACTIVE'
    rescue StandardError
      false
    end
    { checked: checked, skipped: skipped, live_targets_checked: live_targets_checked, violations: violations }
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
    warn "sane_automation_guard: OK — #{report[:checked]} automation spec(s) schema-valid; " \
         "#{report[:live_targets_checked]} ACTIVE heartbeat target(s) live-target-valid; " \
         "#{report[:skipped]} non-spec dir(s) skipped"
    exit 0
  end

  warn "sane_automation_guard: VIOLATIONS in #{store}"
  report[:violations].each do |id, problems|
    problems.each { |p| warn "  - #{id}: #{p}" }
  end
  warn "sane_automation_guard: #{report[:violations].size} automation(s) failed of #{report[:checked]} checked"
  exit 1
end
