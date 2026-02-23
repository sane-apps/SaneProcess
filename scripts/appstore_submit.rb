#!/usr/bin/env ruby
# frozen_string_literal: true

# appstore_submit.rb — App Store Connect submission helper
#
# Handles the full App Store Connect flow:
#   1. Generate JWT token (Ruby jwt gem + openssl)
#   2. Upload build via `xcrun altool --upload-app`
#   3. Poll ASC API for build processing (PROCESSING → VALID)
#   4. Find or create app version for target version string
#   5. Attach build to version
#   6. Ensure review contact detail exists
#   7. Submit for review
#
# Usage:
#   ruby appstore_submit.rb \
#     --pkg PATH --app-id ID --version X.Y.Z \
#     --platform macos|ios --project-root PATH
#
# Dependencies: gem install jwt

require 'json'
require 'net/http'
require 'openssl'
require 'optparse'
require 'securerandom'
require 'time'
require 'uri'
require 'yaml'
require 'tmpdir'

begin
  require 'jwt'
rescue LoadError
  warn 'Missing required gem: jwt'
  warn 'Install with: gem install jwt'
  exit 1
end

# ─── Configuration ───

ISSUER_ID = 'c98b1e0a-8d10-4fce-a417-536b31c09bfb'
KEY_ID = 'S34998ZCRT'
P8_PATH = File.expand_path('~/.private_keys/AuthKey_S34998ZCRT.p8')
ASC_BASE = 'https://api.appstoreconnect.apple.com/v1'

PLATFORM_MAP = {
  'macos' => 'MAC_OS',
  'ios' => 'IOS'
}.freeze

# Screenshot dimensions and ASC display types keyed by .saneprocess screenshot keys
SCREENSHOT_VARIANTS = {
  'MAC_OS' => [
    { key: 'macos', display_type: 'APP_DESKTOP', width: 2880, height: 1800 }
  ],
  'IOS' => [
    { key: 'ios', display_type: 'APP_IPHONE_67', width: 1290, height: 2796 },
    { key: 'ios_65', display_type: 'APP_IPHONE_65', width: 1242, height: 2688 },
    # Apple uses APP_IPAD_PRO_3GEN_129 for 12.9" iPad Pro screenshots in ASC.
    { key: 'ipad', display_type: 'APP_IPAD_PRO_3GEN_129', width: 2048, height: 2732 },
    { key: 'ipad_13', display_type: 'APP_IPAD_PRO_3GEN_129', width: 2048, height: 2732 },
    { key: 'ipad_12.9', display_type: 'APP_IPAD_PRO_3GEN_129', width: 2048, height: 2732 },
    { key: 'ipad_12_9', display_type: 'APP_IPAD_PRO_3GEN_129', width: 2048, height: 2732 }
  ]
}.freeze

BUILD_POLL_INTERVAL = 30   # seconds
BUILD_POLL_TIMEOUT = 2700  # 45 minutes

# ─── Logging ───

def log_info(msg)
  warn "\033[0;32m[ASC]\033[0m #{msg}"
end

def log_warn(msg)
  warn "\033[1;33m[ASC]\033[0m #{msg}"
end

def log_error(msg)
  warn "\033[0;31m[ASC]\033[0m #{msg}"
end

# ─── JWT Token Generation ───

def generate_jwt
  unless File.exist?(P8_PATH)
    log_error "API key not found: #{P8_PATH}"
    exit 1
  end

  private_key = OpenSSL::PKey::EC.new(File.read(P8_PATH))
  now = Time.now.to_i

  payload = {
    iss: ISSUER_ID,
    iat: now,
    exp: now + 1200, # 20 minutes
    aud: 'appstoreconnect-v1'
  }

  header = {
    kid: KEY_ID,
    typ: 'JWT'
  }

  JWT.encode(payload, private_key, 'ES256', header)
end

# ─── HTTP Helpers ───

def asc_request(method, path, body: nil, token: nil)
  token ||= generate_jwt
  uri = URI("#{ASC_BASE}#{path}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60

  request = case method
            when :get    then Net::HTTP::Get.new(uri)
            when :post   then Net::HTTP::Post.new(uri)
            when :patch  then Net::HTTP::Patch.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            end

  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'

  if body
    request.body = body.is_a?(String) ? body : JSON.generate(body)
  end

  response = http.request(request)

  unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated) || response.code == '409'
    log_error "ASC API #{method.upcase} #{path} → #{response.code}"
    log_error response.body[0..500] if response.body
    return nil
  end

  return {} if response.body.nil? || response.body.empty?

  JSON.parse(response.body)
rescue StandardError => e
  log_error "ASC API error: #{e.message}"
  nil
end

def asc_get(path, token: nil)
  asc_request(:get, path, token: token)
end

def asc_post(path, body:, token: nil)
  asc_request(:post, path, body: body, token: token)
end

def asc_patch(path, body:, token: nil)
  asc_request(:patch, path, body: body, token: token)
end

def asc_delete(path, token: nil)
  asc_request(:delete, path, token: token)
end

# ─── Upload Build ───

def upload_build(pkg_path)
  log_info "Uploading #{File.basename(pkg_path)} via altool..."

  cmd = [
    'xcrun', 'altool', '--upload-app',
    '-f', pkg_path,
    '--apiKey', KEY_ID,
    '--apiIssuer', ISSUER_ID,
    '-t', pkg_path.end_with?('.ipa') ? 'ios' : 'macos'
  ]

  output = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  success = $?.success?

  if success
    log_info 'Upload complete.'
  else
    if output.include?('already been uploaded') || output.include?('already exists')
      log_info 'Build already uploaded — continuing.'
      return true
    end
    log_error "altool upload failed:\n#{output}"
    return false
  end

  true
end

# ─── Poll for Build Processing ───

def wait_for_build(app_id, version, asc_platform, token)
  log_info "Waiting for build #{version} to finish processing (up to #{BUILD_POLL_TIMEOUT / 60} min)..."

  deadline = Time.now + BUILD_POLL_TIMEOUT
  build_id = nil

  while Time.now < deadline
    path = "/builds?filter[app]=#{app_id}&filter[version]=#{version}" \
           "&filter[processingState]=PROCESSING,VALID,INVALID" \
           "&sort=-uploadedDate&limit=5"
    resp = asc_get(path, token: token)

    if resp && resp['data']
      # Find build matching our platform
      build = resp['data'].find do |b|
        attrs = b['attributes'] || {}
        attrs['version'].to_s == version.to_s
      end

      if build
        state = build.dig('attributes', 'processingState')
        build_id = build['id']

        case state
        when 'VALID'
          log_info "Build #{version} processed successfully (ID: #{build_id})"
          return build_id
        when 'INVALID'
          log_error "Build #{version} failed processing (INVALID)"
          return nil
        else
          log_info "Build processing... (#{state})"
        end
      else
        log_info 'Build not yet visible in ASC...'
      end
    end

    sleep BUILD_POLL_INTERVAL
  end

  log_error "Build processing timed out after #{BUILD_POLL_TIMEOUT / 60} minutes"
  nil
end

# ─── App Version Management ───

def find_editable_version(app_id, asc_platform, version_string, token)
  # Look for an editable version.
  # READY_FOR_REVIEW still accepts metadata/screenshot updates in ASC for some flows.
  path = "/apps/#{app_id}/appStoreVersions" \
         "?filter[platform]=#{asc_platform}" \
         "&filter[appStoreState]=PREPARE_FOR_SUBMISSION,REJECTED,READY_FOR_REVIEW"
  resp = asc_get(path, token: token)

  return nil unless resp && resp['data']

  resp['data'].find do |v|
    v.dig('attributes', 'versionString') == version_string
  end
end

def find_or_create_version(app_id, asc_platform, version_string, token)
  # Check for existing editable version
  version = find_editable_version(app_id, asc_platform, version_string, token)
  if version
    log_info "Found existing version #{version_string} (#{version.dig('attributes', 'appStoreState')})"
    return version['id']
  end

  # Also check WAITING_FOR_REVIEW — if already submitted, we're done
  path = "/apps/#{app_id}/appStoreVersions" \
         "?filter[platform]=#{asc_platform}" \
         "&filter[appStoreState]=WAITING_FOR_REVIEW,IN_REVIEW"
  resp = asc_get(path, token: token)

  if resp && resp['data']
    already_submitted = resp['data'].find do |v|
      v.dig('attributes', 'versionString') == version_string
    end
    if already_submitted
      state = already_submitted.dig('attributes', 'appStoreState')
      log_info "Version #{version_string} is already #{state} — nothing to do."
      return :already_submitted
    end
  end

  # Create new version
  log_info "Creating new App Store version #{version_string}..."
  body = {
    data: {
      type: 'appStoreVersions',
      attributes: {
        platform: asc_platform,
        versionString: version_string
      },
      relationships: {
        app: {
          data: { type: 'apps', id: app_id }
        }
      }
    }
  }

  resp = asc_post('/appStoreVersions', body: body, token: token)
  if resp && resp.dig('data', 'id')
    log_info "Created version #{version_string} (ID: #{resp['data']['id']})"
    resp['data']['id']
  else
    log_error "Failed to create version #{version_string}"
    nil
  end
end

# ─── Build Attachment ───

def attach_build_to_version(version_id, build_id, token)
  log_info "Attaching build #{build_id} to version #{version_id}..."

  body = {
    data: {
      type: 'builds',
      id: build_id
    }
  }

  resp = asc_patch(
    "/appStoreVersions/#{version_id}/relationships/build",
    body: body,
    token: token
  )

  if resp
    log_info 'Build attached to version.'
    true
  else
    log_error 'Failed to attach build to version.'
    false
  end
end

# ─── Review Contact Detail ───

def ensure_review_detail(version_id, contact, token)
  # Check if review detail already exists
  path = "/appStoreVersions/#{version_id}/appStoreReviewDetail"
  resp = asc_get(path, token: token)

  if resp && resp.dig('data', 'id')
    detail_id = resp['data']['id']
    existing = resp['data']['attributes'] || {}

    # Update if contact info doesn't match
    needs_update = existing['contactFirstName'] != contact[:first_name] ||
                   existing['contactLastName'] != contact[:last_name] ||
                   existing['contactPhone'] != contact[:phone] ||
                   existing['contactEmail'] != contact[:email]

    if needs_update
      log_info 'Updating review contact detail...'
      body = {
        data: {
          type: 'appStoreReviewDetails',
          id: detail_id,
          attributes: {
            contactFirstName: contact[:first_name],
            contactLastName: contact[:last_name],
            contactPhone: contact[:phone],
            contactEmail: contact[:email]
          }
        }
      }
      asc_patch("/appStoreReviewDetails/#{detail_id}", body: body, token: token)
    else
      log_info 'Review contact detail already correct.'
    end
    return true
  end

  # Create review detail
  log_info 'Creating review contact detail...'
  body = {
    data: {
      type: 'appStoreReviewDetails',
      attributes: {
        contactFirstName: contact[:first_name],
        contactLastName: contact[:last_name],
        contactPhone: contact[:phone],
        contactEmail: contact[:email]
      },
      relationships: {
        appStoreVersion: {
          data: { type: 'appStoreVersions', id: version_id }
        }
      }
    }
  }

  resp = asc_post('/appStoreReviewDetails', body: body, token: token)
  if resp
    log_info 'Review contact detail created.'
    true
  else
    log_error 'Failed to create review contact detail.'
    false
  end
end

# ─── Screenshot Management ───

def resize_screenshot(src, target_w, target_h)
  tmp = "/tmp/screenshot_canvas_#{SecureRandom.hex(4)}.png"

  # Resize to target width maintaining aspect ratio
  system('sips', '--resampleWidth', target_w.to_s, src, '--out', tmp,
         out: File::NULL, err: File::NULL)

  # Pad to exact dimensions if needed (dark background)
  system('sips', '--padToHeightWidth', target_h.to_s, target_w.to_s,
         '--padColor', '1E1E23', tmp,
         out: File::NULL, err: File::NULL)

  tmp
end

def screenshot_jobs_for(platform, config)
  variants = SCREENSHOT_VARIANTS[platform] || []
  screenshots_config = config.dig('appstore', 'screenshots') || {}
  jobs = []
  seen_display_types = {}

  variants.each do |variant|
    glob = screenshots_config[variant[:key]]
    next unless glob
    next if seen_display_types[variant[:display_type]]

    jobs << variant.merge(glob: glob)
    seen_display_types[variant[:display_type]] = true
  end

  jobs
end

def upload_screenshot_set(localization_id, files, spec, token)
  # Fetch all sets, then match by display type locally.
  # ASC filtering here has been inconsistent and can return mixed sets.
  sets_path = "/appStoreVersionLocalizations/#{localization_id}/appScreenshotSets"
  sets_resp = asc_get(sets_path, token: token)

  screenshot_set_id = nil
  matching_set = if sets_resp && sets_resp['data']
                   sets_resp['data'].find { |set| set.dig('attributes', 'screenshotDisplayType') == spec[:display_type] }
                 end

  if matching_set
    screenshot_set_id = matching_set['id']

    # Delete existing screenshots in this set (replace with new ones)
    existing_path = "/appScreenshotSets/#{screenshot_set_id}/appScreenshots"
    existing_resp = asc_get(existing_path, token: token)
    if existing_resp && existing_resp['data']
      existing_resp['data'].each do |ss|
        state = ss.dig('attributes', 'assetDeliveryState', 'state')
        if %w[UPLOAD_COMPLETE COMPLETE FAILED].include?(state)
          asc_delete("/appScreenshots/#{ss['id']}", token: token)
        end
      end
    end
  else
    # Create screenshot set
    body = {
      data: {
        type: 'appScreenshotSets',
        attributes: {
          screenshotDisplayType: spec[:display_type]
        },
        relationships: {
          appStoreVersionLocalization: {
            data: { type: 'appStoreVersionLocalizations', id: localization_id }
          }
        }
      }
    }
    resp = asc_post('/appScreenshotSets', body: body, token: token)
    screenshot_set_id = resp&.dig('data', 'id')
  end

  return unless screenshot_set_id

  files.each_with_index do |file, idx|
    log_info "Uploading #{spec[:display_type]} screenshot #{idx + 1}/#{files.length}: #{File.basename(file)}"

    resized = resize_screenshot(file, spec[:width], spec[:height])
    file_size = File.size(resized)
    file_name = File.basename(file)

    body = {
      data: {
        type: 'appScreenshots',
        attributes: {
          fileName: file_name,
          fileSize: file_size
        },
        relationships: {
          appScreenshotSet: {
            data: { type: 'appScreenshotSets', id: screenshot_set_id }
          }
        }
      }
    }

    reservation = asc_post('/appScreenshots', body: body, token: token)
    unless reservation && reservation.dig('data', 'id')
      log_warn "Failed to reserve upload slot for #{file_name}"
      File.delete(resized) if File.exist?(resized)
      next
    end

    screenshot_id = reservation['data']['id']
    upload_ops = reservation.dig('data', 'attributes', 'uploadOperations') || []

    upload_ops.each do |op|
      upload_url = op['url']
      offset = op['offset']
      length = op['length']
      headers = op['requestHeaders'] || []

      chunk = File.binread(resized, length, offset)

      uri = URI(upload_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 120

      req = Net::HTTP::Put.new(uri)
      headers.each { |h| req[h['name']] = h['value'] }
      req.body = chunk

      http.request(req)
    end

    source_checksum = Digest::MD5.hexdigest(File.binread(resized))
    commit_body = {
      data: {
        type: 'appScreenshots',
        id: screenshot_id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: source_checksum
        }
      }
    }
    asc_patch("/appScreenshots/#{screenshot_id}", body: commit_body, token: token)

    File.delete(resized) if File.exist?(resized)
  end
end

def upload_screenshots(version_id, platform, project_root, config, token)
  jobs = screenshot_jobs_for(platform, config)
  return if jobs.empty?

  # Get the version's localizations to find where to attach screenshots
  path = "/appStoreVersions/#{version_id}/appStoreVersionLocalizations"
  resp = asc_get(path, token: token)
  return unless resp && resp['data'] && !resp['data'].empty?

  localization_id = resp['data'].first['id']

  jobs.each do |job|
    pattern = File.join(project_root, job[:glob])
    files = Dir.glob(pattern).sort
    if files.empty?
      log_warn "No screenshots found matching: #{pattern}"
      next
    end
    log_info "Found #{files.length} screenshot(s) for #{job[:display_type]}"
    upload_screenshot_set(localization_id, files, job, token)
  end

  log_info "Screenshot upload complete for #{platform}"
end

# ─── Submit for Review ───

def submit_for_review(app_id, asc_platform, version_id, token)
  log_info 'Submitting for App Review...'

  submission_body = {
    data: {
      type: 'reviewSubmissions',
      relationships: {
        app: {
          data: { type: 'apps', id: app_id }
        }
      }
    }
  }

  uri = URI("https://api.appstoreconnect.apple.com/v1/reviewSubmissions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(submission_body)

  response = http.request(req)
  submission_id = nil

  if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
    parsed = JSON.parse(response.body) rescue {}
    submission_id = parsed.dig('data', 'id')
  elsif response.code == '409'
    list = asc_get("/reviewSubmissions?filter[app]=#{app_id}&limit=50", token: token)
    submission = list&.fetch('data', [])&.find do |s|
      (s.dig('attributes', 'platform') == asc_platform || s.dig('attributes', 'platform').nil?) &&
        s.dig('attributes', 'state') == 'READY_FOR_REVIEW'
    end
    submission_id = submission&.[]('id')
  end

  unless submission_id
    log_error "Submit for review failed: #{response.code}"
    log_error response.body[0..500] if response.body
    return false
  end

  item_body = {
    data: {
      type: 'reviewSubmissionItems',
      relationships: {
        reviewSubmission: { data: { type: 'reviewSubmissions', id: submission_id } },
        appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } }
      }
    }
  }

  item_resp = asc_post('/reviewSubmissionItems', body: item_body, token: token)
  if item_resp
    log_info 'Successfully submitted for review!'
    return true
  end

  log_warn 'Could not create reviewSubmissionItem automatically. App may require manual resubmission in ASC UI.'
  false
end

def default_build_number(version)
  normalized = version.tr('.', '').sub(/^0+/, '')
  normalized.empty? ? '1' : normalized
end

def extract_build_number_from_package(pkg_path)
  return nil unless pkg_path.end_with?('.ipa')

  Dir.mktmpdir('asc_info_plist') do |tmpdir|
    unzip_ok = system("unzip -qq -o #{Shellwords.escape(pkg_path)} 'Payload/*.app/Info.plist' -d #{Shellwords.escape(tmpdir)} >/dev/null 2>&1")
    return nil unless unzip_ok

    info_path = Dir.glob(File.join(tmpdir, 'Payload', '*.app', 'Info.plist')).first
    return nil unless info_path && File.exist?(info_path)

    bundle_version = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleVersion' #{Shellwords.escape(info_path)} 2>/dev/null`.strip
    bundle_version.empty? ? nil : bundle_version
  end
end

# ─── Main ───

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: appstore_submit.rb [options]'

  opts.on('--pkg PATH', 'Path to .pkg or .ipa') { |v| options[:pkg] = v }
  opts.on('--app-id ID', 'App Store Connect app ID') { |v| options[:app_id] = v }
  opts.on('--version VERSION', 'Version string (e.g. 1.0.1)') { |v| options[:version] = v }
  opts.on('--build-number NUMBER', 'Build number override (CFBundleVersion)') { |v| options[:build_number] = v }
  opts.on('--platform PLATFORM', 'macos or ios') { |v| options[:platform] = v }
  opts.on('--project-root PATH', 'Project root directory') { |v| options[:project_root] = v }
  opts.on('--skip-upload', 'Skip binary upload; use existing processed build in ASC') { options[:skip_upload] = true }
  opts.on('--test-screenshots', 'Test screenshot resize only (no API calls)') { options[:test_screenshots] = true }
end.parse!

require 'shellwords'
require 'digest'

# Test screenshots mode
if options[:test_screenshots]
  project_root = options[:project_root] || Dir.pwd
  config_path = File.join(project_root, '.saneprocess')
  unless File.exist?(config_path)
    log_error "No .saneprocess found at #{config_path}"
    exit 1
  end

  config = YAML.safe_load(File.read(config_path)) || {}
  platform = options[:platform] || 'macos'
  asc_platform = PLATFORM_MAP[platform]
  jobs = screenshot_jobs_for(asc_platform, config)

  if jobs.empty?
    log_warn "No screenshot jobs configured for #{asc_platform} in .saneprocess"
    exit 0
  end

  jobs.each do |job|
    pattern = File.join(project_root, job[:glob])
    files = Dir.glob(pattern).sort
    log_info "Found #{files.length} screenshot(s) matching #{pattern} for #{job[:display_type]}"
    files.each do |f|
      resized = resize_screenshot(f, job[:width], job[:height])
      dims = `sips -g pixelWidth -g pixelHeight #{Shellwords.escape(resized)} 2>/dev/null`
      log_info "  #{File.basename(f)} → #{job[:width]}x#{job[:height]} (#{resized})"
      log_info "    #{dims.strip.split("\n").last(2).join(', ')}"
      File.delete(resized) if File.exist?(resized)
    end
  end
  log_info 'Screenshot test complete (no API calls made).'
  exit 0
end

# Validate required options
required = %i[app_id version platform project_root]
required << :pkg unless options[:skip_upload]
required.each do |key|
  unless options[key]
    log_error "Missing required option: --#{key.to_s.tr('_', '-')}"
    exit 1
  end
end

pkg_path = options[:pkg]
app_id = options[:app_id]
version = options[:version]
platform = options[:platform]
project_root = options[:project_root]

asc_platform = PLATFORM_MAP[platform]
unless asc_platform
  log_error "Unknown platform: #{platform} (use macos or ios)"
  exit 1
end

if !options[:skip_upload] && !File.exist?(pkg_path)
  log_error "Package not found: #{pkg_path}"
  exit 1
end

# Load config for contact info and screenshots
config_path = File.join(project_root, '.saneprocess')
config = if File.exist?(config_path)
           YAML.safe_load(File.read(config_path)) || {}
         else
           {}
         end

artifact_label = options[:skip_upload] ? 'existing ASC build' : File.basename(pkg_path)
log_info "App Store submission: #{artifact_label} v#{version} (#{platform})"
log_info "App ID: #{app_id}"

token = generate_jwt

# Step 1: Upload build
unless options[:skip_upload]
  unless upload_build(pkg_path)
    log_error 'Build upload failed. Aborting.'
    exit 1
  end
else
  log_info 'Skipping binary upload (--skip-upload).'
end

# Step 2: Wait for processing
build_number =
  if options[:build_number]
    options[:build_number]
  elsif options[:skip_upload]
    default_build_number(version)
  else
    extract_build_number_from_package(pkg_path) || default_build_number(version)
  end
build_id = wait_for_build(app_id, build_number, asc_platform, token)
unless build_id
  # Try with the version string itself (some projects use version as build number)
  log_info "Retrying build lookup with version string #{version}..."
  build_id = wait_for_build(app_id, version, asc_platform, token)
end

unless build_id
  log_error 'Build not found after processing. Check App Store Connect manually.'
  exit 1
end

# Step 3: Find or create version
version_id = find_or_create_version(app_id, asc_platform, version, token)

if version_id == :already_submitted
  log_info 'Version already submitted for review. Done!'
  exit 0
end

unless version_id
  log_error "Failed to find or create version #{version}."
  exit 1
end

# Step 4: Attach build
# Refresh token (may have expired during polling)
token = generate_jwt
unless attach_build_to_version(version_id, build_id, token)
  log_error 'Failed to attach build. Continuing to try review submission...'
end

# Step 5: Ensure review contact detail
contact_name = config.dig('appstore', 'contact', 'name') || ''
name_parts = contact_name.split(' ', 2)
contact = {
  first_name: name_parts[0] || 'Stephan',
  last_name: name_parts[1] || 'Joseph',
  phone: config.dig('appstore', 'contact', 'phone') || '+17277589785',
  email: config.dig('appstore', 'contact', 'email') || 'hi@saneapps.com'
}
ensure_review_detail(version_id, contact, token)

# Step 6: Upload screenshots (if configured)
upload_screenshots(version_id, asc_platform, project_root, config, token)

# Step 7: Submit for review
token = generate_jwt
if submit_for_review(app_id, asc_platform, version_id, token)
  log_info ''
  log_info '═══════════════════════════════════════════'
  log_info "  APP STORE SUBMISSION COMPLETE"
  log_info "  #{app_id} v#{version} (#{platform})"
  log_info '═══════════════════════════════════════════'
else
  log_error 'Review submission failed. Check App Store Connect manually.'
  exit 1
end
