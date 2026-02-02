#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Deploy Module
# ==============================================================================
# Deployment safety checks for PreToolUse enforcement.
# Extracted per Rule #10 (file size limit — sanetools_checks.rb already at 752 lines).
#
# Catches:
#   1. R2 upload to wrong bucket or with path prefix in key
#   2. Appcast edits with empty/placeholder signatures or wrong URLs
#   3. Pages deploy with bad appcast in deploy directory
#
# Usage:
#   require_relative 'sanetools_deploy'
#   include SaneToolsDeploy
# ==============================================================================

require 'time'
require_relative 'core/state_manager'

module SaneToolsDeploy
  # All SaneApps share ONE R2 bucket via the dist Worker
  CORRECT_R2_BUCKET = 'sanebar-downloads'

  # The dist Worker strips /updates/ from URL path before R2 lookup.
  # R2 keys must be bare filenames — no path prefixes.
  R2_PUT_PATTERN = /wrangler\s+r2\s+object\s+put\s+(\S+)\s+/i.freeze

  # Sparkle signing tool output pattern
  SPARKLE_SIGN_PATTERN = /sign_update(?:\.swift)?\s+["']?([^"'\s]+\.dmg)["']?/i.freeze

  # Stapler validate pattern
  STAPLER_VALIDATE_PATTERN = /xcrun\s+stapler\s+(?:validate|staple)\s+["']?([^"'\s]+\.dmg)["']?/i.freeze

  # DMG file reference in --file= argument
  R2_FILE_ARG_PATTERN = /--file=["']?([^"'\s]+)["']?/i.freeze

  # Appcast signature patterns
  EMPTY_SIGNATURE_PATTERN = /edSignature=""/i.freeze
  PLACEHOLDER_SIGNATURE_PATTERN = /edSignature="(PLACEHOLDER|TODO|FIXME|REPLACE|xxx+)"/i.freeze
  GITHUB_RELEASE_URL_PATTERN = %r{github\.com/[^/]+/[^/]+/releases/download}i.freeze
  DIST_URL_PATTERN = %r{dist\.\w+\.com/}i.freeze

  # === CHECK 1: R2 Upload Protection ===
  # Triggers on: wrangler r2 object put
  def check_r2_upload(tool_name, tool_input)
    return nil unless tool_name == 'Bash'

    command = tool_input['command'] || tool_input[:command] || ''
    return nil unless command.match?(/wrangler\s+r2\s+object\s+put/i)

    reasons = []

    # Extract bucket and key: wrangler r2 object put <bucket>/<key> --file=...
    match = command.match(R2_PUT_PATTERN)
    if match
      bucket_and_key = match[1]
      # Split on first / to get bucket and key
      parts = bucket_and_key.split('/', 2)
      bucket = parts[0]
      r2_key = parts[1] || ''

      # Check 1a: Wrong bucket
      if bucket != CORRECT_R2_BUCKET
        reasons << "WRONG BUCKET: '#{bucket}'\n" \
                   "   All SaneApps share ONE bucket: #{CORRECT_R2_BUCKET}\n" \
                   "   The dist Worker (sane-dist-worker) routes by URL path, not by bucket."
      end

      # Check 1b: R2 key contains path prefix (/ in key)
      if r2_key.include?('/')
        reasons << "WRONG R2 KEY: '#{r2_key}' contains path prefix\n" \
                   "   The dist Worker strips /updates/ from URL before R2 lookup.\n" \
                   "   R2 key must be just the filename (e.g. SaneBar-1.0.17.dmg)."
      end
    end

    # Check 1c: DMG not Sparkle-signed this session
    file_match = command.match(R2_FILE_ARG_PATTERN)
    if file_match
      local_file = file_match[1]
      dmg_filename = File.basename(local_file)

      deployment = StateManager.get(:deployment)
      signed_dmgs = deployment[:sparkle_signed_dmgs] || []

      unless signed_dmgs.include?(dmg_filename)
        reasons << "NO SPARKLE SIGNATURE for '#{dmg_filename}'\n" \
                   "   DMG must be Sparkle-signed before upload.\n" \
                   "   Run: sign_update.swift \"#{local_file}\" first."
      end

      # Check 1d: DMG not stapled
      if File.exist?(local_file)
        staple_result = `xcrun stapler validate "#{local_file}" 2>&1`
        unless staple_result.include?('valid')
          reasons << "DMG NOT STAPLED: '#{dmg_filename}'\n" \
                     "   Run: xcrun stapler staple \"#{local_file}\" first."
        end
      else
        staple_verified = (deployment[:staple_verified_dmgs] || []).include?(dmg_filename)
        unless staple_verified
          reasons << "DMG NOT VERIFIED STAPLED: '#{dmg_filename}'\n" \
                     "   Cannot verify staple (file not at expected path).\n" \
                     "   Run: xcrun stapler validate \"#{local_file}\" first."
        end
      end
    end

    return nil if reasons.empty?

    # Build block message with correct format example
    msg = "DEPLOYMENT SAFETY — R2 UPLOAD BLOCKED\n\n"
    reasons.each_with_index do |r, i|
      msg += "#{i + 1}. #{r}\n\n"
    end
    msg += "Correct format:\n" \
           "  npx wrangler r2 object put #{CORRECT_R2_BUCKET}/AppName-X.Y.Z.dmg --file=\"path/to/dmg\""
    msg
  end

  # === CHECK 2: Appcast Edit Protection ===
  # Triggers on: Edit/Write to any **/appcast.xml
  def check_appcast_edit(tool_name, tool_input, edit_tools)
    return nil unless edit_tools.include?(tool_name)

    file_path = tool_input['file_path'] || tool_input[:file_path] || ''
    return nil unless file_path.match?(/appcast\.xml$/i)

    content = tool_input['new_string'] || tool_input[:new_string] ||
              tool_input['content'] || tool_input[:content] || ''
    return nil if content.empty?

    reasons = []

    # Check 2a: Empty or placeholder edSignature
    if content.match?(EMPTY_SIGNATURE_PATTERN)
      reasons << "EMPTY edSignature=\"\"\n" \
                 "   Sparkle requires a valid EdDSA signature.\n" \
                 "   Get it from: sign_update.swift \"YourApp.dmg\""
    end

    if content.match?(PLACEHOLDER_SIGNATURE_PATTERN)
      reasons << "PLACEHOLDER edSignature detected\n" \
                 "   Replace with actual signature from sign_update.swift."
    end

    # Check 2b: GitHub release URL
    if content.match?(GITHUB_RELEASE_URL_PATTERN)
      reasons << "GITHUB RELEASE URL detected\n" \
                 "   SaneApps use Cloudflare R2 via dist.{app}.com, NOT GitHub Releases.\n" \
                 "   Correct: url=\"https://dist.sanebar.com/SaneBar-X.Y.Z.dmg\""
    end

    # Check 2c: URL doesn't match dist.{app}.com (warning only, non-blocking)
    if content.match?(/url="([^"]+)"/) && !content.match?(DIST_URL_PATTERN) && !content.match?(GITHUB_RELEASE_URL_PATTERN)
      url_match = content.match(/url="([^"]+)"/)
      warn "DEPLOYMENT WARNING: URL '#{url_match[1]}' doesn't match dist.{app}.com pattern"
    end

    # Check 2d: Length mismatch with local DMG
    length_match = content.match(/length="(\d+)"/)
    url_match = content.match(/url="[^"]*?([^"\/]+\.dmg)"/)
    if length_match && url_match
      declared_length = length_match[1].to_i
      dmg_filename = url_match[1]

      # Try to find local DMG and compare size
      project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
      possible_paths = Dir.glob("#{project_dir}/**/#{dmg_filename}") +
                       Dir.glob("#{File.expand_path('~')}/Desktop/#{dmg_filename}")

      possible_paths.each do |path|
        next unless File.exist?(path)

        actual_size = File.size(path)
        if actual_size != declared_length
          reasons << "LENGTH MISMATCH for #{dmg_filename}\n" \
                     "   Appcast declares: #{declared_length} bytes\n" \
                     "   Local file is:    #{actual_size} bytes\n" \
                     "   The DMG may have been re-signed or re-stapled since the length was recorded."
        end
        break
      end
    end

    return nil if reasons.empty?

    msg = "DEPLOYMENT SAFETY — APPCAST EDIT BLOCKED\n\n"
    reasons.each_with_index do |r, i|
      msg += "#{i + 1}. #{r}\n\n"
    end
    msg
  end

  # === CHECK 3: Pages Deploy Protection ===
  # Triggers on: wrangler pages deploy
  def check_pages_deploy(tool_name, tool_input)
    return nil unless tool_name == 'Bash'

    command = tool_input['command'] || tool_input[:command] || ''
    return nil unless command.match?(/wrangler\s+pages\s+deploy/i)

    # Extract deploy directory
    dir_match = command.match(/wrangler\s+pages\s+deploy\s+["']?([^\s"']+)["']?/i)
    return nil unless dir_match

    deploy_dir = File.expand_path(dir_match[1])
    appcast_path = File.join(deploy_dir, 'appcast.xml')
    return nil unless File.exist?(appcast_path)

    reasons = []

    begin
      appcast_content = File.read(appcast_path)

      if appcast_content.match?(EMPTY_SIGNATURE_PATTERN) || appcast_content.match?(PLACEHOLDER_SIGNATURE_PATTERN)
        reasons << "APPCAST HAS EMPTY/PLACEHOLDER SIGNATURE\n" \
                   "   File: #{appcast_path}\n" \
                   "   Fix the signature before deploying the site."
      end

      if appcast_content.match?(GITHUB_RELEASE_URL_PATTERN)
        reasons << "APPCAST HAS GITHUB RELEASE URL\n" \
                   "   File: #{appcast_path}\n" \
                   "   SaneApps use dist.{app}.com, NOT GitHub Releases."
      end
    rescue StandardError => e
      warn "⚠️  Could not read appcast at #{appcast_path}: #{e.message}"
    end

    return nil if reasons.empty?

    msg = "DEPLOYMENT SAFETY — PAGES DEPLOY BLOCKED\n\n"
    reasons.each_with_index do |r, i|
      msg += "#{i + 1}. #{r}\n\n"
    end
    msg
  end
end
