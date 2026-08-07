#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'shellwords'
require 'time'

APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo].freeze
LOCAL_HOSTS = %w[local localhost].freeze
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
NEVER_INDEX_MARKER = '.metadata_never_index'
TRANSIENT_STAGE_ROOT = File.expand_path('/tmp/saneapps-staging.noindex')

class DedupeSaneApps
  def initialize(args)
    @args = args.dup
    @host = extract_option('--host') || 'local'
    apps = extract_option('--apps')
    @apps = apps ? apps.split(',').map(&:strip).reject(&:empty?) : APPS
    @dry_run = @args.delete('--dry-run')
    @json = @args.delete('--json')
    @remote = @args.delete('--remote')
    @launch_services_only = @args.delete('--launch-services-only')

    unknown = @apps - APPS
    abort "Unknown app(s): #{unknown.join(', ')}" unless unknown.empty?
  end

  def run
    return run_remote_wrapper unless local_host? || @remote

    if @launch_services_only
      flush_launch_services
      print_results([])
      return
    end

    results = @apps.map { |app| dedupe_app(app) }
    flush_launch_services
    print_results(results)
  end

  private

  def extract_option(name)
    index = @args.index(name)
    return nil unless index

    value = @args[index + 1]
    abort "Missing value for #{name}" if value.nil? || value.start_with?('--')

    @args.slice!(index, 2)
    value
  end

  def local_host?
    LOCAL_HOSTS.include?(@host)
  end

  def run_remote_wrapper
    remote_args = @args.dup
    remote_args += ['--apps', @apps.join(',')] unless @apps == APPS
    remote_args << '--dry-run' if @dry_run
    remote_args << '--json' if @json
    remote_args << '--launch-services-only' if @launch_services_only
    remote_args << '--remote'

    command = ['ssh', @host, 'ruby', '-', *remote_args]
    stdout, status = Open3.capture2e(*command, stdin_data: File.read(__FILE__))
    abort stdout unless status.success?

    puts stdout
  end

  def dedupe_app(app)
    ensure_never_index_roots(app)
    paths = candidate_paths(app)
    canonical = canonical_path(app)
    promoted_from = nil
    installed_paths = installed_candidate_paths(paths)

    if !File.exist?(canonical)
      source = choose_promotion_source(paths, canonical)
      if source
        promote(source, canonical)
        promoted_from = source
        paths = candidate_paths(app)
        installed_paths = installed_candidate_paths(paths)
      end
    end

    canonical_exists = File.exist?(canonical)
    stale_paths =
      if canonical_exists
        paths.reject { |path| same_path?(path, canonical) }
      else
        installed_paths.reject { |path| same_path?(path, canonical) }
      end
    trashed = stale_paths.map { |path| trash(path) }

    {
      app: app,
      canonical_path: canonical,
      canonical_exists: canonical_exists,
      promoted_from: promoted_from,
      trashed_paths: trashed.compact
    }
  end

  def candidate_paths(app)
    patterns = [
      "/Applications/#{app}.app",
      File.expand_path("~/Applications/#{app}.app"),
      File.expand_path("/tmp/#{app}.app"),
      File.join(TRANSIENT_STAGE_ROOT, "#{app}.app"),
      File.expand_path("~/Library/Developer/Xcode/DerivedData/#{app}-*/Build/Products/*/#{app}.app"),
      File.expand_path("~/codex-runs/**/#{app}.app"),
      File.expand_path("~/SaneApps/apps/#{app}/build/**/#{app}.app"),
      File.expand_path("~/SaneApps/apps/#{app}/outputs/**/#{app}.app"),
      File.expand_path("~/SaneApps/release/**/#{app}.app"),
      File.expand_path("~/SaneApps/release-publish/**/#{app}.app"),
      File.expand_path("~/SaneApps/release-worktrees/**/#{app}.app"),
      File.expand_path("~/SaneApps/tmp/**/#{app}.app"),
      File.expand_path("~/tmp/**/#{app}.app")
    ]

    patterns
      .flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
      .select { |path| File.directory?(path) }
      .map { |path| File.expand_path(path) }
      .reject { |path| path.include?('/.Trash/') }
      .uniq
      .sort
  end

  def canonical_path(app)
    "/Applications/#{app}.app"
  end

  def choose_promotion_source(paths, canonical)
    candidates = paths.reject { |path| same_path?(path, canonical) }
    candidates = candidates.reject { |path| unsafe_promotion_source?(path) }
    return nil if candidates.empty?

    ranked = candidates.sort_by do |path|
      [
        path_priority(path),
        -artifact_mtime(path).to_i
      ]
    end
    ranked.first
  end

  def installed_candidate_paths(paths)
    paths.select do |path|
      path.start_with?('/Applications/') || path.start_with?(File.expand_path('~/Applications/'))
    end
  end

  def path_priority(path)
    return 0 if path.start_with?('/Applications/')
    return 8 if path.start_with?(TRANSIENT_STAGE_ROOT)
    return 2 if path.start_with?(File.expand_path('~/Applications/'))
    return 3 if path.include?('/build/Export/')
    return 4 if path.include?('/build/') && path.include?('.xcarchive/')
    return 5 if path.include?('/outputs/')
    return 6 if path.include?('/release/') || path.include?('/release-publish/') || path.include?('/release-worktrees/')
    return 7 if path.include?('/DerivedData/')

    8
  end

  def unsafe_promotion_source?(path)
    ad_hoc_signed?(path)
  end

  def ad_hoc_signed?(app_path)
    output = `codesign -dv --verbose=4 #{Shellwords.escape(app_path)} 2>&1`
    output.include?('Signature=adhoc')
  end

  def artifact_mtime(app_bundle_path)
    executable = File.join(app_bundle_path, 'Contents', 'MacOS', File.basename(app_bundle_path, '.app'))
    return File.mtime(executable) if File.exist?(executable)

    File.mtime(app_bundle_path)
  rescue StandardError
    Time.at(0)
  end

  def promote(source, target)
    puts "Promoting #{source} -> #{target}" unless @json
    return if @dry_run

    FileUtils.mkdir_p(File.dirname(target))
    staging = "#{target}.staging-#{Process.pid}-#{Time.now.to_i}"
    FileUtils.rm_rf(staging) if File.exist?(staging)

    ok = system('ditto', source, staging, out: File::NULL, err: File::NULL)
    abort "Failed to stage #{source} to #{target}" unless ok && File.directory?(staging)

    if File.exist?(target)
      unregister_launch_services_path(target)
      FileUtils.rm_rf(target)
    end
    FileUtils.mv(staging, target)
  ensure
    FileUtils.rm_rf(staging) if defined?(staging) && staging && File.exist?(staging)
  end

  def trash(path)
    puts "Trashing #{path}" unless @json
    return path if @dry_run

    unregister_launch_services_path(path)
    ok = system('/usr/bin/trash', path, out: File::NULL, err: File::NULL)
    abort "Failed to trash #{path}" unless ok

    path
  end

  def unregister_launch_services_path(path)
    return unless File.executable?(LSREGISTER)

    root = File.expand_path(path)
    bundles = Dir.glob(File.join(root, '**', '*.app')).sort_by { |bundle| -bundle.count(File::SEPARATOR) }
    bundles << root if root.end_with?('.app')
    bundles.uniq.each do |bundle|
      system(LSREGISTER, '-u', bundle, out: File::NULL, err: File::NULL)
    end
  end

  def flush_launch_services
    return unless File.exist?(LSREGISTER)

    puts 'Refreshing Launch Services' unless @json
    return if @dry_run

    unregister_recorded_noncanonical_bundles
    unregister_trashed_app_bundles
    unregister_noncanonical_artifact_bundles
    @apps.each do |app|
      canonical = canonical_path(app)
      system(LSREGISTER, '-f', canonical, out: File::NULL, err: File::NULL) if File.directory?(canonical)
    end
    system(LSREGISTER, '-gc', out: File::NULL, err: File::NULL)
  end

  # Launch Services can retain records after the bundle itself was deleted.
  # Read those recorded paths from its own database so cleanup is not limited
  # to app bundles that still exist on disk.
  def unregister_recorded_noncanonical_bundles
    @apps.each do |app|
      recorded_app_paths(app)
        .reject { |path| same_path?(path, canonical_path(app)) }
        .sort_by { |path| -path.count(File::SEPARATOR) }
        .each { |path| unregister_launch_services_path(path) }
    end
  end

  def recorded_app_paths(app)
    app_bundle = %r{(.*/#{Regexp.escape(app)}[^/]*\.app)(?:/|\s+\(0x)}
    launch_services_dump.lines.filter_map do |line|
      next unless line.start_with?('path:')

      line.delete_prefix('path:').strip[app_bundle, 1]
    end.uniq
  end

  def launch_services_dump
    output, status = Open3.capture2e(LSREGISTER, '-dump')
    status.success? ? output : ''
  end

  # Moving an app to Trash does not reliably remove its Launch Services entry.
  # Leave Trash recoverable, but unregister every trashed copy before registering
  # the one canonical /Applications build.
  def unregister_trashed_app_bundles
    trash_root = File.expand_path('~/.Trash')
    return unless Dir.exist?(trash_root)

    @apps.each do |app|
      pattern = File.join(trash_root, '**', "#{app}*.app")
      Dir.glob(pattern)
        .select { |path| File.directory?(path) }
        .sort_by { |path| -path.count(File::SEPARATOR) }
        .each { |path| unregister_launch_services_path(path) }
    end
  end

  # Xcode registers archive, export, and test products as it creates them.
  # Preserve those release artifacts on disk, but remove their Launch Services
  # registrations so the Dock resolves only the canonical /Applications app.
  def unregister_noncanonical_artifact_bundles
    @apps.each do |app|
      patterns = [
        File.expand_path("~/Library/Developer/Xcode/DerivedData/#{app}-*/Build/**/#{app}.app"),
        File.expand_path("~/SaneApps/apps/#{app}*/build/**/#{app}.app"),
        File.expand_path("~/SaneApps/apps/#{app}*/outputs/**/#{app}.app"),
        File.expand_path("~/SaneApps/release*/**/#{app}.app"),
        File.expand_path("~/codex-runs/**/#{app}.app"),
        File.expand_path("~/tmp/**/#{app}.app"),
        File.expand_path("/tmp/**/#{app}.app")
      ]
      patterns
        .flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
        .select { |path| File.directory?(path) }
        .map { |path| File.expand_path(path) }
        .reject { |path| same_path?(path, canonical_path(app)) }
        .uniq
        .sort_by { |path| -path.count(File::SEPARATOR) }
        .each { |path| unregister_launch_services_path(path) }
    end
  end

  def ensure_never_index_roots(app)
    roots = [
      File.expand_path("~/Library/Developer/Xcode/DerivedData"),
      File.expand_path("~/SaneApps/apps/#{app}/build"),
      File.expand_path("~/SaneApps/apps/#{app}/outputs"),
      File.expand_path('~/SaneApps/release'),
      File.expand_path('~/SaneApps/tmp'),
      File.expand_path('~/SaneApps/release-publish'),
      File.expand_path('~/SaneApps/release-worktrees'),
      File.expand_path('~/tmp'),
      TRANSIENT_STAGE_ROOT
    ].uniq

    roots.each do |root|
      next unless Dir.exist?(root)

      marker = File.join(root, NEVER_INDEX_MARKER)
      next if File.exist?(marker)

      puts "Marking #{root} as never-index" unless @json
      next if @dry_run

      File.write(marker, '')
    end
  end

  def same_path?(left, right)
    File.expand_path(left) == File.expand_path(right)
  end

  def print_results(results)
    if @json
      require 'json'
      puts JSON.pretty_generate(results)
      return
    end

    results.each do |result|
      puts
      puts "#{result[:app]}:"
      puts "  canonical: #{result[:canonical_path]}"
      puts "  present:   #{result[:canonical_exists]}"
      if result[:promoted_from]
        puts "  promoted:  #{result[:promoted_from]}"
      end
      if result[:trashed_paths].empty?
        puts '  trashed:   none'
      else
        puts "  trashed:   #{result[:trashed_paths].length}"
        result[:trashed_paths].each do |path|
          puts "    - #{path}"
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.include?('--help')
    puts 'Usage: ruby scripts/dedupe_sane_apps.rb [--host mini] [--apps App1,App2] [--launch-services-only] [--dry-run] [--json]'
    exit 0
  end

  DedupeSaneApps.new(ARGV).run
end
