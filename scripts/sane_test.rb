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
    @app_dir = File.join(SANE_APPS_ROOT, app_name)

    abort "❌ Unknown app: #{app_name}. Known: #{APPS.keys.join(', ')}" unless @config
    abort "❌ App directory not found: #{@app_dir}" unless File.directory?(@app_dir)
    abort '❌ Cannot use --free-mode and --pro-mode together' if @free_mode && @pro_mode
  end

  def run
    puts "🧪 === SANE TEST: #{@app_name} ==="
    puts ''

    target = determine_target
    puts "📍 Target: #{target == :mini ? 'Mac mini (remote)' : 'Local'}"
    puts ''

    case target
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
    step('1. Kill existing processes (mini)') { kill_remote }
    step('2. Clean ALL stale copies (mini)') { clean_remote }
    step('3. Build fresh debug build') { build_debug }
    step('4. Deploy to mini') { deploy_to_mini }
    step('5. Verify single copy (mini)') { verify_single_copy_remote }
    if @reset_tcc
      step('6. Reset TCC permissions (mini)') { reset_tcc_remote }
    end
    step("#{@reset_tcc ? '7' : '6'}. Set license mode (mini)") { set_license_mode_remote } if @free_mode || @pro_mode
    n = @reset_tcc ? 7 : 6
    n += 1 if @free_mode || @pro_mode
    step("#{n}. Launch on mini") { launch_remote }
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
    ssh("open #{MINI_APPS_DIR}/#{@app_name}.app")
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
    step('1. Kill existing processes') { kill_local }
    step('2. Clean ALL stale copies') { clean_local }
    step('3. Build fresh debug build') { build_debug }
    step('4. Verify single copy') { verify_single_copy_local }
    if @reset_tcc
      step('5. Reset TCC permissions') { reset_tcc_local }
    end
    step("#{@reset_tcc ? '6' : '5'}. Set license mode") { set_license_mode_local } if @free_mode || @pro_mode
    n = @reset_tcc ? 6 : 5
    n += 1 if @free_mode || @pro_mode
    step("#{n}. Launch locally") { launch_local }
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
    # Don't clean DerivedData .app bundles locally — that's where we launch from
    # But DO clean /Applications copies that shouldn't be there
    sys_app = "/Applications/#{@app_name}.app"
    if File.exist?(sys_app)
      FileUtils.rm_rf(sys_app)
      count += 1
    end
    warn "   Cleaned #{count} stale copies"
  end

  def verify_single_copy_local
    dd_app = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless dd_app
    copies = `mdfind 'kMDItemFSName == "#{@app_name}.app"' 2>/dev/null`.strip.split("\n").reject(&:empty?)
    copies.select! { |p| p.end_with?("#{@app_name}.app") }
    # The canonical copy is in DerivedData for local builds
    non_canonical = copies.reject { |p| p.include?('DerivedData') }
    if non_canonical.empty?
      warn "   Single copy verified in DerivedData"
    else
      warn "   ⚠️  Found #{non_canonical.size} extra copies — removing:"
      non_canonical.each do |path|
        warn "      #{path}"
        FileUtils.rm_rf(path)
      end
    end
  end

  def reset_tcc_local
    bundle_ids.each do |bid|
      system('tccutil', 'reset', 'All', bid, out: File::NULL, err: File::NULL)
      system('tccutil', 'reset', 'Accessibility', bid, out: File::NULL, err: File::NULL)
    end
    warn "   Reset TCC for: #{bundle_ids.join(', ')}"
  end

  def launch_local
    app_path = find_derived_data_app
    abort '   ❌ Built app not found in DerivedData' unless app_path

    system('open', app_path)
    sleep 2
    pid = `pgrep -x #{@app_name} 2>/dev/null`.strip
    abort '   ❌ App failed to launch' if pid.empty?
    warn "   Running (PID: #{pid})"
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
    com.sanebar.license.key
    com.sanebar.license.instanceId
  ].freeze

  TEST_LICENSE_KEY = 'SANEBAR-TEST-KEY-FOR-AUTOMATED-TESTING'

  def set_license_mode_local
    if @free_mode
      warn '   Clearing license data (free mode)...'
      LICENSE_KEYCHAIN_KEYS.each do |key|
        system('security', 'delete-generic-password', '-s', key, err: File::NULL)
      end
      # Clear cached validation and grandfathered flag from settings
      clear_license_settings_local
      warn '   License cleared — app will launch as Free user'
    elsif @pro_mode
      warn '   Injecting test license key (pro mode)...'
      system('security', 'add-generic-password', '-s', LICENSE_KEYCHAIN_KEYS[0],
             '-a', 'license', '-w', TEST_LICENSE_KEY, '-U')
      warn "   Test key injected — app will attempt validation with #{TEST_LICENSE_KEY}"
    end
  end

  def set_license_mode_remote
    if @free_mode
      warn '   Clearing license data on mini (free mode)...'
      LICENSE_KEYCHAIN_KEYS.each do |key|
        ssh("security delete-generic-password -s #{key} 2>/dev/null; true")
      end
      clear_license_settings_remote
      warn '   License cleared on mini — app will launch as Free user'
    elsif @pro_mode
      warn '   Injecting test license key on mini (pro mode)...'
      ssh("security add-generic-password -s #{LICENSE_KEYCHAIN_KEYS[0]} -a license -w #{TEST_LICENSE_KEY} -U 2>/dev/null; true")
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

      build_args = [
        'xcodebuild',
        '-scheme', @config[:scheme],
        '-destination', 'platform=macOS',
        '-configuration', 'Debug'
      ]

      unless has_signing_cert
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
    pattern = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{@app_name}-*/Build/Products/Debug/#{@app_name}.app")
    Dir.glob(pattern).max_by { |p| File.mtime(p) }
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
  warn '  --free-mode  Clear license data — launch as Free user'
  warn '  --pro-mode   Inject test license key — launch in Pro validation mode'
  warn '  --reset-tcc  Reset TCC/Accessibility permissions (only for fresh installs)'
  warn ''
  warn 'Default: deploys to Mac mini if reachable, local otherwise.'
  warn 'TCC is preserved by default — single-copy enforcement prevents stale grants.'
  exit 0
end

SaneTest.new(ARGV[0], ARGV[1..] || []).run
