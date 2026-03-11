#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_test.rb — Unified test launch for all SaneApps
#
# Usage:
#   ruby scripts/sane_test.rb SaneBar
#   ruby scripts/sane_test.rb SaneClip --local
#   ruby scripts/sane_test.rb SaneBar --no-logs
#
# Default behavior:
#   1. Detects if Mac mini is reachable (2s timeout)
#   2. If reachable → deploy + test on mini (MacBook Air = production only)
#   3. If unreachable → test locally (coffee shop mode)
#   4. --local flag forces local testing

require 'open3'
require 'fileutils'
require 'tmpdir'
require 'shellwords'
require 'time'

APPS = {
  'SaneBar' => {
    dev: 'com.sanebar.dev',
    prod: 'com.sanebar.app',
    scheme: 'SaneBar',
    log_subsystem: 'com.sanebar'
  },
  'SaneClick' => {
    dev: 'com.saneclick.SaneClick',
    prod: 'com.saneclick.SaneClick',
    scheme: 'SaneClick',
    log_subsystem: 'com.saneclick'
  },
  'SaneClip' => {
    dev: 'com.saneclip.dev',
    prod: 'com.saneclip.app',
    scheme: 'SaneClip',
    log_subsystem: 'com.saneclip'
  },
  'SaneHosts' => {
    dev: 'com.mrsane.SaneHosts',
    prod: 'com.mrsane.SaneHosts',
    scheme: 'SaneHosts',
    log_subsystem: 'com.mrsane'
  },
  'SaneSales' => {
    dev: 'com.sanesales.dev',
    prod: 'com.sanesales.app',
    scheme: 'SaneSales',
    log_subsystem: 'com.sanesales'
  },
  'SaneSync' => {
    dev: 'com.sanesync.SaneSync',
    prod: 'com.sanesync.SaneSync',
    scheme: 'SaneSync',
    log_subsystem: 'com.sanesync'
  },
  'SaneVideo' => {
    dev: 'com.sanevideo.app',
    prod: 'com.sanevideo.app',
    scheme: 'SaneVideo',
    log_subsystem: 'com.sanevideo'
  }
}.freeze

SANE_APPS_ROOT = File.expand_path('~/SaneApps/apps')
MINI_HOST = 'mini'
MINI_APPS_DIR = '/Applications'
MINI_LEGACY_USER_APPS_DIR = '~/Applications'

class SaneTest
  def initialize(app_name, args)
    @app_name = app_name
    @config = APPS[app_name]
    @raw_args = args.dup
    @force_local = args.include?('--local')
    @no_logs = args.include?('--no-logs')
    @free_mode = args.include?('--free-mode')
    @pro_mode = args.include?('--pro-mode')
    @reset_tcc = args.include?('--reset-tcc')
    @repair_accessibility = args.include?('--repair-accessibility') || ENV['SANETEST_REPAIR_ACCESSIBILITY'] == '1'
    @fresh = args.include?('--fresh')
    @allow_keychain = args.include?('--allow-keychain')
    @allow_unsigned_debug = args.include?('--allow-unsigned-debug')
    @release_build = args.include?('--release')
    @target = nil
    @last_build_config = nil
    @app_dir = File.join(SANE_APPS_ROOT, app_name)

    abort "❌ Unknown app: #{app_name}. Known: #{APPS.keys.join(', ')}" unless @config
    abort "❌ App directory not found: #{@app_dir}" unless File.directory?(@app_dir)
    abort '❌ Cannot use --free-mode and --pro-mode together' if @free_mode && @pro_mode
  end

  def run
    puts "🧪 === SANE TEST: #{@app_name} ==="
    puts ''

    @target = determine_target
    puts "📍 Target: #{@target == :mini ? 'Mac mini (remote)' : 'Local'}"
    puts ''

    case @target
    when :mini then run_remote
    when :local then run_local
    end
  end

  private

  def determine_target
    return :local if @force_local

    if mini_reachable?
      puts '✅ Mac mini is reachable → deploying there'
      :mini
    else
      puts '⚠️  Mac mini not reachable → testing locally'
      :local
    end
  end

  def mini_reachable?
    system('ssh', '-o', 'ConnectTimeout=2', '-o', 'BatchMode=yes', MINI_HOST, 'true',
           out: File::NULL, err: File::NULL)
  end

  def bundle_ids
    [@config[:dev], @config[:prod]].uniq
  end

  def canonical_remote_app_path
    "#{MINI_APPS_DIR}/#{@app_name}.app"
  end

  def legacy_remote_user_app_path
    "#{MINI_LEGACY_USER_APPS_DIR}/#{@app_name}.app"
  end

  def remote_runtime_bundle_id
    cmd = %(APP="#{canonical_remote_app_path}/Contents/Info.plist"; /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP" 2>/dev/null)
    bid = ssh_capture(cmd).strip
    return bid if bid.match?(/\A[a-zA-Z0-9.\-]+\z/)

    @config[:prod]
  end

  # ── Remote (Mac mini) workflow ──────────────────────────────

  def run_remote
    remote_app_dir = map_local_path_to_mini(@app_dir)
    remote_script_path = map_local_path_to_mini(__FILE__)
    remote_saneprocess_dir = File.dirname(File.dirname(remote_script_path))

    abort "❌ Could not map app repo to mini: #{@app_dir}" unless remote_app_dir
    abort "❌ Could not map sane_test.rb to mini: #{__FILE__}" unless remote_script_path

    n = 0
    step("#{n += 1}. Sync SaneProcess launcher to mini") { sync_file_to_mini(__FILE__, remote_script_path) }
    step("#{n += 1}. Sync app workspace to mini") { sync_repo_to_mini(@app_dir, remote_app_dir) }
    step("#{n += 1}. Run full build + launch flow on mini") { exec_remote_sane_test(remote_saneprocess_dir) }
  end

  def kill_remote
    ssh("killall -9 #{@app_name} 2>/dev/null; true")
    sleep 1
    result = ssh_capture("pgrep -x #{@app_name} 2>/dev/null").strip
    abort "   ❌ Failed to kill #{@app_name} (PID: #{result})" unless result.empty?
  end

  def clean_remote
    count = 0
    # Remove from ALL possible locations — there must be ZERO copies before deploy
    locations = [
      canonical_remote_app_path,
      legacy_remote_user_app_path,
      "/Applications/#{@app_name}.app",
      "/tmp/#{@app_name}.app",
      "/tmp/#{@app_name}-dev.tar.gz"
    ]
    locations.each do |loc|
      exists = ssh_capture("[ -e #{loc} ] && echo yes || echo no").strip
      if exists == 'yes'
        ssh("rm -rf #{loc}")
        count += 1
      end
    end
    # Also nuke any .app bundles in DerivedData on the mini (shouldn't exist but safety)
    dd_apps = ssh_capture("find ~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products -name '#{@app_name}.app' -type d 2>/dev/null").strip
    dd_apps.split("\n").reject(&:empty?).each do |path|
      ssh("rm -rf '#{path}'")
      count += 1
    end
    # Flush Launch Services so macOS doesn't resolve to a stale cached path
    ssh("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null; true")
    warn "   Removed #{count} stale copies, flushed Launch Services on mini"
  end

  def reset_tcc_remote
    bids = [remote_runtime_bundle_id].compact.uniq
    bids.each do |bid|
      escaped_bid = Shellwords.escape(bid)
      ssh("tccutil reset All #{escaped_bid} 2>/dev/null; true")
      ssh("tccutil reset Accessibility #{escaped_bid} 2>/dev/null; true")
    end
    warn "   Reset TCC for: #{bids.join(', ')}"
  end

  def fresh_reset_remote
    # Wipe Application Support
    ssh("rm -rf \"$HOME/Library/Application Support/#{@app_name}\" 2>/dev/null; true")
    # Wipe UserDefaults for ALL bundle IDs (dev + prod) and flush preferences cache
    bundle_ids.each do |b|
      ssh("defaults delete #{b} 2>/dev/null; true")
      ssh("rm -f \"$HOME/Library/Preferences/#{b}.plist\" 2>/dev/null; true")
      ssh("rm -f \"$HOME/Library/Containers/#{b}/Data/Library/Preferences/#{b}.plist\" 2>/dev/null; true")
    end
    ssh("killall cfprefsd 2>/dev/null; true")
    # Reset TCC/Accessibility for the actual runtime bundle only
    runtime_bids = [remote_runtime_bundle_id].compact.uniq
    runtime_bids.each do |b|
      escaped_b = Shellwords.escape(b)
      ssh("tccutil reset All #{escaped_b} 2>/dev/null; true")
    end
    # Clear no-keychain fallback license data for ALL bundle IDs
    runtime_bids.each { |b| clear_license_fallback_remote(b) }
    warn "   Wiped App Support, UserDefaults, TCC, fallback license for #{runtime_bids.join(', ')}"
  end

  def fresh_reset_local
    # Wipe Application Support
    app_support = File.expand_path("~/Library/Application Support/#{@app_name}")
    FileUtils.rm_rf(app_support) if File.exist?(app_support)
    # Wipe UserDefaults for ALL bundle IDs (dev + prod) and flush preferences cache
    bundle_ids.each do |b|
      system('defaults', 'delete', b, err: File::NULL, out: File::NULL)
      prefs_file = File.expand_path("~/Library/Preferences/#{b}.plist")
      FileUtils.rm_f(prefs_file) if File.exist?(prefs_file)
      container_prefs = File.expand_path("~/Library/Containers/#{b}/Data/Library/Preferences/#{b}.plist")
      FileUtils.rm_f(container_prefs) if File.exist?(container_prefs)
    end
    system('killall', 'cfprefsd', err: File::NULL, out: File::NULL)
    # Reset TCC/Accessibility
    bundle_ids.each do |b|
      system('tccutil', 'reset', 'All', b, out: File::NULL, err: File::NULL)
    end
    # Clear no-keychain fallback license data for ALL bundle IDs
    bundle_ids.each { |b| clear_license_fallback_local(b) }
    warn "   Wiped App Support, UserDefaults, TCC, fallback license for #{bundle_ids.join(', ')}"
  end

  def verify_single_copy_remote
    # After deploy, ensure ONLY the canonical copy exists
    canonical = canonical_remote_app_path
    copies = ssh_capture("mdfind 'kMDItemFSName == \"#{@app_name}.app\"' 2>/dev/null").strip.split("\n").reject(&:empty?)
    # Filter to actual .app bundles (mdfind can return partial matches)
    copies.select! { |p| p.end_with?("#{@app_name}.app") }
    canonical_expanded = canonical.sub('~', '$HOME')
    non_canonical = copies.reject { |p| p == canonical || p == canonical_expanded || p == canonical.gsub('~', '/Users/stephansmac') }
    if non_canonical.empty?
      warn "   Single copy verified at #{canonical}"
    else
      warn "   ⚠️  Found #{non_canonical.size} extra copies — removing:"
      non_canonical.each do |path|
        warn "      #{path}"
        ssh("rm -rf '#{path}'")
      end
      # Re-flush Launch Services after cleanup
      ssh("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null; true")
    end
  end

  def dedupe_accessibility_entries_remote
    runtime_bid = remote_runtime_bundle_id
    other_bids = bundle_ids.reject { |bid| bid == runtime_bid }
    return if other_bids.empty?

    # macOS can materialize a disabled ghost row when tccutil reset is called
    # on bundle IDs that are not currently granted. Only reset entries that are
    # actively granted to avoid reintroducing duplicate "SaneBar" rows.
    granted_other_bids = other_bids.select { |bid| accessibility_auth_value_remote(bid) == 2 }
    if granted_other_bids.empty?
      warn "   Dedupe: no extra granted Accessibility entries to reset (running #{runtime_bid})"
      return
    end

    unless repair_accessibility?
      warn "   Dedupe: found extra granted Accessibility entries for #{granted_other_bids.join(', ')}; leaving them alone"
      warn '   Re-run with --repair-accessibility if you want those entries reset.'
      return
    end

    granted_other_bids.each do |bid|
      escaped_bid = Shellwords.escape(bid)
      ssh("tccutil reset Accessibility #{escaped_bid} 2>/dev/null; true")
    end

    warn "   Dedupe: reset Accessibility for #{granted_other_bids.join(', ')} (running #{runtime_bid})"
  end

  def accessibility_auth_value_remote(bundle_id)
    escaped_bundle = bundle_id.gsub("'", "''")
    dbs = [
      '$HOME/Library/Application Support/com.apple.TCC/TCC.db',
      '/Library/Application Support/com.apple.TCC/TCC.db'
    ]

    dbs.each do |db|
      db_exists = ssh_capture("DB=\"#{db}\"; [ -f \"$DB\" ] && echo yes || echo no").strip
      next unless db_exists == 'yes'

      sql = "SELECT auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}' ORDER BY rowid DESC LIMIT 1;"
      value = ssh_capture("DB=\"#{db}\"; sqlite3 \"$DB\" #{Shellwords.escape(sql)} 2>/dev/null").strip
      return value.to_i if value.match?(/\A\d+\z/)
    end

    nil
  end

  def reconcile_accessibility_trust_remote
    app_path = canonical_remote_app_path
    info_plist = "#{app_path}/Contents/Info.plist"
    bundle_id = ssh_capture("/usr/libexec/PlistBuddy -c \"Print :CFBundleIdentifier\" #{Shellwords.escape(info_plist)} 2>/dev/null").strip
    return unless bundle_id.match?(/\A[a-zA-Z0-9.\-]+\z/)

    escaped_bundle = bundle_id.gsub("'", "''")
    dbs = [
      '$HOME/Library/Application Support/com.apple.TCC/TCC.db',
      '/Library/Application Support/com.apple.TCC/TCC.db'
    ]

    stale_detected = false

    dbs.each do |db|
      db_exists = ssh_capture("[ -f \"#{db}\" ] && echo yes || echo no").strip
      next unless db_exists == 'yes'

      sql = "SELECT rowid || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}';"
      rows_raw = ssh_capture("sqlite3 #{Shellwords.escape(db)} #{Shellwords.escape(sql)}").strip
      next if rows_raw.empty?

      rows_raw.each_line do |line|
        row = line.strip
        next if row.empty?

        _, csreq_hex = row.split('|', 2)

        if csreq_hex.nil? || csreq_hex.empty?
          stale_detected = true
          break
        end

        csreq_path = File.join(Dir.tmpdir, "saneapps-ax-remote-#{@app_name}-#{Process.pid}-#{Time.now.to_i}.csreq")
        begin
          File.binwrite(csreq_path, [csreq_hex].pack('H*'))
          requirement = `csreq -r "#{csreq_path}" -t 2>/dev/null`.strip
          if requirement.empty?
            stale_detected = true
            break
          end

          remote_requirement = Shellwords.escape(requirement)
          remote_app = Shellwords.escape(canonical_remote_app_path)
          matches = system('ssh', MINI_HOST, "codesign -R #{remote_requirement} #{remote_app}",
                           out: File::NULL, err: File::NULL)
          unless matches
            stale_detected = true
            break
          end
        ensure
          FileUtils.rm_f(csreq_path)
        end
      end

      break if stale_detected
    end

    return unless stale_detected

    unless repair_accessibility?
      warn "   Repair: stale Accessibility trust detected for #{bundle_id}; leaving it unchanged"
      warn '   Re-run with --repair-accessibility if you want that Accessibility grant reset.'
      return
    end

    warn "   Repair: stale Accessibility trust detected for #{bundle_id}; resetting Accessibility grant"
    ssh("tccutil reset Accessibility #{bundle_id} 2>/dev/null; true")
    ssh("killall tccd 2>/dev/null; true")
  end

  def deploy_to_mini
    dd_app = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless dd_app

    tar_path = "/tmp/#{@app_name}-dev.tar.gz"
    system('tar', 'czf', tar_path, '-C', File.dirname(dd_app), "#{@app_name}.app")

    unless system('scp', '-o', 'ConnectTimeout=5', tar_path, "#{MINI_HOST}:/tmp/")
      abort '   ❌ Failed to upload to mini'
    end

    ssh("mkdir -p #{MINI_APPS_DIR} && tar xzf /tmp/#{@app_name}-dev.tar.gz -C #{MINI_APPS_DIR}/")
    warn "   Deployed to #{MINI_HOST}:#{canonical_remote_app_path}"
  end

  def launch_remote
    env_args = launch_env_pairs
    launch_cmd =
      if @allow_keychain
        "open #{env_args.join(' ')} #{canonical_remote_app_path}"
      else
        "open #{env_args.join(' ')} #{canonical_remote_app_path} --args --sane-no-keychain"
      end
    ssh(launch_cmd)
    sleep 2
    pid = ssh_capture("pgrep -x #{@app_name} 2>/dev/null").strip
    abort '   ❌ App failed to launch on mini' if pid.empty?
    warn "   Running (PID: #{pid})"
  end

  def stream_logs_remote
    puts ''
    puts '📡 Streaming logs from mini (Ctrl+C to stop)...'
    puts '─' * 60
    Kernel.exec('ssh', '-o', 'ServerAliveInterval=30', MINI_HOST, 'log', 'stream', '--predicate',
                "subsystem BEGINSWITH \"#{@config[:log_subsystem]}\"", '--info', '--debug', '--style', 'compact')
  end

  # ── Local workflow ──────────────────────────────────────────

  def run_local
    n = 0
    step("#{n += 1}. Kill existing processes") { kill_local }
    step("#{n += 1}. Clean ALL stale copies") { clean_local }
    build_label = @release_build ? 'Build fresh release build' : 'Build fresh debug build'
    step("#{n += 1}. #{build_label}") { build_debug }
    step("#{n += 1}. Verify single copy") { verify_single_copy_local }
    step("#{n += 1}. Inspect Accessibility entries") { dedupe_accessibility_entries_local }
    step("#{n += 1}. Fresh reset") { fresh_reset_local } if @fresh
    step("#{n += 1}. Reset TCC permissions") { reset_tcc_local } if @reset_tcc && !@fresh
    step("#{n += 1}. Set license mode") { set_license_mode_local } if (@free_mode || @pro_mode) && !@fresh
    step("#{n += 1}. Launch locally") { launch_local }
    stream_logs_local unless @no_logs
  end

  def kill_local
    system('killall', '-9', @app_name, err: File::NULL)
    sleep 1
    abort "   ❌ Failed to kill #{@app_name}" if system('pgrep', '-x', @app_name, out: File::NULL)
  end

  def clean_local
    temp_paths = ["/tmp/#{@app_name}-dev.tar.gz"]
    removed_temp_files = temp_paths.count do |path|
      next false unless File.exist?(path)

      FileUtils.rm_f(path)
      true
    end
    trashed_copies = trash_noncanonical_local_app_copies
    warn "   Removed #{removed_temp_files} temp file(s), trashed #{trashed_copies} non-canonical app bundle(s)"
  end

  def verify_single_copy_local
    dd_app = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless dd_app
    canonical = stage_to_canonical_local_app_path(dd_app)
    trashed_copies = trash_noncanonical_local_app_copies(preserve_path: canonical)
    remaining = local_app_copy_paths.reject { |path| File.expand_path(path) == File.expand_path(canonical) }
    unless remaining.empty?
      warn "   Remaining copies: #{remaining.join(', ')}"
      abort "   ❌ Expected a single runtime copy at #{canonical}"
    end

    warn "   Single runtime copy verified at #{canonical}"
    warn "   Trashed #{trashed_copies} non-canonical app bundle(s)" if trashed_copies.positive?
  end

  def dedupe_accessibility_entries_local
    # For apps with distinct dev/pro bundle IDs, remove the non-runtime grant
    # so System Settings doesn't show duplicate entries for the same app.
    return unless @config[:dev] && @config[:prod] && @config[:dev] != @config[:prod]

    app_path = if File.exist?(canonical_local_app_path)
                 canonical_local_app_path
               else
                 find_derived_data_app
               end
    return unless app_path

    info_plist = File.join(app_path, 'Contents', 'Info.plist')
    runtime_bundle = `"/usr/libexec/PlistBuddy" -c "Print :CFBundleIdentifier" "#{info_plist}" 2>/dev/null`.strip
    non_runtime = [@config[:dev], @config[:prod]].uniq.reject { |bid| bid == runtime_bundle }
    return if non_runtime.empty?

    granted_non_runtime = non_runtime.select { |bid| accessibility_auth_value_local(bid) == 2 }
    if granted_non_runtime.empty?
      warn "   Dedupe: no extra granted Accessibility entries to reset (running #{runtime_bundle})"
      return
    end

    unless repair_accessibility?
      warn "   Dedupe: found extra granted Accessibility entries for #{granted_non_runtime.join(', ')}; leaving them alone"
      warn '   Re-run with --repair-accessibility if you want those entries reset.'
      return
    end

    granted_non_runtime.each do |bid|
      system('tccutil', 'reset', 'Accessibility', bid, out: File::NULL, err: File::NULL)
    end
    warn "   Dedupe: reset Accessibility for #{granted_non_runtime.join(', ')} (running #{runtime_bundle})"
  end

  def accessibility_auth_value_local(bundle_id)
    escaped_bundle = bundle_id.gsub("'", "''")
    dbs = [
      File.expand_path('~/Library/Application Support/com.apple.TCC/TCC.db'),
      '/Library/Application Support/com.apple.TCC/TCC.db'
    ]

    dbs.each do |db|
      next unless File.exist?(db)

      value = `sqlite3 "#{db}" "SELECT auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}' ORDER BY rowid DESC LIMIT 1;"`.strip
      return value.to_i if value.match?(/\A\d+\z/)
    end

    nil
  end

  def reconcile_accessibility_trust_local(app_path)
    bundle_id = bundle_id_for_app(app_path)
    return unless bundle_id

    user_db = File.expand_path('~/Library/Application Support/com.apple.TCC/TCC.db')
    return unless File.exist?(user_db)

    escaped_bundle = bundle_id.gsub("'", "''")
    rows_raw = `sqlite3 "#{user_db}" "SELECT rowid || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}';"`.strip
    return if rows_raw.empty?

    stale_row_ids = []

    rows_raw.each_line do |line|
      row = line.strip
      next if row.empty?

      row_id, csreq_hex = row.split('|', 2)
      next unless row_id && row_id.match?(/\A\d+\z/)

      if csreq_hex.nil? || csreq_hex.empty?
        stale_row_ids << row_id
        next
      end

      csreq_path = File.join(Dir.tmpdir, "saneapps-ax-#{@app_name}-#{row_id}.csreq")
      begin
        File.binwrite(csreq_path, [csreq_hex].pack('H*'))
        requirement = `csreq -r "#{csreq_path}" -t 2>/dev/null`.strip

        if requirement.empty?
          stale_row_ids << row_id
          next
        end

        matches = system('codesign', "-R=#{requirement}", app_path, out: File::NULL, err: File::NULL)
        stale_row_ids << row_id unless matches
      ensure
        FileUtils.rm_f(csreq_path)
      end
    end

    return if stale_row_ids.empty?

    unless repair_accessibility?
      warn "   Repair: found #{stale_row_ids.size} stale Accessibility row(s) for #{bundle_id}; leaving them alone"
      warn '   Re-run with --repair-accessibility if you want those stale rows removed.'
      return
    end

    warn "   Repair: removing #{stale_row_ids.size} stale Accessibility row(s) for #{bundle_id}"
    system('killall', 'tccd', out: File::NULL, err: File::NULL)
    system('sqlite3', user_db, "DELETE FROM access WHERE rowid IN (#{stale_row_ids.join(',')});", out: File::NULL, err: File::NULL)
    system('killall', 'tccd', out: File::NULL, err: File::NULL)
  end

  def reset_tcc_local
    bundle_ids.each do |bid|
      system('tccutil', 'reset', 'All', bid, out: File::NULL, err: File::NULL)
      system('tccutil', 'reset', 'Accessibility', bid, out: File::NULL, err: File::NULL)
    end
    warn "   Reset TCC for: #{bundle_ids.join(', ')}"
  end

  def launch_local
    app_path = canonical_local_app_path
    unless File.exist?(app_path)
      source_app_path = find_derived_data_app
      abort '   ❌ Built app not found in DerivedData' unless source_app_path
      app_path = stage_to_canonical_local_app_path(source_app_path)
    end
    reconcile_accessibility_trust_local(app_path)

    open_args = launch_env_pairs
    if @allow_keychain
      system('open', *open_args, app_path)
    else
      system('open', *open_args, app_path, '--args', '--sane-no-keychain')
    end
    sleep 2
    processes = local_app_processes(app_path)
    abort "   ❌ App failed to launch from #{app_path}" if processes.empty?
    if processes.length > 1
      warn "   Running copies: #{processes.join(' | ')}"
      abort "   ❌ Expected one running #{@app_name} process for #{app_path}"
    end

    pid = processes.first.split(/\s+/, 2).first
    warn "   Running canonical app at #{app_path} (PID: #{pid})"
  end

  def repair_accessibility?
    @repair_accessibility || @fresh || @reset_tcc
  end

  def canonical_local_app_path
    env_override = ENV['SANETEST_CANONICAL_APP_PATH'] || ENV['SANEMASTER_CANONICAL_APP_PATH']
    return File.expand_path(env_override) if env_override && !env_override.strip.empty?

    app_name = "#{@app_name}.app"
    system_app = File.join('/Applications', app_name)
    user_app = File.expand_path(File.join('~/Applications', app_name))

    return system_app if system_app_dir_writable?
    return system_app if File.exist?(system_app)

    user_app
  end

  def local_app_copy_paths
    patterns = [
      File.join('/Applications', "#{@app_name}.app"),
      File.expand_path(File.join('~/Applications', "#{@app_name}.app")),
      File.expand_path("/tmp/#{@app_name}.app"),
      File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products/*/#{@app_name}.app"),
      File.expand_path("~/codex-runs/**/#{@app_name}.app"),
      File.expand_path("~/codex-runs/.worktrees/**/#{@app_name}.app")
    ]

    patterns
      .flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
      .select { |path| File.directory?(path) }
      .map { |path| File.expand_path(path) }
      .uniq
      .sort
  end

  def system_app_dir_writable?
    File.writable?('/Applications')
  rescue StandardError
    false
  end

  def trash_noncanonical_local_app_copies(preserve_path: canonical_local_app_path)
    preserved = File.expand_path(preserve_path)
    stale_paths = local_app_copy_paths.reject { |path| File.expand_path(path) == preserved }
    stale_paths.each do |path|
      warn "   Trashing stale app bundle: #{path}"
      trash_local_path(path)
    end
    stale_paths.length
  end

  def trash_local_path(path)
    return unless File.exist?(path)

    ok = system('/usr/bin/trash', path, out: File::NULL, err: File::NULL)
    abort "   ❌ Failed to move stale app bundle to Trash: #{path}" unless ok
  end

  def local_app_processes(app_path)
    expected_binary = File.join(File.expand_path(app_path), 'Contents', 'MacOS', @app_name)
    `ps ax -o pid=,command=`
      .lines
      .map(&:strip)
      .reject(&:empty?)
      .select do |line|
        _pid, command = line.split(/\s+/, 2)
        next false unless command

        binary = command.split(/\s+/, 2).first.to_s
        File.expand_path(binary) == expected_binary
      end
  end

  def stage_to_canonical_local_app_path(source_app_path)
    target_app_path = canonical_local_app_path
    target_parent = File.dirname(target_app_path)
    FileUtils.mkdir_p(target_parent) unless Dir.exist?(target_parent)

    if File.expand_path(source_app_path) == File.expand_path(target_app_path)
      warn "   Using canonical app path: #{target_app_path}"
      return target_app_path
    end

    warn "   Staging app to canonical path: #{target_app_path}"
    lock_path = File.join(Dir.tmpdir, "saneapps-stage-#{@app_name}.lock")
    staged_ok = false

    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
      lock_file.flock(File::LOCK_EX)

      temp_app_path = "#{target_app_path}.staging-#{Process.pid}-#{Time.now.to_i}"
      begin
        FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
        ok = system('ditto', source_app_path, temp_app_path)
        abort "   ❌ Failed to stage app to canonical path: #{target_app_path}" unless ok && File.exist?(temp_app_path)

        if File.exist?(target_app_path)
          # Avoid creating backup app bundle identities under /Applications.
          # TCC can retain those paths and keep stale camera attribution alive.
          FileUtils.rm_rf(target_app_path)
        end
        FileUtils.mv(temp_app_path, target_app_path)
        staged_ok = File.exist?(target_app_path)
      ensure
        FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
        lock_file.flock(File::LOCK_UN)
      end
    end

    abort "   ❌ Canonical app missing after staging: #{target_app_path}" unless staged_ok

    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    if File.exist?(lsregister)
      system(lsregister, '-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user',
             out: File::NULL, err: File::NULL)
    end

    target_app_path
  end

  def bundle_id_for_app(app_path)
    info_plist = File.join(app_path, 'Contents', 'Info.plist')
    return nil unless File.exist?(info_plist)

    bundle_id = `"/usr/libexec/PlistBuddy" -c "Print :CFBundleIdentifier" "#{info_plist}" 2>/dev/null`.strip
    return nil if bundle_id.empty?

    bundle_id
  end

  def stream_logs_local
    puts ''
    puts '📡 Streaming logs (Ctrl+C to stop)...'
    puts '─' * 60
    Kernel.exec('log', 'stream', '--predicate',
                "subsystem BEGINSWITH \"#{@config[:log_subsystem]}\"", '--info', '--debug', '--style', 'compact')
  end

  # ── License Mode ─────────────────────────────────────────────

  TEST_LICENSE_KEY = 'test-pro'.freeze
  EARLY_ADOPTER_KEY = 'early-adopter'.freeze

  def set_license_mode_local
    bid = @config[:dev]
    if @free_mode
      warn '   Clearing fallback license data (free mode)...'
      clear_license_fallback_local(bid)
      # Clear cached validation and grandfathered flag from settings
      clear_license_settings_local
      warn '   License cleared — app will launch as Free user'
    elsif @pro_mode
      warn '   Writing fallback license data (pro mode)...'
      set_pro_fallback_local(bid)
      warn '   Pro fallback key written (no keychain access required)'
    end
  end

  def set_license_mode_remote
    bid = remote_runtime_bundle_id
    if @free_mode
      warn '   Clearing fallback license data on mini (free mode)...'
      clear_license_fallback_remote(bid)
      clear_license_settings_remote
      warn '   License cleared on mini — app will launch as Free user'
    elsif @pro_mode
      warn '   Writing fallback license data on mini (pro mode)...'
      set_pro_fallback_remote(bid)
      warn '   Pro fallback key written on mini (no keychain access required)'
    end
  end

  def license_key_name
    @app_name == 'SaneBar' ? 'pro_license_key' : 'license_key'
  end

  def license_email_name
    @app_name == 'SaneBar' ? 'pro_license_email' : 'license_email'
  end

  def license_date_name
    @app_name == 'SaneBar' ? 'pro_last_validation' : 'last_validation'
  end

  def fallback_domain(bundle_id)
    "#{bundle_id}.no-keychain"
  end

  def fallback_pref_key(bundle_id, key_name)
    "sane.no-keychain.#{bundle_id}.#{key_name}"
  end

  def clear_license_fallback_local(bundle_id)
    domain = fallback_domain(bundle_id)
    [license_key_name, license_email_name, license_date_name].each do |name|
      key = fallback_pref_key(bundle_id, name)
      system('defaults', 'delete', domain, key, out: File::NULL, err: File::NULL)
    end
  end

  def clear_license_fallback_remote(bundle_id)
    domain = fallback_domain(bundle_id)
    [license_key_name, license_email_name, license_date_name].each do |name|
      key = fallback_pref_key(bundle_id, name)
      ssh("defaults delete #{Shellwords.escape(domain)} #{Shellwords.escape(key)} 2>/dev/null; true")
    end
  end

  def set_pro_fallback_local(bundle_id)
    domain = fallback_domain(bundle_id)
    key = fallback_pref_key(bundle_id, license_key_name)
    date_key = fallback_pref_key(bundle_id, license_date_name)
    email_key = fallback_pref_key(bundle_id, license_email_name)
    pro_value = (@app_name == 'SaneBar') ? EARLY_ADOPTER_KEY : TEST_LICENSE_KEY

    system('defaults', 'write', domain, key, '-string', pro_value)
    system('defaults', 'write', domain, date_key, '-string', Time.now.utc.iso8601)
    system('defaults', 'write', domain, email_key, '-string', 'test@saneapps.local') unless @app_name == 'SaneBar'
  end

  def set_pro_fallback_remote(bundle_id)
    domain = fallback_domain(bundle_id)
    key = fallback_pref_key(bundle_id, license_key_name)
    date_key = fallback_pref_key(bundle_id, license_date_name)
    email_key = fallback_pref_key(bundle_id, license_email_name)
    pro_value = (@app_name == 'SaneBar') ? EARLY_ADOPTER_KEY : TEST_LICENSE_KEY
    now = Time.now.utc.iso8601

    ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(key)} -string #{Shellwords.escape(pro_value)}")
    ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(date_key)} -string #{Shellwords.escape(now)}")
    unless @app_name == 'SaneBar'
      ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(email_key)} -string test@saneapps.local")
    end
  end

  def launch_env_pairs
    env_args = ['--env', 'SANEAPPS_PERMISSIONLESS_AUTOMATION=1', '--env', 'SANEVIDEO_ENABLE_HARDWARE_TESTS=0']
    if @free_mode
      env_args += ['--env', 'SANEAPPS_FORCE_LICENSE_CHECK=1']
      env_args += ['--env', 'SANEAPPS_FORCE_FREE_MODE=1'] unless @app_name == 'SaneBar'
    end
    env_args
  end

  def clear_license_settings_local
    app_support = File.expand_path("~/Library/Application Support/SaneBar")
    settings_path = File.join(app_support, 'settings.json')
    return unless File.exist?(settings_path)

    require 'json'
    settings = JSON.parse(File.read(settings_path))
    settings.delete('isGrandfathered')
    settings.delete('cachedLicenseValidation')
    File.write(settings_path, JSON.pretty_generate(settings))
  rescue StandardError => e
    warn "   ⚠️  Could not clear license settings: #{e.message}"
  end

  def clear_license_settings_remote
    ssh(<<~SH)
      SETTINGS="$HOME/Library/Application Support/SaneBar/settings.json"
      if [ -f "$SETTINGS" ]; then
        python3 -c "
import json, sys
with open('$SETTINGS') as f: s = json.load(f)
s.pop('isGrandfathered', None)
s.pop('cachedLicenseValidation', None)
with open('$SETTINGS', 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null || true
      fi
    SH
  end

  # ── Shared ──────────────────────────────────────────────────

  def build_debug
    Dir.chdir(@app_dir) do
      if File.exist?('project.yml') && Dir.glob('*.xcodeproj').empty?
        warn '   Running xcodegen...'
        system('xcodegen', 'generate', out: File::NULL, err: File::NULL)
      end

      # Check if signing certificates are available; fall back to ad-hoc if not
      has_signing_cert = !`security find-identity -v -p codesigning 2>/dev/null`.strip.start_with?('0 valid')

      # SaneBar has a known macOS WindowServer failure mode when launched from
      # local unsigned Debug builds. Enforce signed ProdDebug for local runs.
      if @app_name == 'SaneBar' && @target == :local && !has_signing_cert && !@allow_unsigned_debug
        abort '   ❌ SaneBar local testing requires Apple Development signing (ProdDebug). Install signing certs or run without --local to use Mac mini.'
      end

      # Use ProdDebug config when signing certs are available.
      # Debug config uses ad-hoc signing (CODE_SIGN_IDENTITY="-") and no entitlements,
      # which causes WindowServer to reject status bar windows on modern macOS
      # (invisible menu bar items: windowNumber=2^32, Y=-22).
      # ProdDebug has proper signing + entitlements.
      # Fall back to Debug if ProdDebug config doesn't exist (e.g., xcodeproj-based projects).
      # --release: Build with Release config for production testing (e.g., license gate).
      if @release_build
        config_name = 'Release'
      else
        has_prod_debug = `xcodebuild -list 2>/dev/null`.include?('ProdDebug')
        config_name = (has_signing_cert && has_prod_debug) ? 'ProdDebug' : 'Debug'
      end
      @last_build_config = config_name

      build_args = [
        'xcodebuild',
        '-scheme', @config[:scheme],
        '-destination', 'platform=macOS',
        '-configuration', config_name,
        'ENABLE_DEBUG_DYLIB=NO'
      ]

      if has_signing_cert
        # Keep dev bundle ID even with ProdDebug config for non-SaneBar apps.
        # SaneBar local stability depends on signed ProdDebug with default bundle.
        if @app_name != 'SaneBar'
          dev_bundle_id = @config[:dev]
          if dev_bundle_id
            build_args << "PRODUCT_BUNDLE_IDENTIFIER=#{dev_bundle_id}"
          end
        end
        # For apps without ProdDebug, keep Debug launches ad-hoc signed.
        # Forcing Apple Development signing here can fail on package bundles
        # during unattended Mini builds (errSecInternalComponent).
        unless has_prod_debug
          build_args += [
            'CODE_SIGN_IDENTITY=-',
            'CODE_SIGNING_REQUIRED=NO',
            'CODE_SIGNING_ALLOWED=NO',
            'DEVELOPMENT_TEAM='
          ]
        end
      else
        warn '   ⚠️  No signing cert found — using ad-hoc signing'
        build_args += %w[
          CODE_SIGN_IDENTITY=-
          CODE_SIGNING_REQUIRED=NO
          CODE_SIGNING_ALLOWED=NO
          DEVELOPMENT_TEAM=
        ]
      end

      build_args << 'build'

      stdout, status = Open3.capture2e(*build_args)

      unless status.success?
        if @target == :local
          trashed_copies = trash_noncanonical_local_app_copies
          warn "   Cleaned #{trashed_copies} non-canonical app bundle(s) after failed build" if trashed_copies.positive?
        end
        puts ''
        failure_lines = stdout.lines.select { |l| l.match?(/error:|BUILD FAILED|Command .* failed with a nonzero exit code/) }.last(8)
        if failure_lines.empty?
          warn '   Build log tail:'
          stdout.lines.last(40).each { |l| warn "   #{l.rstrip}" }
        else
          failure_lines.each { |l| warn "   #{l.rstrip}" }
        end
        if stdout.include?('Sparkle.framework') && stdout.include?('errSecInternalComponent')
          warn '   Mini Sparkle signing hit errSecInternalComponent.'
          warn '   Fallback: build ProdDebug unsigned on Mini, then Developer ID sign the staged app bundle from a trusted local session.'
        end
        abort '   ❌ Build failed'
      end

      built_app = find_derived_data_app
      assert_runtime_binary!(built_app) if built_app
    end
  end

  def find_derived_data_app
    fallback_configs = %w[Release ProdDebug Debug]
    configs =
      if @app_name == 'SaneBar' && @target == :local
        preferred = @last_build_config || 'ProdDebug'
        [preferred] + (fallback_configs - [preferred])
      elsif @last_build_config
        [@last_build_config] + (fallback_configs - [@last_build_config])
      else
        fallback_configs
      end

    configs.each do |config|
      pattern = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products/#{config}/#{@app_name}.app")
      # App bundle directory mtime can stay stale across incremental builds.
      # Prefer executable mtime to reliably pick the freshest artifact.
      result = Dir.glob(pattern).max_by { |p| artifact_mtime(p) }
      return result if result
    end
    nil
  end

  def artifact_mtime(app_bundle_path)
    executable = File.join(app_bundle_path, 'Contents', 'MacOS', @app_name)
    return File.mtime(executable) if File.exist?(executable)

    File.mtime(app_bundle_path)
  rescue StandardError
    Time.at(0)
  end

  def assert_runtime_binary!(app_bundle_path)
    executable = File.join(app_bundle_path, 'Contents', 'MacOS', @app_name)
    return unless File.exist?(executable)

    header = `strings "#{executable}" 2>/dev/null | head -n 60`
    return unless header.include?('com.apple.Previews.StubExecutor') ||
                  header.include?('PreviewsAgentExecutorLibrary')

    abort "   ❌ Build produced Xcode Previews stub executable (#{@app_name}). " \
          'Use ENABLE_DEBUG_DYLIB=NO for standalone launches.'
  end

  def ssh(cmd)
    system('ssh', '-o', 'ConnectTimeout=5', MINI_HOST, cmd)
  end

  def ssh_capture(cmd)
    stdout, _status = Open3.capture2('ssh', '-o', 'ConnectTimeout=5', MINI_HOST, cmd, err: File::NULL)
    stdout
  end

  def map_local_path_to_mini(local_path)
    expanded = File.expand_path(local_path)
    return expanded if expanded.start_with?('/Users/stephansmac/')
    return nil unless expanded.start_with?('/Users/sj/')

    "/Users/stephansmac/#{expanded.delete_prefix('/Users/sj/')}"
  end

  def sync_file_to_mini(local_path, remote_path)
    remote_dir = File.dirname(remote_path)
    ok = system('ssh', '-o', 'ConnectTimeout=5', MINI_HOST, "mkdir -p #{Shellwords.escape(remote_dir)}")
    abort "   ❌ Failed to prepare remote directory: #{remote_dir}" unless ok

    ok = system('rsync', '-az', local_path, "#{MINI_HOST}:#{remote_path}")
    abort "   ❌ Failed to sync #{local_path} to mini" unless ok
  end

  def sync_repo_to_mini(local_repo, remote_repo)
    ok = system(
      'rsync',
      '-az',
      '--delete',
      '--filter', ':- .gitignore',
      '--exclude', '.git',
      '--exclude', '.build',
      '--exclude', 'DerivedData',
      '--exclude', 'node_modules',
      '--exclude', 'vendor/bundle',
      '--exclude', 'test_output.txt',
      "#{File.expand_path(local_repo)}/",
      "#{MINI_HOST}:#{remote_repo}/"
    )
    abort "   ❌ Failed to sync app repo to mini: #{local_repo}" unless ok

    sync_ignored_test_assets_to_mini(local_repo, remote_repo)
  end

  def sync_ignored_test_assets_to_mini(local_repo, remote_repo)
    assets_dir = File.join(File.expand_path(local_repo), 'Tests', 'Assets')
    return unless Dir.exist?(assets_dir)

    remote_assets_dir = File.join(remote_repo, 'Tests', 'Assets')
    ok = system('rsync', '-az', '--delete', "#{assets_dir}/", "#{MINI_HOST}:#{remote_assets_dir}/")
    abort "   ❌ Failed to sync ignored test assets to mini: #{assets_dir}" unless ok
  end

  def exec_remote_sane_test(remote_saneprocess_dir)
    forwarded_args = @raw_args.reject { |arg| arg == '--local' }
    remote_args = ([@app_name, '--local'] + forwarded_args).map { |arg| Shellwords.escape(arg) }.join(' ')
    exec('ssh', MINI_HOST, "cd #{Shellwords.escape(remote_saneprocess_dir)} && ruby scripts/sane_test.rb #{remote_args}")
  end

  def step(name)
    warn name
    yield
    warn '   ✅ Done'
  end
end

# ── Main ──────────────────────────────────────────────────────

if ARGV.empty? || ARGV[0] == '--help'
  warn 'Usage: ruby scripts/sane_test.rb <AppName> [options]'
  warn ''
  warn "Available apps: #{APPS.keys.join(', ')}"
  warn ''
  warn 'Options:'
  warn '  --local      Force local testing (skip mini even if reachable)'
  warn '  --no-logs    Skip log streaming after launch'
  warn '  --fresh      Wipe ALL state (App Support, UserDefaults, TCC, license) — true first launch'
  warn '  --free-mode  Clear fallback license data — launch as Free user'
  warn '  --pro-mode   Write fallback Pro marker — launch in Pro mode'
  warn '  --reset-tcc  Reset TCC/Accessibility permissions (only for fresh installs)'
  warn '  --repair-accessibility  Repair duplicate/stale Accessibility entries if inspection finds them'
  warn '  --allow-keychain  Allow real keychain access during app launch (default is no-keychain)'
  warn '  --allow-unsigned-debug  Allow local SaneBar Debug launch without signing certs (unsupported visibility path)'
  warn '  --release    Build Release config and stage it to the canonical app path'
  warn ''
  warn 'Default: deploys to Mac mini if reachable, local otherwise.'
  warn 'TCC is preserved by default — single-copy enforcement prevents stale grants.'
  warn 'Use --fresh to test onboarding or first-launch experience.'
  exit 0
end

SaneTest.new(ARGV[0], ARGV[1..] || []).run
