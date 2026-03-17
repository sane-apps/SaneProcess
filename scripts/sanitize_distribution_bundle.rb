#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "optparse"

CHANNEL_RULES = {
  "setapp" => {
    plist_keys: %w[
      SUFeedURL
      SUPublicEDKey
      SUEnableAutomaticChecks
      SUEnableSystemProfiling
      AppStoreProductID
    ]
  },
  "appstore" => {
    plist_keys: %w[
      SUFeedURL
      SUPublicEDKey
      SUEnableAutomaticChecks
      SUEnableSystemProfiling
      AppStoreProductID
      NSServices
      NSAppleEventsUsageDescription
      NSAccessibilityUsageDescription
    ]
  }
}.freeze

options = {}

OptionParser.new do |opts|
  opts.banner = "Usage: sanitize_distribution_bundle.rb --channel setapp|appstore /path/to/App.app"
  opts.on("--channel CHANNEL", "Target channel: setapp or appstore") { |value| options[:channel] = value }
end.parse!

bundle_path = ARGV[0]
channel = options[:channel]
rules = CHANNEL_RULES[channel]

unless rules
  warn "Unsupported or missing --channel. Use one of: #{CHANNEL_RULES.keys.join(', ')}"
  exit 1
end

unless bundle_path && Dir.exist?(bundle_path)
  warn "Bundle path does not exist: #{bundle_path.inspect}"
  exit 1
end

plist_path = File.join(bundle_path, "Contents", "Info.plist")
unless File.exist?(plist_path)
  warn "Info.plist not found at #{plist_path}"
  exit 1
end

script_dir = File.expand_path(__dir__)
weaken_script = File.join(script_dir, "weaken_sparkle.rb")

unless File.exist?(weaken_script)
  warn "Missing helper script: #{weaken_script}"
  exit 1
end

def delete_plist_key(plist_path, key)
  system("/usr/libexec/PlistBuddy", "-c", "Delete :#{key}", plist_path, out: File::NULL, err: File::NULL)
end

def sparkle_linked?(binary_path)
  output = `otool -L "#{binary_path}" 2>/dev/null`
  $?.success? && output.include?("Sparkle.framework")
end

frameworks_removed = 0
Dir.glob(File.join(bundle_path, "**", "Sparkle.framework")).each do |framework_path|
  FileUtils.rm_rf(framework_path)
  frameworks_removed += 1
end

deleted_keys = []
rules[:plist_keys].each do |key|
  deleted_keys << key if delete_plist_key(plist_path, key)
end

patched_binaries = []
Find.find(bundle_path) do |path|
  next unless path.include?("/Contents/MacOS/")
  next unless File.file?(path)
  next unless sparkle_linked?(path)

  unless system("ruby", weaken_script, path, out: File::NULL, err: File::NULL)
    warn "Failed to weaken Sparkle linkage in #{path}"
    exit 1
  end

  patched_binaries << path
end

puts "Sanitized #{bundle_path}"
puts "  channel: #{channel}"
puts "  removed Sparkle frameworks: #{frameworks_removed}"
puts "  deleted plist keys: #{deleted_keys.empty? ? '<none>' : deleted_keys.join(', ')}"
puts "  patched Mach-O files: #{patched_binaries.empty? ? '<none>' : patched_binaries.join(', ')}"
