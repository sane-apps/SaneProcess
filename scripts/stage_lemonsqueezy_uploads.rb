#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage the requested release ZIP for the Mini dashboard uploader.
# SHA-256 proves local copy identity, not signing, runtime health, or remote
# publication. Retain earlier local ZIPs: staging has no hosted-file proof.
# Remove superseded customer-visible files only after verifying the replacement.
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
require 'digest'
require 'tempfile'

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
    artifact_sha256 = Digest::SHA256.file(artifact).hexdigest
    target_sha256 = Digest::SHA256.file(target).hexdigest if File.file?(target)
    staged_now = target_sha256 != artifact_sha256
    if staged_now
      Tempfile.create(['.staging-', '.zip'], uploads_dir) do |temporary|
        FileUtils.cp(artifact, temporary.path)
        unless Digest::SHA256.file(temporary.path).hexdigest == artifact_sha256
          return result(:error, "staging verification failed for #{app} #{version}", app: app, version: version)
        end
        # Preserve even a same-version archive with different bytes.
        FileUtils.cp(target, "#{target}.previous-#{target_sha256}") if target_sha256
        File.rename(temporary.path, target)
      end
    end
    retained = Dir.glob(File.join(uploads_dir, "#{app}-*"))
                  .select { |path| File.file?(path) && path != target }.map { |path| File.basename(path) }.sort
    result(staged_now ? :staged : :current,
           "#{app}-#{version}.zip staged and SHA-256 verified; earlier local archives retained pending remote proof",
           app: app, version: version, removed: [], retained: retained, target: target, sha256: artifact_sha256)

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
