#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'shellwords'

path = ARGV[0] || '.saneprocess'
unless File.exist?(path)
  warn "Config not found: #{path}"
  exit 1
end

config = YAML.safe_load(File.read(path)) || {}

# Support both string and symbol keys (YAML loads strings by default)
def fetch_config(config, *keys)
  keys.reduce(config) do |acc, key|
    break nil unless acc.is_a?(Hash)

    acc[key] || acc[key.to_s]
  end
end

def emit(name, value)
  return if value.nil?
  return if value.respond_to?(:empty?) && value.empty?

  if value.is_a?(Array)
    items = value.map { |v| Shellwords.escape(v.to_s) }.join(' ')
    puts "#{name}=(#{items})"
    return
  end

  scalar = if value.is_a?(TrueClass) || value.is_a?(FalseClass) || value.is_a?(Numeric)
             value.to_s
           else
             Shellwords.escape(value.to_s)
           end
  puts "#{name}=#{scalar}"
end

# Project/build settings
emit('APP_NAME', fetch_config(config, 'name'))
emit('BUNDLE_ID', fetch_config(config, 'bundle_id') || fetch_config(config, 'release', 'bundle_id'))
emit('SCHEME', fetch_config(config, 'scheme') || fetch_config(config, 'build', 'scheme'))
emit('XCODEGEN', fetch_config(config, 'build', 'xcodegen'))
emit('WORKSPACE', fetch_config(config, 'build', 'workspace'))
emit('XCODEPROJ', fetch_config(config, 'build', 'xcodeproj') || fetch_config(config, 'project'))

# Release settings
emit('DIST_HOST', fetch_config(config, 'release', 'dist_host'))
emit('SITE_HOST', fetch_config(config, 'release', 'site_host'))
emit('R2_BUCKET', fetch_config(config, 'release', 'r2_bucket'))
emit('USE_SPARKLE', fetch_config(config, 'release', 'use_sparkle'))
emit('MIN_SYSTEM_VERSION', fetch_config(config, 'release', 'min_system_version'))
emit('NOTARY_PROFILE', fetch_config(config, 'release', 'notary_profile'))
emit('GITHUB_REPO', fetch_config(config, 'release', 'github_repo'))
emit('SIGNING_IDENTITY', fetch_config(config, 'release', 'signing_identity'))
emit('TEAM_ID', fetch_config(config, 'release', 'team_id'))
emit('VERIFY_STAPLE', fetch_config(config, 'release', 'verify_staple'))

# DMG settings
emit('DMG_VOLUME_ICON', fetch_config(config, 'release', 'dmg', 'volume_icon'))
emit('DMG_FILE_ICON', fetch_config(config, 'release', 'dmg', 'file_icon'))
emit('DMG_BACKGROUND', fetch_config(config, 'release', 'dmg', 'background'))
emit('DMG_BACKGROUND_GENERATOR', fetch_config(config, 'release', 'dmg', 'background_generator'))
emit('DMG_WINDOW_POS', fetch_config(config, 'release', 'dmg', 'window_pos'))
emit('DMG_WINDOW_SIZE', fetch_config(config, 'release', 'dmg', 'window_size'))
emit('DMG_ICON_SIZE', fetch_config(config, 'release', 'dmg', 'icon_size'))
emit('DMG_APP_ICON_POS', fetch_config(config, 'release', 'dmg', 'app_icon_pos'))
emit('DMG_DROP_POS', fetch_config(config, 'release', 'dmg', 'drop_pos'))
emit('DMG_HIDE_EXTENSION', fetch_config(config, 'release', 'dmg', 'hide_extension'))
emit('DMG_NO_INTERNET_ENABLE', fetch_config(config, 'release', 'dmg', 'no_internet_enable'))

# Export/signing settings
emit('EXPORT_OPTIONS_PLIST', fetch_config(config, 'release', 'export', 'options_plist'))
emit('EXPORT_OPTIONS_EXTRA_XML', fetch_config(config, 'release', 'export', 'extra_xml'))
emit('EXPORT_OPTIONS_PROFILES', fetch_config(config, 'release', 'export', 'profiles'))

# Extra args/hooks
emit('ARCHIVE_EXTRA_ARGS', fetch_config(config, 'release', 'archive_extra_args'))
emit('CREATE_DMG_EXTRA_ARGS', fetch_config(config, 'release', 'create_dmg_extra_args'))
emit('VERSION_BUMP_CMD', fetch_config(config, 'release', 'version_bump_cmd'))
emit('VERSION_BUMP_RESTORE_CMD', fetch_config(config, 'release', 'version_bump_restore_cmd'))
emit('VERSION_BUMP_FILES', fetch_config(config, 'release', 'version_bump_files'))

# App Store Connect settings
appstore = fetch_config(config, 'appstore')
if appstore
  emit('APPSTORE_ENABLED', fetch_config(config, 'appstore', 'enabled'))
  emit('APPSTORE_APP_ID', fetch_config(config, 'appstore', 'app_id'))
  emit('APPSTORE_PLATFORMS', fetch_config(config, 'appstore', 'platforms'))
  emit('APPSTORE_CONFIGURATION', fetch_config(config, 'appstore', 'configuration'))
  emit('APPSTORE_IOS_SCHEME', fetch_config(config, 'appstore', 'ios_scheme'))
  emit('APPSTORE_SCREENSHOTS_MACOS', fetch_config(config, 'appstore', 'screenshots', 'macos'))
  emit('APPSTORE_SCREENSHOTS_IOS', fetch_config(config, 'appstore', 'screenshots', 'ios'))
  emit('APPSTORE_CONTACT_NAME', fetch_config(config, 'appstore', 'contact', 'name'))
  emit('APPSTORE_CONTACT_PHONE', fetch_config(config, 'appstore', 'contact', 'phone'))
  emit('APPSTORE_CONTACT_EMAIL', fetch_config(config, 'appstore', 'contact', 'email'))
end
