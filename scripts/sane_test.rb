#!/usr/bin/env ruby
# frozen_string_literal: true

# Hook/launchd/ssh shells often run with a C locale, which makes Ruby default
# to US-ASCII and raise "invalid byte sequence" when xcodebuild/tool output
# containing UTF-8 hits a regex (2026-06-11: aborted a SaneBar launch in
# build_debug). Force UTF-8 before anything reads command output.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# sane_test.rb — Unified test launch for all SaneApps
#
# Usage:
#   ruby scripts/sane_test.rb SaneBar
#   ruby scripts/sane_test.rb SaneClip --local
#   ruby scripts/sane_test.rb SaneBar --no-logs
#   ruby scripts/sane_test.rb SaneVideo --hardware
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
require 'socket'
require 'digest'
require 'etc'

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
TRANSIENT_STAGE_ROOT = '/tmp/saneapps-staging.noindex'
SIGNED_RELEASE_RUNTIME_APPS = %w[SaneClip].freeze

class SaneTest
  SANEAPPS_DEVELOPER_TEAM_ID = 'M78L6FXD48'
  CODESIGN_BIN = '/usr/bin/codesign'
  SECURITY_BIN = '/usr/bin/security'
  NESTED_CODE_ROOTS = %w[Frameworks PlugIns XPCServices Helpers Library/LoginItems].freeze
  class SigningValidationError < StandardError; end

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
    @release_build = args.include?('--release') || signed_release_runtime_required?
    @hardware = args.include?('--hardware')
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

    if running_on_mini_host?
      puts '✅ Already running on Mac mini → using local canonical path'
      return :local
    end

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

  def running_on_mini_host?
    host = Socket.gethostname.to_s.downcase
    return true if host.include?('mini')

    computer_name, status = Open3.capture2('/usr/sbin/scutil', '--get', 'ComputerName')
    status.success? && computer_name.to_s.downcase.include?('mac mini')
  rescue StandardError
    false
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
    # Quit cleanly first: a bare SIGKILL on an activated GUI/agent app leaves a
    # ghost Dock tile that accumulates across test runs. Graceful quit lets
    # macOS remove the tile; SIGKILL is the fallback and killall Dock sweeps any
    # tile a force-killed app left behind.
    ssh(%(osascript -e 'quit app "#{@app_name}"' 2>/dev/null; true))
    sleep 1
    ssh("killall -9 #{@app_name} 2>/dev/null; true")
    sleep 1
    ssh('killall Dock 2>/dev/null; true')
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
          remote_codesign = "/usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C " \
                            "/usr/bin/codesign -R #{remote_requirement} #{remote_app}"
          matches = system('ssh', MINI_HOST, remote_codesign,
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
    step("#{n += 1}. Re-sign with Developer ID (preserve TCC)") { ensure_developer_id_signature_local }
    step("#{n += 1}. Launch locally") { launch_local }
    print_air_ui_test_hints_local
    stream_logs_local unless @no_logs
  end

  # A local debug build is signed with an Apple Development cert, NOT the
  # Developer ID the machine's TCC grants (Accessibility, etc.) were issued
  # for, so macOS does not honor the existing grant: the app shows "Grant
  # Access" and menu-bar moves silently fail. Re-sign the staged build with
  # the Developer ID Application identity so the pre-existing grant matches
  # and UI verification (e.g. notch testing on the Air) just works — no manual
  # codesign + Accessibility-toggle dance. See SaneBar docs/AIR_UI_TESTING.md.
  def ensure_developer_id_signature_local
    app_path = canonical_local_app_path
    unless app_path && File.exist?(app_path)
      abort '   ❌ Re-sign required but staged app was not found'
    end
    existing_entitlements = signed_entitlements_xml(app_path)
    if existing_entitlements && deep_signature_valid?(app_path) && saneapps_signature_tree_valid?(app_path)
      warn '   Already Developer ID-signed; existing TCC grants should hold'
      return
    end
    # A previously re-signed app can be Developer ID-signed while lacking its
    # original entitlement payload. Recover from the fresh Xcode product when
    # it is still available instead of accepting that stripped canonical copy.
    entitlements = existing_entitlements || fresh_build_entitlements_xml(app_path)
    if developer_id_signed?(app_path) && entitlements.nil?
      abort '   ❌ Developer ID app has no entitlement payload and no fresh signed payload is available to restore'
    end
    identity_output, identity_status = codesigning_identity_output
    identity = developer_id_identity_from_output(identity_output) if identity_status.success?
    unless identity
      if @allow_unsigned_debug && !signed_release_runtime_required?
        warn '   ⚠️  Explicit --allow-unsigned-debug exception: Developer ID re-sign skipped'
        return
      end

      warn '   ⚠️  No "Developer ID Application" identity found — TCC grant may not hold'
      warn '   (menu-bar moves can silently fail; grant Accessibility manually or import the cert).'
      abort '   ❌ Developer ID re-sign is required for trustworthy TCC/runtime proof'
    end
    sign_out, status = resign_with_developer_id(identity, app_path, entitlements)
    if status.success?
      warn "   Re-signed with #{identity}"
      warn '   (preserves the existing Accessibility/TCC grant for this build)'
    elsif sign_out.include?('errSecInternalComponent')
      # Deterministic, not guesswork: this specific failure means codesign can't
      # reach the signing key from a plain ssh shell. Run the build in the Mini's
      # GUI session, which has keychain access.
      warn '   ⚠️  Re-sign failed: errSecInternalComponent — codesign cannot reach the'
      warn '       signing key over plain ssh. Run the build/sign in the Mini GUI session:'
      warn "         ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh \\"
      warn '           --title "build" --log-file /tmp/build.log -- \\'
      warn "           \"cd #{@app_dir} && ruby #{__FILE__} #{@app_name} --release --local\"'"
      warn '       (one-time alternative: set the login-keychain codesign partition list; see mini/README.md).'
      abort '   ❌ Developer ID re-sign failed; refusing to launch an untrusted TCC runtime'
    else
      warn '   ⚠️  Re-sign failed — TCC grant may not hold; menu-bar moves can fail'
      first = sign_out.lines.map(&:strip).reject(&:empty?).first
      warn "   codesign: #{first}" if first
      abort '   ❌ Developer ID re-sign failed; refusing to launch an invalid or partially signed app'
    end
  rescue SigningValidationError => e
    abort "   ❌ Developer ID re-sign validation failed: #{e.message}"
  end

  def developer_id_identity_from_output(output)
    output.to_s.lines.map do |line|
      identity = line[/"(Developer ID Application: [^"]+)"/, 1]
      identity if identity&.include?("(#{SANEAPPS_DEVELOPER_TEAM_ID})")
    end.compact.first
  end

  def signing_command_environment
    {
      'HOME' => Etc.getpwuid(Process.uid).dir,
      'TMPDIR' => '/tmp',
      'PATH' => '/usr/bin:/bin',
      'LANG' => 'C',
      'LC_ALL' => 'C'
    }
  end

  def capture_signing_command(*command)
    executable = command.first
    unless [CODESIGN_BIN, SECURITY_BIN].include?(executable)
      raise SigningValidationError, "untrusted signing executable: #{executable}"
    end

    Open3.capture2e(signing_command_environment, *command, unsetenv_others: true)
  end

  def capture_signing_command3(*command)
    executable = command.first
    unless [CODESIGN_BIN, SECURITY_BIN].include?(executable)
      raise SigningValidationError, "untrusted signing executable: #{executable}"
    end

    Open3.capture3(signing_command_environment, *command, unsetenv_others: true)
  end

  def system_signing_command(*command, **options)
    executable = command.first
    unless [CODESIGN_BIN, SECURITY_BIN].include?(executable)
      raise SigningValidationError, "untrusted signing executable: #{executable}"
    end

    system(signing_command_environment, *command, **options, unsetenv_others: true)
  end

  def codesigning_identity_output
    capture_signing_command(SECURITY_BIN, 'find-identity', '-v', '-p', 'codesigning')
  end

  # `--deep` is intentionally absent. Apple deprecates it for signing and
  # applies every parent signing option to nested code, which can incorrectly
  # give frameworks or helpers the app's entitlement payload. Nested code keeps
  # its existing valid signature while the outer app is re-signed.
  def developer_id_resign_command(identity, app_path, entitlements_path: nil)
    command = [
      CODESIGN_BIN, '--force', '--sign', identity, '--options', 'runtime',
      '--preserve-metadata=identifier,requirements,entitlements'
    ]
    command.concat(['--entitlements', entitlements_path]) if entitlements_path
    command << app_path
  end

  def resign_with_developer_id(identity, app_path, entitlements)
    nested_output, nested_status = resign_nested_code_with_developer_id(identity, app_path)
    return [nested_output, nested_status] unless nested_status.success?

    unless entitlements
      app_output, app_status = capture_signing_command(*developer_id_resign_command(identity, app_path))
      return verify_resigned_app(app_path, nested_output + app_output, app_status)
    end

    Dir.mktmpdir('saneapps-entitlements') do |dir|
      entitlements_path = File.join(dir, 'preserved.entitlements')
      File.binwrite(entitlements_path, entitlements)
      app_output, app_status = capture_signing_command(
        *developer_id_resign_command(identity, app_path, entitlements_path: entitlements_path)
      )
      return verify_resigned_app(app_path, nested_output + app_output, app_status)
    end
  end

  # Xcode strips development-only framework resources (for example Sparkle's
  # Headers and Modules) after SwiftPM has signed the package product. Re-sign
  # each physical nested code bundle after staging so its resource seal matches
  # the shipped files. Signing deepest-first keeps parent seals current, while
  # applying no app entitlement file to nested code prevents entitlement leaks.
  def resign_nested_code_with_developer_id(identity, app_path)
    output = +''
    last_status = nil
    trusted_nested_code = trusted_fresh_nested_code_map!(app_path)

    nested_code_paths(app_path).each do |path|
      relative_path = nested_code_relative_path(app_path, path)
      trusted_path = trusted_nested_code[relative_path]
      unless trusted_path
        raise SigningValidationError, "nested code is absent from the fresh build product: #{relative_path}"
      end

      validate_existing_nested_signature!(path, trusted_path: trusted_path, relative_path: relative_path)
      command = developer_id_resign_command(identity, path)
      command_output, status = capture_signing_command(*command)
      output << command_output
      return [output, status] unless status.success?
      validate_saneapps_developer_id_signature!(path)

      last_status = status
    end

    last_status ||= Open3.capture2e('/usr/bin/true').last
    [output, last_status]
  end

  def trusted_fresh_nested_code_map!(app_path)
    fresh_app = find_derived_data_app
    unless fresh_app && File.directory?(fresh_app)
      raise SigningValidationError, 'fresh build product is unavailable for nested-code validation'
    end

    staged_root = File.realpath(app_path)
    fresh_root = File.realpath(fresh_app)
    if staged_root == fresh_root
      raise SigningValidationError, 'fresh build product must be distinct from the staged runtime app'
    end

    validate_staged_manifest_matches_fresh!(app_path, fresh_app)

    nested_code_paths(fresh_app).each_with_object({}) do |path, trusted|
      relative_path = nested_code_relative_path(fresh_app, path)
      raise SigningValidationError, "duplicate nested code path in fresh build: #{relative_path}" if trusted.key?(relative_path)

      trusted[relative_path] = path
    end
  rescue Errno::ENOENT => e
    raise SigningValidationError, "fresh build product cannot be resolved: #{e.message}"
  end

  def validate_staged_manifest_matches_fresh!(staged_app, fresh_app)
    staged_manifest = bundle_contents_manifest!(staged_app, role: 'staged')
    fresh_manifest = bundle_contents_manifest!(fresh_app, role: 'fresh-build')
    paths = (staged_manifest.keys | fresh_manifest.keys).sort

    paths.each do |relative_path|
      staged = staged_manifest[relative_path]
      fresh = fresh_manifest[relative_path]
      unless staged
        raise SigningValidationError, "staged app is missing fresh-build path: #{relative_path}"
      end
      unless fresh
        raise SigningValidationError, "staged app contains an added path: #{relative_path}"
      end

      mismatches = (staged.keys | fresh.keys).reject { |field| staged[field] == fresh[field] }
      next if mismatches.empty?

      raise SigningValidationError,
            "staged app differs from fresh build at #{relative_path} (#{mismatches.join(', ')})"
    end

    true
  end

  # Staging uses `ditto --noextattr --noacl`, so filesystem content, modes, and
  # symlink topology must remain identical. Extended attributes and ACLs are the
  # only deliberate build-strip differences and are not part of this manifest.
  def bundle_contents_manifest!(app_path, role:)
    contents = File.join(app_path, 'Contents')
    root_metadata = File.lstat(contents)
    if root_metadata.symlink? || !root_metadata.directory?
      raise SigningValidationError, "#{role} app Contents is not a physical directory: #{contents}"
    end

    manifest = { '.' => { type: 'directory', mode: root_metadata.mode & 0o7777 } }
    collect_manifest_entries!(contents, contents, manifest, role: role)
    manifest
  rescue Errno::ENOENT => e
    raise SigningValidationError, "#{role} app manifest cannot be read: #{e.message}"
  end

  def collect_manifest_entries!(root, directory, manifest, role:)
    Dir.each_child(directory).sort.each do |name|
      path = File.join(directory, name)
      relative_path = path.delete_prefix("#{root}/")
      metadata = File.lstat(path)
      entry = if metadata.directory?
                { type: 'directory', mode: metadata.mode & 0o7777 }
              elsif metadata.file?
                {
                  type: 'file', mode: metadata.mode & 0o7777, size: metadata.size,
                  sha256: regular_file_sha256!(path, metadata, role: role)
                }
              elsif metadata.symlink?
                target = File.readlink(path)
                { type: 'symlink', size: target.bytesize, target: target }
              else
                raise SigningValidationError, "#{role} app contains unsupported filesystem object: #{relative_path}"
              end

      manifest[relative_path] = entry
      collect_manifest_entries!(root, path, manifest, role: role) if metadata.directory?
    end
  end

  def regular_file_sha256!(path, expected_metadata, role:)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    digest = Digest::SHA256.new
    File.open(path, flags) do |file|
      opened_metadata = file.stat
      unless opened_metadata.file? && opened_metadata.dev == expected_metadata.dev &&
             opened_metadata.ino == expected_metadata.ino && opened_metadata.size == expected_metadata.size
        raise SigningValidationError, "#{role} app file changed during manifest read: #{path}"
      end

      while (chunk = file.read(64 * 1024))
        digest << chunk
      end
    end
    digest.hexdigest
  rescue Errno::ELOOP, Errno::ENOENT => e
    raise SigningValidationError, "#{role} app file cannot be hashed safely: #{path} (#{e.message})"
  end

  def nested_code_paths(app_path)
    contents = File.join(app_path, 'Contents')
    return [] unless File.directory?(contents)

    bundle_suffixes = %w[.appex .app .bundle .framework .plugin .xpc]
    candidates = NESTED_CODE_ROOTS.flat_map do |root|
      root_path = File.join(contents, root)
      next [] unless File.exist?(root_path) || File.symlink?(root_path)

      root_metadata = File.lstat(root_path)
      raise SigningValidationError, "nested code root is a symlink: #{root_path}" if root_metadata.symlink?
      raise SigningValidationError, "nested code root is not a directory: #{root_path}" unless root_metadata.directory?

      Dir.glob(File.join(root_path, '**', '*'), File::FNM_DOTMATCH)
    end
    bundles = candidates.select do |path|
      bundle_suffixes.include?(File.extname(path))
    end
    libraries = candidates.select { |path| File.extname(path) == '.dylib' }

    (bundles + libraries)
      .map { |path| validated_nested_code_path(app_path, path) }
      .uniq
      .sort_by { |path| [-path.count(File::SEPARATOR), path] }
  end

  def validated_nested_code_path(app_path, candidate)
    metadata = File.lstat(candidate)
    raise SigningValidationError, "nested code candidate is a symlink: #{candidate}" if metadata.symlink?

    suffix = File.extname(candidate)
    expected_type = suffix == '.dylib' ? metadata.file? : metadata.directory?
    raise SigningValidationError, "nested code candidate has unexpected type: #{candidate}" unless expected_type

    app_root = File.realpath(app_path)
    real_path = File.realpath(candidate)
    unless real_path.start_with?("#{app_root}/Contents/")
      raise SigningValidationError, "nested code candidate escapes staged app: #{candidate}"
    end

    relative = real_path.delete_prefix("#{app_root}/Contents/")
    unless NESTED_CODE_ROOTS.any? { |root| relative == root || relative.start_with?("#{root}/") }
      raise SigningValidationError, "nested code candidate is outside an approved code root: #{relative}"
    end
    File.expand_path(candidate)
  end

  def nested_code_relative_path(app_path, path)
    app_root = File.realpath(app_path)
    real_path = File.realpath(path)
    prefix = "#{app_root}/Contents/"
    unless real_path.start_with?(prefix)
      raise SigningValidationError, "nested code candidate escapes staged app: #{path}"
    end

    real_path.delete_prefix(prefix)
  rescue Errno::ENOENT => e
    raise SigningValidationError, "nested code path cannot be resolved: #{e.message}"
  end

  def code_signature_details(path)
    capture_signing_command(CODESIGN_BIN, '-dv', '--verbose=4', '-r-', path)
  end

  def validate_existing_nested_signature!(path, trusted_path:, relative_path:)
    staged_identity = nested_code_signature_identity!(path, role: 'staged')
    trusted_identity = nested_code_signature_identity!(trusted_path, role: 'fresh-build')
    mismatches = %i[type identifier cdhash].reject do |field|
      staged_identity[field] == trusted_identity[field]
    end
    return true if mismatches.empty?

    raise SigningValidationError,
          "nested code does not match fresh build at #{relative_path} (#{mismatches.join(', ')})"
  end

  def nested_code_signature_identity!(path, role:)
    details, status = code_signature_details(path)
    valid_requirement = details.include?('designated =>') && details.include?('anchor apple generic')
    valid_team = details.include?("TeamIdentifier=#{SANEAPPS_DEVELOPER_TEAM_ID}") &&
                 details.include?("certificate leaf[subject.OU] = #{SANEAPPS_DEVELOPER_TEAM_ID}")
    identifier = details[/^Identifier=(.+)$/i, 1].to_s.strip
    cdhash = details[/^CDHash=([0-9a-f]+)$/i, 1].to_s.downcase
    valid_identity = !identifier.empty? && cdhash.match?(/\A[0-9a-f]{20,128}\z/)
    if status.success? && valid_requirement && valid_team && valid_identity
      executable = nested_code_executable_path!(path, details, role: role)
      unless nested_code_executable_signature_valid?(executable)
        raise SigningValidationError,
              "refusing to sign #{role} nested code whose executable signature is invalid: #{path}"
      end

      metadata = File.lstat(path)
      return {
        type: metadata.file? ? "file:#{File.extname(path)}" : "directory:#{File.extname(path)}",
        identifier: identifier,
        cdhash: cdhash
      }
    end

    raise SigningValidationError,
          "refusing to sign #{role} nested code without a matching SaneApps signature identity: #{path}"
  rescue Errno::ENOENT => e
    raise SigningValidationError, "#{role} nested code cannot be inspected: #{e.message}"
  end

  def nested_code_executable_path!(path, signature_details, role:)
    object_path = File.realpath(path)
    metadata = File.lstat(path)
    executable_path = if metadata.file?
                        object_path
                      else
                        reported = signature_details[/^Executable=(.+)$/i, 1].to_s.strip
                        raise SigningValidationError, "#{role} nested code has no signed executable path: #{path}" if reported.empty?

                        File.realpath(reported)
                      end
    if metadata.directory? && !executable_path.start_with?("#{object_path}/")
      raise SigningValidationError, "#{role} nested executable escapes its code object: #{path}"
    end
    raise SigningValidationError, "#{role} nested executable is not a regular file: #{executable_path}" unless File.file?(executable_path)

    executable_path
  rescue Errno::ENOENT => e
    raise SigningValidationError, "#{role} nested executable cannot be resolved: #{e.message}"
  end

  def nested_code_executable_signature_valid?(executable_path)
    _output, status = capture_signing_command(
      CODESIGN_BIN, '--verify', '--strict', '--verbose=2', executable_path
    )
    status.success?
  end

  def validate_saneapps_developer_id_signature!(path)
    details, status = code_signature_details(path)
    valid = status.success? &&
            details.include?("Authority=Developer ID Application:") &&
            details.include?("TeamIdentifier=#{SANEAPPS_DEVELOPER_TEAM_ID}") &&
            details.include?('designated =>') &&
            details.include?('anchor apple generic') &&
            details.include?("certificate leaf[subject.OU] = #{SANEAPPS_DEVELOPER_TEAM_ID}")
    raise SigningValidationError, "signature does not preserve the SaneApps designated requirement: #{path}" unless valid

    true
  end

  def verify_resigned_app(app_path, output, preceding_status)
    return [output, preceding_status] unless preceding_status.success?

    verify_output, verify_status = capture_signing_command(
      CODESIGN_BIN, '--verify', '--deep', '--strict', '--verbose=2', app_path
    )
    validate_saneapps_developer_id_signature!(app_path) if verify_status.success?
    [output + verify_output, verify_status]
  end

  def deep_signature_valid?(app_path)
    system_signing_command(
      CODESIGN_BIN, '--verify', '--deep', '--strict', app_path,
      out: File::NULL, err: File::NULL
    )
  end

  def developer_id_signed?(app_path)
    validate_saneapps_developer_id_signature!(app_path)
    true
  rescue SigningValidationError
    false
  end

  def saneapps_signature_tree_valid?(app_path)
    validate_saneapps_developer_id_signature!(app_path)
    nested_code_paths(app_path).each { |path| validate_saneapps_developer_id_signature!(path) }
    true
  rescue SigningValidationError, Errno::ENOENT
    false
  end

  def fresh_build_entitlements_xml(app_path)
    fresh_build = find_derived_data_app
    return nil unless fresh_build && File.expand_path(fresh_build) != File.expand_path(app_path)

    signed_entitlements_xml(fresh_build)
  end

  def signed_entitlements_xml(app_path)
    stdout, stderr, status = capture_signing_command3(
      CODESIGN_BIN, '--display', '--entitlements', '-', '--xml', app_path
    )
    return nil unless status.success?

    [stdout, stderr].map { |output| entitlement_plist_from_codesign_output(output) }.compact.first
  end

  def entitlement_plist_from_codesign_output(output)
    normalized = self.class.normalize_command_output(output)
    start_index = normalized.index('<?xml') || normalized.index('<plist')
    return nil unless start_index

    end_index = normalized.index('</plist>', start_index)
    return nil unless end_index

    normalized[start_index..(end_index + '</plist>'.length - 1)]
  end

  # Enforce the live-logging finding: print the exact, working capture command
  # so UI verification always has code evidence alongside the visual. log stream
  # MUST run from a script file (the agent shell mangles the predicate's nested
  # quotes inline). SaneBar ships Scripts/sanebar_logwatch.sh for this.
  def print_air_ui_test_hints_local
    watcher = File.join(@app_dir, 'Scripts', 'sanebar_logwatch.sh')
    return unless File.exist?(watcher)

    warn ''
    warn '   📡 Live logs (code evidence for UI tests):'
    warn "      bash #{watcher} > /tmp/#{@app_name.downcase}_live.log 2>&1 &"
    warn "      tail -40 /tmp/#{@app_name.downcase}_live.log | grep -iE 'moveIcon task|Move complete|notch-unsafe'"
    warn '   📖 Air UI-test runbook: docs/AIR_UI_TESTING.md'
  end

  def kill_local
    # Graceful quit before SIGKILL so macOS clears the Dock tile (a hard kill on
    # an activated app leaves a ghost tile); killall Dock is the backstop.
    system('osascript', '-e', %(quit app "#{@app_name}"), err: File::NULL, out: File::NULL)
    sleep 1
    system('killall', '-9', @app_name, err: File::NULL)
    sleep 1
    system('killall', 'Dock', err: File::NULL, out: File::NULL)
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

        matches = system_signing_command(
          CODESIGN_BIN, "-R=#{requirement}", app_path,
          out: File::NULL, err: File::NULL
        )
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
    ensure_gatekeeper_safe_launch!(app_path)

    if launch_services_gatekeeper_rejected?(app_path)
      warn "   LaunchServices would show Gatekeeper for #{app_path}; launching executable directly."
      executable = File.join(app_path, 'Contents', 'MacOS', @app_name)
      pid = spawn(launch_env_hash, executable, *direct_launch_args, out: File::NULL, err: File::NULL)
      Process.detach(pid)
    else
      open_args = launch_env_pairs
      if @allow_keychain
        system('open', *open_args, app_path)
      else
        system('open', *open_args, app_path, '--args', '--sane-no-keychain')
      end
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

  def ensure_gatekeeper_safe_launch!(app_path)
    return if ENV['SANETEST_ALLOW_ADHOC_GATEKEEPER_DIALOG'] == '1'
    return unless ad_hoc_signed?(app_path)

    abort "   ❌ Refusing to launch ad-hoc signed #{@app_name}; macOS can show an unidentified-developer dialog. Re-run with --release for a signed runtime build."
  end

  def ad_hoc_signed?(app_path)
    output, = capture_signing_command(CODESIGN_BIN, '-dv', '--verbose=4', app_path)
    output.include?('Signature=adhoc')
  end

  def launch_services_gatekeeper_rejected?(app_path)
    return false unless quarantined?(app_path)

    _stdout, _stderr, status = Open3.capture3('spctl', '-a', '-vv', app_path)
    !status.success?
  end

  def quarantined?(app_path)
    _stdout, _stderr, status = Open3.capture3('xattr', '-p', 'com.apple.quarantine', app_path)
    status.success?
  end

  def clear_gatekeeper_staging_attributes(app_path)
    return unless app_path && File.exist?(app_path)

    system('xattr', '-cr', app_path, out: File::NULL, err: File::NULL)
    system('xattr', '-dr', 'com.apple.quarantine', app_path, out: File::NULL, err: File::NULL)
    system('xattr', '-dr', 'com.apple.provenance', app_path, out: File::NULL, err: File::NULL)
  end

  def canonical_local_app_path
    env_override = ENV['SANETEST_CANONICAL_APP_PATH'] || ENV['SANEMASTER_CANONICAL_APP_PATH']
    return File.expand_path(env_override) if env_override && !env_override.strip.empty?

    app_name = "#{@app_name}.app"
    system_app = File.join('/Applications', app_name)
    transient_app = File.expand_path(File.join(TRANSIENT_STAGE_ROOT, app_name))

    return system_app if system_app_dir_writable?
    return system_app if File.exist?(system_app)

    transient_app
  end

  def local_app_copy_paths
    patterns = [
      File.join('/Applications', "#{@app_name}.app"),
      File.expand_path(File.join(TRANSIENT_STAGE_ROOT, "#{@app_name}.app")),
      File.expand_path("/tmp/#{@app_name}.app"),
      File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products/*/#{@app_name}.app"),
      File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Index.noindex/Build/Products/**/#{@app_name}.app"),
      File.expand_path("~/Library/Caches/com.github.peripheryapp/DerivedData*/Build/Products/**/#{@app_name}.app"),
      File.expand_path("~/codex-runs/**/#{@app_name}.app"),
      File.expand_path("~/codex-runs/.worktrees/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/apps/#{@app_name}/build/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/apps/#{@app_name}/outputs/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/release/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/release-publish/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/release-worktrees/**/#{@app_name}.app"),
      File.expand_path("~/SaneApps/tmp/**/#{@app_name}.app"),
      File.expand_path("~/tmp/**/#{@app_name}.app")
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
        ok = system('ditto', '--noextattr', '--noacl', source_app_path, temp_app_path)
        abort "   ❌ Failed to stage app to canonical path: #{target_app_path}" unless ok && File.exist?(temp_app_path)

        if File.exist?(target_app_path)
          # Avoid creating backup app bundle identities under /Applications.
          # TCC can retain those paths and keep stale camera attribution alive.
          FileUtils.rm_rf(target_app_path)
        end
        FileUtils.mv(temp_app_path, target_app_path)
        clear_gatekeeper_staging_attributes(target_app_path)
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
    bid = local_runtime_bundle_id
    if @free_mode
      warn '   Clearing fallback license data (free mode)...'
      ([bid] + bundle_ids).compact.uniq.each { |bundle_id| clear_license_fallback_local(bundle_id) }
      # Clear cached validation and grandfathered flag from settings
      clear_license_settings_local
      warn '   License cleared — app will launch as Free user'
    elsif @pro_mode
      warn '   Writing fallback license data (pro mode)...'
      ([bid] + bundle_ids).compact.uniq.each { |bundle_id| clear_license_fallback_local(bundle_id) }
      set_pro_fallback_local(bid)
      warn "   Pro fallback key written for #{bid} (no keychain access required)"
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
    bundle_id
  end

  def local_runtime_bundle_id
    bundle_id = bundle_id_for_app(canonical_local_app_path)
    return bundle_id if bundle_id && bundle_id.match?(/\A[a-zA-Z0-9.\-]+\z/)

    @config[:prod]
  end

  def legacy_fallback_domain(bundle_id)
    "#{bundle_id}.no-keychain"
  end

  def fallback_plist_path(domain)
    File.expand_path("~/Library/Preferences/#{domain}.plist")
  end

  def fallback_pref_key(bundle_id, key_name)
    "sane.no-keychain.#{bundle_id}.#{key_name}"
  end

  def clear_license_fallback_local(bundle_id)
    domain = fallback_domain(bundle_id)
    legacy_domain = legacy_fallback_domain(bundle_id)
    domain_plist = fallback_plist_path(domain)
    legacy_plist = fallback_plist_path(legacy_domain)
    [license_key_name, license_email_name, license_date_name].each do |name|
      key = fallback_pref_key(bundle_id, name)
      system('defaults', 'delete', domain, key, out: File::NULL, err: File::NULL)
      system('defaults', 'delete', domain_plist, key, out: File::NULL, err: File::NULL)
      system('defaults', 'delete', legacy_domain, key, out: File::NULL, err: File::NULL)
      system('defaults', 'delete', legacy_plist, key, out: File::NULL, err: File::NULL)
    end
  end

  def clear_license_fallback_remote(bundle_id)
    domain = fallback_domain(bundle_id)
    legacy_domain = legacy_fallback_domain(bundle_id)
    domain_plist = fallback_plist_path(domain)
    legacy_plist = fallback_plist_path(legacy_domain)
    [license_key_name, license_email_name, license_date_name].each do |name|
      key = fallback_pref_key(bundle_id, name)
      ssh("defaults delete #{Shellwords.escape(domain)} #{Shellwords.escape(key)} 2>/dev/null; true")
      ssh("defaults delete #{Shellwords.escape(domain_plist)} #{Shellwords.escape(key)} 2>/dev/null; true")
      ssh("defaults delete #{Shellwords.escape(legacy_domain)} #{Shellwords.escape(key)} 2>/dev/null; true")
      ssh("defaults delete #{Shellwords.escape(legacy_plist)} #{Shellwords.escape(key)} 2>/dev/null; true")
    end
  end

  def set_pro_fallback_local(bundle_id)
    domain = fallback_domain(bundle_id)
    legacy_domain = legacy_fallback_domain(bundle_id)
    domain_plist = fallback_plist_path(domain)
    legacy_plist = fallback_plist_path(legacy_domain)
    key = fallback_pref_key(bundle_id, license_key_name)
    date_key = fallback_pref_key(bundle_id, license_date_name)
    email_key = fallback_pref_key(bundle_id, license_email_name)
    pro_value = (@app_name == 'SaneBar') ? EARLY_ADOPTER_KEY : TEST_LICENSE_KEY

    system('defaults', 'write', domain, key, '-string', pro_value)
    system('defaults', 'write', domain_plist, key, '-string', pro_value)
    system('defaults', 'write', domain, date_key, '-string', Time.now.utc.iso8601)
    system('defaults', 'write', domain_plist, date_key, '-string', Time.now.utc.iso8601)
    system('defaults', 'write', domain, email_key, '-string', 'test@saneapps.local') unless @app_name == 'SaneBar'
    system('defaults', 'write', domain_plist, email_key, '-string', 'test@saneapps.local') unless @app_name == 'SaneBar'
    system('defaults', 'delete', legacy_domain, key, out: File::NULL, err: File::NULL)
    system('defaults', 'delete', legacy_plist, key, out: File::NULL, err: File::NULL)
    system('defaults', 'delete', legacy_domain, date_key, out: File::NULL, err: File::NULL)
    system('defaults', 'delete', legacy_plist, date_key, out: File::NULL, err: File::NULL)
    system('defaults', 'delete', legacy_domain, email_key, out: File::NULL, err: File::NULL)
    system('defaults', 'delete', legacy_plist, email_key, out: File::NULL, err: File::NULL)
  end

  def set_pro_fallback_remote(bundle_id)
    domain = fallback_domain(bundle_id)
    legacy_domain = legacy_fallback_domain(bundle_id)
    domain_plist = fallback_plist_path(domain)
    legacy_plist = fallback_plist_path(legacy_domain)
    key = fallback_pref_key(bundle_id, license_key_name)
    date_key = fallback_pref_key(bundle_id, license_date_name)
    email_key = fallback_pref_key(bundle_id, license_email_name)
    pro_value = (@app_name == 'SaneBar') ? EARLY_ADOPTER_KEY : TEST_LICENSE_KEY
    now = Time.now.utc.iso8601

    ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(key)} -string #{Shellwords.escape(pro_value)}")
    ssh("defaults write #{Shellwords.escape(domain_plist)} #{Shellwords.escape(key)} -string #{Shellwords.escape(pro_value)}")
    ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(date_key)} -string #{Shellwords.escape(now)}")
    ssh("defaults write #{Shellwords.escape(domain_plist)} #{Shellwords.escape(date_key)} -string #{Shellwords.escape(now)}")
    unless @app_name == 'SaneBar'
      ssh("defaults write #{Shellwords.escape(domain)} #{Shellwords.escape(email_key)} -string test@saneapps.local")
      ssh("defaults write #{Shellwords.escape(domain_plist)} #{Shellwords.escape(email_key)} -string test@saneapps.local")
    end
    ssh("defaults delete #{Shellwords.escape(legacy_domain)} #{Shellwords.escape(key)} 2>/dev/null; true")
    ssh("defaults delete #{Shellwords.escape(legacy_plist)} #{Shellwords.escape(key)} 2>/dev/null; true")
    ssh("defaults delete #{Shellwords.escape(legacy_domain)} #{Shellwords.escape(date_key)} 2>/dev/null; true")
    ssh("defaults delete #{Shellwords.escape(legacy_plist)} #{Shellwords.escape(date_key)} 2>/dev/null; true")
    ssh("defaults delete #{Shellwords.escape(legacy_domain)} #{Shellwords.escape(email_key)} 2>/dev/null; true")
    ssh("defaults delete #{Shellwords.escape(legacy_plist)} #{Shellwords.escape(email_key)} 2>/dev/null; true")
  end

  def launch_env_pairs
    permissionless_automation = @hardware ? '0' : '1'
    hardware_tests = @hardware ? '1' : '0'
    env_args = [
      '--env', 'SANEAPPS_SKIP_MOVE_TO_APPLICATIONS=1',
      '--env', "SANEAPPS_PERMISSIONLESS_AUTOMATION=#{permissionless_automation}",
      '--env', "SANEVIDEO_ENABLE_HARDWARE_TESTS=#{hardware_tests}"
    ]
    if @free_mode
      env_args += ['--env', 'SANEAPPS_FORCE_LICENSE_CHECK=1']
      env_args += ['--env', 'SANEAPPS_FORCE_FREE_MODE=1'] unless @app_name == 'SaneBar'
    end
    env_args
  end

  def launch_env_hash
    launch_env_pairs.each_slice(2).each_with_object({}) do |(flag, assignment), env|
      next unless flag == '--env' && assignment

      key, value = assignment.split('=', 2)
      env[key] = value.to_s if key && !key.empty?
    end
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

  # Command output can arrive mis-tagged (C-locale shells) or with invalid
  # bytes; retag/scrub before any regex or substring matching.
  def self.normalize_command_output(output)
    text = output.to_s.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : text.scrub('?')
  end

  def build_debug
    Dir.chdir(@app_dir) do
      if File.exist?('project.yml') && Dir.glob('*.xcodeproj').empty?
        warn '   Running xcodegen...'
        system('xcodegen', 'generate', out: File::NULL, err: File::NULL)
      end

      # Check if signing certificates are available; fall back to ad-hoc if not
      identities, identity_status = codesigning_identity_output
      identities = '' unless identity_status.success?
      has_signing_cert = !identities.strip.start_with?('0 valid')
      has_developer_id = identities.include?('"Developer ID Application:')
      if signed_release_runtime_required? && !has_developer_id
        abort "   ❌ #{@app_name} runtime testing requires Developer ID signing; refusing unsigned/dev launch."
      end

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
      has_prod_debug = SaneTest.normalize_command_output(`xcodebuild -list 2>/dev/null`).include?('ProdDebug')
      if @release_build
        config_name = 'Release'
      else
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
        if dev_bundle_override_for_build?(config_name)
          dev_bundle_id = @config[:dev]
          if dev_bundle_id
            build_args << "PRODUCT_BUNDLE_IDENTIFIER=#{dev_bundle_id}"
          end
        end
        # For apps without ProdDebug, keep Debug launches ad-hoc signed.
        # Forcing Apple Development signing here can fail on package bundles
        # during unattended Mini builds (errSecInternalComponent).
        if unsigned_debug_overrides_for_build?(config_name, has_prod_debug)
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
      stdout = SaneTest.normalize_command_output(stdout)

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

  def signed_release_runtime_required?
    SIGNED_RELEASE_RUNTIME_APPS.include?(@app_name)
  end

  def dev_bundle_override_for_build?(config_name)
    @app_name != 'SaneBar' && config_name != 'Release'
  end

  def unsigned_debug_overrides_for_build?(config_name, has_prod_debug)
    config_name != 'Release' && !has_prod_debug
  end

  def direct_launch_args
    args = ['--sane-skip-app-move']
    args << '--sane-no-keychain' unless @allow_keychain
    args
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
    SaneTest.normalize_command_output(stdout)
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
      '--include', '*/project.xcworkspace/contents.xcworkspacedata',
      '--filter', ':- .gitignore',
      '--exclude', '.git',
      '--exclude', '.worktrees',
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

if __FILE__ == $PROGRAM_NAME
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
    warn '  --hardware   Allow real hardware/permission prompts for SaneVideo camera verification'
    warn ''
    warn 'Default: deploys to Mac mini if reachable, local otherwise.'
    warn 'SaneClip always uses signed Release runtime to preserve TCC.'
    warn 'TCC is preserved by default — single-copy enforcement prevents stale grants.'
    warn 'Use --fresh to test onboarding or first-launch experience.'
    exit 0
  end

  SaneTest.new(ARGV[0], ARGV[1..] || []).run
end
