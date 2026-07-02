#!/usr/bin/env ruby
# frozen_string_literal: true

# Pin UTF-8 as the default encoding before any I/O. Review-comments/release-notes
# files and HTTP response bodies legitimately contain non-ASCII (em dashes, curly
# quotes, emoji). Under a locale-less shell (hooks, launchd, non-login ssh to the
# Mini) Ruby defaults to US-ASCII, so File.read + a later string match raises
# "invalid byte sequence in US-ASCII". Same fix family as sane_test.rb / e7bab2c.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'json'
require 'digest'
require 'find'
require 'open3'
require 'optparse'
require 'rexml/document'
require 'tempfile'
require 'tmpdir'
require 'uri'
require_relative 'setapp_config'
require_relative 'setapp_status'

class SetappUpload
  CommandStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.to_i.zero?
    end
  end

  API_BASE = 'https://developer-api.setapp.com/v1'
  CI_ENDPOINT = "#{API_BASE}/ci/version"
  PORTAL_UPLOAD_ENDPOINT = "#{API_BASE}/versions/upload_archive"
  TRUSTED_ARCHIVE_HOSTS = %w[store.setapp.com downloads.macpaw.com].freeze
  PRIVATE_COMMENT_KEYS = %w[
    vendor_comment
    reviewer_comment
    review_comment
    decline_reason
    rejection_reason
  ].freeze
  MAX_ARCHIVE_ENTRIES = 20_000
  MAX_ARCHIVE_BYTES = 1 * 1024 * 1024 * 1024
  MAX_ARCHIVE_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
  STATUS_LABELS = {
    2 => 'Needs Revision',
    5 => 'In Review',
    9 => 'Manual Release Required',
    10 => 'Released'
  }.freeze
  NON_ACTION_STATUSES = [5, 10].freeze
  REQUIRED_INFO_PLIST_KEYS = %w[
    CFBundleIdentifier
    CFBundleName
    CFBundleIconFile
    CFBundleVersion
    CFBundleShortVersionString
    NSUpdateSecurityPolicy
  ].freeze
  SETAPP_AGENT_PROCESS = 'com.setapp.DesktopClient.SetappAgent'
  FORBIDDEN_ARCHIVE_ENTRIES = [
    [/\A__MACOSX(?:\/|\z)/, '__MACOSX metadata folder'],
    [/(?:\A|\/)\.DS_Store\z/, '.DS_Store metadata file'],
    [%r{(?:\A|/)Sparkle\.framework(?:/|\z)}, 'Sparkle.framework payload']
  ].freeze
  FORBIDDEN_SETAPP_PAYLOAD_PATTERNS = [
    [/\bSaneSparkleRow\b/i, 'Sparkle settings UI'],
    [/\bSUFeedURL\b/i, 'Sparkle feed key'],
    [%r{github\.com/sponsors}i, 'GitHub Sponsors/donation link'],
    [/\bdirect download\b/i, 'direct-download copy']
  ].freeze

  # Inert direct-channel residue: strings that unavoidably land in the main
  # executable because the shared app TARGET weak-links the Sparkle SPM
  # product for all configs and shared SaneUI carries direct-channel string
  # constants. These are tolerated ONLY in Mach-O binaries and ONLY when the
  # bundle is proven functionally Sparkle-free: no Sparkle.framework payload
  # anywhere (separately fatal above) AND every Sparkle load command is
  # LC_LOAD_WEAK_DYLIB (a strong link to a stripped framework would crash at
  # launch). Setapp approved builds with exactly this weak-link shape (e.g.
  # SaneClip 2.3.9, thread #895). The same strings anywhere else (plists,
  # resources) remain fatal — there they are configuration, not linker
  # fallout. Owner decision 2026-07-01: verify non-functionality instead of
  # string hygiene until the dedicated no-Sparkle Setapp target exists.
  INERT_WEAK_LINK_PAYLOAD_PATTERNS = [
    [/\bSparkle\.framework\b/i, 'Sparkle framework reference'],
    [/\bAppStoreProductID\b/i, 'direct/App Store product identifier key'],
    [/sparkle-project\.org/i, 'Sparkle project URL']
  ].freeze

  # Direct-license residue from shared SaneUI's LicenseService, which serves
  # direct/App Store/Setapp purchase from one class used by 7 SaneApps
  # products — splitting it into per-channel modules is a bigger, riskier cut
  # than is safe to make blind across apps this scanner can't test. What IS
  # verified: SaneUI's SaneLicenseServiceSetappGateTests.swift
  # (sane-apps/SaneUI, added alongside this tolerance) pins the FULL
  # reachability chain for a Setapp-backed instance — checkoutURL is nil,
  # activate(key:) and checkCachedLicense() both return before EVER calling
  # validateWithLemonSqueezy()/lemonSqueezyValidationURL() (the two call sites
  # that construct and hit the LemonSqueezy API), and the entry-UI branch that
  # would show "Enter/Paste License Key" copy is unreachable behind
  # usesSetappPurchase/usesAppStorePurchase checks in the view's if/else-if
  # chain.
  #
  # LicenseService's ascii([UInt8]) helper does NOT remove the literal
  # "lemonsqueezy"/"licenses"/"validate" bytes from the compiled binary — it
  # only hides the string from a SOURCE-code grep. The Swift array literal
  # still compiles to the exact same readable ASCII bytes in the Mach-O, so a
  # binary `strings` scan finds it regardless (verified directly: repro
  # 2026-07-01, SaneClip 2.3.12 Setapp build). Do not treat that helper as a
  # binary-level defense for this tolerance's purposes.
  #
  # Tolerated ONLY in Mach-O binaries (a resource/plist hit remains fatal —
  # that would be configuration, not compiled-in dead code). Owner decision
  # 2026-07-01: verify non-functionality instead of string hygiene until the
  # dedicated no-Sparkle, no-direct-license Setapp target exists (tracked:
  # SaneClip session task #26).
  INERT_UNREACHABLE_LICENSE_PAYLOAD_PATTERNS = [
    [/\b(?:Enter|Paste) License Key\b/i, 'direct license-key UI copy'],
    [/\bcheckout(?:URL|Clicked)?\b/i, 'direct checkout code/copy'],
    [/\blemon ?squeezy\b/i, 'Lemon Squeezy direct-license string'],
    [%r{api\.lemonsqueezy\.com/v1/licenses/validate}i, 'Lemon Squeezy license API string']
  ].freeze
  PROFILE_REQUIRED_ENTITLEMENTS = [
    'com.apple.developer.icloud-container-identifiers',
    'com.apple.developer.icloud-services',
    'com.apple.security.application-groups',
    'keychain-access-groups'
  ].freeze
  RELEASE_NOTES_MAX_CHARS = 5_000
  REVIEW_COMMENTS_MAX_CHARS = 2_000
  RELEASE_NOTES_FORBIDDEN_PATTERNS = [
    [/\breview(?:er| team)?\b/i, 'release notes must not mention review process details'],
    [/\b(reupload|resubmit|submission|developer account|portal|build settings)\b/i, 'release notes must not mention portal or submission workflow'],
    [/\b(?:app|build|zip|uploaded|submitted|review) archive\b|\barchive_url\b|\bnotari[sz]ed\b|\bcode[- ]?sign(?:ed|ing)?\b|\bDeveloper ID signed\b|\bprovisioning profile\b|\bentitlements?\b/i, 'release notes must not mention packaging/signing internals'],
    [/\b(bundle id|bundle identifier|version id|app id)\b/i, 'release notes must not mention internal identifiers'],
    [/\b(1024|824|100px|png|icns|margins?|rounded design corners?)\b/i, 'release notes must not mention icon geometry requirements'],
    [/\b(lemon ?squeezy|license key|checkout|sparkle|dmg|direct download|github sponsors?|donat(?:e|ion))\b/i, 'release notes must not mention direct-channel purchase/update/donation surfaces'],
    [/\b(todo|tbd|placeholder|lorem ipsum|test notes?|release notes?)\b/i, 'release notes must not be placeholders']
  ].freeze

  def initialize(argv)
    @options = {
      status: 'review',
      beta: false,
      release_on_approval: false,
      allow_overwrite: true,
      portal_fallback: false,
      safari_token: true,
      allow_needs_revision: false,
      validate_only: false,
      json: false,
      dry_run: false
    }
    parse!(argv)
  end

  def run
    validate!
    return validate_only if @options[:validate_only]
    return dry_run if @options[:dry_run]

    enforce_mini_host!

    if @options[:portal_fallback]
      run_portal_fallback
    else
      run_ci_upload
    end
  end

  private

  def parse!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: setapp_upload --zip ZIP --release-notes TEXT [--portal-fallback --app-id ID --version-id ID]'
      opts.on('--zip PATH', 'Setapp ZIP archive to upload') { |value| @options[:zip] = value }
      opts.on('--release-notes TEXT', 'Release notes text') { |value| @options[:release_notes] = value }
      opts.on('--release-notes-file PATH', 'Read release notes from a file') do |value|
        @options[:release_notes] = File.read(value)
      end
      opts.on('--review-comments TEXT', 'Private comments for the Setapp review team') { |value| @options[:review_comments] = value }
      opts.on('--review-comments-file PATH', 'Read private Setapp review comments from a file') do |value|
        @options[:review_comments] = File.read(value)
      end
      opts.on('--no-review-comments-needed', 'Explicitly confirm no private Setapp review comments are needed') do
        @options[:no_review_comments_needed] = true
      end
      opts.on('--app-id ID', 'Setapp application id; required for portal fallback') { |value| @options[:app_id] = value }
      opts.on('--version-id ID', 'Existing Setapp version id to patch; required for portal fallback') { |value| @options[:version_id] = value }
      opts.on('--status STATUS', 'CI upload status: draft or review') { |value| @options[:status] = value }
      opts.on('--release-on-approval BOOL', 'Publish automatically after approval') do |value|
        @options[:release_on_approval] = parse_bool(value)
      end
      opts.on('--beta BOOL', 'Upload as beta build') { |value| @options[:beta] = parse_bool(value) }
      opts.on('--allow-overwrite BOOL', 'Allow CI overwrite of a waiting review build') do |value|
        @options[:allow_overwrite] = parse_bool(value)
      end
      opts.on('--portal-fallback', 'Use logged-in portal upload + patch path') { @options[:portal_fallback] = true }
      opts.on('--no-safari-token', 'Do not read the portal token from Safari cookies') { @options[:safari_token] = false }
      opts.on('--allow-needs-revision', 'Attach archive without failing when the portal still needs Submit for review') do
        @options[:allow_needs_revision] = true
      end
      opts.on('--validate-only', 'Validate the archive and exit without uploading') { @options[:validate_only] = true }
      opts.on('--json', 'Print machine-readable response') { @options[:json] = true }
      opts.on('--dry-run', 'Validate inputs and print the planned upload path') { @options[:dry_run] = true }
      opts.on('-h', '--help', 'Show help') do
        puts opts
        exit 0
      end
    end

    parser.parse!(argv)
  rescue Errno::ENOENT => e
    abort "Release notes file not found: #{e.message}"
  end

  def validate!
    abort 'Missing --zip PATH' if @options[:zip].to_s.empty?
    abort "ZIP not found: #{@options[:zip]}" unless File.file?(@options[:zip])
    if !@options[:validate_only] && @options[:release_notes].to_s.strip.empty?
      abort 'Missing --release-notes or --release-notes-file'
    end
    validate_release_notes!(@options[:release_notes]) if !@options[:validate_only] || !@options[:release_notes].to_s.strip.empty?
    validate_review_comments!(@options[:review_comments]) unless @options[:review_comments].to_s.strip.empty?
    abort 'Setapp status must be draft or review' unless %w[draft review].include?(@options[:status])
    validate_archive!
    enforce_manifest_policies!

    return unless @options[:portal_fallback]

    abort 'Portal fallback requires --app-id' if @options[:app_id].to_s.empty?
    abort 'Portal fallback requires --version-id' if @options[:version_id].to_s.empty?
    validate_portal_target_matches_archive!
  end

  def validate_archive!
    validate_zip_central_directory!
    validate_zip_entry_names!
    Dir.mktmpdir('setapp-upload-archive') do |tmpdir|
      _stdout, stderr, status = capture3_with_timeout(
        120,
        '/usr/bin/unzip',
        '-q',
        File.expand_path(@options[:zip]),
        '-d',
        tmpdir
      )
      abort "Setapp archive could not be expanded: #{stderr.strip}" unless status.success?

      reject_extracted_links!(tmpdir)

      app_paths = archive_app_paths(tmpdir)
      if app_paths.length != 1
        abort "Setapp archive must contain exactly one .app bundle at the archive root or inside one wrapper directory; found #{app_paths.length}"
      end

      app_path = safe_extracted_path!(app_paths.first, tmpdir, 'Setapp archive app')
      root_icon_path = File.join(File.dirname(app_path), "#{File.basename(app_path, '.app')}.png")
      abort "Setapp archive is missing sibling app icon PNG: #{File.basename(root_icon_path)}" unless File.file?(root_icon_path)
      root_icon_path = safe_extracted_path!(root_icon_path, tmpdir, 'Setapp archive sibling app icon PNG')
      @root_icon_geometry = validate_root_icon_png!(root_icon_path)

      icon_path = File.join(app_path, 'Contents', 'Resources', 'AppIcon.icns')
      abort 'Setapp archive is missing Contents/Resources/AppIcon.icns' unless File.file?(icon_path)
      icon_path = safe_extracted_path!(icon_path, tmpdir, 'Setapp archive AppIcon.icns')
      validate_archive_icon!(icon_path)

      info_plist = safe_extracted_path!(File.join(app_path, 'Contents', 'Info.plist'), tmpdir, 'Setapp archive Info.plist')
      validate_required_info_plist_keys!(info_plist, 'Setapp archive app')
      validate_setapp_update_security_policy!(info_plist, 'Setapp archive app')
      @archive_metadata = {
        app_name: File.basename(app_path, '.app'),
        bundle_id: plist_value(info_plist, 'CFBundleIdentifier', 'Setapp archive app'),
        version: plist_value(info_plist, 'CFBundleVersion', 'Setapp archive app'),
        ui_version: plist_value(info_plist, 'CFBundleShortVersionString', 'Setapp archive app')
      }
      validate_supported_architectures!(info_plist, 'Setapp archive MPSupportedArchitectures')
      validate_executable_architectures!(bundle_executable_path(app_path), 'Setapp archive executable')
      validate_signature!(app_path, 'Setapp archive app')
      validate_developer_id_signature!(app_path, 'Setapp archive app') if gatekeeper_validation_required?
      validate_embedded_profile!(app_path, 'Setapp archive app')
      validate_gatekeeper_acceptance!(app_path, 'Setapp archive app') if gatekeeper_validation_required?
      validate_forbidden_setapp_payload_strings!(app_path)

      Dir.glob(File.join(app_path, 'Contents', 'PlugIns', '*.appex')).each do |appex_path|
        appex_path = safe_extracted_path!(appex_path, tmpdir, "Setapp archive extension #{File.basename(appex_path)}")
        validate_executable_architectures!(
          bundle_executable_path(appex_path),
          "Setapp archive extension #{File.basename(appex_path)}"
        )
        validate_signature!(appex_path, "Setapp archive extension #{File.basename(appex_path)}")
        validate_developer_id_signature!(appex_path, "Setapp archive extension #{File.basename(appex_path)}") if gatekeeper_validation_required?
        validate_embedded_profile!(appex_path, "Setapp archive extension #{File.basename(appex_path)}")
      end
    end
  end

  def archive_app_paths(tmpdir)
    top_level_apps = Dir.glob(File.join(tmpdir, '*.app')).select { |path| File.directory?(path) }
    return top_level_apps unless top_level_apps.empty?

    children = Dir.children(tmpdir).reject { |entry| entry.start_with?('.') }.map { |entry| File.join(tmpdir, entry) }
    dirs = children.select { |path| File.directory?(path) }
    files = children.select { |path| File.file?(path) }
    return [] unless dirs.length == 1 && files.empty?

    Dir.glob(File.join(dirs.first, '*.app')).select { |path| File.directory?(path) }
  end

  def validate_zip_central_directory!
    archive_size = File.size(File.expand_path(@options[:zip]))
    if archive_size > MAX_ARCHIVE_BYTES
      abort "Setapp archive is #{archive_size} bytes; Setapp limits upload ZIPs to #{MAX_ARCHIVE_BYTES} bytes"
    end

    output, stderr, status = capture3_with_timeout(30, '/usr/bin/zipinfo', '-l', File.expand_path(@options[:zip]))
    abort "Setapp archive central directory could not be inspected: #{stderr.strip}" unless status.success?

    entry_count = 0
    total_uncompressed = 0
    output.each_line do |line|
      next unless line.match?(/\A[-dl]/)

      entry_count += 1
      parts = line.split(/\s+/)
      total_uncompressed += parts[3].to_i if parts[3]
      abort 'Setapp archive contains symlinks; refusing to validate or upload it' if line.start_with?('l')
    end
    if entry_count > MAX_ARCHIVE_ENTRIES
      abort "Setapp archive has #{entry_count} entries; maximum allowed is #{MAX_ARCHIVE_ENTRIES}"
    end
    if total_uncompressed > MAX_ARCHIVE_UNCOMPRESSED_BYTES
      abort "Setapp archive expands to #{total_uncompressed} bytes; maximum allowed is #{MAX_ARCHIVE_UNCOMPRESSED_BYTES}"
    end
  end

  def validate_zip_entry_names!
    output, stderr, status = capture3_with_timeout(30, '/usr/bin/zipinfo', '-1', File.expand_path(@options[:zip]))
    abort "Setapp archive entry names could not be inspected: #{stderr.strip}" unless status.success?

    output.each_line do |line|
      entry = line.strip
      next if entry.empty?

      FORBIDDEN_ARCHIVE_ENTRIES.each do |pattern, reason|
        abort "Setapp archive contains forbidden #{reason}: #{entry}" if entry.match?(pattern)
      end
    end
  end

  def validate_release_notes!(notes)
    text = notes.to_s.tr("\r", '').strip
    abort 'Setapp release notes are empty after trimming whitespace' if text.empty?
    if text.length > RELEASE_NOTES_MAX_CHARS
      abort "Setapp release notes are #{text.length} characters; Setapp limits release notes to #{RELEASE_NOTES_MAX_CHARS}"
    end
    abort 'Setapp release notes must not contain control characters' if text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)

    RELEASE_NOTES_FORBIDDEN_PATTERNS.each do |pattern, reason|
      next unless text.match?(pattern)

      abort "Setapp release notes are not user-facing: #{reason}"
    end
    true
  end

  def validate_review_comments!(comments)
    text = comments.to_s.tr("\r", '').strip
    abort 'Setapp review comments are empty after trimming whitespace' if text.empty?
    if text.length > REVIEW_COMMENTS_MAX_CHARS
      abort "Setapp review comments are #{text.length} characters; Setapp limits review-team comments to #{REVIEW_COMMENTS_MAX_CHARS}"
    end
    abort 'Setapp review comments must not contain control characters' if text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)

    true
  end

  def reject_extracted_links!(root_dir)
    Find.find(root_dir) do |path|
      stat = File.lstat(path)
      abort "Setapp archive contains a symlink: #{relative_extract_path(root_dir, path)}" if stat.symlink?
      next unless stat.file?

      if stat.nlink > 1
        abort "Setapp archive contains a hardlinked file: #{relative_extract_path(root_dir, path)}"
      end
    end
  end

  def safe_extracted_path!(path, root_dir, label)
    root = File.realpath(root_dir)
    real = File.realpath(path)
    return real if real == root || real.start_with?("#{root}#{File::SEPARATOR}")

    abort "#{label} resolves outside the extracted Setapp archive: #{path}"
  rescue Errno::ENOENT
    abort "#{label} is missing: #{path}"
  end

  def relative_extract_path(root_dir, path)
    path.sub(/\A#{Regexp.escape(root_dir)}\/?/, '')
  end

  def validate_root_icon_png!(icon_path)
    output, icon_stderr, icon_status = capture3_with_timeout(
      30,
      '/usr/bin/sips',
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      icon_path
    )
    abort "Setapp archive sibling app icon PNG could not be inspected: #{icon_stderr.strip}" unless icon_status.success?

    width = output[/pixelWidth:\s*(\d+)/, 1].to_i
    height = output[/pixelHeight:\s*(\d+)/, 1].to_i
    unless width == 1024 && height == 1024
      abort "Setapp archive sibling app icon PNG is #{width}x#{height}; Setapp requires 1024x1024"
    end

    validate_setapp_icon_geometry!(icon_path, label: 'Setapp archive sibling app icon PNG')
  end

  def validate_setapp_icon_geometry!(icon_path, label:, rendered: false)
    args = [
      swift_executable,
      setapp_icon_tool_path,
      'validate',
      '--path',
      icon_path,
      '--size',
      '1024'
    ]
    args << '--rendered' if rendered
    output, icon_stderr, icon_status = capture3_with_timeout(
      60,
      *args
    )
    return output.strip if icon_status.success?

    detail = [icon_stderr.strip, output.strip].reject(&:empty?).join("\n")
    abort "#{label} does not meet Setapp frame/corner requirements: #{detail}"
  end

  def setapp_icon_tool_path
    @setapp_icon_tool_path ||= File.expand_path('setapp_icon_tool.swift', __dir__)
  end

  def swift_executable
    return @swift_executable if @swift_executable

    configured = ENV['SWIFT_BIN'].to_s
    return @swift_executable = configured if !configured.empty? && File.executable?(configured)

    stdout, _stderr, status = Open3.capture3('/usr/bin/env', 'which', 'swift')
    abort 'swift executable not found; Setapp icon validation requires Swift/AppKit on the Mini' unless status.success?

    @swift_executable = stdout.strip
  end

  def validate_archive_icon!(icon_path)
    output, icon_stderr, icon_status = capture3_with_timeout(
      30,
      '/usr/bin/sips',
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      icon_path
    )
    abort "Setapp archive AppIcon.icns could not be inspected: #{icon_stderr.strip}" unless icon_status.success?

    width = output[/pixelWidth:\s*(\d+)/, 1].to_i
    height = output[/pixelHeight:\s*(\d+)/, 1].to_i
    unless width >= 512 && height >= 512
      abort "Setapp archive AppIcon.icns is #{width}x#{height}; Setapp requires at least 512x512"
    end

    validate_setapp_icon_geometry!(icon_path, label: 'Setapp archive AppIcon.icns', rendered: true)
  end

  def bundle_executable_path(bundle_path)
    plist_path = File.join(bundle_path, 'Contents', 'Info.plist')
    output, stderr, status = capture3_with_timeout(
      10,
      '/usr/libexec/PlistBuddy',
      '-c',
      'Print :CFBundleExecutable',
      plist_path
    )
    abort "Setapp archive missing CFBundleExecutable in #{File.basename(bundle_path)}: #{stderr.strip}" unless status.success?

    executable_path = File.join(bundle_path, 'Contents', 'MacOS', output.strip)
    abort "Setapp archive missing executable: #{executable_path}" unless File.file?(executable_path)

    executable_path
  end

  def validate_executable_architectures!(executable_path, label)
    output, stderr, status = capture3_with_timeout(10, '/usr/bin/lipo', '-archs', executable_path)
    abort "#{label} architectures could not be inspected: #{stderr.strip}" unless status.success?

    archs = output.split
    missing = []
    missing << 'arm64' unless archs.any? { |arch| arch.start_with?('arm64') }
    missing << 'x86_64' unless archs.include?('x86_64')
    return if missing.empty?

    abort "#{label} must include arm64 and x86_64 for Setapp review; missing #{missing.join(', ')} (found: #{archs.join(', ')})"
  end

  def validate_supported_architectures!(plist_path, label)
    output, _stderr, status = capture3_with_timeout(
      10,
      '/usr/libexec/PlistBuddy',
      '-c',
      'Print :MPSupportedArchitectures',
      plist_path
    )
    abort "#{label} is missing from Info.plist" unless status.success?

    archs = output.scan(/\b(?:arm64|x86_64)\b/)
    missing = %w[arm64 x86_64] - archs
    return if missing.empty?

    abort "#{label} must include arm64 and x86_64; missing #{missing.join(', ')}"
  end

  def validate_required_info_plist_keys!(plist_path, label)
    REQUIRED_INFO_PLIST_KEYS.each do |key|
      value = plist_value(plist_path, key, label)
      abort "#{label} #{key} is empty" if value.to_s.strip.empty?
    end
  end

  def validate_setapp_update_security_policy!(plist_path, label)
    output, stderr, status = capture3_with_timeout(
      10,
      '/usr/libexec/PlistBuddy',
      '-c',
      'Print :NSUpdateSecurityPolicy:AllowProcesses:MEHY5QF425',
      plist_path
    )
    abort "#{label} missing Setapp NSUpdateSecurityPolicy AllowProcesses: #{stderr.strip}" unless status.success?
    return if output.include?(SETAPP_AGENT_PROCESS)

    abort "#{label} NSUpdateSecurityPolicy must authorize #{SETAPP_AGENT_PROCESS}"
  end

  def validate_signature!(bundle_path, label)
    _output, stderr, status = capture3_with_timeout(
      30,
      '/usr/bin/codesign',
      '--verify',
      '--deep',
      '--strict',
      '--verbose=2',
      bundle_path
    )
    abort "#{label} signature verification failed: #{stderr.strip}" unless status.success?
  end

  def validate_developer_id_signature!(bundle_path, label)
    output, stderr, status = capture3_with_timeout(
      20,
      '/usr/bin/codesign',
      '-dv',
      '--verbose=4',
      bundle_path
    )
    abort "#{label} signature details could not be inspected: #{stderr.strip}" unless status.success?

    details = [output, stderr].join("\n")
    return if details.match?(/^Authority=Developer ID Application:/)

    abort "#{label} must be signed with Developer ID Application authority for Setapp upload"
  end

  def validate_gatekeeper_acceptance!(bundle_path, label)
    _output, stderr, status = capture3_with_timeout(
      60,
      '/usr/sbin/spctl',
      '--assess',
      '--type',
      'execute',
      '--verbose=4',
      bundle_path
    )
    abort "#{label} Gatekeeper assessment failed; archive is not proven notarized: #{stderr.strip}" unless status.success?

    _stapler_output, stapler_stderr, stapler_status = capture3_with_timeout(
      60,
      '/usr/bin/xcrun',
      'stapler',
      'validate',
      bundle_path
    )
    abort "#{label} stapled notarization ticket validation failed: #{stapler_stderr.strip}" unless stapler_status.success?
  end

  def gatekeeper_validation_required?
    ENV['SETAPP_UPLOAD_SKIP_GATEKEEPER_FOR_TESTS'] != '1'
  end

  def validate_forbidden_setapp_payload_strings!(app_path)
    Find.find(app_path) do |path|
      next unless File.file?(path)
      next if File.size(path).zero?
      next if File.size(path) > 25 * 1024 * 1024
      next unless setapp_payload_scan_candidate?(path)

      output, _stderr, status = capture3_with_timeout(10, '/usr/bin/strings', '-a', path)
      next unless status.success?

      relative = relative_extract_path(File.dirname(app_path), path)

      FORBIDDEN_SETAPP_PAYLOAD_PATTERNS.each do |pattern, reason|
        next unless output.match?(pattern)

        abort "Setapp archive contains forbidden direct-channel residue (#{reason}) in #{relative}"
      end

      INERT_WEAK_LINK_PAYLOAD_PATTERNS.each do |pattern, reason|
        next unless output.match?(pattern)

        unless macho_file?(path)
          abort "Setapp archive contains forbidden direct-channel residue (#{reason}) in #{relative} (non-binary file — configuration, not linker fallout)"
        end
        unless sparkle_linkage_weak_only?(path)
          abort "Setapp archive contains forbidden direct-channel residue (#{reason}) in #{relative} (Sparkle is strongly linked — a stripped framework would crash at launch)"
        end

        warn "note: inert direct-channel residue tolerated in #{relative} (#{reason}): Sparkle payload absent, load commands weak-only"
        break # inertness proven once per file; no need to re-check per pattern
      end

      INERT_UNREACHABLE_LICENSE_PAYLOAD_PATTERNS.each do |pattern, reason|
        next unless output.match?(pattern)

        unless macho_file?(path)
          abort "Setapp archive contains forbidden direct-channel residue (#{reason}) in #{relative} (non-binary file — configuration, not linker fallout)"
        end

        warn "note: inert direct-channel residue tolerated in #{relative} (#{reason}): unreachable per SaneUI SaneLicenseServiceSetappGateTests"
        break # inertness proven once per file; no need to re-check per pattern
      end
    end
  end

  # True when every Sparkle load command in the Mach-O is a weak link
  # (LC_LOAD_WEAK_DYLIB). A binary with no Sparkle load commands also passes.
  def sparkle_linkage_weak_only?(macho_path)
    output, _stderr, status = capture3_with_timeout(15, '/usr/bin/otool', '-l', macho_path)
    return false unless status.success?

    self.class.sparkle_linkage_weak_only_from_otool?(output)
  end

  # Pure parser, class-level so tests can exercise it without a real binary.
  def self.sparkle_linkage_weak_only_from_otool?(otool_output)
    current_cmd = nil
    otool_output.each_line do |line|
      if (match = line.match(/^\s*cmd\s+(LC_\w+)/))
        current_cmd = match[1]
        next
      end

      next unless line.match?(/^\s*name\s+.*Sparkle\.framework/i)
      return false unless current_cmd == 'LC_LOAD_WEAK_DYLIB'
    end

    true
  end

  def setapp_payload_scan_candidate?(path)
    ext = File.extname(path).downcase
    return false if %w[.png .jpg .jpeg .gif .icns .car .swiftmodule .swiftdoc .swiftsourceinfo .abi].include?(ext)

    true
  end

  def macho_file?(path)
    magic = File.open(path, 'rb') { |file| file.read(4) }.to_s
    [
      "\xFE\xED\xFA\xCE".b,
      "\xCE\xFA\xED\xFE".b,
      "\xFE\xED\xFA\xCF".b,
      "\xCF\xFA\xED\xFE".b,
      "\xCA\xFE\xBA\xBE".b,
      "\xBE\xBA\xFE\xCA".b
    ].include?(magic)
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def validate_embedded_profile!(bundle_path, label)
    entitlements = signed_entitlements(bundle_path, label)
    return unless profile_required?(entitlements)

    profile_path = File.join(bundle_path, 'Contents', 'embedded.provisionprofile')
    abort "#{label} signs restricted entitlements but is missing Contents/embedded.provisionprofile" unless File.file?(profile_path)

    profile = decode_profile(profile_path, label)
    profile_entitlements = profile.fetch('Entitlements', {})
    bundle_id = plist_value(File.join(bundle_path, 'Contents', 'Info.plist'), 'CFBundleIdentifier', label)

    abort "#{label} embedded provisioning profile does not match #{bundle_id}" unless profile_bundle_id_matches?(profile_entitlements, bundle_id)
    unless profile_covers_restricted_entitlements?(profile_entitlements, entitlements)
      abort "#{label} embedded provisioning profile does not cover signed restricted entitlements"
    end
  end

  def signed_entitlements(bundle_path, label)
    output, stderr, status = capture3_with_timeout(
      20,
      '/usr/bin/codesign',
      '-d',
      '--entitlements',
      ':-',
      bundle_path
    )
    abort "#{label} entitlements could not be inspected: #{stderr.strip}" unless status.success?

    return {} if output.strip.empty?

    parse_plist_string(output)
  end

  def profile_required?(entitlements)
    PROFILE_REQUIRED_ENTITLEMENTS.any? { |key| entitlement_present?(entitlements[key]) }
  end

  def entitlement_present?(value)
    case value
    when Array then !value.empty?
    when Hash then !value.empty?
    when String then !value.empty?
    else !value.nil? && value != false
    end
  end

  def decode_profile(profile_path, label)
    output, stderr, status = capture3_with_timeout(20, '/usr/bin/security', 'cms', '-D', '-i', profile_path)
    abort "#{label} embedded provisioning profile could not be decoded: #{stderr.strip}" unless status.success?

    parse_plist_string(output)
  end

  def profile_bundle_id_matches?(profile_entitlements, bundle_id)
    identifier = profile_entitlements['com.apple.application-identifier'].to_s
    team_id, profile_bundle_id = identifier.split('.', 2)
    return false if team_id.to_s.empty? || profile_bundle_id.to_s.empty? || bundle_id.to_s.empty?

    profile_team_id = profile_entitlements['com.apple.developer.team-identifier'].to_s
    return false unless profile_team_id.empty? || profile_team_id == team_id

    if profile_bundle_id.end_with?('.*')
      wildcard_prefix = profile_bundle_id.delete_suffix('.*')
      return bundle_id == wildcard_prefix || bundle_id.start_with?("#{wildcard_prefix}.")
    end

    profile_bundle_id == bundle_id
  end

  def profile_covers_icloud?(profile_entitlements, signed_entitlements)
    required = Array(signed_entitlements['com.apple.developer.icloud-container-identifiers']).reject(&:empty?)
    return true if required.empty?

    available = Array(profile_entitlements['com.apple.developer.icloud-container-identifiers'])
    (required - available).empty?
  end

  def profile_covers_restricted_entitlements?(profile_entitlements, signed_entitlements)
    profile_covers_icloud?(profile_entitlements, signed_entitlements) &&
      profile_covers_icloud_services?(profile_entitlements, signed_entitlements) &&
      profile_covers_array_entitlement?(profile_entitlements, signed_entitlements, 'com.apple.security.application-groups') &&
      profile_covers_array_entitlement?(profile_entitlements, signed_entitlements, 'keychain-access-groups')
  end

  def profile_covers_icloud_services?(profile_entitlements, signed_entitlements)
    required = Array(signed_entitlements['com.apple.developer.icloud-services']).reject(&:empty?)
    return true if required.empty?

    available = Array(profile_entitlements['com.apple.developer.icloud-services']).reject(&:empty?)
    return true if available.include?('*')

    (required - available).empty?
  end

  def profile_covers_array_entitlement?(profile_entitlements, signed_entitlements, key)
    required = Array(signed_entitlements[key]).reject(&:empty?)
    return true if required.empty?

    available = Array(profile_entitlements[key]).reject(&:empty?)
    team_id = profile_entitlements['com.apple.developer.team-identifier'].to_s
    required.all? do |value|
      available.any? do |candidate|
        candidate == value ||
          (candidate.end_with?('*') && value.start_with?(candidate.delete_suffix('*'))) ||
          team_wildcard_covers_app_group?(key, candidate, value, team_id)
      end
    end
  end

  def team_wildcard_covers_app_group?(key, candidate, value, team_id)
    key == 'com.apple.security.application-groups' &&
      !team_id.empty? &&
      candidate == "#{team_id}.*" &&
      value.start_with?('group.')
  end

  def plist_value(plist_path, key, label)
    output, stderr, status = capture3_with_timeout(
      10,
      '/usr/libexec/PlistBuddy',
      '-c',
      "Print :#{key}",
      plist_path
    )
    abort "#{label} missing #{key}: #{stderr.strip}" unless status.success?

    output.strip
  end

  def parse_plist_string(source)
    Tempfile.create(['setapp-plist', '.plist']) do |file|
      file.write(source)
      file.flush
      output, stderr, status = capture3_with_timeout(10, '/usr/bin/plutil', '-convert', 'xml1', '-o', '-', file.path)
      abort "Setapp archive plist data could not be parsed: #{stderr.strip}" unless status.success?

      parse_plist_xml(output)
    end
  end

  def parse_plist_xml(source)
    doc = REXML::Document.new(source)
    root = doc.elements['plist']
    abort 'Setapp archive plist data could not be parsed: missing plist root' unless root

    first_element = root.elements.to_a.first
    abort 'Setapp archive plist data could not be parsed: empty plist' unless first_element

    parse_plist_node(first_element)
  end

  def parse_plist_node(node)
    case node.name
    when 'dict'
      values = {}
      children = node.elements.to_a
      children.each_slice(2) do |key_node, value_node|
        next unless key_node&.name == 'key' && value_node

        values[key_node.text.to_s] = parse_plist_node(value_node)
      end
      values
    when 'array'
      node.elements.to_a.map { |child| parse_plist_node(child) }
    when 'string', 'date', 'data'
      node.text.to_s.strip
    when 'integer'
      node.text.to_i
    when 'real'
      node.text.to_f
    when 'true'
      true
    when 'false'
      false
    else
      node.text.to_s
    end
  end

  def validate_portal_target_matches_archive!
    target = portal_target_for_app_id(@options[:app_id].to_s)
    unless target
      abort "Unknown Setapp app id #{@options[:app_id]}; add its app name and bundle id before using portal fallback"
    end

    if @options[:version_id].to_s != target[:version_id]
      abort "Setapp portal app #{@options[:app_id]} expects version id #{target[:version_id]}, but received #{@options[:version_id]}"
    end
    if @archive_metadata[:app_name] != target[:app_name]
      abort "Setapp portal app #{@options[:app_id]} expects #{target[:app_name]}, but archive contains #{@archive_metadata[:app_name]}"
    end
    return if @archive_metadata[:bundle_id] == target[:bundle_id]

    abort "Setapp portal app #{@options[:app_id]} expects bundle id #{target[:bundle_id]}, but archive contains #{@archive_metadata[:bundle_id]}"
  end

  def enforce_manifest_policies!
    target = manifest_target_for_archive
    return unless target

    if target[:require_manual_release_confirmation] && @options[:release_on_approval]
      abort "Setapp manifest requires manual release confirmation for #{target[:app_name]}; --release-on-approval true is prohibited"
    end

    unless target[:release_notes_public]
      abort "Setapp manifest must declare release_notes_public: true for #{target[:app_name]} so public release notes are treated as customer-facing copy"
    end

    if target[:review_comments_private] &&
       !@options[:validate_only] &&
       @options[:status] == 'review' &&
       @options[:review_comments].to_s.strip.empty? &&
       !@options[:no_review_comments_needed]
      abort "Setapp private review comments must be supplied with --review-comments-file, or explicitly skipped with --no-review-comments-needed for #{target[:app_name]}"
    end

    SetappConfig.validate_listing_screenshots!(target)
  end

  def manifest_target_for_archive
    SetappConfig.portal_targets.values.find { |target| target[:bundle_id] == @archive_metadata[:bundle_id] }
  end

  def portal_target_for_app_id(app_id)
    SetappConfig.portal_targets[app_id.to_s]
  end

  def enforce_mini_host!
    return if ENV['SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT'] == '1'
    return if running_on_mini_host?

    abort 'Setapp upload is Mini-first. Run through ./scripts/SaneMaster.rb setapp_upload, or set SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT=1 only for a documented local test.'
  end

  def running_on_mini_host?
    host = `hostname -s 2>/dev/null`.strip.downcase
    user = ENV['USER'].to_s
    host.include?('mini') || user == 'stephansmac'
  end

  def validate_upload_response_matches_archive!(data)
    if data['version'].to_s != @archive_metadata[:version].to_s
      abort "Setapp upload response version #{data['version']} does not match archive build #{@archive_metadata[:version]}"
    end
    return if data['ui_version'].to_s == @archive_metadata[:ui_version].to_s

    abort "Setapp upload response display version #{data['ui_version']} does not match archive version #{@archive_metadata[:ui_version]}"
  end

  def validate_upload_proof_data!(data, context:)
    required = %w[version ui_version archive_url]
    missing = required.select { |key| data[key].to_s.empty? }
    unless missing.empty?
      abort "#{context} accepted the archive but did not return proof fields: #{missing.join(', ')}. Treating upload as unproven; verify with setapp_status and hosted archive byte-match before claiming success."
    end

    validate_upload_response_matches_archive!(data)
    true
  end

  def dry_run
    payload = {
      mode: @options[:portal_fallback] ? 'portal_fallback' : 'ci',
      zip: File.expand_path(@options[:zip]),
      endpoint: @options[:portal_fallback] ? PORTAL_UPLOAD_ENDPOINT : CI_ENDPOINT,
      archive: @archive_metadata,
      app_id: @options[:app_id],
      version_id: @options[:version_id],
      status: @options[:status],
      beta: @options[:beta],
      release_on_approval: @options[:release_on_approval],
      allow_overwrite: @options[:allow_overwrite],
      allow_needs_revision: @options[:allow_needs_revision]
    }

    return puts(JSON.pretty_generate(payload)) if @options[:json]

    puts 'Setapp upload dry run'
    payload.each { |key, value| puts "  #{key}: #{value}" unless value.nil? || value.to_s.empty? }
  end

  def validate_only
    payload = {
      ok: true,
      zip: File.expand_path(@options[:zip]),
      archive: @archive_metadata,
      root_icon_geometry: @root_icon_geometry,
      checks: [
        'top-level .app bundle',
        'sibling root app icon PNG is 1024x1024 with the Setapp 824px frame, 100px margins, and curved corners',
        'AppIcon.icns is 512px or larger and follows the same Setapp frame/corner geometry',
        'MPSupportedArchitectures includes arm64 and x86_64',
        'main executable includes arm64 and x86_64',
        'extension executables include arm64 and x86_64',
        'app and extensions have valid signatures',
        'app and extensions are Developer ID signed',
        'app has accepted Gatekeeper/notarization proof',
        'restricted-entitlement bundles embed matching provisioning profiles'
      ]
    }

    return puts(JSON.pretty_generate(payload)) if @options[:json]

    puts "Setapp archive validation passed: #{File.expand_path(@options[:zip])}"
    puts "  app: #{@archive_metadata[:app_name]} #{@archive_metadata[:ui_version]} (#{@archive_metadata[:version]})"
    puts "  bundle id: #{@archive_metadata[:bundle_id]}"
    puts "  root icon: #{@root_icon_geometry}"
  end

  def run_ci_upload
    token = ENV['SETAPP_AUTOMATION_TOKEN'].to_s
    abort 'Missing SETAPP_AUTOMATION_TOKEN for official Setapp CI upload' if token.empty?

    form_args = [
      ['--form', "archive=@#{File.expand_path(@options[:zip])};type=application/zip"],
      ['--form-string', "release_notes=#{@options[:release_notes]}"],
      ['--form-string', "status=#{@options[:status]}"],
      ['--form-string', "beta=#{@options[:beta]}"],
      ['--form-string', "release_on_approval=#{@options[:release_on_approval]}"],
      ['--form-string', "allow_overwrite=#{@options[:allow_overwrite]}"]
    ]
    form_args << ['--form-string', "vendor_comment=#{@options[:review_comments]}"] unless @options[:review_comments].to_s.strip.empty?

    response = curl_form(
      CI_ENDPOINT,
      "Bearer #{token}",
      form_args
    )
    fail_unless_success!(response, expected: [200, 202, 204])

    data = response.dig(:json, 'data') || {}
    if data.empty?
      return print_unverified_ci_result(response)
    end

    validate_upload_proof_data!(data, context: 'Setapp CI upload')
    verify_uploaded_archive_matches!(response[:json])
    print_result('Setapp CI upload accepted and hosted archive verified', response[:json])
  end

  def run_portal_fallback
    token = portal_token
    abort 'Missing Setapp portal token. Log into developer.setapp.com in Safari on this machine, or set SETAPP_PORTAL_TOKEN.' if token.empty?

    upload_response = curl_form(
      PORTAL_UPLOAD_ENDPOINT,
      "Token #{token}",
      [
        ['--form-string', "application_id=#{@options[:app_id]}"],
        ['--form', "archive=@#{File.expand_path(@options[:zip])};type=application/zip"]
      ]
    )
    fail_unless_success!(upload_response, expected: [200])

    data = upload_response.dig(:json, 'data') || {}
    required = %w[archive_tmp_name icon_url version ui_version]
    missing = required.select { |key| data[key].to_s.empty? }
    abort "Setapp upload response missing: #{missing.join(', ')}" unless missing.empty?
    validate_upload_response_matches_archive!(data)

    patch_payload = {
      archive_tmp_name: data.fetch('archive_tmp_name'),
      icon_url: data.fetch('icon_url'),
      version: data.fetch('version'),
      ui_version: data.fetch('ui_version'),
      release_notes: @options[:release_notes]
    }
    patch_payload[:vendor_comment] = @options[:review_comments] unless @options[:review_comments].to_s.strip.empty?
    patch_response = curl_json(
      "#{API_BASE}/versions/#{@options[:version_id]}",
      "Token #{token}",
      patch_payload
    )
    fail_unless_success!(patch_response, expected: [200])

    status_response = curl_get("#{API_BASE}/versions/#{@options[:version_id]}", "Token #{token}")
    fail_unless_success!(status_response, expected: [200])
    enforce_portal_review_state!(status_response[:json])
    verify_uploaded_archive_matches!(status_response[:json])
    print_portal_result(patch_response[:json], status_response[:json])
  end

  def verify_uploaded_archive_matches!(payload)
    data = payload.is_a?(Hash) ? payload['data'] : nil
    archive_url = data.is_a?(Hash) ? data['archive_url'].to_s : ''
    abort 'Setapp version status did not include archive_url for hosted archive verification' if archive_url.empty?
    validate_setapp_archive_url!(archive_url)

    local_sha = sha256(File.expand_path(@options[:zip]))
    current_url = archive_url
    Tempfile.create(['setapp-hosted-archive', '.zip']) do |download|
      response = nil
      5.times do
        validate_setapp_archive_url!(current_url)
        response = curl_download(current_url, download.path)
        break unless response[:status].between?(300, 399) && !response[:location].to_s.empty?

        current_url = trusted_redirect_url!(current_url, response[:location])
      end
      unless response && response[:ok] && response[:status] == 200
        detail = response ? response[:stderr].to_s.strip : 'redirect limit exceeded'
        status = response ? response[:status] : 0
        abort "Setapp hosted archive could not be downloaded for byte-match proof (HTTP #{status}): #{detail}"
      end
      hosted_sha = sha256(download.path)
      abort "Setapp hosted archive SHA mismatch: local #{local_sha}, hosted #{hosted_sha}" unless hosted_sha == local_sha

      @uploaded_archive_sha256 = hosted_sha
    end
  end

  def portal_token
    env_token = ENV['SETAPP_PORTAL_TOKEN'].to_s
    return env_token unless env_token.empty?
    return '' unless @options[:safari_token]

    script = <<~APPLESCRIPT
      tell application "Safari"
        if not running then return "{\\"error\\":\\"Safari is not running\\"}"
        if (count of documents) is 0 then return "{\\"error\\":\\"Safari has no open document\\"}"
        return do JavaScript "JSON.stringify({host: location.hostname, token: decodeURIComponent((document.cookie.split('; ').find(c=>c.startsWith('access_token='))||'=').split('=')[1]||'')})" in front document
      end tell
    APPLESCRIPT
    output, stderr, status = capture3_with_timeout(10, '/usr/bin/osascript', stdin_data: script)
    unless status.success?
      abort "Could not read Setapp portal token from Safari via AppleScript: #{stderr.strip}"
    end

    data = JSON.parse(output)
    abort 'Safari is not running or has no open Setapp developer page' if data['error']
    unless data['host'].to_s == 'developer.setapp.com'
      abort "Safari front tab must be developer.setapp.com for portal fallback; current host is #{data['host']}"
    end

    token = data['token'].to_s
    abort 'Setapp portal token was empty; refresh developer.setapp.com in Safari and retry' if token.empty?

    token
  rescue JSON::ParserError => e
    abort "Could not parse Setapp portal token response from Safari: #{e.message}"
  end

  def curl_form(url, authorization, form_args)
    with_curl_config(url, authorization, extra_args: form_args.flatten)
  end

  def curl_json(url, authorization, payload)
    Tempfile.create(['setapp-upload-payload', '.json']) do |payload_file|
      payload_file.write(JSON.generate(payload))
      payload_file.flush
      with_curl_config(url, authorization, method: 'PATCH', json: true, extra_args: ['--data-binary', "@#{payload_file.path}"])
    end
  end

  def curl_get(url, authorization)
    with_curl_config(url, authorization, method: 'GET')
  end

  def curl_download(url, output_path)
    Tempfile.create('setapp-download-curl') do |config|
      config.chmod(0o600)
      config.puts 'silent'
      config.puts 'show-error'
      config.puts 'proto = "=https"'
      config.puts 'request = "GET"'
      config.puts %(url = "#{curl_config_quote(url)}")
      config.flush

      headers = Tempfile.new('setapp-download-headers')
      _stdout, stderr, status = capture3_with_timeout(
        1_800,
        'curl',
        '--config',
        config.path,
        '-D',
        headers.path,
        '-o',
        output_path
      )
      {
        ok: status.success?,
        status: parse_http_status(File.read(headers.path)),
        location: parse_http_location(File.read(headers.path)),
        stderr: stderr
      }
    ensure
      headers&.close!
    end
  end

  def trusted_redirect_url!(current_url, location)
    next_url = URI.join(current_url, location.to_s).to_s
    validate_setapp_archive_url!(next_url)
    next_url
  rescue URI::InvalidURIError => e
    abort "Setapp hosted archive redirect URL is invalid before authorization: #{e.message}"
  end

  def validate_setapp_archive_url!(archive_url)
    uri = URI.parse(archive_url.to_s)
    unless uri.is_a?(URI::HTTPS)
      abort "Setapp hosted archive URL must use HTTPS before sending portal authorization: #{archive_url}"
    end

    host = uri.host.to_s.downcase
    trusted = TRUSTED_ARCHIVE_HOSTS.include?(host)
    return true if trusted

    abort "Setapp hosted archive URL is not on a trusted Setapp/MacPaw HTTPS host: #{host.empty? ? archive_url : host}"
  rescue URI::InvalidURIError => e
    abort "Setapp hosted archive URL is invalid before authorization: #{e.message}"
  end

  def with_curl_config(url, authorization, method: 'POST', json: false, extra_args: [])
    Tempfile.create('setapp-upload-curl') do |config|
      config.chmod(0o600)
      config.puts 'silent'
      config.puts 'show-error'
      config.puts %(request = "#{method}")
      config.puts %(url = "#{curl_config_quote(url)}")
      config.puts %(header = "Authorization: #{curl_config_quote(authorization)}")
      config.puts 'header = "Accept: application/json"'
      config.puts 'header = "Content-Type: application/json"' if json
      config.flush

      headers = Tempfile.new('setapp-upload-headers')
      body = Tempfile.new('setapp-upload-body')
      _stdout, stderr, status = capture3_with_timeout(
        1_800,
        'curl',
        '--config',
        config.path,
        '-D',
        headers.path,
        '-o',
        body.path,
        *extra_args
      )
      response = {
        ok: status.success?,
        status: parse_http_status(File.read(headers.path)),
        stderr: stderr,
        body: File.read(body.path)
      }
      response[:json] = JSON.parse(response[:body]) unless response[:body].to_s.strip.empty?
      response
    ensure
      headers&.close!
      body&.close!
    end
  end

  def capture3_with_timeout(timeout_seconds, *command, stdin_data: nil)
    stdin_file = nil
    Tempfile.create('setapp-upload-stdout') do |stdout_file|
      Tempfile.create('setapp-upload-stderr') do |stderr_file|
        spawn_options = { in: File::NULL, out: stdout_file.path, err: stderr_file.path }
        if stdin_data
          stdin_file = Tempfile.new('setapp-upload-stdin')
          stdin_file.write(stdin_data)
          stdin_file.flush
          spawn_options[:in] = stdin_file.path
        end

        pid = Process.spawn(*command, spawn_options)
        status = wait_for_pid(pid, timeout_seconds)

        stdout_file.rewind
        stderr_file.rewind
        [stdout_file.read, stderr_file.read, status]
      end
    end
  ensure
    stdin_file&.close!
  end

  def wait_for_pid(pid, timeout_seconds)
    deadline = Time.now + timeout_seconds
    loop do
      waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if waited_pid
      break if Time.now >= deadline

      sleep 0.1
    end

    terminate_child(pid)
    CommandStatus.new(124)
  end

  def terminate_child(pid)
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      return
    end

    20.times do
      waited_pid = waitpid_nohang(pid)
      return if waited_pid

      sleep 0.1
    end
    begin
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      return
    end
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def waitpid_nohang(pid)
    waited_pid, = Process.waitpid2(pid, Process::WNOHANG)
    waited_pid
  rescue Errno::ECHILD
    pid
  end

  def parse_http_status(headers)
    headers.scan(/^HTTP\/\S+\s+(\d{3})/).flatten.last.to_i
  end

  def parse_http_location(headers)
    block = headers.split(/\r?\n\r?\n/).reject(&:empty?).last.to_s
    block[/^Location:\s*(.+)$/i, 1].to_s.strip
  end

  def fail_unless_success!(response, expected:)
    return if response[:ok] && expected.include?(response[:status])

    detail = response.dig(:json, 'errors', 0, 'detail') ||
             response.dig(:json, 'errors', 0, 'title') ||
             response[:body].to_s.strip ||
             response[:stderr].to_s.strip
    abort "Setapp upload failed (HTTP #{response[:status]}): #{detail}"
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def print_result(label, payload)
    return puts(JSON.pretty_generate(redacted_payload(payload || {}))) if @options[:json]

    data = payload.is_a?(Hash) ? payload['data'] : nil
    puts "✅ #{label}"
    return unless data.is_a?(Hash)

    puts "  app version: #{data['version']}" if data['version']
    puts "  display version: #{data['ui_version']}" if data['ui_version']
    puts "  status: #{data['status']}" if data['status']
    puts "  archive: #{data['archive_url']}" if data['archive_url']
    puts "  hosted archive sha256: #{@uploaded_archive_sha256}" if @uploaded_archive_sha256
  end

  def print_unverified_ci_result(response)
    payload = {
      'data' => {
        'status' => response[:status],
        'accepted_without_proof' => true,
        'proof_required' => 'Run setapp_status and hosted archive byte-match verification before claiming Setapp release success.'
      }
    }
    print_result('Setapp CI upload accepted without hosted archive proof', payload)
  end

  def print_portal_result(patch_payload, status_payload)
    if @options[:json]
      return puts(JSON.pretty_generate(redacted_payload({ upload: patch_payload || {}, version_status: status_payload || {} })))
    end

    print_result('Setapp portal fallback attached archive', patch_payload)
    data = status_payload.is_a?(Hash) ? status_payload['data'] : nil
    return unless data.is_a?(Hash)

    code = data['status'].to_i
    puts "  post-attach review status: #{status_label(code)} (#{code})"
    return unless action_required_status?(code)

    puts "  action required: #{portal_action_message(code)}"
  end

  def enforce_portal_review_state!(payload)
    data = payload.is_a?(Hash) ? payload['data'] : nil
    status_code = data.is_a?(Hash) ? data['status'].to_i : 0
    return unless action_required_status?(status_code)
    return if status_code == 2 && @options[:allow_needs_revision]

    abort "Setapp archive was attached, but the version is still #{status_label(status_code)}. The build is NOT complete; #{portal_action_message(status_code)}"
  end

  def status_label(code)
    STATUS_LABELS.fetch(code, "Status #{code}")
  end

  def action_required_status?(code)
    !NON_ACTION_STATUSES.include?(code.to_i)
  end

  def portal_action_message(code)
    case code.to_i
    when 2
      'click Submit for review in developer.setapp.com, then rerun setapp_status.'
    when 9
      'manually release the approved version in developer.setapp.com, then rerun setapp_status.'
    else
      'complete the required portal action in developer.setapp.com, then rerun setapp_status.'
    end
  end

  def redacted_payload(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), result|
        result[key] = private_comment_key?(key) ? '[redacted]' : redacted_payload(child)
      end
    when Array
      value.map { |child| redacted_payload(child) }
    else
      value
    end
  end

  def private_comment_key?(key)
    normalized = key.to_s.downcase
    PRIVATE_COMMENT_KEYS.include?(normalized) || normalized.match?(/(?:reviewer|vendor|review|decline|rejection).*comment|(?:decline|rejection)_reason/)
  end

  def parse_bool(value)
    case value.to_s.downcase
    when '1', 'true', 'yes' then true
    when '0', 'false', 'no' then false
    else
      abort "Invalid boolean: #{value}"
    end
  end

  def curl_config_quote(value)
    text = value.to_s
    abort 'Refusing to write control characters into curl config' if text.match?(/[\x00-\x1F\x7F]/)

    text.gsub('\\', '\\\\').gsub('"', '\"')
  end
end

SetappUpload.new(ARGV).run if __FILE__ == $PROGRAM_NAME
