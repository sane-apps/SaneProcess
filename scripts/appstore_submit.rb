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
require 'shellwords'
require 'digest'
require 'time'
require 'uri'
require 'yaml'
require 'tmpdir'
require 'open3'

begin
  require 'jwt'
rescue LoadError
  warn 'Missing required gem: jwt'
  warn 'Install with: gem install jwt'
  exit 1
end

# ─── Headless Secret Fallback ───

def parse_env_file(path)
  return unless File.file?(path)

  File.foreach(path) do |line|
    next if line.strip.empty? || line.lstrip.start_with?('#')

    text = line.sub(/\A\s*export\s+/, '').strip
    next unless text.include?('=')

    key, raw_value = text.split('=', 2)
    key = key.to_s.strip
    next if key.empty? || ENV.key?(key)

    value = raw_value.to_s.strip
    if value.start_with?('"') && value.end_with?('"') && value.length >= 2
      value = value[1..-2]
    elsif value.start_with?("'") && value.end_with?("'") && value.length >= 2
      value = value[1..-2]
    end
    ENV[key] = value
  end
end

def keychain_secret(service, account = nil)
  cmd = ['security', 'find-generic-password', '-w', '-s', service]
  cmd += ['-a', account] if account && !account.empty?
  out, status = Open3.capture2e(*cmd)
  return out.strip if status.success?
  ''
rescue StandardError
  ''
end

def set_env_if_missing(key, value)
  return if key.to_s.empty? || value.to_s.empty?
  return if ENV.key?(key) && !ENV[key].to_s.empty?

  ENV[key] = value
end

def hydrate_headless_env
  files = [
    ENV['SANEPROCESS_SECRETS_FILE'],
    File.expand_path('~/.config/saneprocess/secrets.env'),
    File.expand_path('~/.saneprocess/secrets.env')
  ].compact

  files.each do |path|
    next unless File.file?(path)
    parse_env_file(path)
    break
  end

  set_env_if_missing('ASC_AUTH_KEY_ID', keychain_secret('saneprocess.asc.key_id', 'asc_key_id'))
  set_env_if_missing('ASC_AUTH_KEY_ID', keychain_secret('saneprocess.asc.key_id'))
  set_env_if_missing('ASC_AUTH_ISSUER_ID', keychain_secret('saneprocess.asc.issuer_id', 'asc_issuer_id'))
  set_env_if_missing('ASC_AUTH_ISSUER_ID', keychain_secret('saneprocess.asc.issuer_id'))
  set_env_if_missing('ASC_AUTH_KEY_PATH', keychain_secret('saneprocess.asc.key_path', 'asc_key_path'))
  set_env_if_missing('ASC_AUTH_KEY_PATH', keychain_secret('saneprocess.asc.key_path'))
end

hydrate_headless_env

# ─── Configuration ───

ISSUER_ID = ENV['ASC_AUTH_ISSUER_ID'] || ENV['ASC_ISSUER_ID'] || 'c98b1e0a-8d10-4fce-a417-536b31c09bfb'
KEY_ID = ENV['ASC_AUTH_KEY_ID'] || ENV['ASC_KEY_ID'] || 'S34998ZCRT'
P8_PATH = File.expand_path(
  ENV['ASC_AUTH_KEY_PATH'] || ENV['ASC_KEY_PATH'] || '~/.private_keys/AuthKey_S34998ZCRT.p8'
)
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
SUBMISSION_POLL_INTERVAL = 8
SUBMISSION_POLL_TIMEOUT = 180

SUBMITTED_APP_STORE_STATES = %w[
  WAITING_FOR_REVIEW
  IN_REVIEW
  PENDING_APPLE_RELEASE
  PENDING_DEVELOPER_RELEASE
  PROCESSING_FOR_DISTRIBUTION
  READY_FOR_SALE
].freeze

CATEGORY_ID_MAP = {
  'public.app-category.utilities' => 'UTILITIES',
  'public.app-category.productivity' => 'PRODUCTIVITY',
  'public.app-category.finance' => 'FINANCE',
  'public.app-category.business' => 'BUSINESS'
}.freeze

AGE_RATING_SAFE_DEFAULTS = {
  advertising: false,
  alcoholTobaccoOrDrugUseOrReferences: 'NONE',
  contests: 'NONE',
  gambling: false,
  gamblingSimulated: 'NONE',
  gunsOrOtherWeapons: 'NONE',
  healthOrWellnessTopics: false,
  lootBox: false,
  medicalOrTreatmentInformation: 'NONE',
  messagingAndChat: false,
  parentalControls: false,
  profanityOrCrudeHumor: 'NONE',
  ageAssurance: false,
  sexualContentGraphicAndNudity: 'NONE',
  sexualContentOrNudity: 'NONE',
  horrorOrFearThemes: 'NONE',
  matureOrSuggestiveThemes: 'NONE',
  unrestrictedWebAccess: false,
  userGeneratedContent: false,
  violenceCartoonOrFantasy: 'NONE',
  violenceRealisticProlongedGraphicOrSadistic: 'NONE',
  violenceRealistic: 'NONE',
  ageRatingOverrideV2: 'NONE',
  koreaAgeRatingOverride: 'NONE'
}.freeze

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

def asc_request(method, path, body: nil, token: nil, retry_on_unauthorized: true)
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

  if response.code == '401' && retry_on_unauthorized
    log_warn "ASC API #{method.upcase} #{path} returned 401; refreshing token and retrying once..."
    return asc_request(
      method,
      path,
      body: body,
      token: generate_jwt,
      retry_on_unauthorized: false
    )
  end

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

def asc_post_with_status(path, body:, token: nil)
  token ||= generate_jwt
  uri = URI("#{ASC_BASE}#{path}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60

  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'
  request.body = body.is_a?(String) ? body : JSON.generate(body)

  response = http.request(request)
  parsed = begin
    JSON.parse(response.body.to_s)
  rescue StandardError
    { 'raw' => response.body.to_s }
  end
  [response.code.to_i, parsed]
rescue StandardError => e
  log_error "ASC API raw POST error: #{e.message}"
  [0, { 'error' => e.message }]
end

def asc_patch_with_status(path, body:, token: nil)
  token ||= generate_jwt
  uri = URI("#{ASC_BASE}#{path}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60

  request = Net::HTTP::Patch.new(uri)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'
  request.body = body.is_a?(String) ? body : JSON.generate(body)

  response = http.request(request)
  parsed = begin
    JSON.parse(response.body.to_s)
  rescue StandardError
    { 'raw' => response.body.to_s }
  end
  [response.code.to_i, parsed]
rescue StandardError => e
  log_error "ASC API raw PATCH error: #{e.message}"
  [0, { 'error' => e.message }]
end

def asc_delete_with_status(path, token: nil)
  token ||= generate_jwt
  uri = URI("#{ASC_BASE}#{path}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60

  request = Net::HTTP::Delete.new(uri)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'

  response = http.request(request)
  parsed = begin
    JSON.parse(response.body.to_s)
  rescue StandardError
    { 'raw' => response.body.to_s }
  end
  [response.code.to_i, parsed]
rescue StandardError => e
  log_error "ASC API raw DELETE error: #{e.message}"
  [0, { 'error' => e.message }]
end

# ─── Package Metadata ───

def extract_app_info_from_package(pkg_path)
  read_plist = lambda do |info_path|
    return nil unless info_path && File.exist?(info_path)

    bundle_id = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleIdentifier' #{Shellwords.escape(info_path)} 2>/dev/null`.strip
    short_version = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleShortVersionString' #{Shellwords.escape(info_path)} 2>/dev/null`.strip
    build_number = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleVersion' #{Shellwords.escape(info_path)} 2>/dev/null`.strip

    return nil if bundle_id.empty? || short_version.empty? || build_number.empty?

    {
      bundle_id: bundle_id,
      short_version: short_version,
      build_number: build_number
    }
  end

  if pkg_path.end_with?('.ipa')
    Dir.mktmpdir('asc_info_plist') do |tmpdir|
      unzip_ok = system("unzip -qq -o #{Shellwords.escape(pkg_path)} 'Payload/*.app/Info.plist' -d #{Shellwords.escape(tmpdir)} >/dev/null 2>&1")
      return nil unless unzip_ok

      info_path = Dir.glob(File.join(tmpdir, 'Payload', '*.app', 'Info.plist')).first
      return read_plist.call(info_path)
    end
  elsif pkg_path.end_with?('.pkg')
    Dir.mktmpdir('asc_pkg_info') do |tmpdir|
      expanded = File.join(tmpdir, 'expanded')
      expand_ok = system('pkgutil', '--expand-full', pkg_path, expanded, out: File::NULL, err: File::NULL)
      return nil unless expand_ok

      candidates = Dir.glob(File.join(expanded, '**', 'Payload', '*.app', 'Contents', 'Info.plist'))
      info_path = candidates.find { |p| !p.include?('/Frameworks/') && !p.include?('/PlugIns/') } || candidates.first
      return read_plist.call(info_path)
    end
  end

  nil
end

# ─── Upload Build ───

def upload_build(pkg_path, app_id:, version:)
  log_info "Uploading #{File.basename(pkg_path)} via altool..."

  package_info = extract_app_info_from_package(pkg_path)
  cmd =
    if package_info
      [
        'xcrun', 'altool', '--upload-package', pkg_path,
        '-t', pkg_path.end_with?('.ipa') ? 'ios' : 'macos',
        '--apple-id', app_id,
        '--bundle-id', package_info[:bundle_id],
        '--bundle-version', package_info[:build_number],
        '--bundle-short-version-string', package_info[:short_version],
        '--wait',
        '--apiKey', KEY_ID,
        '--apiIssuer', ISSUER_ID
      ]
    else
      [
        'xcrun', 'altool', '--upload-app',
        '-f', pkg_path,
        '--apiKey', KEY_ID,
        '--apiIssuer', ISSUER_ID,
        '-t', pkg_path.end_with?('.ipa') ? 'ios' : 'macos'
      ]
    end

  output = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  success = $?.success?
  output_failure_patterns = [
    /upload failed/i,
    /validation failed/i,
    /state_error\.validation_error/i,
    /missing info\.plist/i,
    /app sandbox not enabled/i
  ]
  reported_failure = output_failure_patterns.any? { |pattern| output.match?(pattern) }

  if success && !reported_failure
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
           "&filter[preReleaseVersion.platform]=#{asc_platform}" \
           "&filter[processingState]=PROCESSING,VALID,INVALID" \
           "&sort=-uploadedDate&limit=5&include=preReleaseVersion"
    resp = asc_get(path, token: token)

    if resp && resp['data']
      pr_versions = {}
      (resp['included'] || []).each do |entry|
        next unless entry['type'] == 'preReleaseVersions'

        pr_versions[entry['id']] = entry.dig('attributes', 'platform')
      end

      # Find build matching our platform
      build = resp['data'].find do |b|
        attrs = b['attributes'] || {}
        next false unless attrs['version'].to_s == version.to_s

        pr_id = b.dig('relationships', 'preReleaseVersion', 'data', 'id')
        platform = pr_versions[pr_id]
        platform.nil? || platform == asc_platform
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
         "&filter[appStoreState]=PREPARE_FOR_SUBMISSION,REJECTED,DEVELOPER_REJECTED,READY_FOR_REVIEW"
  resp = asc_get(path, token: token)

  return nil unless resp && resp['data']

  resp['data'].find do |v|
    v.dig('attributes', 'versionString') == version_string
  end
end

def check_version_state_preflight(app_id, asc_platform, version_string, token)
  path = "/apps/#{app_id}/appStoreVersions" \
         "?filter[platform]=#{asc_platform}" \
         "&filter[appStoreState]=PREPARE_FOR_SUBMISSION,REJECTED,DEVELOPER_REJECTED,READY_FOR_REVIEW"
  resp = asc_get(path, token: token)
  return false unless resp
  return true unless resp['data'] && !resp['data'].empty?

  matching = resp['data'].find do |v|
    v.dig('attributes', 'versionString') == version_string
  end
  if matching
    linked_submission = find_linked_review_submission(app_id, asc_platform, matching['id'], token)
    if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
      log_unresolved_submission_blocker(app_id, matching['id'], linked_submission)
      return false
    end
    log_info "ASC editable version preflight passed for #{version_string} (#{matching.dig('attributes', 'appStoreState')})."
    return true
  end

  conflict = resp['data'].first
  conflict_version = conflict.dig('attributes', 'versionString') || 'unknown'
  conflict_state = conflict.dig('attributes', 'appStoreState') || 'unknown'
  log_error "Editable App Store version conflict: #{conflict_version} (#{conflict_state}) exists, but release target is #{version_string}."
  log_error "Update the existing draft to version #{version_string}, or clear that draft before submission."
  false
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

  code, resp = asc_patch_with_status(
    "/appStoreVersions/#{version_id}/relationships/build",
    body: body,
    token: token
  )

  if [200, 201, 202, 204].include?(code)
    log_info 'Build attached to version.'
    true
  else
    detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
    log_error "Failed to attach build to version: #{detail}"
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
    desired_notes = contact[:notes].to_s.strip
    existing_notes = existing['notes'].to_s.strip
    needs_update = existing['contactFirstName'] != contact[:first_name] ||
                   existing['contactLastName'] != contact[:last_name] ||
                   existing['contactPhone'] != contact[:phone] ||
                   existing['contactEmail'] != contact[:email] ||
                   existing['demoAccountRequired'] != false ||
                   (!desired_notes.empty? && existing_notes != desired_notes)

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
            contactEmail: contact[:email],
            notes: desired_notes.empty? ? existing_notes : desired_notes,
            demoAccountRequired: false
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
        contactEmail: contact[:email],
        notes: contact[:notes].to_s,
        demoAccountRequired: false
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

# ─── Listing Metadata Hydration ───

def fallback_description(app_name, review_notes)
  note = review_notes.to_s.strip
  return note[0, 4000] unless note.empty?

  "#{app_name} helps you stay productive on Apple devices with a clear free tier and a Pro upgrade."
end

def fallback_keywords(app_name)
  base = app_name.to_s.downcase
  case base
  when 'sanebar'
    'menu bar,productivity,mac utility,organization,status icons'
  when 'saneclick'
    'finder,right click,automation,productivity,scripts,mac utility'
  when 'saneclip'
    'clipboard,copy paste,history,productivity,mac utility,snippets'
  when 'sanehosts'
    'hosts file,focus,privacy,utilities,blocklists,mac utility'
  when 'sanesales'
    'sales,analytics,revenue,dashboard,productivity,business'
  else
    'productivity,utility,mac'
  end
end

def latest_app_info_id(app_id, token)
  resp = asc_get("/apps/#{app_id}/appInfos?limit=10", token: token)
  return nil unless resp && resp['data'] && !resp['data'].empty?

  resp['data'].max_by { |info| info.dig('attributes', 'createdDate').to_s }['id']
end

def find_locale_record(path, token, locale: 'en-US')
  resp = asc_get(path, token: token)
  return nil unless resp && resp['data'] && !resp['data'].empty?

  resp['data'].find { |entry| entry.dig('attributes', 'locale') == locale } || resp['data'].first
end

def ensure_content_rights_declaration(app_id, declaration, token)
  return if declaration.to_s.strip.empty?

  app_resp = asc_get("/apps/#{app_id}", token: token)
  existing = app_resp&.dig('data', 'attributes', 'contentRightsDeclaration').to_s
  return if existing == declaration

  body = {
    data: {
      type: 'apps',
      id: app_id,
      attributes: { contentRightsDeclaration: declaration }
    }
  }
  asc_patch("/apps/#{app_id}", body: body, token: token)
end

def ensure_primary_category(app_info_id, category_id, token)
  return if app_info_id.to_s.empty? || category_id.to_s.empty?

  resp = asc_get("/appInfos/#{app_info_id}/primaryCategory", token: token)
  return if resp && resp.dig('data', 'id') == category_id

  body = {
    data: {
      type: 'appInfos',
      id: app_info_id,
      relationships: {
        primaryCategory: {
          data: { type: 'appCategories', id: category_id }
        }
      }
    }
  }
  asc_patch("/appInfos/#{app_info_id}", body: body, token: token)
end

def ensure_app_info_localization(app_info_id, privacy_policy_url, token, locale: 'en-US')
  return if app_info_id.to_s.empty? || privacy_policy_url.to_s.strip.empty?

  loc = find_locale_record("/appInfos/#{app_info_id}/appInfoLocalizations?limit=50", token, locale: locale)
  return unless loc

  current = loc.dig('attributes', 'privacyPolicyUrl').to_s.strip
  desired = privacy_policy_url.to_s.strip
  return if desired.empty? || current == desired

  body = {
    data: {
      type: 'appInfoLocalizations',
      id: loc['id'],
      attributes: { privacyPolicyUrl: desired }
    }
  }
  asc_patch("/appInfoLocalizations/#{loc['id']}", body: body, token: token)
end

def ensure_version_localization(version_id, description, keywords, support_url, token, locale: 'en-US')
  loc = find_locale_record("/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50", token, locale: locale)
  return unless loc

  attrs = {}
  desc = description.to_s.strip
  kw = keywords.to_s.strip
  sup = support_url.to_s.strip

  attrs[:description] = desc unless desc.empty?
  attrs[:keywords] = kw unless kw.empty?
  attrs[:supportUrl] = sup unless sup.empty?
  return if attrs.empty?

  body = {
    data: {
      type: 'appStoreVersionLocalizations',
      id: loc['id'],
      attributes: attrs
    }
  }
  asc_patch("/appStoreVersionLocalizations/#{loc['id']}", body: body, token: token)
end

def ensure_version_copyright(version_id, desired_value, token)
  return if desired_value.to_s.strip.empty?

  version_resp = asc_get("/appStoreVersions/#{version_id}", token: token)
  existing = version_resp&.dig('data', 'attributes', 'copyright').to_s.strip
  desired = desired_value.to_s.strip
  return if existing == desired

  body = {
    data: {
      type: 'appStoreVersions',
      id: version_id,
      attributes: { copyright: desired }
    }
  }
  asc_patch("/appStoreVersions/#{version_id}", body: body, token: token)
end

def ensure_age_rating_declaration(version_id, token)
  resp = asc_get("/appStoreVersions/#{version_id}/ageRatingDeclaration", token: token)
  age_id = resp&.dig('data', 'id')
  return if age_id.to_s.empty?

  body = {
    data: {
      type: 'ageRatingDeclarations',
      id: age_id,
      attributes: AGE_RATING_SAFE_DEFAULTS
    }
  }
  asc_patch("/ageRatingDeclarations/#{age_id}", body: body, token: token)
end

def ensure_build_export_compliance(build_id, token)
  return if build_id.to_s.empty?

  build_resp = asc_get("/builds/#{build_id}", token: token)
  uses_non_exempt = build_resp&.dig('data', 'attributes', 'usesNonExemptEncryption')
  return if uses_non_exempt == false

  body = {
    data: {
      type: 'builds',
      id: build_id,
      attributes: { usesNonExemptEncryption: false }
    }
  }
  asc_patch("/builds/#{build_id}", body: body, token: token)
end

def ensure_minimum_review_metadata(app_id:, version_id:, build_id:, config:, token:)
  appstore_cfg = config['appstore'] || {}
  app_name = config['name'].to_s.strip
  app_name = 'SaneApps' if app_name.empty?

  content_rights = appstore_cfg['content_rights_declaration'].to_s.strip
  content_rights = 'DOES_NOT_USE_THIRD_PARTY_CONTENT' if content_rights.empty?
  ensure_content_rights_declaration(app_id, content_rights, token)

  app_info_id = latest_app_info_id(app_id, token)
  category_id = CATEGORY_ID_MAP[appstore_cfg['category'].to_s.strip]
  ensure_primary_category(app_info_id, category_id, token) if app_info_id && category_id
  ensure_app_info_localization(app_info_id, appstore_cfg['privacy_policy_url'], token) if app_info_id

  description = appstore_cfg['description']
  description = fallback_description(app_name, appstore_cfg['review_notes']) if description.to_s.strip.empty?
  keywords = appstore_cfg['keywords']
  keywords = fallback_keywords(app_name) if keywords.to_s.strip.empty?
  ensure_version_localization(version_id, description, keywords, appstore_cfg['support_url'], token)

  default_copyright = "#{Time.now.year} SaneApps"
  ensure_version_copyright(version_id, appstore_cfg['copyright'].to_s.strip.empty? ? default_copyright : appstore_cfg['copyright'], token)
  ensure_age_rating_declaration(version_id, token)
  ensure_build_export_compliance(build_id, token)
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

  linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
  if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
    log_warn "Detected unresolved review submission #{linked_submission[:id]} for version #{version_id}."
    clear_stale_version_submission(version_id, token)
    token = generate_jwt
    linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
    if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
      log_unresolved_submission_blocker(app_id, version_id, linked_submission)
      return false
    end
  end

  # Preferred endpoint for final submission state transition.
  # Some API keys do not allow CREATE on appStoreVersionSubmissions; we detect
  # that and fall back to reviewSubmissions flow.
  version_submission_body = {
    data: {
      type: 'appStoreVersionSubmissions',
      relationships: {
        appStoreVersion: {
          data: { type: 'appStoreVersions', id: version_id }
        }
      }
    }
  }
  version_submission_code, version_submission_resp = asc_post_with_status(
    '/appStoreVersionSubmissions',
    body: version_submission_body,
    token: token
  )
  if [200, 201, 202, 409].include?(version_submission_code)
    log_info 'Created appStoreVersionSubmission.'
    return verify_submitted_state(version_id, token)
  end
  if version_submission_code == 403
    detail = version_submission_resp.dig('errors', 0, 'detail') || 'Forbidden'
    log_warn "appStoreVersionSubmissions create not allowed for this key: #{detail}"
    log_warn 'Falling back to reviewSubmissions flow.'
  end
  if version_submission_code != 403
    log_warn "Could not create appStoreVersionSubmission (HTTP #{version_submission_code}). Falling back to reviewSubmissions path."
  end

  submission_body = {
    data: {
      type: 'reviewSubmissions',
      attributes: {
        platform: asc_platform
      },
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
    parsed = JSON.parse(response.body) rescue {}
    associated = parsed.dig('errors', 0, 'meta', 'associatedErrors')
    summarize_associated_errors(associated) if associated.is_a?(Hash)
    submission_id = find_best_review_submission(app_id, asc_platform, version_id, token)
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

  if review_submission_has_version?(submission_id, version_id, token)
    log_info "Review submission #{submission_id} already contains appStoreVersion #{version_id}."
  else
    item_code, item_resp = asc_post_with_status('/reviewSubmissionItems', body: item_body, token: token)
    if [200, 201, 202].include?(item_code)
      log_info 'Review submission item created.'
    elsif item_code == 409
      conflict_submission_id = extract_conflict_submission_id(item_resp)
      if conflict_submission_id && conflict_submission_id != submission_id
        log_warn "Version belongs to existing review submission #{conflict_submission_id}; switching target."
        submission_id = conflict_submission_id
      elsif invalid_review_item_response?(item_resp)
        detail = item_resp.dig('errors', 0, 'detail') || item_resp.dig('errors', 0, 'title') || 'Item is invalid for review'
        log_error "Review submission item invalid: #{detail}"
        associated = item_resp.dig('errors', 0, 'meta', 'associatedErrors')
        summarize_associated_errors(associated) if associated.is_a?(Hash)
        return false
      else
        log_warn 'Review submission item already exists (409).'
      end
    else
      detail = item_resp.dig('errors', 0, 'detail') || item_resp.dig('errors', 0, 'title') || "HTTP #{item_code}"
      log_error "Could not create reviewSubmissionItem: #{detail}"
      return false
    end
  end

  token = generate_jwt
  unless review_submission_has_version?(submission_id, version_id, token)
    log_error "Review submission #{submission_id} does not include appStoreVersion #{version_id}."
    return false
  end
  log_info "Review submission includes appStoreVersion #{version_id}."

  linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
  if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
    log_warn "Review submission returned to unresolved state for version #{version_id}; attempting one automatic clear."
    clear_stale_version_submission(version_id, token)
    token = generate_jwt
    linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
    if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
      log_unresolved_submission_blocker(app_id, version_id, linked_submission)
      return false
    end
  end

  unless mark_review_submission_submitted(submission_id, token)
    log_error 'Failed to mark review submission as submitted.'
    return false
  end
  return verify_submitted_state(version_id, token)

end

def mark_review_submission_submitted(submission_id, token)
  attribute_variants = [
    { isSubmitted: true },
    { submitted: true },
    { state: 'SUBMITTED' }
  ]

  last_detail = nil
  attribute_variants.each do |attrs|
    body = {
      data: {
        type: 'reviewSubmissions',
        id: submission_id,
        attributes: attrs
      }
    }

    code, resp = asc_patch_with_status("/reviewSubmissions/#{submission_id}", body: body, token: token)
    if [200, 201, 202].include?(code)
      log_info "Review submission marked as submitted (#{attrs.keys.first})."
      return true
    end

    detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
    log_warn "Review submission submit attempt failed (#{attrs.keys.first}): #{detail}"
    associated = resp.dig('errors', 0, 'meta', 'associatedErrors')
    summarize_associated_errors(associated) if associated.is_a?(Hash)
    last_detail = detail
  end

  log_error "Review submission submit failed: #{last_detail || 'no accepted submission attribute'}"
  false
end

def summarize_associated_errors(associated_errors)
  associated_errors.each do |resource, errors|
    next unless errors.is_a?(Array)
    errors.first(5).each do |entry|
      message = entry['detail'] || entry['title'] || entry['code'] || 'Unknown associated error'
      log_warn "  ↳ #{resource}: #{message}"
    end
    next unless errors.length > 5

    log_warn "  ↳ #{resource}: ... #{errors.length - 5} more"
  end
end

def review_submission_has_version?(submission_id, version_id, token)
  resp = asc_get("/reviewSubmissions/#{submission_id}/items?include=appStoreVersion&limit=200", token: token)
  return false unless resp && resp['data']

  version_ids = []
  resp['data'].each do |item|
    linked_id = item.dig('relationships', 'appStoreVersion', 'data', 'id')
    version_ids << linked_id if linked_id
  end

  version_ids.include?(version_id)
end

def find_linked_review_submission(app_id, asc_platform, version_id, token)
  list = asc_get("/reviewSubmissions?filter[app]=#{app_id}&limit=200", token: token)
  return nil unless list && list['data']

  candidates = list['data'].select do |submission|
    platform = submission.dig('attributes', 'platform')
    platform == asc_platform || platform.nil?
  end

  match = candidates.find { |submission| review_submission_has_version?(submission['id'], version_id, token) }
  return nil unless match

  {
    id: match['id'],
    state: match.dig('attributes', 'state')
  }
end

def log_unresolved_submission_blocker(app_id, version_id, submission)
  return unless submission

  log_error "App Store version #{version_id} is linked to review submission #{submission[:id]} (#{submission[:state]})."
  log_error 'This is a previously submitted/rejected item, and App Store Connect API will not clear it automatically.'
  log_error "Open App Store Connect for app #{app_id}, remove/cancel the rejected item in that submission,"
  log_error 'then run appstore_submit.rb again to submit the updated build.'
end

def clear_stale_version_submission(version_id, token)
  code, resp = asc_delete_with_status("/appStoreVersionSubmissions/#{version_id}", token: token)
  case code
  when 204
    log_warn "Cleared stale appStoreVersionSubmission for version #{version_id}."
    true
  when 404
    log_warn "No appStoreVersionSubmission resource found for version #{version_id}."
    false
  else
    detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
    log_warn "Could not clear stale appStoreVersionSubmission for version #{version_id}: #{detail}"
    false
  end
end

def find_best_review_submission(app_id, asc_platform, version_id, token)
  list = asc_get("/reviewSubmissions?filter[app]=#{app_id}&limit=50", token: token)
  return nil unless list && list['data']

  candidates = list['data'].select do |s|
    platform = s.dig('attributes', 'platform')
    platform == asc_platform || platform.nil?
  end
  return nil if candidates.empty?

  with_version = candidates.find { |s| review_submission_has_version?(s['id'], version_id, token) }
  return with_version['id'] if with_version

  ready = candidates.find { |s| s.dig('attributes', 'state') == 'READY_FOR_REVIEW' }
  return ready['id'] if ready

  unresolved = candidates.find { |s| s.dig('attributes', 'state') == 'UNRESOLVED_ISSUES' }
  return unresolved['id'] if unresolved

  candidates.first['id']
end

def extract_conflict_submission_id(item_resp)
  return nil unless item_resp.is_a?(Hash)

  errors = item_resp['errors']
  return nil unless errors.is_a?(Array)

  errors.each do |err|
    detail = err['detail'].to_s
    next if detail.empty?

    match = detail.match(/reviewSubmission with id ([0-9a-f-]+)/i)
    return match[1] if match
  end

  nil
end

def invalid_review_item_response?(item_resp)
  return false unless item_resp.is_a?(Hash)

  errors = item_resp['errors']
  return false unless errors.is_a?(Array) && !errors.empty?

  errors.any? do |err|
    code = err['code'].to_s
    code.start_with?('STATE_ERROR.ENTITY_STATE_INVALID') || code.start_with?('STATE_ERROR')
  end
end

def current_app_store_state(version_id, token)
  resp = asc_get("/appStoreVersions/#{version_id}", token: token)
  resp&.dig('data', 'attributes', 'appStoreState')
end

def verify_submitted_state(version_id, token)
  deadline = Time.now + SUBMISSION_POLL_TIMEOUT
  last_state = nil

  while Time.now < deadline
    last_state = current_app_store_state(version_id, token)
    if SUBMITTED_APP_STORE_STATES.include?(last_state)
      log_info "Successfully submitted for review (state: #{last_state})."
      return true
    end
    sleep SUBMISSION_POLL_INTERVAL
  end

  log_error "Submission did not transition to review state (current: #{last_state || 'unknown'})."
  log_error 'App Store draft may exist, but final submission is still pending. Submit manually in App Store Connect UI.'
  false
end

def default_build_number(version)
  normalized = version.tr('.', '').sub(/^0+/, '')
  normalized.empty? ? '1' : normalized
end

def detect_project_build_number(project_root)
  return nil if project_root.nil? || project_root.empty?

  project_yml = File.join(project_root, 'project.yml')
  if File.exist?(project_yml)
    content = File.read(project_yml)
    match = content.match(/CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?/)
    return match[1] if match
  end

  pbxproj = Dir.glob(File.join(project_root, '*.xcodeproj', 'project.pbxproj')).first
  if pbxproj && File.exist?(pbxproj)
    content = File.read(pbxproj)
    match = content.match(/CURRENT_PROJECT_VERSION = ([0-9]+);/)
    return match[1] if match
  end

  nil
end

def extract_build_number_from_package(pkg_path)
  if pkg_path.end_with?('.ipa')
    Dir.mktmpdir('asc_info_plist') do |tmpdir|
      unzip_ok = system("unzip -qq -o #{Shellwords.escape(pkg_path)} 'Payload/*.app/Info.plist' -d #{Shellwords.escape(tmpdir)} >/dev/null 2>&1")
      return nil unless unzip_ok

      info_path = Dir.glob(File.join(tmpdir, 'Payload', '*.app', 'Info.plist')).first
      return nil unless info_path && File.exist?(info_path)

      bundle_version = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleVersion' #{Shellwords.escape(info_path)} 2>/dev/null`.strip
      return bundle_version unless bundle_version.empty?
      nil
    end
  elsif pkg_path.end_with?('.pkg')
    Dir.mktmpdir('asc_pkg_info') do |tmpdir|
      expanded = File.join(tmpdir, 'expanded')
      expand_ok = system('pkgutil', '--expand-full', pkg_path, expanded, out: File::NULL, err: File::NULL)
      return nil unless expand_ok

      candidates = Dir.glob(File.join(expanded, '**', 'Payload', '*.app', 'Contents', 'Info.plist'))
      info_path = candidates.find { |p| !p.include?('/Frameworks/') && !p.include?('/PlugIns/') } || candidates.first
      return nil unless info_path && File.exist?(info_path)

      bundle_version = `"/usr/libexec/PlistBuddy" -c 'Print :CFBundleVersion' #{Shellwords.escape(info_path)} 2>/dev/null`.strip
      return bundle_version unless bundle_version.empty?
      nil
    end
  else
    nil
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
  opts.on('--skip-screenshots', 'Skip screenshot upload; use screenshots already present in ASC') { options[:skip_screenshots] = true }
  opts.on('--preflight-version-state', 'Check editable ASC version state only (no upload, no submission)') { options[:preflight_version_state] = true }
  opts.on('--test-screenshots', 'Test screenshot resize only (no API calls)') { options[:test_screenshots] = true }
end.parse!

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

if options[:preflight_version_state]
  required = %i[app_id version platform]
  required.each do |key|
    unless options[key]
      log_error "Missing required option: --#{key.to_s.tr('_', '-')}"
      exit 1
    end
  end

  asc_platform = PLATFORM_MAP[options[:platform]]
  unless asc_platform
    log_error "Unknown platform: #{options[:platform]} (use macos or ios)"
    exit 1
  end

  token = generate_jwt
  if check_version_state_preflight(options[:app_id], asc_platform, options[:version], token)
    exit 0
  end
  exit 1
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

config_app_id = config.dig('appstore', 'app_id').to_s.strip
if !config_app_id.empty?
  if app_id.to_s.strip.empty?
    app_id = config_app_id
    log_info "Using app_id from .saneprocess: #{app_id}"
  elsif app_id.to_s.strip != config_app_id
    log_error "App ID mismatch: --app-id #{app_id} does not match .saneprocess appstore.app_id #{config_app_id}"
    log_error "Use the project app_id to avoid uploading to the wrong ASC app."
    exit 1
  end
end

artifact_label = options[:skip_upload] ? 'existing ASC build' : File.basename(pkg_path)
log_info "App Store submission: #{artifact_label} v#{version} (#{platform})"
log_info "App ID: #{app_id}"

token = generate_jwt

# Step 1: Upload build
unless options[:skip_upload]
  unless upload_build(pkg_path, app_id: app_id, version: version)
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
    detected_build_number = detect_project_build_number(project_root)
    if detected_build_number
      log_info "Using build number #{detected_build_number} from project metadata."
      detected_build_number
    else
      default_build_number(version)
    end
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
  log_error 'Failed to attach build. Aborting before review submission.'
  exit 1
end

# Step 5: Ensure review contact detail
contact_name = config.dig('appstore', 'contact', 'name') || ''
name_parts = contact_name.split(' ', 2)
contact = {
  first_name: name_parts[0] || 'Stephan',
  last_name: name_parts[1] || 'Joseph',
  phone: config.dig('appstore', 'contact', 'phone') || '+17277589785',
  email: config.dig('appstore', 'contact', 'email') || 'hi@saneapps.com',
  notes: config.dig('appstore', 'review_notes').to_s
}
ensure_review_detail(version_id, contact, token)

# Step 6: Upload screenshots (if configured)
if options[:skip_screenshots]
  log_info 'Skipping screenshot upload (--skip-screenshots).'
else
  upload_screenshots(version_id, asc_platform, project_root, config, token)
end

# Step 7: Fill required listing/build metadata before submission
token = generate_jwt
ensure_minimum_review_metadata(
  app_id: app_id,
  version_id: version_id,
  build_id: build_id,
  config: config,
  token: token
)

# Step 8: Submit for review
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
