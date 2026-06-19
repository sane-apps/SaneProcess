#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'open3'
require 'pathname'

module SetappConfig
  APP_DIRS = %w[SaneClip SaneBar].freeze

  module_function

  def apps(root: saneapps_root)
    app_dirs(root).map { |app_dir| app_config(app_dir, root: root) }.compact
  end

  def app_named(name, root: saneapps_root)
    apps_root = File.join(root, 'apps')
    candidates = app_dir_candidates(apps_root)
    app_dir = candidates.find { |candidate| candidate.casecmp(name.to_s).zero? }
    abort "Unknown Setapp app #{name}; known app directories: #{candidates.join(', ')}" unless app_dir

    app = app_config(app_dir, root: root)
    abort "Setapp app #{name} is not enabled in #{File.join(apps_root, app_dir, '.saneprocess')}" unless app

    app
  end

  def app_dirs(root)
    apps_root = File.join(root, 'apps')
    discovered = if Dir.exist?(apps_root)
                   Dir.children(apps_root).select do |entry|
                     manifest_path = File.join(apps_root, entry, '.saneprocess')
                     next false unless File.file?(manifest_path)

                     data = YAML.safe_load(File.read(manifest_path), aliases: true) || {}
                     data.dig('setapp', 'enabled') == true
                   rescue Psych::Exception
                     abort "Setapp manifest could not be parsed: #{manifest_path}"
                   end
                 else
                   []
                 end
    (APP_DIRS + discovered).uniq
  end

  def portal_targets(root: saneapps_root)
    apps(root: root).each_with_object({}) do |app, targets|
      targets[app.fetch(:app_id)] = {
        app_name: app.fetch(:name),
        app_root: app.fetch(:app_root),
        bundle_id: app.fetch(:bundle_id),
        version_id: app.fetch(:version_id),
        release_notes_public: app.fetch(:release_notes_public),
        require_manual_release_confirmation: app.fetch(:require_manual_release_confirmation),
        review_comments_private: app.fetch(:review_comments_private),
        listing_screenshots: app.fetch(:listing_screenshots),
        listing_screenshot_roles: app.fetch(:listing_screenshot_roles),
        screenshot_source: app.fetch(:screenshot_source),
        screenshot_asset_root: app.fetch(:screenshot_asset_root),
        setapp_url: app.fetch(:setapp_url)
      }
    end
  end

  def listing_screenshot_paths(app)
    roles = Array(app[:listing_screenshot_roles])
    Array(app[:listing_screenshots]).map.with_index do |relative_path, index|
      path = safe_listing_screenshot_path(app.fetch(:app_root), relative_path)
      {
        relative_path: relative_path,
        path: path,
        role: roles[index].to_s
      }
    end
  end

  def validate_listing_screenshots!(target, max_count: 5)
    screenshots = listing_screenshot_paths(target)
    abort "Setapp listing screenshots are missing from .saneprocess for #{target[:app_name] || target[:name]}" if screenshots.empty?
    app_name = target[:app_name] || target[:name]
    validate_listing_policy!(target, screenshots, app_name)
    if screenshots.length > max_count
      abort "Setapp listing for #{app_name} declares #{screenshots.length} screenshots; Setapp macOS listings allow up to #{max_count}"
    end

    asset_root = safe_listing_asset_root(target.fetch(:app_root), target.fetch(:screenshot_asset_root))
    screenshots.each do |screenshot|
      relative_path = screenshot.fetch(:relative_path)
      path = screenshot.fetch(:path)
      abort "Setapp listing screenshot missing for #{app_name}: #{relative_path}" unless File.file?(path)
      abort "Setapp listing screenshot must not be a symlink: #{relative_path}" if File.lstat(path).symlink?

      app_root = File.realpath(target.fetch(:app_root))
      real_path = File.realpath(path)
      unless real_path == app_root || real_path.start_with?("#{app_root}#{File::SEPARATOR}")
        abort "Setapp listing screenshot #{relative_path} resolves outside #{app_name}"
      end
      unless real_path == asset_root || real_path.start_with?("#{asset_root}#{File::SEPARATOR}")
        abort "Setapp listing screenshot #{relative_path} is outside the approved Setapp asset root #{target.fetch(:screenshot_asset_root)}"
      end

      extension = File.extname(path).downcase
      unless %w[.png .jpg .jpeg].include?(extension)
        abort "Setapp listing screenshot #{relative_path} must be PNG or JPG"
      end

      width, height = image_dimensions(path, "Setapp listing screenshot #{relative_path}")
      unless width >= 1280 && height >= 800
        abort "Setapp listing screenshot #{relative_path} is #{width}x#{height}; Setapp requires at least 1280x800"
      end
      unless (width * 10) == (height * 16)
        abort "Setapp listing screenshot #{relative_path} is #{width}x#{height}; Setapp requires a 16:10 ratio"
      end
    end
  end

  def saneapps_root
    ENV['SANEAPPS_ROOT'].to_s.empty? ? File.expand_path('../../..', __dir__) : File.expand_path(ENV['SANEAPPS_ROOT'])
  end

  def app_config(app_dir, root:)
    app_root = File.join(root, 'apps', app_dir)
    manifest_path = File.join(app_root, '.saneprocess')
    abort "Setapp manifest not found: #{manifest_path}" unless File.file?(manifest_path)

    data = YAML.safe_load(File.read(manifest_path), aliases: true) || {}
    setapp = data.fetch('setapp', {})
    return nil unless setapp['enabled']

    listing = setapp.fetch('listing', {})
    {
      name: app_dir,
      app_root: app_root,
      app_id: required(setapp, 'app_id', manifest_path),
      version_id: required(setapp, 'version_id', manifest_path),
      bundle_id: required(setapp, 'bundle_id', manifest_path),
      scheme: setapp['scheme'].to_s,
      configuration: setapp['configuration'].to_s,
      release_notes_public: setapp['release_notes_public'] == true,
      review_comments_private: setapp['review_comments_private'] == true,
      require_manual_release_confirmation: setapp['require_manual_release_confirmation'] == true,
      listing_screenshots: Array(listing['screenshots']).map(&:to_s).reject(&:empty?),
      listing_screenshot_roles: Array(listing['screenshot_roles']).map(&:to_s).reject(&:empty?),
      screenshot_source: listing['screenshot_source'].to_s.strip,
      screenshot_asset_root: listing['screenshot_asset_root'].to_s.strip,
      setapp_url: listing['setapp_url'].to_s.strip
    }
  end

  def app_dir_candidates(apps_root)
    discovered = Dir.exist?(apps_root) ? Dir.children(apps_root) : []
    (APP_DIRS + discovered).uniq
  end

  def safe_listing_screenshot_path(app_root, relative_path)
    text = relative_path.to_s
    abort 'Setapp listing screenshot path is empty' if text.empty?
    abort "Setapp listing screenshot path must be relative: #{text}" if Pathname.new(text).absolute?
    abort "Setapp listing screenshot path contains control characters: #{text.inspect}" if text.match?(/[\x00-\x1F\x7F]/)

    root = File.expand_path(app_root)
    path = File.expand_path(text, root)
    return path if path == root || path.start_with?("#{root}#{File::SEPARATOR}")

    abort "Setapp listing screenshot path escapes the app repo: #{text}"
  end

  def safe_listing_asset_root(app_root, relative_path)
    text = relative_path.to_s
    abort 'Setapp listing screenshot_asset_root is missing from .saneprocess' if text.empty?
    abort "Setapp listing screenshot_asset_root must be relative: #{text}" if Pathname.new(text).absolute?

    root = File.expand_path(app_root)
    path = File.expand_path(text, root)
    unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      abort "Setapp listing screenshot_asset_root escapes the app repo: #{text}"
    end
    abort "Setapp listing screenshot_asset_root does not exist: #{text}" unless Dir.exist?(path)

    File.realpath(path)
  end

  def validate_listing_policy!(target, screenshots, app_name)
    source = target.fetch(:screenshot_source).to_s
    unless source.downcase.include?('app-in-use')
      abort "Setapp listing for #{app_name} must declare an app-in-use screenshot_source"
    end
    url = target.fetch(:setapp_url).to_s
    unless url.match?(%r{\Ahttps://setapp\.com/apps/[-a-z0-9]+\z}i)
      abort "Setapp listing for #{app_name} must declare its public setapp_url"
    end

    roles = screenshots.map { |screenshot| screenshot.fetch(:role).to_s }
    if roles.length != screenshots.length || roles.any?(&:empty?)
      abort "Setapp listing for #{app_name} must declare one screenshot_roles entry per screenshot"
    end
    unless roles.first.include?('core_workflow')
      abort "Setapp listing for #{app_name} must lead with an actual working app screenshot"
    end
    unless roles.any? { |role| role.match?(/privacy|touch_id/) }
      abort "Setapp listing for #{app_name} must include a privacy or Touch ID screenshot role"
    end
    unless roles.count { |role| role.include?('core_workflow') } >= 2
      abort "Setapp listing for #{app_name} must include at least two working app screenshots"
    end
    settings_count = roles.count { |role| role.include?('settings') }
    return if settings_count <= 2

    abort "Setapp listing for #{app_name} is too settings-heavy: #{settings_count} of #{roles.length} screenshots are settings"
  end

  def required(hash, key, manifest_path)
    value = hash[key].to_s.strip
    abort "Setapp manifest #{manifest_path} missing #{key}" if value.empty?

    value
  end

  def image_dimensions(path, label)
    output, stderr, status = Open3.capture3(
      '/usr/bin/sips',
      '-g',
      'pixelWidth',
      '-g',
      'pixelHeight',
      path
    )
    abort "#{label} could not be inspected: #{stderr.strip}" unless status.success?

    [output[/pixelWidth:\s*(\d+)/, 1].to_i, output[/pixelHeight:\s*(\d+)/, 1].to_i]
  end
end
