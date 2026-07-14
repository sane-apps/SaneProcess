# frozen_string_literal: true

require 'digest'
require 'open3'

# Canonical source-tree identity for verify/release evidence and the hook
# layer. Verify and release receipts bind to release_status_source_fingerprint
# — a pure content hash over release-relevant tracked and untracked files — so
# every consumer that COMPARES a receipt fingerprint must compute it with this
# same module. The git-recipe hash (HEAD + status + diff) that hooks used
# before 2026-07-14 is not comparable: it never matches receipt fingerprints
# and even differs between clones of identical content because `git diff`
# abbreviates index lines by per-clone object count.
#
# Extracted from scripts/sanemaster/release.rb (byte-identical behavior);
# release.rb delegates here so release preflight, verify evidence, and hooks
# share one identity.
module SaneSourceFingerprint
  UPGRADE_PATH_RECEIPT_PATHS = %w[
    .sane/upgrade_path_behavioral_receipt.json
    outputs/upgrade_path_behavioral_receipt.json
  ].freeze

  module_function

  def process_root
    File.expand_path('../..', __dir__)
  end

  def default_saneapps_root
    File.expand_path('../..', process_root)
  end

  def release_status_source_fingerprint(project_path = Dir.pwd, saneapps_root: default_saneapps_root)
    entries = release_status_source_entries(project_path, saneapps_root: saneapps_root)
    return nil if entries.empty?

    digest = Digest::SHA256.new
    entries.each do |entry|
      absolute_path = entry.fetch(:absolute_path)
      next unless File.file?(absolute_path)

      digest.update(entry.fetch(:digest_path))
      digest.update("\0")
      digest.update(Digest::SHA256.file(absolute_path).hexdigest)
      digest.update("\0")
    end
    digest.hexdigest
  rescue StandardError
    nil
  end

  def release_status_source_files(project_path)
    tracked, tracked_status = Open3.capture2e('git', '-C', project_path, 'ls-files', '-z')
    others, others_status = Open3.capture2e('git', '-C', project_path, 'ls-files', '--others', '--exclude-standard', '-z')
    files = []
    files.concat(tracked.split("\0")) if tracked_status.success?
    files.concat(others.split("\0")) if others_status.success?
    files = filesystem_release_status_source_files(project_path) if files.empty?
    files.concat(release_status_proof_files(project_path))
    files.select { |path| release_status_source_file?(project_path, path) }.uniq.sort
  rescue StandardError
    []
  end

  def filesystem_release_status_source_files(project_path)
    Dir.chdir(project_path) do
      Dir.glob('**/*', File::FNM_DOTMATCH).reject do |path|
        path.start_with?('.git/') ||
          path.start_with?('outputs/') ||
          path.start_with?('.sanemaster/') ||
          File.directory?(path)
      end
    end
  rescue StandardError
    []
  end

  def release_status_source_entries(project_path, saneapps_root: default_saneapps_root)
    app_entries = release_status_source_files(project_path).map do |relative_path|
      {
        digest_path: "app/#{relative_path}",
        absolute_path: File.join(project_path, relative_path)
      }
    end

    harness_entries = release_status_harness_source_files(process_root).map do |relative_path|
      {
        digest_path: "SaneProcess/#{relative_path}",
        absolute_path: File.join(process_root, relative_path)
      }
    end
    shared_entries = release_status_shared_source_files(project_path, saneapps_root: saneapps_root).map do |entry|
      {
        digest_path: entry.fetch(:digest_path),
        absolute_path: entry.fetch(:absolute_path)
      }
    end

    app_entries + harness_entries + shared_entries
  rescue StandardError
    []
  end

  def release_status_shared_source_files(project_path, saneapps_root: default_saneapps_root)
    root = saneapps_root
    app_source = release_status_source_files(project_path)
    receipt_paths = [
      '.sane/customer_ui_action_receipt.json',
      'outputs/customer_ui_action_receipt.json'
    ]
    needs_saneui = app_source.any? do |relative_path|
      receipt_paths.include?(relative_path) ||
        relative_path.start_with?('Sane', 'Shared/', 'Sources/', 'UI/', 'Core/')
    end
    return [] unless needs_saneui

    patterns = [
      'infra/SaneUI/Sources/**/*.{swift,xcstrings}'
    ]
    patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
            .select { |path| File.file?(path) }
            .map do |path|
              relative_path = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
              {
                digest_path: "SaneApps/#{relative_path}",
                absolute_path: path
              }
            end
            .uniq { |entry| entry[:digest_path] }
            .sort_by { |entry| entry[:digest_path] }
  rescue StandardError
    []
  end

  def release_status_harness_source_files(root = process_root)
    patterns = [
      'scripts/SaneMaster.rb',
      'scripts/release.sh',
      'scripts/validation_report.rb',
      'scripts/sanemaster/**/*.rb',
      'scripts/hooks/**/*.{rb,sh}'
    ]
    patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
            .select { |path| File.file?(path) }
            .map { |path| path.sub(%r{\A#{Regexp.escape(root)}/?}, '') }
            .uniq
            .sort
  rescue StandardError
    []
  end

  def release_status_proof_files(project_path)
    [
      '.sane/customer_ui_action_receipt.json',
      'outputs/customer_ui_action_receipt.json',
      *Dir.glob(File.join(project_path, 'outputs', 'runtime-preflight', 'sanebar_runtime_*.{json,log}')).map do |path|
        path.sub(%r{\A#{Regexp.escape(project_path)}/?}, '')
      end,
      *Dir.glob(File.join(project_path, 'outputs', 'customer-ui', '**', 'resource-soak-*')).map do |path|
        path.sub(%r{\A#{Regexp.escape(project_path)}/?}, '')
      end
    ].select { |path| File.file?(File.join(project_path, path)) }
  rescue StandardError
    []
  end

  def release_status_source_file?(project_path, relative_path)
    return false if relative_path.to_s.empty?
    return false if UPGRADE_PATH_RECEIPT_PATHS.include?(relative_path.to_s)
    return true if relative_path == 'docs/_redirects' || relative_path == 'website/_redirects'
    return true if relative_path.match?(%r{\A(?:docs|website)/.*\.(?:css|html|js|json|xml)\z})
    return true if relative_path == 'outputs/customer_ui_action_receipt.json'
    return true if relative_path == '.sane/customer_ui_action_receipt.json'
    return true if relative_path.match?(%r{\Aoutputs/runtime-preflight/sanebar_runtime_.*\.(?:json|log)\z})
    return true if relative_path.match?(%r{\Aoutputs/customer-ui/.*resource-soak-.*\.(?:json|log)\z})
    return false if %w[
      .sane/customer_ui_action_receipt.json AGENTS.md ARCHITECTURE.md CLAUDE.md
      DEVELOPMENT.md README.md SESSION_HANDOFF.md
    ].include?(relative_path)
    return false if relative_path.start_with?(
      '.build/',
      '.claude/',
      '.codex/',
      '.git/',
      '.sanemaster/',
      '.serena/',
      'DerivedData/',
      'build/',
      'docs/',
      'fastlane/test_output/',
      'node_modules/',
      'outputs/',
      'releases/',
      'vendor/bundle/',
      'website/'
    )

    app_folder = File.basename(project_path)
    return true if relative_path == '.saneprocess'
    return true if %w[Package.resolved Package.swift project.yml].include?(relative_path)
    return true if relative_path.end_with?('.xcodeproj/project.pbxproj')
    return true if relative_path.start_with?("#{app_folder}/")
    return true if relative_path.start_with?('Config/', 'Scripts/', 'Shared/', 'Sources/', 'Tests/', 'scripts/')

    %w[
      .c .cc .cpp .entitlements .h .json .metal .m .mm .plist .rb .sh .storyboard
      .swift .xcconfig .xcprivacy .xcstrings .xib .yaml .yml
    ].include?(File.extname(relative_path))
  end
end
