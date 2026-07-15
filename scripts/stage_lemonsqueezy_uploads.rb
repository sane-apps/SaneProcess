#!/usr/bin/env ruby
# frozen_string_literal: true

# stage_lemonsqueezy_uploads.rb — keep the manual-upload staging folder
# (~/Desktop/LemonSqueezy-Uploads by default) populated with ONLY the latest
# release ZIP per app.
#
# Why: Lemon Squeezy's hosted file is the one release channel release.sh cannot
# auto-deploy — the file is replaced by hand in the LS dashboard, and this
# folder is the staging area. Codex or the owner drives that upload; Claude can
# click through dashboards via Brave but cannot upload files through the
# browser, so Claude's post-flight (the Stop hook) runs this after every
# release so the uploader always finds exactly the right file with no stale
# versions beside it. See memory lemonsqueezy-uploads-folder-rule.
#
# Idempotent. Operates on the LOCAL filesystem (run it on the host that holds
# the artifacts + the staging folder — the Mac mini). On a host with no staging
# folder it is a safe no-op.
#
# Usage:
#   stage_lemonsqueezy_uploads.rb --project <app-dir> [--version X.Y.Z]
#                                 [--uploads-dir DIR] [--json]
#
# Exit codes: 0 = staged or nothing-to-do; 2 = real failure (e.g. expected
# artifact missing — release likely did not complete).

require 'fileutils'
require 'json'

module StageLemonSqueezyUploads
  DEFAULT_UPLOADS_DIR = File.expand_path('~/Desktop/LemonSqueezy-Uploads')
  ARTIFACT_SUBDIRS = %w[releases build].freeze

  module_function

  def parse_args(argv)
    opts = { json: false }
    rest = argv.dup
    until rest.empty?
      flag = rest.shift
      case flag
      when '--project' then opts[:project] = rest.shift
      when '--version' then opts[:version] = rest.shift
      when '--uploads-dir' then opts[:uploads_dir] = rest.shift
      when '--json' then opts[:json] = true
      when '-h', '--help'
        warn File.read(__FILE__).lines[1..40].join
        exit 0
      else
        warn "Unknown argument: #{flag}"
        exit 2
      end
    end
    opts
  end

  # Version sources, in order:
  #   1. project.yml         `MARKETING_VERSION: "2.1.84"`  (XcodeGen apps)
  #   2. Config/*.xcconfig   `MARKETING_VERSION = 1.1.22`   (SaneHosts has no
  #      project.yml; Shared.xcconfig is read first, then any other Config
  #      xcconfig)
  # A leading [0-9] is required so build-setting references ($(inherited),
  # $(MARKETING_VERSION)) are never mistaken for a version.
  def marketing_version(project)
    version_from_project_yml(project) || version_from_xcconfig(project)
  end

  def version_from_project_yml(project)
    yml = File.join(project, 'project.yml')
    return nil unless File.file?(yml)

    File.foreach(yml) do |line|
      m = line.match(/^\s*MARKETING_VERSION:\s*"?([0-9][^"\s]*)"?/)
      return m[1] if m
    end
    nil
  rescue StandardError
    nil
  end

  def version_from_xcconfig(project)
    xcconfig_files(project).each do |path|
      File.foreach(path) do |line|
        # `MARKETING_VERSION = 1.1.22`, tolerating an xcconfig condition
        # suffix such as MARKETING_VERSION[sdk=macosx*] = 1.1.22
        m = line.match(/^\s*MARKETING_VERSION(?:\[[^\]]*\])?\s*=\s*"?([0-9][^"\s]*)"?/)
        return m[1] if m
      end
    end
    nil
  rescue StandardError
    nil
  end

  # Shared.xcconfig first (the SaneApps convention), then any sibling.
  def xcconfig_files(project)
    shared = File.join(project, 'Config', 'Shared.xcconfig')
    ([shared] + Dir.glob(File.join(project, 'Config', '*.xcconfig')).sort)
      .uniq.select { |p| File.file?(p) }
  end

  def find_artifact(project, app, version)
    ARTIFACT_SUBDIRS.each do |sub|
      candidate = File.join(project, sub, "#{app}-#{version}.zip")
      return candidate if File.file?(candidate)
    end
    nil
  end

  # Recoverable delete: `trash` if present, else File.delete.
  def remove_file(path)
    if system('command -v trash > /dev/null 2>&1')
      system('trash', path, out: File::NULL, err: File::NULL) || File.delete(path)
    else
      File.delete(path)
    end
  rescue StandardError
    false
  end

  # Returns a result hash; never raises.
  def stage(project:, uploads_dir: DEFAULT_UPLOADS_DIR, version: nil)
    return result(:error, 'no --project given') if project.to_s.empty?

    project = File.expand_path(project)
    uploads_dir = File.expand_path(uploads_dir)
    app = File.basename(project)
    version ||= marketing_version(project)
    if version.to_s.empty?
      return result(:error,
                    "could not resolve version for #{app} " \
                    '(no MARKETING_VERSION in project.yml or Config/*.xcconfig)')
    end

    # Not the staging host (no folder) → safe no-op, not a failure.
    unless File.directory?(uploads_dir)
      return result(:noop, "no staging folder at #{uploads_dir} (not the staging host)", app: app, version: version)
    end

    artifact = find_artifact(project, app, version)
    unless artifact
      return result(:error,
                    "no built artifact for #{app} #{version} in releases/ or build/ - did the release finish?",
                    app: app, version: version)
    end

    target = File.join(uploads_dir, "#{app}-#{version}.zip")
    artifact_size = File.size(artifact)

    staged_now = false
    unless File.file?(target) && File.size(target) == artifact_size
      FileUtils.cp(artifact, target)
      staged_now = true
    end

    # Remove every OTHER <app>-*.zip so only the latest remains. Leaves other
    # apps' ZIPs alone.
    removed = []
    Dir.glob(File.join(uploads_dir, "#{app}-*.zip")).each do |existing|
      next if File.basename(existing) == File.basename(target)

      removed << File.basename(existing) if remove_file(existing)
    end

    # Verify final state.
    ok = File.file?(target) && File.size(target) == artifact_size &&
         Dir.glob(File.join(uploads_dir, "#{app}-*.zip")).map { |p| File.basename(p) } == [File.basename(target)]
    unless ok
      return result(:error, "staging verification failed for #{app} #{version}", app: app, version: version)
    end

    result(staged_now || !removed.empty? ? :staged : :current,
           "#{app}-#{version}.zip staged; removed #{removed.empty? ? 'none' : removed.join(', ')}",
           app: app, version: version, removed: removed, target: target)
  rescue StandardError => e
    result(:error, "exception: #{e.class}: #{e.message}")
  end

  def result(status, message, **extra)
    { status: status.to_s, message: message }.merge(extra)
  end

  def run(argv)
    opts = parse_args(argv)
    res = stage(project: opts[:project], uploads_dir: opts[:uploads_dir] || DEFAULT_UPLOADS_DIR, version: opts[:version])
    if opts[:json]
      puts JSON.generate(res)
    else
      icon = { 'staged' => '✅', 'current' => '✅', 'noop' => 'ℹ️', 'error' => '❌' }[res[:status]] || '•'
      puts "#{icon} LemonSqueezy-Uploads: #{res[:message]}"
    end
    res[:status] == 'error' ? 2 : 0
  end
end

exit(StageLemonSqueezyUploads.run(ARGV)) if $PROGRAM_NAME == __FILE__
