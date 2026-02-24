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
MINI_APPS_DIR = '~/Applications'

class SaneTest
  def initialize(app_name, args)
    @app_name = app_name
    @config = APPS[app_name]
    @force_local = args.include?('--local')
    @no_logs = args.include?('--no-logs')
    @free_mode = args.include?('--free-mode')
    @pro_mode = args.include?('--pro-mode')
    @reset_tcc = args.include?('--reset-tcc')
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

  # ── Remote (Mac mini) workflow ──────────────────────────────

  def run_remote
    n = 0
    step("#{n += 1}. Kill existing processes (mini)") { kill_remote }
    step("#{n += 1}. Clean ALL stale copies (mini)") { clean_remote }
    step("#{n += 1}. Build fresh debug build") { build_debug }
    step("#{n += 1}. Deploy to mini") { deploy_to_mini }
    step("#{n += 1}. Verify single copy (mini)") { verify_single_copy_remote }
    step("#{n += 1}. Fresh reset (mini)") { fresh_reset_remote } if @fresh
    step("#{n += 1}. Reset TCC permissions (mini)") { reset_tcc_remote } if @reset_tcc && !@fresh
    step("#{n += 1}. Set license mode (mini)") { set_license_mode_remote } if (@free_mode || @pro_mode) && !@fresh
    step("#{n += 1}. Launch on mini") { launch_remote }
    stream_logs_remote unless @no_logs
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
      "#{MINI_APPS_DIR}/#{@app_name}.app",
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
    bundle_ids.each do |bid|
      ssh("tccutil reset All #{bid} 2>/dev/null; true")
      ssh("tccutil reset Accessibility #{bid} 2>/dev/null; true")
    end
    warn "   Reset TCC for: #{bundle_ids.join(', ')}"
  end

  def fresh_reset_remote
    # Wipe Application Support
    ssh("rm -rf \"$HOME/Library/Application Support/#{@app_name}\" 2>/dev/null; true")
    # Wipe UserDefaults for ALL bundle IDs (dev + prod) and flush preferences cache
    bundle_ids.each do |b|
      ssh("defaults delete #{b} 2>/dev/null; true")
    end
    ssh("killall cfprefsd 2>/dev/null; true")
    # Reset TCC/Accessibility
    bundle_ids.each do |b|
      ssh("tccutil reset All #{b} 2>/dev/null; true")
    end
    # Clear license keychain entries for ALL bundle IDs
    bundle_ids.each do |b|
      LICENSE_KEYCHAIN_KEYS.each do |key|
        ssh("security delete-generic-password -s #{b} -a #{key} 2>/dev/null; true")
      end
    end
    warn "   Wiped App Support, UserDefaults, TCC, license for #{bundle_ids.join(', ')}"
  end

  def fresh_reset_local
    # Wipe Application Support
    app_support = File.expand_path("~/Library/Application Support/#{@app_name}")
    FileUtils.rm_rf(app_support) if File.exist?(app_support)
    # Wipe UserDefaults for ALL bundle IDs (dev + prod) and flush preferences cache
    bundle_ids.each do |b|
      system('defaults', 'delete', b, err: File::NULL, out: File::NULL)
    end
    system('killall', 'cfprefsd', err: File::NULL, out: File::NULL)
    # Reset TCC/Accessibility
    bundle_ids.each do |b|
      system('tccutil', 'reset', 'All', b, out: File::NULL, err: File::NULL)
    end
    # Clear license keychain entries for ALL bundle IDs
    bundle_ids.each do |b|
      LICENSE_KEYCHAIN_KEYS.each do |key|
        system('security', 'delete-generic-password', '-s', b, '-a', key, err: File::NULL)
      end
    end
    warn "   Wiped App Support, UserDefaults, TCC, license for #{bundle_ids.join(', ')}"
  end

  def verify_single_copy_remote
    # After deploy, ensure ONLY the canonical copy exists
    canonical = "#{MINI_APPS_DIR}/#{@app_name}.app"
    copies = ssh_capture("mdfind 'kMDItemFSName == \"#{@app_name}.app\"' 2>/dev/null").strip.split("\n").reject(&:empty?)
    # Filter to actual .app bundles (mdfind can return partial matches)
    copies.select! { |p| p.end_with?("#{@app_name}.app") }
    non_canonical = copies.reject { |p| p.include?(canonical.sub('~', '')) }
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

  def deploy_to_mini
    dd_app = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless dd_app

    tar_path = "/tmp/#{@app_name}-dev.tar.gz"
    system('tar', 'czf', tar_path, '-C', File.dirname(dd_app), "#{@app_name}.app")

    unless system('scp', '-o', 'ConnectTimeout=5', tar_path, "#{MINI_HOST}:/tmp/")
      abort '   ❌ Failed to upload to mini'
    end

    ssh("mkdir -p #{MINI_APPS_DIR} && tar xzf /tmp/#{@app_name}-dev.tar.gz -C #{MINI_APPS_DIR}/")
    warn "   Deployed to #{MINI_HOST}:#{MINI_APPS_DIR}/#{@app_name}.app"
  end

  def launch_remote
    launch_cmd =
      if @allow_keychain
        "open #{MINI_APPS_DIR}/#{@app_name}.app"
      else
        "open #{MINI_APPS_DIR}/#{@app_name}.app --args --sane-no-keychain"
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
    step("#{n += 1}. Build fresh debug build") { build_debug }
    step("#{n += 1}. Verify single copy") { verify_single_copy_local }
    step("#{n += 1}. Dedupe Accessibility entries") { dedupe_accessibility_entries_local }
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
    count = 0
    ["/tmp/#{@app_name}.app", "/tmp/#{@app_name}-dev.tar.gz"].each do |path|
      if File.exist?(path)
        FileUtils.rm_rf(path)
        count += 1
      end
    end
    # Local launch now stages to a canonical app path (not DerivedData).
    # Keep DerivedData as build source only; do not remove canonical app here.
    warn "   Cleaned #{count} stale copies"
  end

  def verify_single_copy_local
    dd_app = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless dd_app
    canonical = canonical_local_app_path
    warn "   Local launch canonical path: #{canonical}"
  end

  def dedupe_accessibility_entries_local
    # Local SaneBar launches use signed ProdDebug with production bundle ID.
    # If a prior unsigned/dev run granted com.sanebar.dev, System Settings shows
    # two "SaneBar" entries. Remove the dev Accessibility grant in this case.
    return unless @app_name == 'SaneBar'
    return unless @config[:dev] && @config[:prod] && @config[:dev] != @config[:prod]

    app_path = find_derived_data_app
    return unless app_path

    info_plist = File.join(app_path, 'Contents', 'Info.plist')
    runtime_bundle = `"/usr/libexec/PlistBuddy" -c "Print :CFBundleIdentifier" "#{info_plist}" 2>/dev/null`.strip
    return unless runtime_bundle == @config[:prod]

    system('tccutil', 'reset', 'Accessibility', @config[:dev], out: File::NULL, err: File::NULL)
    warn "   Dedupe: reset Accessibility for #{@config[:dev]} (running #{@config[:prod]})"
  end

  def reset_tcc_local
    bundle_ids.each do |bid|
      system('tccutil', 'reset', 'All', bid, out: File::NULL, err: File::NULL)
      system('tccutil', 'reset', 'Accessibility', bid, out: File::NULL, err: File::NULL)
    end
    warn "   Reset TCC for: #{bundle_ids.join(', ')}"
  end

  def launch_local
    source_app_path = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless source_app_path
    app_path = stage_to_canonical_local_app_path(source_app_path)

    if @allow_keychain
      system('open', app_path)
    else
      system('open', app_path, '--args', '--sane-no-keychain')
    end
    sleep 2
    pid = `pgrep -x #{@app_name} 2>/dev/null`.strip
    abort '   ❌ App failed to launch' if pid.empty?
    warn "   Running (PID: #{pid})"
  end

  def canonical_local_app_path
    env_override = ENV['SANETEST_CANONICAL_APP_PATH'] || ENV['SANEMASTER_CANONICAL_APP_PATH']
    return File.expand_path(env_override) if env_override && !env_override.strip.empty?

    app_name = "#{@app_name}.app"
    system_app = File.join('/Applications', app_name)
    user_app = File.expand_path(File.join('~/Applications', app_name))

    return system_app if File.exist?(system_app)
    return user_app if File.exist?(user_app)

    user_app
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
      backup_app_path = "#{target_app_path}.backup-#{Process.pid}-#{Time.now.to_i}"

      begin
        FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
        ok = system('ditto', source_app_path, temp_app_path)
        abort "   ❌ Failed to stage app to canonical path: #{target_app_path}" unless ok && File.exist?(temp_app_path)

        FileUtils.mv(target_app_path, backup_app_path) if File.exist?(target_app_path)
        FileUtils.mv(temp_app_path, target_app_path)
        staged_ok = File.exist?(target_app_path)
      ensure
        FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
        FileUtils.rm_rf(backup_app_path) if File.exist?(backup_app_path)
        lock_file.flock(File::LOCK_UN)
      end
    end

    abort "   ❌ Canonical app missing after staging: #{target_app_path}" unless staged_ok

    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    system(lsregister, '-kill', '-r', '-domain', 'user', out: File::NULL, err: File::NULL) if File.exist?(lsregister)

    target_app_path
  end

  def stream_logs_local
    puts ''
    puts '📡 Streaming logs (Ctrl+C to stop)...'
    puts '─' * 60
    Kernel.exec('log', 'stream', '--predicate',
                "subsystem BEGINSWITH \"#{@config[:log_subsystem]}\"", '--info', '--debug', '--style', 'compact')
  end

  # ── License Mode ─────────────────────────────────────────────

  LICENSE_KEYCHAIN_KEYS = %w[
    pro_license_key
    pro_license_email
    pro_last_validation
  ].freeze

  TEST_LICENSE_KEY = '66C2DC9C-3B72-41DC-8F79-BDE07715F2DE'

  def set_license_mode_local
    bid = @config[:dev]
    if @free_mode
      warn '   Clearing license data (free mode)...'
      LICENSE_KEYCHAIN_KEYS.each do |key|
        system('security', 'delete-generic-password', '-s', bid, '-a', key, err: File::NULL)
      end
      # Clear cached validation and grandfathered flag from settings
      clear_license_settings_local
      warn '   License cleared — app will launch as Free user'
    elsif @pro_mode
      warn '   Injecting test license key (pro mode)...'
      system('security', 'add-generic-password', '-s', bid,
             '-a', LICENSE_KEYCHAIN_KEYS[0], '-w', TEST_LICENSE_KEY, '-U')
      warn "   Test key injected — app will attempt validation with #{TEST_LICENSE_KEY}"
    end
  end

  def set_license_mode_remote
    bid = @config[:dev]
    if @free_mode
      warn '   Clearing license data on mini (free mode)...'
      LICENSE_KEYCHAIN_KEYS.each do |key|
        ssh("security delete-generic-password -s #{bid} -a #{key} 2>/dev/null; true")
      end
      clear_license_settings_remote
      warn '   License cleared on mini — app will launch as Free user'
    elsif @pro_mode
      warn '   Injecting test license key on mini (pro mode)...'
      ssh("security add-generic-password -s #{bid} -a #{LICENSE_KEYCHAIN_KEYS[0]} -w #{TEST_LICENSE_KEY} -U 2>/dev/null; true")
      warn "   Test key injected on mini — app will attempt validation"
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
        '-configuration', config_name
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
        # When falling back to Debug (no ProdDebug), override signing so the
        # binary is properly signed and can launch on remote machines (Mini).
        unless has_prod_debug
          build_args += [
            'CODE_SIGN_IDENTITY=Apple Development',
            'DEVELOPMENT_TEAM=M78L6FXD48'
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
        puts ''
        stdout.lines.select { |l| l.match?(/error:|BUILD FAILED/) }.last(5).each { |l| warn "   #{l.rstrip}" }
        abort '   ❌ Build failed'
      end
    end
  end

  def find_derived_data_app
    configs =
      if @app_name == 'SaneBar' && @target == :local
        %w[ProdDebug]
      elsif @last_build_config
        [@last_build_config] + (%w[ProdDebug Debug] - [@last_build_config])
      else
        %w[ProdDebug Debug]
      end

    configs.each do |config|
      pattern = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products/#{config}/#{@app_name}.app")
      result = Dir.glob(pattern).max_by { |p| File.mtime(p) }
      return result if result
    end
    nil
  end

  def ssh(cmd)
    system('ssh', '-o', 'ConnectTimeout=5', MINI_HOST, cmd)
  end

  def ssh_capture(cmd)
    `ssh -o ConnectTimeout=5 #{MINI_HOST} '#{cmd}' 2>/dev/null`
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
  warn '  --free-mode  Clear license data — launch as Free user'
  warn '  --pro-mode   Inject test license key — launch in Pro validation mode'
  warn '  --reset-tcc  Reset TCC/Accessibility permissions (only for fresh installs)'
  warn '  --allow-keychain  Allow real keychain access during app launch (default is no-keychain)'
  warn '  --allow-unsigned-debug  Allow local SaneBar Debug launch without signing certs (unsupported visibility path)'
  warn ''
  warn 'Default: deploys to Mac mini if reachable, local otherwise.'
  warn 'TCC is preserved by default — single-copy enforcement prevents stale grants.'
  warn 'Use --fresh to test onboarding or first-launch experience.'
  exit 0
end

SaneTest.new(ARGV[0], ARGV[1..] || []).run
