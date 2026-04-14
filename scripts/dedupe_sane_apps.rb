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

    unknown = @apps - APPS
    abort "Unknown app(s): #{unknown.join(', ')}" unless unknown.empty?
  end

  def run
    return run_remote_wrapper unless local_host? || @remote

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
    return 1 if path.start_with?(TRANSIENT_STAGE_ROOT)
    return 2 if path.start_with?(File.expand_path('~/Applications/'))
    return 3 if path.include?('/build/Export/')
    return 4 if path.include?('/build/') && path.include?('.xcarchive/')
    return 5 if path.include?('/outputs/')
    return 6 if path.include?('/release/') || path.include?('/release-publish/') || path.include?('/release-worktrees/')
    return 7 if path.include?('/DerivedData/')

    8
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

    FileUtils.rm_rf(target) if File.exist?(target)
    FileUtils.mv(staging, target)
  ensure
    FileUtils.rm_rf(staging) if defined?(staging) && staging && File.exist?(staging)
  end

  def trash(path)
    puts "Trashing #{path}" unless @json
    return path if @dry_run

    ok = system('/usr/bin/trash', path, out: File::NULL, err: File::NULL)
    abort "Failed to trash #{path}" unless ok

    path
  end

  def flush_launch_services
    return unless File.exist?(LSREGISTER)

    puts 'Refreshing Launch Services' unless @json
    return if @dry_run

    system(LSREGISTER, '-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user',
           out: File::NULL, err: File::NULL)
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

if ARGV.include?('--help')
  puts 'Usage: ruby scripts/dedupe_sane_apps.rb [--host mini] [--apps App1,App2] [--dry-run] [--json]'
  exit 0
end

DedupeSaneApps.new(ARGV).run
