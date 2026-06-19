#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rexml/document'
require 'shellwords'
require 'tempfile'
require 'tmpdir'
require 'time'

class SetappPackage
  ICONSET_REPRESENTATIONS = [
    ['icon_16x16.png', 16],
    ['icon_16x16@2x.png', 32],
    ['icon_32x32.png', 32],
    ['icon_32x32@2x.png', 64],
    ['icon_128x128.png', 128],
    ['icon_128x128@2x.png', 256],
    ['icon_256x256.png', 256],
    ['icon_256x256@2x.png', 512],
    ['icon_512x512.png', 512],
    ['icon_512x512@2x.png', 1024]
  ].freeze

  def initialize(argv)
    @options = {
      project: Dir.pwd,
      configuration: 'Release-Setapp',
      signing_identity: 'Developer ID Application',
      notary_profile: 'notarytool',
      output_root: File.expand_path('~/SaneApps/outputs/setapp_review')
    }
    parse!(argv)
  end

  def run
    enforce_mini_host!
    load_cached_env
    @project = File.expand_path(@options[:project])
    abort "Project directory not found: #{@project}" unless File.directory?(@project)

    @app_name = @options[:app_name] || infer_app_name
    @scheme = @options[:scheme] || "#{@app_name}Setapp"
    @version = @options[:version] || infer_version
    @stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    @output_dir = File.join(
      File.expand_path(@options[:output_root]),
      "#{@stamp}-#{@app_name.downcase}-#{@version}-setapp"
    )
    @archive_path = File.join(@output_dir, "#{@scheme}.xcarchive")
    @app_path = File.join(@archive_path, 'Products', 'Applications', "#{@app_name}.app")
    @notary_zip = File.join(@output_dir, "#{@app_name}-Setapp-#{@version}-notary.zip")
    @final_zip = File.join(@output_dir, "#{@app_name}-Setapp-#{@version}.zip")

    FileUtils.mkdir_p(@output_dir)

    generate_project
    archive_unsigned
    sanitize
    normalize_app_icon
    write_root_icon_png
    prepare_signing_session
    embed_provisioning_profiles
    sign_nested_extensions
    sign_app
    write_receipts
    verify_signature
    notarize
    staple
    package_final_zip
    validate_final_zip
    verify_quarantined_launch

    puts "Setapp package ready: #{@final_zip}"
  end

  private

  def enforce_mini_host!
    return if ENV['SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT'] == '1'
    return if running_on_mini_host?

    abort 'Setapp packaging is Mini-first. Run through ./scripts/SaneMaster.rb setapp_package, or set SANEPROCESS_ALLOW_LOCAL_SETAPP_SCRIPT=1 only for a documented local test.'
  end

  def running_on_mini_host?
    host = `hostname -s 2>/dev/null`.strip.downcase
    user = ENV['USER'].to_s
    host.include?('mini') || user == 'stephansmac'
  end

  def parse!(argv)
    OptionParser.new do |opts|
      opts.banner = 'Usage: setapp_package [--project PATH] [--app-name NAME] [--scheme NAME] [--version X.Y.Z]'
      opts.on('--project PATH', 'Project root (default: current directory)') { |value| @options[:project] = value }
      opts.on('--app-name NAME', 'App name, for example SaneClip') { |value| @options[:app_name] = value }
      opts.on('--scheme NAME', 'Setapp archive scheme') { |value| @options[:scheme] = value }
      opts.on('--configuration NAME', 'Archive configuration') { |value| @options[:configuration] = value }
      opts.on('--version X.Y.Z', 'Version string for output naming') { |value| @options[:version] = value }
      opts.on('--output-root PATH', 'Output root for receipts and zips') { |value| @options[:output_root] = value }
      opts.on('--signing-identity NAME', 'Developer ID signing identity') { |value| @options[:signing_identity] = value }
      opts.on('--notary-profile NAME', 'notarytool keychain profile') { |value| @options[:notary_profile] = value }
      opts.on('-h', '--help', 'Show help') do
        puts opts
        exit 0
      end
    end.parse!(argv)
  end

  def infer_app_name
    if (project = Dir.glob(File.join(@project, '*.xcodeproj')).first)
      return File.basename(project, '.xcodeproj')
    end

    File.basename(@project)
  end

  def infer_version
    project_yml = File.join(@project, 'project.yml')
    if File.file?(project_yml)
      source = File.read(project_yml)
      return Regexp.last_match(1) if source =~ /MARKETING_VERSION:\s*"?([^"\n]+)"?/
    end

    'unknown'
  end

  def generate_project
    return unless File.file?(File.join(@project, 'project.yml'))

    run_logged('xcodegen.log', 'xcodegen', 'generate')
  end

  def archive_unsigned
    project_file = File.join(@project, "#{@app_name}.xcodeproj")
    abort "Xcode project not found: #{project_file}" unless File.directory?(project_file)

    run_logged(
      'archive.log',
      'xcodebuild',
      '-project',
      project_file,
      '-scheme',
      @scheme,
      '-configuration',
      @options[:configuration],
      '-archivePath',
      @archive_path,
      'clean',
      'archive',
      'CODE_SIGNING_ALLOWED=NO'
    )
    abort "Archive did not produce #{@app_path}" unless File.directory?(@app_path)
  end

  def sanitize
    script = File.expand_path('sanitize_distribution_bundle.rb', __dir__)
    run_logged('sanitize.log', 'ruby', script, '--channel', 'setapp', @app_path)
  end

  def normalize_app_icon
    source = setapp_icon_source_png

    resource_dir = File.join(@app_path, 'Contents', 'Resources')
    target_icon = File.join(resource_dir, 'AppIcon.icns')
    FileUtils.mkdir_p(resource_dir)

    Dir.mktmpdir('setapp-appicon') do |dir|
      iconset_dir = File.join(dir, 'AppIcon.iconset')
      FileUtils.mkdir_p(iconset_dir)
      ICONSET_REPRESENTATIONS.each do |filename, size|
        render_setapp_icon(
          source,
          File.join(iconset_dir, filename),
          size,
          "appicon-render-#{filename.tr('@', '-')}.log"
        )
      end

      run_logged('appicon-normalize.log', 'iconutil', '-c', 'icns', iconset_dir, '-o', target_icon)
    end
  end

  def write_root_icon_png
    render_setapp_icon(setapp_icon_source_png, root_icon_png_path, 1024, 'root-icon-render.log')
    validate_setapp_icon_geometry(root_icon_png_path, 'root-icon-validate.log')
  end

  def setapp_icon_source_png
    @setapp_icon_source_png ||= begin
      source = largest_app_icon_png
      abort 'No source AppIcon PNG found for Setapp icon generation' unless source

      width, height = png_dimensions(source)
      unless width >= 1024 && height >= 1024
        abort "Setapp source AppIcon #{source} is #{width}x#{height}; Setapp packaging requires a 1024x1024 source"
      end
      source
    end
  end

  def render_setapp_icon(source, output, size, log_name)
    run_logged(
      log_name,
      swift_executable,
      setapp_icon_tool_path,
      'render',
      '--source',
      source,
      '--output',
      output,
      '--size',
      size.to_s
    )
  end

  def validate_setapp_icon_geometry(path, log_name)
    run_logged(
      log_name,
      swift_executable,
      setapp_icon_tool_path,
      'validate',
      '--path',
      path,
      '--size',
      '1024'
    )
  end

  def setapp_icon_tool_path
    @setapp_icon_tool_path ||= File.expand_path('setapp_icon_tool.swift', __dir__)
  end

  def swift_executable
    return @swift_executable if @swift_executable

    configured = ENV['SWIFT_BIN'].to_s
    return @swift_executable = configured if !configured.empty? && File.executable?(configured)

    stdout, _stderr, status = Open3.capture3('/usr/bin/env', 'which', 'swift')
    abort 'swift executable not found; Setapp icon generation requires Swift/AppKit on the Mini' unless status.success?

    @swift_executable = stdout.strip
  end

  def largest_app_icon_png
    source_iconset = app_iconset_path
    return nil unless source_iconset

    paths = app_icon_manifest_pngs(source_iconset)
    paths = Dir.glob(File.join(source_iconset, '*.png')) if paths.empty?

    candidates = paths.map do |path|
      dimensions = png_dimensions(path)
      next unless dimensions

      [dimensions.first * dimensions.last, path]
    end.compact
    candidates.max_by(&:first)&.last
  end

  def app_icon_manifest_pngs(source_iconset)
    manifest = File.join(source_iconset, 'Contents.json')
    return [] unless File.file?(manifest)

    data = JSON.parse(File.read(manifest))
    Array(data['images']).map { |image| image['filename'].to_s }.reject(&:empty?).map do |filename|
      File.join(source_iconset, filename)
    end.select { |path| File.file?(path) }
  rescue JSON::ParserError
    []
  end

  def png_dimensions(path)
    output, _stderr, status = Open3.capture3(
      '/usr/bin/sips',
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      path
    )
    return nil unless status.success?

    [
      output[/pixelWidth:\s*(\d+)/, 1].to_i,
      output[/pixelHeight:\s*(\d+)/, 1].to_i
    ]
  end

  def root_icon_png_path
    @root_icon_png_path ||= File.join(@output_dir, "#{@app_name}.png")
  end

  def app_iconset_path
    candidates = [
      File.join(@project, 'Resources', 'Assets.xcassets', 'AppIcon.appiconset'),
      File.join(@project, 'Assets.xcassets', 'AppIcon.appiconset')
    ]
    candidates.find { |path| File.directory?(path) }
  end

  def sign_nested_extensions
    Dir.glob(File.join(@app_path, 'Contents', 'PlugIns', '*.appex')).each do |appex|
      args = sign_args(appex)
      entitlements = extension_entitlements(appex)
      args += ['--entitlements', entitlements] if entitlements
      run_logged("codesign-#{File.basename(appex)}.log", *args)
    end
  end

  def sign_app
    args = sign_args(@app_path)
    entitlements = main_entitlements
    args += ['--entitlements', entitlements] if entitlements
    run_logged('codesign-app.log', *args)
  end

  def sign_args(path)
    args = [
      'codesign',
      '--force',
      '--options',
      'runtime',
      '--timestamp',
      '--sign',
      @options[:signing_identity],
    ]
    args += ['--keychain', @codesign_keychain] if @codesign_keychain
    args << path
    args
  end

  def embed_provisioning_profiles
    embed_provisioning_profile(@app_path, main_entitlements, 'main app')
    Dir.glob(File.join(@app_path, 'Contents', 'PlugIns', '*.appex')).each do |appex|
      embed_provisioning_profile(appex, extension_entitlements(appex), File.basename(appex))
    end
  end

  def embed_provisioning_profile(bundle_path, entitlements_path, label)
    entitlements = entitlements_path ? plist_file(entitlements_path) : {}
    return unless provisioning_profile_required?(entitlements)

    bundle_id = plist_value(File.join(bundle_path, 'Contents', 'Info.plist'), 'CFBundleIdentifier')
    profile = best_provisioning_profile(bundle_id, entitlements)
    abort "No provisioning profile found for #{label} (#{bundle_id})" unless profile

    destination = File.join(bundle_path, 'Contents', 'embedded.provisionprofile')
    FileUtils.cp(profile[:path], destination)
    puts "Embedded provisioning profile for #{label}: #{profile[:name]} (#{profile[:uuid]})"
  end

  def provisioning_profile_required?(entitlements)
    restricted_keys = [
      'com.apple.developer.icloud-container-identifiers',
      'com.apple.developer.icloud-services',
      'com.apple.security.application-groups',
      'keychain-access-groups'
    ]
    restricted_keys.any? { |key| entitlement_present?(entitlements[key]) }
  end

  def entitlement_present?(value)
    case value
    when Array then !value.empty?
    when Hash then !value.empty?
    when String then !value.empty?
    else !value.nil? && value != false
    end
  end

  def best_provisioning_profile(bundle_id, entitlements)
    candidates = provisioning_profiles.select do |profile|
      profile_bundle_id_matches?(profile[:entitlements], bundle_id) &&
        profile_covers_restricted_entitlements?(profile[:entitlements], entitlements)
    end

    candidates.max_by { |profile| [profile[:score], profile[:expiration].to_i, profile[:creation].to_i] }
  end

  def provisioning_profiles
    @provisioning_profiles ||= begin
      roots = [
        File.join(@project, 'Provisioning', '*.{provisionprofile,mobileprovision}'),
        File.expand_path('~/Library/MobileDevice/Provisioning Profiles/*.{provisionprofile,mobileprovision}'),
        File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.{provisionprofile,mobileprovision}')
      ]
      roots.flat_map { |pattern| Dir.glob(pattern) }.map { |path| decode_profile(path) }.compact
    end
  end

  def decode_profile(path)
    stdout, _stderr, status = Open3.capture3('security', 'cms', '-D', '-i', path)
    return nil unless status.success?

    profile = plist_string(stdout)
    entitlements = profile.fetch('Entitlements', {})
    {
      path: path,
      name: profile['Name'].to_s,
      uuid: profile['UUID'].to_s,
      entitlements: entitlements,
      creation: parse_time(profile['CreationDate']),
      expiration: parse_time(profile['ExpirationDate']),
      score: profile_score(profile)
    }
  rescue REXML::ParseException
    nil
  end

  def profile_score(profile)
    score = 0
    score += 100 if profile['Name'].to_s.include?(@options[:configuration].split('-').last.to_s)
    score += 50 if profile['Name'].to_s.include?(@version.to_s.delete('.'))
    score += 10 unless profile['Name'].to_s.empty?
    score
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

  def parse_time(value)
    return Time.at(0) if value.to_s.empty?

    Time.parse(value.to_s)
  rescue ArgumentError
    Time.at(0)
  end

  def load_cached_env
    env_path = ENV.fetch('SANE_ENV_CACHE_FILE', File.expand_path('~/.config/nv/env'))
    return unless File.file?(env_path)

    File.readlines(env_path, chomp: true).each do |line|
      next if line.strip.empty? || line.lstrip.start_with?('#')
      next unless line =~ /\A(?:export\s+)?([A-Z0-9_]+)=(.*)\z/

      key = Regexp.last_match(1)
      value = Regexp.last_match(2).strip
      value = value[1...-1] if value.length >= 2 && %w[" '].include?(value[0]) && value[-1] == value[0]
      ENV[key] = value if ENV[key].to_s.empty?
    end
  end

  def prepare_signing_session
    keychain = ENV['SANEBAR_KEYCHAIN_PATH'] || ENV['KEYCHAIN_PATH'] || File.expand_path('~/Library/Keychains/login.keychain-db')
    password = ENV['SANEBAR_KEYCHAIN_PASSWORD'] || ENV['KEYCHAIN_PASSWORD'] || ENV['KEYCHAIN_PASS']
    return unless File.file?(keychain)

    @codesign_keychain = keychain
    return if password.to_s.strip.empty?

    run_quiet('security', 'unlock-keychain', '-p', password, keychain)
    grant_partition_access(keychain, password)
    probe_signing_identity!(keychain)
  end

  def grant_partition_access(keychain, password)
    stamp_root = File.expand_path('~/.cache/saneprocess/keychain-partitions')
    FileUtils.mkdir_p(stamp_root)
    stamp_key = "#{File.mtime(keychain).to_i}-#{@options[:signing_identity]}".gsub(/[^A-Za-z0-9_.-]/, '_')
    stamp_file = File.join(stamp_root, "#{stamp_key}.stamp")
    return if File.file?(stamp_file) && ENV['SANEPROCESS_FORCE_KEYCHAIN_PARTITION'] != '1'

    run_quiet(
      'security',
      'set-key-partition-list',
      '-S',
      'apple-tool:,apple:,codesign:',
      '-s',
      '-k',
      password,
      keychain
    )
    FileUtils.touch(stamp_file)
  end

  def probe_signing_identity!(keychain)
    probe = nil
    Tempfile.create('setapp-codesign-probe') do |file|
      probe = file.path
      file.write('sane')
      file.flush
      run_quiet('codesign', '--force', '--sign', @options[:signing_identity], '--keychain', keychain, '--timestamp=none', probe)
    end
  rescue StandardError
    abort 'Codesign cannot access the Developer ID private key. Check SANEBAR_KEYCHAIN_PASSWORD / KEYCHAIN_PASSWORD / KEYCHAIN_PASS on the Mini.'
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def run_quiet(*cmd)
    _stdout, stderr, status = Open3.capture3(*cmd)
    abort "Command failed (#{status.exitstatus}): #{redacted_shelljoin(cmd)}\n#{stderr}" unless status.success?
  end

  def redacted_shelljoin(cmd)
    redact_next = false
    cmd.map do |arg|
      if redact_next
        redact_next = false
        Shellwords.escape('[REDACTED]')
      elsif %w[-p -k].include?(arg)
        redact_next = true
        Shellwords.escape(arg)
      else
        Shellwords.escape(arg)
      end
    end.join(' ')
  end

  def main_entitlements
    candidate = File.join(@project, @app_name, "#{@app_name}Setapp.entitlements")
    File.file?(candidate) ? candidate : nil
  end

  def extension_entitlements(appex)
    executable = plist_value(File.join(appex, 'Contents', 'Info.plist'), 'CFBundleExecutable')
    candidate = File.join(@project, executable.sub(/Widgets\z/, ''), "#{executable}.entitlements")
    return candidate if File.file?(candidate)

    widgets = File.join(@project, 'Widgets', "#{executable}.entitlements")
    File.file?(widgets) ? widgets : nil
  end

  def plist_file(path)
    stdout, stderr, status = Open3.capture3('plutil', '-convert', 'xml1', '-o', '-', path)
    abort "Could not parse plist #{path}: #{stderr.strip}" unless status.success?

    parse_plist_xml(stdout)
  end

  def plist_string(source)
    Tempfile.create(['setapp-plist', '.plist']) do |file|
      file.write(source)
      file.flush
      stdout, stderr, status = Open3.capture3('plutil', '-convert', 'xml1', '-o', '-', file.path)
      abort "Could not parse plist data: #{stderr.strip}" unless status.success?

      parse_plist_xml(stdout)
    end
  end

  def parse_plist_xml(source)
    doc = REXML::Document.new(source)
    root = doc.elements['plist']
    abort 'Could not parse plist data: missing plist root' unless root

    first_element = root.elements.to_a.first
    abort 'Could not parse plist data: empty plist' unless first_element

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

  def write_receipts
    run_logged('info.plist.txt', 'plutil', '-p', File.join(@app_path, 'Contents', 'Info.plist'))
    capture_to('entitlements.plist', 'codesign', '-d', '--entitlements', ':-', @app_path)
    capture_embedded_profile(@app_path, 'embedded-profile.plist')
    Dir.glob(File.join(@app_path, 'Contents', 'PlugIns', '*.appex')).each do |appex|
      capture_to("#{File.basename(appex)}-entitlements.plist", 'codesign', '-d', '--entitlements', ':-', appex)
      capture_embedded_profile(appex, "#{File.basename(appex)}-embedded-profile.plist")
    end
    capture_to(
      'otool-main.txt',
      'otool',
      '-L',
      File.join(@app_path, 'Contents', 'MacOS', plist_value(File.join(@app_path, 'Contents', 'Info.plist'), 'CFBundleExecutable'))
    )
  end

  def capture_embedded_profile(bundle_path, log_name)
    profile_path = File.join(bundle_path, 'Contents', 'embedded.provisionprofile')
    return unless File.file?(profile_path)

    capture_to(log_name, 'security', 'cms', '-D', '-i', profile_path)
  end

  def verify_signature
    run_logged('codesign-verify.log', 'codesign', '--verify', '--deep', '--strict', '--verbose=2', @app_path)
  end

  def notarize
    run_logged('notary-zip.log', 'ditto', '--norsrc', '-c', '-k', '--keepParent', @app_path, @notary_zip)
    run_logged('notary.log', 'xcrun', 'notarytool', 'submit', @notary_zip, '--keychain-profile', @options[:notary_profile], '--wait')
  end

  def staple
    run_logged('stapler.log', 'xcrun', 'stapler', 'staple', @app_path)
    run_logged('stapler-validate.log', 'xcrun', 'stapler', 'validate', @app_path)
    run_logged('spctl.log', 'spctl', '--assess', '--type', 'execute', '--verbose=4', @app_path)
  end

  def package_final_zip
    Dir.mktmpdir('setapp-final-zip') do |stage_dir|
      run_logged(
        'final-zip-stage-app.log',
        'ditto',
        '--norsrc',
        @app_path,
        File.join(stage_dir, "#{@app_name}.app")
      )
      FileUtils.cp(root_icon_png_path, File.join(stage_dir, "#{@app_name}.png"))
      run_logged('final-zip.log', 'ditto', '--norsrc', '-c', '-k', stage_dir, @final_zip)
    end
    capture_to('sha256.txt', 'shasum', '-a', '256', @final_zip)
  end

  def validate_final_zip
    upload_script = File.expand_path('setapp_upload.rb', __dir__)
    run_logged(
      'setapp-archive-validate.log',
      'ruby',
      upload_script,
      '--validate-only',
      '--zip',
      @final_zip,
      '--release-notes',
      'Maintenance update.'
    )
  end

  def verify_quarantined_launch
    log_path = File.join(@output_dir, 'quarantined-launch.log')
    Dir.mktmpdir('setapp-quarantined-launch') do |dir|
      run_logged('quarantined-launch-unzip.log', 'ditto', '-x', '-k', @final_zip, dir)
      app_path = Dir.glob(File.join(dir, '*.app')).first
      abort 'Quarantined launch proof could not find a top-level .app after expanding final ZIP' unless app_path

      executable = plist_value(File.join(app_path, 'Contents', 'Info.plist'), 'CFBundleExecutable')
      executable_path = File.join(app_path, 'Contents', 'MacOS', executable)
      before_pids = pids_for_process_name(executable)
      File.open(log_path, 'w') do |log|
        log.puts("app=#{app_path}")
        log.puts("executable=#{executable_path}")
        log.puts("before_pids=#{before_pids.join(',')}")
        _stdout, stderr, status = Open3.capture3(
          '/usr/bin/xattr',
          '-w',
          'com.apple.quarantine',
          '0081;00000000;Safari;https://store.setapp.com/',
          app_path
        )
        abort "Could not apply quarantine for launch proof: #{stderr.strip}" unless status.success?

        stdout, open_stderr, open_status = Open3.capture3('/usr/bin/open', '-n', app_path)
        log.puts("open_status=#{open_status.exitstatus}")
        log.puts(stdout) unless stdout.empty?
        log.puts(open_stderr) unless open_stderr.empty?
        unless open_status.success?
          abort "Quarantined Setapp launch proof failed. See #{log_path}"
        end

        sleep 4
        pids = pids_for_process_name(executable) - before_pids
        log.puts("observed_pids=#{pids.join(',')}")
        if pids.empty?
          abort "Quarantined Setapp launch proof did not observe a new #{executable} process. See #{log_path}"
        end
        pids.each { |pid| Process.kill('TERM', pid) rescue nil }
      end
    end
  end

  def pids_for_process_name(process_name)
    stdout, _stderr, status = Open3.capture3('/bin/ps', '-axo', 'pid=,command=')
    return [] unless status.success?

    stdout.each_line.map do |line|
      pid, command = line.strip.split(/\s+/, 2)
      pid.to_i if File.basename(command.to_s.split(/\s+/, 2).first.to_s) == process_name
    end.compact
  end

  def plist_value(plist, key)
    stdout, stderr, status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", plist)
    abort "Could not read #{key} from #{plist}: #{stderr.strip}" unless status.success?

    stdout.strip
  end

  def run_logged(log_name, *cmd)
    log_path = File.join(@output_dir, log_name)
    puts "→ #{cmd.shelljoin}"
    File.open(log_path, 'w') do |log|
      log.puts("$ #{cmd.shelljoin}")
      status = nil
      Open3.popen2e({ 'NSUnbufferedIO' => 'YES' }, *cmd, chdir: @project) do |_stdin, output, wait_thr|
        output.each_line do |line|
          print line
          log.write(line)
        end
        status = wait_thr.value
      end
      abort "Command failed (#{status.exitstatus}): #{cmd.shelljoin}\nLog: #{log_path}" unless status.success?
    end
  end

  def capture_to(log_name, *cmd)
    stdout, stderr, status = Open3.capture3(*cmd, chdir: @project)
    File.write(File.join(@output_dir, log_name), stdout)
    File.write(File.join(@output_dir, "#{log_name}.stderr"), stderr) unless stderr.empty?
    abort "Command failed (#{status.exitstatus}): #{cmd.shelljoin}\n#{stderr}" unless status.success?
  end
end

SetappPackage.new(ARGV).run if __FILE__ == $PROGRAM_NAME
