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
require 'date'
require 'fileutils'
require 'time'
require 'uri'
require 'yaml'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'pathname'
require_relative 'hooks/release_receipt_signer'

APPSTORE_PREFLIGHT_CLOCK_SKEW_SECONDS = 5

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
    File.expand_path('~/.config/nv/env'),
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

ASC_BASE = 'https://api.appstoreconnect.apple.com/v1'
ASC_V2_BASE = 'https://api.appstoreconnect.apple.com/v2'

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
    { key: 'ipad_12_9', display_type: 'APP_IPAD_PRO_3GEN_129', width: 2048, height: 2732 },
    # watchOS screenshots are uploaded through the iOS listing lane in ASC.
    { key: 'watch', display_type: 'APP_WATCH_SERIES_7', width: 396, height: 484 }
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
].freeze

CATEGORY_ID_MAP = {
  'public.app-category.utilities' => 'UTILITIES',
  'public.app-category.productivity' => 'PRODUCTIVITY',
  'public.app-category.finance' => 'FINANCE',
  'public.app-category.business' => 'BUSINESS',
  'public.app-category.video' => 'PHOTO_AND_VIDEO'
}.freeze

ACCESSIBILITY_DEVICE_FAMILY_MAP = {
  'iphone' => 'IPHONE',
  'ios' => 'IPHONE',
  'phone' => 'IPHONE',
  'ipad' => 'IPAD',
  'tablet' => 'IPAD',
  'appletv' => 'APPLE_TV',
  'tv' => 'APPLE_TV',
  'applewatch' => 'APPLE_WATCH',
  'watch' => 'APPLE_WATCH',
  'mac' => 'MAC',
  'macos' => 'MAC',
  'vision' => 'VISION',
  'visionpro' => 'VISION'
}.freeze

ACCESSIBILITY_ATTRIBUTE_KEY_MAP = {
  'supportsaudiodescriptions' => 'supportsAudioDescriptions',
  'supportscaptions' => 'supportsCaptions',
  'supportsdarkinterface' => 'supportsDarkInterface',
  'supportsdifferentiatewithoutcoloralone' => 'supportsDifferentiateWithoutColorAlone',
  'supportslargertext' => 'supportsLargerText',
  'supportsreducedmotion' => 'supportsReducedMotion',
  'supportssufficientcontrast' => 'supportsSufficientContrast',
  'supportsvoicecontrol' => 'supportsVoiceControl',
  'supportsvoiceover' => 'supportsVoiceover'
}.freeze

ACCESSIBILITY_FAMILIES_BY_PLATFORM = {
  'MAC_OS' => %w[MAC],
  'IOS' => %w[IPHONE IPAD APPLE_TV APPLE_WATCH VISION]
}.freeze

IAP_DEFAULT_USD_PRICE = '6.99'
IAP_DEFAULT_REVIEW_NOTE = 'One-time Pro unlock. Purchase unlocks advanced features immediately.'
IAP_LOCALIZATION_NAME_MAX = 30
IAP_LOCALIZATION_DESCRIPTION_MAX = 45
IAP_DEFAULT_LOCALIZATION_DESCRIPTION = 'Unlock Pro with a one-time purchase.'
IAP_REVIEW_SCREENSHOT_TARGETS = {
  'macos' => { width: 1440, height: 900 },
  'ios' => { width: 1290, height: 2796 },
  'ipad' => { width: 2048, height: 2732 }
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

def ensure_strict_customer_ui_contract!(project_root)
  sanemaster = File.join(project_root, 'scripts', 'SaneMaster.rb')
  unless File.file?(sanemaster)
    log_error "Missing SaneMaster wrapper at #{sanemaster}; cannot verify strict customer UI contract."
    return :failed
  end

  command = sanemaster_invocation(sanemaster)
  output, status = Open3.capture2e(
    { 'SANEPROCESS_APPSTORE_SUBMIT_GUARD' => '1' },
    *command,
    'customer_ui_contract',
    '--strict-visual',
    chdir: project_root
  )
  if status.success?
    log_info 'Strict customer UI visual contract passed.'
    return true
  end

  log_error 'Strict customer UI visual contract failed. App Store upload/submission is blocked.'
  output.to_s.lines.last(20).map(&:strip).reject(&:empty?).each do |line|
    log_error "  #{line}"
  end
  false
end

def sanemaster_invocation(path)
  first_line = File.open(path, &:readline).to_s
  return ['ruby', path] if first_line.include?('ruby')
  return ['bash', path] if first_line.include?('bash') || first_line.include?('sh')

  File.executable?(path) ? [path] : ['ruby', path]
rescue StandardError
  ['ruby', path]
end

def present_value(value)
  trimmed = value.to_s.strip
  trimmed.empty? ? nil : trimmed
end

def resolved_asc_credentials
  key_path = present_value(ENV['ASC_AUTH_KEY_PATH']) || present_value(ENV['ASC_KEY_PATH'])
  {
    issuer_id: present_value(ENV['ASC_AUTH_ISSUER_ID']) || present_value(ENV['ASC_ISSUER_ID']),
    key_id: present_value(ENV['ASC_AUTH_KEY_ID']) || present_value(ENV['ASC_KEY_ID']),
    key_path: key_path ? File.expand_path(key_path) : nil
  }
end

def require_asc_credentials!
  credentials = resolved_asc_credentials
  missing = []
  missing << 'ASC_AUTH_KEY_ID' if credentials[:key_id].nil?
  missing << 'ASC_AUTH_ISSUER_ID' if credentials[:issuer_id].nil?
  missing << 'ASC_AUTH_KEY_PATH' if credentials[:key_path].nil?

  unless missing.empty?
    log_error "Missing App Store Connect API credentials: #{missing.join(', ')}"
    log_error 'Set env vars or keychain services saneprocess.asc.key_id, saneprocess.asc.issuer_id, and saneprocess.asc.key_path.'
    exit 1
  end

  credentials
end

def config_value(hash, *keys)
  return nil unless hash.is_a?(Hash)

  keys.each do |key|
    str_key = key.to_s
    sym_key = str_key.to_sym
    value = hash.key?(str_key) ? hash[str_key] : hash[sym_key]
    present = present_value(value)
    return present if present
  end

  nil
end

def metadata_overrides_for_platform(appstore_cfg, asc_platform)
  metadata_cfg = appstore_cfg['metadata'].is_a?(Hash) ? appstore_cfg['metadata'] : {}
  default_cfg = metadata_cfg['default'].is_a?(Hash) ? metadata_cfg['default'] : {}

  platform_keys =
    case asc_platform
    when 'MAC_OS'
      %w[macos mac macosx desktop]
    when 'IOS'
      %w[ios iphone ipad mobile]
    else
      []
    end

  platform_cfg = {}
  platform_keys.each do |key|
    candidate = metadata_cfg[key]
    if candidate.is_a?(Hash)
      platform_cfg = candidate
      break
    end
  end

  [default_cfg, platform_cfg]
end

def trim_metadata_to_limits(metadata)
  limits = {
    subtitle: 30,
    promotionalText: 170,
    keywords: 100,
    description: 4000,
    whatsNew: 4000
  }

  trimmed = metadata.dup
  limits.each do |key, max_len|
    value = trimmed[key]
    next unless value && value.length > max_len

    log_warn "Metadata field #{key} exceeds #{max_len} chars (#{value.length}); truncating."
    trimmed[key] = value[0, max_len].rstrip
  end
  trimmed
end

def resolve_version_metadata(appstore_cfg:, app_name:, asc_platform:)
  default_cfg, platform_cfg = metadata_overrides_for_platform(appstore_cfg, asc_platform)

  description =
    config_value(platform_cfg, 'description') ||
    config_value(default_cfg, 'description') ||
    config_value(appstore_cfg, 'description') ||
    fallback_description(app_name)

  keywords =
    config_value(platform_cfg, 'keywords') ||
    config_value(default_cfg, 'keywords') ||
    config_value(appstore_cfg, 'keywords') ||
    fallback_keywords(app_name)

  metadata = {
    description: description,
    keywords: keywords,
    subtitle: config_value(platform_cfg, 'subtitle') ||
              config_value(default_cfg, 'subtitle') ||
              config_value(appstore_cfg, 'subtitle'),
    promotionalText: config_value(platform_cfg, 'promotional_text', 'promotionalText') ||
                     config_value(default_cfg, 'promotional_text', 'promotionalText') ||
                     config_value(appstore_cfg, 'promotional_text', 'promotionalText'),
    supportUrl: config_value(platform_cfg, 'support_url', 'supportUrl') ||
                config_value(default_cfg, 'support_url', 'supportUrl') ||
                config_value(appstore_cfg, 'support_url', 'supportUrl'),
    marketingUrl: config_value(platform_cfg, 'marketing_url', 'marketingUrl') ||
                  config_value(default_cfg, 'marketing_url', 'marketingUrl') ||
                  config_value(appstore_cfg, 'marketing_url', 'marketingUrl'),
    whatsNew: config_value(platform_cfg, 'whats_new', 'whatsNew') ||
              config_value(default_cfg, 'whats_new', 'whatsNew') ||
              config_value(appstore_cfg, 'whats_new', 'whatsNew')
  }.compact

  trim_metadata_to_limits(metadata)
end

def review_notes_explain_app_store_business_model?(notes)
  normalized = notes.to_s.downcase.gsub(/\s+/, ' ').strip
  sentences = normalized.split(/[.!?;\n]+/).map(&:strip).reject(&:empty?)

  contradictory_model = normalized.match?(%r{
    \bbasic(?:\s+(?:tier|mode|access))?\s+(?:is\s+not|isn't|isnt|remains\s+not)\s+free\b
    |
    \b(?:a\s+)?(?:\d+[- ]day\s+)?(?:pro\s+)?trial\s+(?:is\s+not|isn't|isnt|remains\s+not)\s+free\b
    |
    \b(?:no|without|not)\s+(?:an?\s+)?(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b
    |
    \bdoes(?:n't|\s+not)\s+(?:require|use)\s+(?:an?\s+)?(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b
    |
    \bin-app\s+purchase\b.{0,24}\b(?:is\s+not|are\s+not|isn't|isnt|aren't|arent)\s+(?:required|used|available)\b
    |
    \bpro\b.{0,24}\b(?:
      (?:cannot|can't|cant)\s+be\s+purchased
      |
      (?:is\s+not|isn't|isnt)\s+available\s+for\s+(?:an?\s+)?(?:in-app\s+)?purchase
      |
      is\s+unavailable\s+for\s+(?:an?\s+)?(?:in-app\s+)?purchase
    )\b
    |
    \b(?:pro\s+)?(?:can\s+be\s+)?purchas(?:e|ed)\s+(?:through|via|from|on)\s+(?:the\s+)?(?:website|web\s*site|external\s+checkout)\b
    |
    \b(?:website|web\s*site|external\s+checkout|license\s+keys?)\b.{0,40}\b(?:unlocks?|upgrades?)\s+(?:the\s+)?(?:app|pro)\b
  }x)
  return false if contradictory_model

  free_basic_path = sentences.any? do |sentence|
    sentence.match?(/\bbasic(?:\s+(?:tier|mode|access))?\s+(?:is|remains)\s+(?:available\s+)?free\b/)
  end
  included_actions_path = sentences.any? do |sentence|
    sentence.match?(/\b(?:the\s+)?app\s+includes\s+\d+\s+(?:built-in\s+)?actions?\b/) ||
      sentence.match?(/\b\d+\s+(?:built-in\s+)?actions?\s+(?:are|remain)\s+included\b/)
  end
  trial_offer = sentences.any? do |sentence|
    sentence.match?(/\b(?:a\s+)?(?:\d+[- ]day\s+)?(?:pro\s+)?trial\s+(?:starts|begins|is\s+available|is\s+included)\b/)
  end
  trial_conversion = sentences.any? do |sentence|
    sentence.match?(/\bafter\s+(?:the\s+)?trial\b.*\b(?:continued\s+(?:app\s+)?access\s+requires|pro\s+(?:access\s+)?requires|purchase|unlock)\b/)
  end
  app_store_purchase_path = sentences.any? do |sentence|
    sentence.match?(/\b(?:pro|unlocks?\s+pro|upgrade\s+to\s+pro|continued\s+(?:app\s+)?access)\b.*\b(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b/) ||
      sentence.match?(/\b(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b.*\b(?:unlocks?\s+pro|pro\s+unlock|continued\s+(?:app\s+)?access)\b/) ||
      sentence.match?(/\bpurchase\s+(?:through|via|from|in)\s+(?:the\s+)?app\s+store\b.*\b(?:unlocks?\s+pro|pro\s+unlock|continued\s+(?:app\s+)?access)\b/) ||
      sentence.match?(/\b(?:one-time\s+)?app\s+store\s+(?:in-app\s+)?purchase\b.*\b(?:adds?|unlocks?)\b/)
  end
  no_external_checkout = sentences.any? { |sentence| sentence.match?(/\bno\s+(?:external|website|web)\s+checkout\b/) }
  no_license_keys = sentences.any? do |sentence|
    sentence.match?(/\bno\s+license\s+keys?\b/) ||
      sentence.match?(/\bno\s+(?:external|website|web)\s+checkout\s+(?:or|and)\s+license\s+keys?\b/)
  end

  (free_basic_path || included_actions_path || (trial_offer && trial_conversion)) &&
    app_store_purchase_path && no_external_checkout && no_license_keys
end

def metadata_review_readiness_report(config:, asc_platform:, app_name:, project_root:)
  appstore_cfg = config['appstore'] || {}
  metadata = resolve_version_metadata(appstore_cfg: appstore_cfg, app_name: app_name, asc_platform: asc_platform)
  default_cfg, platform_cfg = metadata_overrides_for_platform(appstore_cfg, asc_platform)
  issues = []
  warnings = []
  swift_files = Dir.glob(File.join(project_root, '**/*.swift')).reject { |path| path.include?('/build/') || path.include?('/DerivedData/') }
  source_blob = swift_files.map { |path| File.read(path) rescue '' }.join("\n")

  platform_label =
    case asc_platform
    when 'MAC_OS' then 'macOS'
    when 'IOS' then 'iOS'
    else asc_platform.to_s
    end

  unless platform_cfg.is_a?(Hash) && !platform_cfg.empty?
    issues << "#{platform_label} metadata block is missing in .saneprocess (appstore.metadata.#{asc_platform == 'MAC_OS' ? 'macos' : 'ios'})"
  end

  description = metadata[:description].to_s
  keywords = metadata[:keywords].to_s
  subtitle = metadata[:subtitle].to_s
  promotional = metadata[:promotionalText].to_s
  support_url = metadata[:supportUrl].to_s
  marketing_url = metadata[:marketingUrl].to_s
  review_notes = resolve_review_notes(config, asc_platform).to_s
  notes_downcase = review_notes.downcase
  has_external_credentials = source_blob.match?(/Paste your API key|set(LemonSqueezy|Gumroad|Stripe)APIKey|KeychainService\.(lemonSqueezyAPIKey|gumroadAPIKey|stripeAPIKey)|Connect .* Account/i)
  has_demo_mode = source_blob.match?(/Try Demo Data|Enable Demo Mode|demoMode|DemoData|demo data/i)
  uses_license_service = source_blob.match?(/\bLicenseService\b/)
  has_try_demo_action = source_blob.match?(/Try Demo Data/i)
  has_settings_demo_toggle = source_blob.match?(/Enable Demo Mode|Disable Demo Mode/i)

  issues << "#{platform_label} description is missing" if description.strip.empty?
  issues << "#{platform_label} keywords are missing" if keywords.strip.empty?
  issues << "#{platform_label} subtitle is missing" if subtitle.strip.empty?
  issues << "#{platform_label} support URL is missing" if support_url.strip.empty?
  issues << "#{platform_label} privacy policy URL is missing" if appstore_cfg['privacy_policy_url'].to_s.strip.empty?
  issues << "#{platform_label} review notes are missing" if review_notes.strip.empty?

  if description == fallback_description(app_name)
    issues << "#{platform_label} description is still generic fallback copy"
  end

  if keywords == fallback_keywords(app_name)
    issues << "#{platform_label} keywords are still generic fallback terms"
  end

  review_style_re = /(does not request|does not simulate|to test:|frontmost app|cmd\+v|manually press|keyboard events)/i
  ios_macos_mismatch_re = /(menu bar|frontmost app|cmd\+v|cgevent|accessibility|finder|right-click|notch|applescript|status item|apple silicon)/i
  placeholder_re = /\b(lorem ipsum|tbd|placeholder|coming soon|dummy text)\b/i

  if [description, subtitle, promotional].any? { |text| text.match?(placeholder_re) }
    issues << "#{platform_label} listing copy still contains placeholder text"
  end

  if [description, promotional].any? { |text| text.match?(review_style_re) }
    warnings << "#{platform_label} listing copy reads like review notes/debug instructions"
  end

  if asc_platform == 'IOS' && [description, subtitle, promotional].any? { |text| text.match?(ios_macos_mismatch_re) }
    issues << 'iOS listing copy still mentions macOS-only concepts'
  end

  if promotional.strip.empty?
    warnings << "#{platform_label} promotional text is empty"
  elsif promotional.length < 45
    warnings << "#{platform_label} promotional text is short (#{promotional.length} chars)"
  end

  warnings << "#{platform_label} marketing URL is empty" if marketing_url.strip.empty?

  if keywords.split(',').map(&:strip).reject(&:empty?).length < 5
    warnings << "#{platform_label} keywords field has fewer than 5 focused terms"
  end

  privacy_url = appstore_cfg['privacy_policy_url'].to_s.strip
  if !support_url.strip.empty?
    support_health = metadata_url_health(support_url)
    unless support_health[:ok]
      issues << "#{platform_label} support URL #{support_url} did not resolve successfully (#{support_health[:error]})"
    end
  end

  if !privacy_url.empty?
    privacy_health = metadata_url_health(privacy_url)
    unless privacy_health[:ok]
      issues << "#{platform_label} privacy policy URL #{privacy_url} did not resolve successfully (#{privacy_health[:error]})"
    end
  end

  if !marketing_url.strip.empty?
    marketing_health = metadata_url_health(marketing_url)
    unless marketing_health[:ok]
      warnings << "#{platform_label} marketing URL #{marketing_url} did not resolve successfully (#{marketing_health[:error]})"
    end
  end

  if has_external_credentials
    if review_notes.strip.empty?
      issues << "#{platform_label} review notes are missing the reviewer-access path for a credential-gated app"
    elsif has_demo_mode
      unless notes_downcase.match?(/demo|sample data|try demo data|enable demo mode/)
        issues << "#{platform_label} review notes do not explain the demo-mode reviewer path"
      end
      unless notes_downcase.match?(/no account required|no api key required|no credentials required|no sign.?in required|no .*payment .*launch|no .*payment .*demo/)
        issues << "#{platform_label} review notes do not clearly state that no account/API key/payment is required for review"
      end
    elsif !notes_downcase.match?(/api key|credential|username|password|sign in|login|demo account/)
      issues << "#{platform_label} review notes do not provide usable credentials or access steps"
    end
  elsif has_demo_mode && !notes_downcase.match?(/demo|sample data|try demo data|enable demo mode/)
    warnings << "#{platform_label} demo mode exists in code, but review notes do not mention it"
  end

  if notes_downcase.include?('try demo data') && !has_try_demo_action
    issues << "#{platform_label} review notes mention “Try Demo Data”, but that action is not present in code"
  end

  if notes_downcase.include?('enable demo mode') && !has_settings_demo_toggle
    issues << "#{platform_label} review notes mention “Enable Demo Mode”, but that settings action is not present in code"
  end

  if uses_license_service
    purchase_surface_path = notes_downcase.match?(/settings\s*>\s*license|license tab|unlock pro|upgrade to pro|restore purchases|browse library|locked categor|open .*license/i)
    durable_purchase_surface_path = notes_downcase.match?(/settings\s*>\s*license|license tab|browse library|locked categor|open .*license/i)
    one_shot_onboarding_path = source_blob.match?(/hasSeenWelcome|WelcomeGateView/)

    unless purchase_surface_path
      issues << "#{platform_label} review notes do not tell App Review where to find the optional Pro unlock"
    end

    if one_shot_onboarding_path && !durable_purchase_surface_path
      warnings << "#{platform_label} onboarding paywall appears one-shot; review notes should mention a durable post-onboarding upgrade path like Settings > License"
    end

    unless review_notes_explain_app_store_business_model?(notes_downcase)
      issues << "#{platform_label} review notes do not fully explain the App Store business model"
    end

    if has_external_credentials &&
       !notes_downcase.match?(/existing merchant|their own .*api|their own sales data|not sold by|do not unlock paid app features|do not unlock paid app features or digital content/)
      warnings << "#{platform_label} review notes do not clearly explain that external provider accounts are optional existing merchant accounts and do not unlock paid app features"
    end
  end

  {
    issues: issues.uniq,
    warnings: warnings.uniq
  }
end

def metadata_fetch_url_status(url, method: :head)
  if system('command', '-v', 'curl', out: File::NULL, err: File::NULL)
    args = ['curl', '-4', '-sS', '-o', '/dev/null', '-w', "%{http_code}\n%{redirect_url}", '--connect-timeout', '10', '--max-time', '20']
    args << '-I' unless method == :get
    stdout, stderr, status = Open3.capture3(*args, url)
    if status.success?
      code, location = stdout.split("\n", 2)
      return {
        code: code.to_i,
        location: location.to_s.strip,
        error: nil
      }
    end
  end

  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 20

  request =
    case method
    when :get then Net::HTTP::Get.new(uri)
    else Net::HTTP::Head.new(uri)
    end
  response = http.request(request)
  {
    code: response.code.to_i,
    location: response['location'].to_s,
    error: nil
  }
rescue StandardError => e
  {
    code: 0,
    location: '',
    error: e.message
  }
end

def metadata_url_health(url, limit: 4)
  current = url.to_s.strip
  redirects = 0

  while !current.empty? && redirects <= limit
    status = nil

    3.times do |attempt|
      status = metadata_fetch_url_status(current, method: :head)
      break unless status[:error]

      sleep 1 if attempt < 2
    end

    if status[:error] || [403, 405].include?(status[:code].to_i)
      fallback_status = metadata_fetch_url_status(current, method: :get)
      status = fallback_status unless fallback_status[:error]
    end

    return { ok: false, code: status[:code], final_url: current, error: status[:error] } if status[:error]

    code = status[:code].to_i
    if code >= 200 && code < 400
      location = status[:location].to_s.strip
      if code >= 300 && !location.empty?
        next_url = begin
          URI.join(current, location).to_s
        rescue StandardError
          location
        end
        redirects += 1
        current = next_url
        next
      end

      return { ok: true, code: code, final_url: current, error: nil }
    end

    return { ok: false, code: code, final_url: current, error: "HTTP #{code}" }
  end

  { ok: false, code: 0, final_url: current, error: 'too many redirects' }
end

def resolve_review_notes(config, asc_platform)
  appstore_cfg = config['appstore'] || {}
  by_platform = appstore_cfg['review_notes_by_platform']

  if by_platform.is_a?(Hash)
    platform_keys =
      case asc_platform
      when 'MAC_OS'
        %w[macos mac]
      when 'IOS'
        %w[ios iphone ipad]
      else
        []
      end

    platform_keys.each do |key|
      note = config_value(by_platform, key)
      return note if note
    end
  end

  config_value(appstore_cfg, 'review_notes').to_s
end

def resolve_review_contact(config)
  cfg_contact = config.dig('appstore', 'contact') || {}

  # Apple review/compliance is a real-name vendor lane (owner ruling
  # 2026-07-15): never the Mr. Sane customer alias here.
  name = present_value(ENV['APPSTORE_CONTACT_NAME']) ||
         present_value(cfg_contact['name']) ||
         'Stephan Joseph'
  first_name, last_name = name.split(' ', 2)

  phone = present_value(ENV['APPSTORE_CONTACT_PHONE']) ||
          present_value(cfg_contact['phone'])
  email = present_value(ENV['APPSTORE_CONTACT_EMAIL']) ||
          present_value(cfg_contact['email']) ||
          'hi@saneapps.com'

  missing = []
  missing << 'APPSTORE_CONTACT_PHONE (or appstore.contact.phone)' if phone.nil?
  missing << 'APPSTORE_CONTACT_EMAIL (or appstore.contact.email)' if email.nil?

  unless missing.empty?
    log_error "Missing App Store review contact fields: #{missing.join(', ')}"
    log_error 'Set contact values in environment or .saneprocess before submit.'
    exit 1
  end

  {
    first_name: first_name || 'Stephan',
    last_name: last_name || 'Joseph',
    phone: phone,
    email: email
  }
end

def resolve_review_demo_account(config, project_root:)
  demo_cfg = config.dig('appstore', 'review_demo_account')
  return nil unless demo_cfg.is_a?(Hash)

  account_name = config_value(demo_cfg, 'name', 'account_name')
  password_file = config_value(demo_cfg, 'password_file')
  if account_name.nil? || password_file.nil?
    raise ArgumentError,
          'appstore.review_demo_account requires non-empty name and password_file values'
  end

  expanded_path =
    if Pathname.new(password_file).absolute?
      File.expand_path(password_file)
    else
      File.expand_path(password_file, project_root)
    end

  unless File.file?(expanded_path)
    raise ArgumentError, 'App Store review demo password file is missing or is not a regular file'
  end
  if File.symlink?(expanded_path)
    raise ArgumentError, 'App Store review demo password file must not be a symbolic link'
  end

  mode = File.stat(expanded_path).mode & 0o777
  unless mode == 0o600
    raise ArgumentError, 'App Store review demo password file must have permissions 600'
  end

  password = File.read(expanded_path, encoding: Encoding::UTF_8).strip
  if password.empty?
    raise ArgumentError, 'App Store review demo password file is empty'
  end
  if password.bytesize > 4_096
    raise ArgumentError, 'App Store review demo password file exceeds the 4096-byte limit'
  end

  {
    name: account_name,
    password: password
  }
end

# ─── JWT Token Generation ───

def generate_jwt
  credentials = require_asc_credentials!
  unless File.exist?(credentials[:key_path])
    log_error "API key not found: #{credentials[:key_path]}"
    exit 1
  end

  private_key = OpenSSL::PKey::EC.new(File.read(credentials[:key_path]))
  now = Time.now.to_i

  payload = {
    iss: credentials[:issuer_id],
    iat: now,
    exp: now + 1200, # 20 minutes
    aud: 'appstoreconnect-v1'
  }

  header = {
    kid: credentials[:key_id],
    typ: 'JWT'
  }

  JWT.encode(payload, private_key, 'ES256', header)
end

# ─── HTTP Helpers ───

def redact_asc_response_body(response_body, request_body)
  response_text = response_body.to_s
  return response_text[0..500] unless request_body.is_a?(Hash)

  secret = request_body.dig(:data, :attributes, :demoAccountPassword) ||
           request_body.dig('data', 'attributes', 'demoAccountPassword')
  secret = secret.to_s
  return response_text[0..500] if secret.empty?

  response_text.gsub(secret, '[REDACTED]')[0..500]
end

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

  unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
    log_error "ASC API #{method.upcase} #{path} → #{response.code}"
    log_error redact_asc_response_body(response.body, body) if response.body
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

def asc_get_with_status(path, token: nil, base: ASC_BASE)
  token ||= generate_jwt
  uri = URI("#{base}#{path}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60

  request = Net::HTTP::Get.new(uri)
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
  log_error "ASC API raw GET error: #{e.message}"
  [0, { 'error' => e.message }]
end

def asc_get_v2(path, token: nil)
  asc_get_with_status(path, token: token, base: ASC_V2_BASE)
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

def asc_post_with_status(path, body:, token: nil, base: ASC_BASE)
  token ||= generate_jwt
  uri = URI("#{base}#{path}")

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

def asc_patch_with_status(path, body:, token: nil, base: ASC_BASE)
  token ||= generate_jwt
  uri = URI("#{base}#{path}")

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

def asc_delete_with_status(path, token: nil, base: ASC_BASE)
  token ||= generate_jwt
  uri = URI("#{base}#{path}")

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

def app_info_from_plist(info_path)
  return nil unless info_path && File.file?(info_path)

  values = %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion].map do |key|
    output, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", info_path)
    return nil unless status.success? && !output.to_s.strip.empty?

    output.to_s.strip
  end
  { bundle_id: values[0], short_version: values[1], build_number: values[2] }
rescue StandardError
  nil
end

def select_unique_package_app_info(info_paths, expected_bundle_id: nil)
  candidates = Array(info_paths).uniq.sort.map { |path| app_info_from_plist(path) }.compact
  unless expected_bundle_id.to_s.empty?
    candidates = candidates.select { |candidate| candidate[:bundle_id] == expected_bundle_id.to_s }
  end
  return nil unless candidates.length == 1

  candidates.first
end

def top_level_pkg_app_info_paths(expanded_dir)
  Dir.glob(File.join(expanded_dir, '**', 'Payload', '**', '*.app', 'Contents', 'Info.plist')).select do |path|
    relative = path.split('/Payload/', 2)[1].to_s
    app_components = relative.split('/').select { |component| component.end_with?('.app') }
    app_components.length == 1
  end.uniq.sort
end

def extract_app_info_from_package(pkg_path, expected_bundle_id: nil)

  if pkg_path.end_with?('.ipa')
    Dir.mktmpdir('asc_info_plist') do |tmpdir|
      unzip_ok = system("unzip -qq -o #{Shellwords.escape(pkg_path)} 'Payload/*.app/Info.plist' -d #{Shellwords.escape(tmpdir)} >/dev/null 2>&1")
      return nil unless unzip_ok

      info_paths = Dir.glob(File.join(tmpdir, 'Payload', '*.app', 'Info.plist'))
      return select_unique_package_app_info(info_paths, expected_bundle_id: expected_bundle_id)
    end
  elsif pkg_path.end_with?('.pkg')
    Dir.mktmpdir('asc_pkg_info') do |tmpdir|
      expanded = File.join(tmpdir, 'expanded')
      expand_ok = system('pkgutil', '--expand-full', pkg_path, expanded, out: File::NULL, err: File::NULL)
      return nil unless expand_ok

      info_paths = top_level_pkg_app_info_paths(expanded)
      return select_unique_package_app_info(info_paths, expected_bundle_id: expected_bundle_id)
    end
  end

  nil
end

# ─── Upload Build ───

def exact_appstore_upload_command(pkg_path, app_id:, credentials:)
  package_info = extract_app_info_from_package(pkg_path)
  return nil unless package_info

  [
    'xcrun', 'altool', '--upload-package', pkg_path,
    '-t', pkg_path.end_with?('.ipa') ? 'ios' : 'macos',
    '--apple-id', app_id,
    '--bundle-id', package_info[:bundle_id],
    '--bundle-version', package_info[:build_number],
    '--bundle-short-version-string', package_info[:short_version],
    '--wait',
    '--apiKey', credentials[:key_id],
    '--apiIssuer', credentials[:issuer_id]
  ]
end

def classify_appstore_upload_output(success:, output:)
  duplicate_upload_patterns = [
    /already been uploaded/i,
    /already exists/i,
    /bundle version must be higher than the previously uploaded version/i,
    /ENTITY_ERROR\.ATTRIBUTE\.INVALID\.DUPLICATE/i,
    /attribute with a value that has already been used/i
  ]
  return :duplicate if duplicate_upload_patterns.any? { |pattern| output.match?(pattern) }

  output_failure_patterns = [
    /upload failed/i,
    /validation failed/i,
    /state_error\.validation_error/i,
    /missing info\.plist/i,
    /app sandbox not enabled/i
  ]
  reported_failure = output_failure_patterns.any? { |pattern| output.match?(pattern) }
  return :uploaded if success && !reported_failure

  :failed
end

def upload_build(pkg_path, app_id:, version:)
  log_info "Uploading #{File.basename(pkg_path)} via altool..."

  credentials = require_asc_credentials!
  cmd = exact_appstore_upload_command(pkg_path, app_id: app_id, credentials: credentials)
  unless cmd
    log_error 'Could not reparse one exact top-level app identity from the staged package. Refusing generic upload fallback.'
    return :failed
  end

  output = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  outcome = classify_appstore_upload_output(success: $?.success?, output: output)
  case outcome
  when :uploaded
    log_info 'Upload complete.'
  when :duplicate
    log_error 'Build already exists in ASC. Increment the build number, create a fresh package, and retry the normal upload.'
  else
    log_error "altool upload failed:\n#{output}"
  end
  outcome
end

# ─── Poll for Build Processing ───

def wait_for_build(app_id, build_number, asc_platform, token, expected_marketing_version:)
  log_info "Waiting for build #{build_number} (version #{expected_marketing_version}) to finish processing (up to #{BUILD_POLL_TIMEOUT / 60} min)..."

  deadline = Time.now + BUILD_POLL_TIMEOUT
  build_id = nil

  while Time.now < deadline
    path = "/builds?filter[app]=#{app_id}&filter[version]=#{build_number}" \
           "&filter[preReleaseVersion.platform]=#{asc_platform}" \
           "&filter[processingState]=PROCESSING,VALID,INVALID" \
           "&sort=-uploadedDate&limit=5&include=preReleaseVersion"
    resp = asc_get(path, token: token)

    if resp && resp['data']
      prerelease_identities = {}
      (resp['included'] || []).each do |entry|
        next unless entry['type'] == 'preReleaseVersions'

        prerelease_identities[entry['id']] = {
          platform: entry.dig('attributes', 'platform').to_s,
          version: entry.dig('attributes', 'version').to_s
        }
      end

      numbered_builds = resp['data'].select do |b|
        attrs = b['attributes'] || {}
        attrs['version'].to_s == build_number.to_s
      end
      if numbered_builds.any?
        missing_identity = numbered_builds.any? do |build|
          prerelease_identities[build.dig('relationships', 'preReleaseVersion', 'data', 'id')].nil?
        end
        if missing_identity
          log_error "ASC build #{build_number} is missing included pre-release version identity; refusing ambiguous selection."
          return nil
        end
        exact_builds = numbered_builds.select do |build|
          identity = prerelease_identities[build.dig('relationships', 'preReleaseVersion', 'data', 'id')]
          identity[:platform] == asc_platform && identity[:version] == expected_marketing_version.to_s
        end
        if exact_builds.empty?
          identities = numbered_builds.map do |build|
            prerelease_identities[build.dig('relationships', 'preReleaseVersion', 'data', 'id')]
          end
          summary = identities.map { |identity| "#{identity[:version]}@#{identity[:platform]}" }.uniq.join(', ')
          log_error "ASC build #{build_number} belongs to #{summary}, not #{expected_marketing_version}@#{asc_platform}."
          return nil
        end
        if exact_builds.length != 1
          log_error "ASC build #{build_number} is ambiguous for #{expected_marketing_version}@#{asc_platform}."
          return nil
        end
        build = exact_builds.first
      end

      if build
        state = build.dig('attributes', 'processingState')
        build_id = build['id']

        case state
        when 'VALID'
          log_info "Build #{build_number} processed successfully (ID: #{build_id})"
          return build_id
        when 'INVALID'
          log_error "Build #{build_number} failed processing (INVALID)"
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

def find_version_any_state(app_id, asc_platform, version_string, token)
  path = "/apps/#{app_id}/appStoreVersions" \
         "?filter[platform]=#{asc_platform}" \
         "&limit=200"
  resp = asc_get(path, token: token)
  return nil unless resp && resp['data']

  resp['data'].find do |v|
    v.dig('attributes', 'versionString') == version_string
  end
end

def list_versions(app_id, asc_platform, token)
  path = "/apps/#{app_id}/appStoreVersions?limit=200"
  path += "&filter[platform]=#{asc_platform}" if asc_platform
  resp = asc_get(path, token: token)
  return nil unless resp && resp['data']

  versions = resp['data'].map do |version|
    attrs = version['attributes'] || {}
    linked_submission = find_linked_review_submission(app_id, attrs['platform'], version['id'], token)
    {
      id: version['id'],
      version: attrs['versionString'],
      platform: attrs['platform'],
      state: attrs['appStoreState'],
      created: attrs['createdDate'],
      submission_state: linked_submission&.dig(:state),
      submission_id: linked_submission&.dig(:id)
    }
  end

  versions.sort_by do |row|
    [
      row[:platform].to_s,
      Gem::Version.new(row[:version].to_s[/\d+(?:\.\d+)*/] || '0')
    ]
  rescue ArgumentError
    [row[:platform].to_s, row[:version].to_s]
  end.reverse
end

def applescript_quote(text)
  text.to_s.gsub('\\', '\\\\\\').gsub('"', '\"')
end

def run_brave_javascript(url:, javascript:, delay_seconds: 8, navigate: true)
  script = <<~APPLESCRIPT
    tell application "Brave Browser"
      if not running then
        error "Brave Browser is not running."
      end if

      if (count of windows) = 0 then
        error "Brave Browser has no open window."
      end if

      set ascTab to missing value
      repeat with browserWindow in windows
        repeat with browserTab in tabs of browserWindow
          if (URL of browserTab starts with "https://appstoreconnect.apple.com") then
            set ascTab to browserTab
            exit repeat
          end if
        end repeat
        if ascTab is not missing value then exit repeat
      end repeat

      if ascTab is missing value then
        error "Brave Browser has no open App Store Connect tab."
      end if
      if #{navigate ? 'true' : 'false'} then
        set URL of ascTab to "#{applescript_quote(url)}"
      end if

      delay #{delay_seconds}
      if (URL of ascTab does not start with "https://appstoreconnect.apple.com") then
        error "Brave App Store Connect authentication is unavailable."
      end if
      return execute ascTab javascript "#{applescript_quote(javascript)}"
    end tell
  APPLESCRIPT

  stdout, stderr, status = Open3.capture3('osascript', stdin_data: script)
  raise(stderr.strip.empty? ? 'Brave App Store Connect automation failed.' : stderr.strip) unless status.success?

  stdout
end

def brave_page_snapshot(url:, delay_seconds: 8, navigate: true)
  javascript = <<~JAVASCRIPT
    JSON.stringify({
      url: location.href,
      body: document.body ? document.body.innerText.slice(0, 20000) : ""
    })
  JAVASCRIPT

  raw = run_brave_javascript(url: url, javascript: javascript, delay_seconds: delay_seconds, navigate: navigate)
  snapshot = JSON.parse(raw)
  current_url = snapshot['url'].to_s
  body = snapshot['body'].to_s
  unless current_url.start_with?('https://appstoreconnect.apple.com/')
    raise "Brave returned an unexpected App Store Connect URL: #{current_url}"
  end
  if body.include?('authResult=FAILED') || body.match?(/\bSign In\b.*\bApple (?:Account|ID)\b/i)
    raise 'Brave App Store Connect authentication is expired; sign in in Brave and retry.'
  end
  snapshot
rescue JSON::ParserError => e
  raise "Brave returned invalid App Store Connect page JSON: #{e.message}"
end

def version_page_includes_iap?(app_id:, platform:, product_id:)
  return nil if app_id.to_s.strip.empty? || product_id.to_s.strip.empty?

  platform_path = platform.to_s.downcase == 'ios' ? 'ios' : 'macos'
  url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/#{platform_path}/version/inflight"

  6.times do |attempt|
    snapshot = brave_page_snapshot(
      url: url,
      delay_seconds: attempt.zero? ? 8 : 2,
      navigate: attempt.zero?
    )
    body = snapshot['body'].to_s
    next if body.empty?

    return true if body.include?(product_id.to_s) &&
                   body.include?('Included Assets') &&
                   body.include?('In-App Purchases and Subscriptions')
    next if body.include?('Included Assets') || body.include?('In-App Purchases and Subscriptions')
  end

  false
rescue StandardError
  nil
end

def iap_version_attachment_status(app_id:, platform:, product_id:)
  attached = version_page_includes_iap?(app_id: app_id, platform: platform, product_id: product_id)
  return :attached if attached == true
  return :not_attached if attached == false

  :unknown
end

def normalize_review_page_text(text)
  clean = text.to_s.gsub("\u00A0", ' ').gsub("\r\n", "\n").gsub("\r", "\n")
  clean = clean.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip

  anchors = [
    /Messages\s*\(\d+\)/,
    /Apple(?:Today|Yesterday|[A-Z][a-z]{2}.*\d{4})/,
    /Hello,/
  ]
  start_index = anchors.map { |pattern| clean.index(pattern) }.compact.min
  start_index ? clean[start_index..].strip : clean
end

def fetch_review_message_from_brave(app_id:, submission_id:)
  review_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/reviewsubmissions/details/#{submission_id}"
  delays = [10, 5, 5, 5]
  delays.each_with_index do |delay_seconds, attempt|
    snapshot = brave_page_snapshot(
      url: review_url,
      delay_seconds: delay_seconds,
      navigate: attempt.zero?
    )
    current_url = snapshot['url'].to_s
    body = snapshot['body'].to_s
    url_matches = current_url.include?(app_id.to_s) && current_url.include?(submission_id.to_s)
    body_matches = body.include?('Messages (') || body.include?('Hello,') || body.match?(/Apple(?:Today|Yesterday|[A-Z][a-z]{2})/)
    return normalize_review_page_text(body) if url_matches && body_matches
  end

  raise "Brave did not open the expected App Review page for app #{app_id} submission #{submission_id}."
end

def review_downloads_dir
  override = ENV['APPSTORE_REVIEW_DOWNLOADS_DIR'].to_s.strip
  return File.expand_path(override) unless override.empty?

  File.expand_path('~/Downloads')
end

def snapshot_downloads(downloads_dir)
  return {} unless Dir.exist?(downloads_dir)

  Dir.children(downloads_dir).each_with_object({}) do |entry, memo|
    path = File.join(downloads_dir, entry)
    next unless File.file?(path)

    stat = File.stat(path)
    memo[path] = {
      mtime: stat.mtime.to_f,
      size: stat.size
    }
  end
end

def new_downloads_since(before_snapshot, downloads_dir)
  current = snapshot_downloads(downloads_dir)
  current.keys.select do |path|
    previous = before_snapshot[path]
    previous.nil? || previous[:mtime] != current[path][:mtime] || previous[:size] != current[path][:size]
  end.sort_by { |path| File.mtime(path) }.reverse
end

def click_review_downloads_in_brave(app_id:, submission_id:)
  review_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/reviewsubmissions/details/#{submission_id}"
  javascript = <<~JAVASCRIPT
    JSON.stringify((() => {
      const bodyText = document.body ? document.body.innerText.slice(0, 20000) : "";
      const isVisible = (el) => {
        if (!el) return false;
        const rect = el.getBoundingClientRect();
        const style = window.getComputedStyle(el);
        return rect.width > 0 &&
          rect.height > 0 &&
          style.display !== "none" &&
          style.visibility !== "hidden" &&
          style.opacity !== "0";
      };
      const labelFor = (el) => {
        return [
          el.innerText,
          el.getAttribute("aria-label"),
          el.getAttribute("title"),
          el.getAttribute("download"),
          el.getAttribute("href")
        ]
          .filter(Boolean)
          .join(" ")
          .replace(/\\s+/g, " ")
          .trim();
      };

      const seen = new Set();
      const clicks = [];
      for (const el of Array.from(document.querySelectorAll('a, button, [role="button"]'))) {
        if (!isVisible(el)) continue;
        const label = labelFor(el);
        if (!/download/i.test(label)) continue;
        const key = label || `download-${clicks.length + 1}`;
        if (seen.has(key)) continue;
        seen.add(key);
        try {
          el.click();
          clicks.push(key);
        } catch (error) {
          clicks.push(`ERROR:${key}:${String(error)}`);
        }
      }

      return {
        url: location.href,
        clicks,
        body: bodyText
      };
    })())
  JAVASCRIPT

  raw = run_brave_javascript(url: review_url, javascript: javascript, delay_seconds: 2, navigate: false)
  JSON.parse(raw)
rescue JSON::ParserError => e
  raise "Brave returned invalid App Review download metadata: #{e.message}"
end

def fetch_review_package_from_brave(app_id:, submission_id:, downloads_dir: review_downloads_dir, download_wait_seconds: 5)
  review_text = fetch_review_message_from_brave(app_id: app_id, submission_id: submission_id)
  before_snapshot = snapshot_downloads(downloads_dir)
  click_payload = click_review_downloads_in_brave(app_id: app_id, submission_id: submission_id)
  sleep download_wait_seconds if download_wait_seconds.to_i.positive?
  downloaded_files = new_downloads_since(before_snapshot, downloads_dir)

  {
    'review_url' => "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/reviewsubmissions/details/#{submission_id}",
    'page_url' => click_payload['url'].to_s,
    'review_text' => review_text,
    'page_text' => normalize_review_page_text(click_payload['body'].to_s),
    'download_clicks' => Array(click_payload['clicks']).map(&:to_s),
    'downloaded_files' => downloaded_files
  }
end

def review_package_output_dir(project_root:, platform:, version:, submission_id:)
  timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
  base_dir =
    if project_root && !project_root.to_s.strip.empty?
      File.join(project_root, 'outputs')
    else
      Dir.pwd
    end

  File.join(base_dir, "appreview-#{platform}-#{version}-#{submission_id}-#{timestamp}")
end

def persist_review_package(package:, output_dir:)
  FileUtils.mkdir_p(output_dir)

  copied_files = []
  Array(package['downloaded_files']).each do |path|
    next unless File.file?(path)

    destination = File.join(output_dir, File.basename(path))
    FileUtils.cp(path, destination)
    copied_files << destination
  rescue StandardError
    next
  end

  summary = package.merge('copied_files' => copied_files)
  File.write(File.join(output_dir, 'review_message.txt'), package['review_text'].to_s)
  File.write(File.join(output_dir, 'review_page.txt'), package['page_text'].to_s)
  File.write(File.join(output_dir, 'summary.json'), JSON.pretty_generate(summary))

  summary
end

def delete_empty_draft_submissions_from_brave(app_id:, max_iterations: 20)
  review_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/reviewsubmissions"
  deleted_count = 0

  max_iterations.times do |index|
    delay_seconds = index.zero? ? 8 : 2
    javascript = <<~JAVASCRIPT
      (() => {
        const body = document.body ? document.body.innerText : "";
        const match = body.match(/Draft Submissions \\((\\d+)\\)/);
        const buttons = Array.from(document.querySelectorAll('button[aria-label="Delete"]'));
        const loaded = /App Review/.test(body) && (/Drafts/.test(body) || /Submissions/.test(body));
        if (!loaded) {
          return JSON.stringify({
            action: "loading",
            remaining: match ? Number(match[1]) : null,
            body: body.slice(0, 12000)
          });
        }
        if (!buttons.length) {
          return JSON.stringify({
            action: "none",
            remaining: match ? Number(match[1]) : 0,
            body: body.slice(0, 12000)
          });
        }
        buttons[0].click();
        return JSON.stringify({
          action: "clicked",
          remainingBefore: match ? Number(match[1]) : buttons.length
        });
      })()
    JAVASCRIPT

    raw = run_brave_javascript(
      url: review_url,
      javascript: javascript,
      delay_seconds: delay_seconds,
      navigate: index.zero?
    )
    payload = JSON.parse(raw, symbolize_names: true)

    if payload[:action] == 'clicked'
      deleted_count += 1
      sleep 2
      next
    end

    next if payload[:action] == 'loading'

    return {
      deleted_count: deleted_count,
      remaining_count: payload[:remaining].to_i,
      body: payload[:body].to_s
    }
  end

  raise 'Timed out while deleting draft submissions in Brave.'
end

def remove_app_from_brave(app_id:)
  info_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/info"
  click_remove_app = <<~JAVASCRIPT
    (() => {
      const normalize = (text) => (text || "").replace(/\\s+/g, " ").trim();
      const body = document.body ? document.body.innerText : "";
      const button = Array.from(document.querySelectorAll('button')).find((candidate) =>
        normalize(candidate.innerText || candidate.textContent || candidate.getAttribute('aria-label')) === "Remove App"
      );
      if (!button) {
        return JSON.stringify({ stage: "missing-remove-app", url: location.href, body: body.slice(0, 12000) });
      }
      button.click();
      return JSON.stringify({ stage: "opened-confirm" });
    })()
  JAVASCRIPT

  click_confirm = <<~JAVASCRIPT
    (() => {
      const normalize = (text) => (text || "").replace(/\\s+/g, " ").trim();
      const body = document.body ? document.body.innerText : "";
      const button = Array.from(document.querySelectorAll('button')).find((candidate) =>
        normalize(candidate.innerText || candidate.textContent || candidate.getAttribute('aria-label')) === "Remove"
      );
      if (!button) {
        return JSON.stringify({ stage: "missing-confirm", body: body.slice(0, 12000) });
      }
      button.click();
      return JSON.stringify({ stage: "confirmed" });
    })()
  JAVASCRIPT
  snapshot_script = <<~JAVASCRIPT
    JSON.stringify({
      url: location.href,
      body: document.body ? document.body.innerText.slice(0, 20000) : ""
    })
  JAVASCRIPT

  script = <<~APPLESCRIPT
    tell application "Brave Browser"
      if not running then
        error "Brave Browser is not running."
      end if

      if (count of windows) = 0 then
        error "Brave Browser has no open window."
      end if
      set ascTab to missing value
      repeat with browserWindow in windows
        repeat with browserTab in tabs of browserWindow
          if (URL of browserTab starts with "https://appstoreconnect.apple.com") then
            set ascTab to browserTab
            exit repeat
          end if
        end repeat
        if ascTab is not missing value then exit repeat
      end repeat
      if ascTab is missing value then error "Brave Browser has no open App Store Connect tab."
      set URL of ascTab to "#{applescript_quote(info_url)}"
      delay 10
      if (URL of ascTab does not start with "https://appstoreconnect.apple.com") then
        error "Brave App Store Connect authentication is unavailable."
      end if

      set stepOne to execute ascTab javascript "#{applescript_quote(click_remove_app)}"
      delay 2
      set stepTwo to execute ascTab javascript "#{applescript_quote(click_confirm)}"
      delay 4
      set snapshot to execute ascTab javascript "#{applescript_quote(snapshot_script)}"

      return stepOne & linefeed & "<<<ASC_SPLIT>>>" & linefeed & stepTwo & linefeed & "<<<ASC_SPLIT>>>" & linefeed & snapshot
    end tell
  APPLESCRIPT

  stdout, stderr, status = Open3.capture3('osascript', stdin_data: script)
  raise(stderr.strip.empty? ? 'Brave remove-app automation failed.' : stderr.strip) unless status.success?

  parts = stdout.split("\n<<<ASC_SPLIT>>>\n", 3)
  step_one = JSON.parse(parts[0].to_s, symbolize_names: true)
  return step_one if step_one[:stage] != 'opened-confirm'

  step_two = JSON.parse(parts[1].to_s, symbolize_names: true)
  return step_two if step_two[:stage] != 'confirmed'

  snapshot = JSON.parse(parts[2].to_s)
  body = snapshot['body'].to_s
  if body.include?('This app is unable to be removed right now.') || body.include?('This app cannot be removed.')
    {
      stage: 'blocked',
      body: body
    }
  else
    {
      stage: 'completed',
      url: snapshot['url'].to_s,
      body: body
    }
  end
end

def check_version_state_preflight(app_id, asc_platform, version_string, token)
  editable_path = "/apps/#{app_id}/appStoreVersions" \
                  "?filter[platform]=#{asc_platform}" \
                  "&filter[appStoreState]=PREPARE_FOR_SUBMISSION,REJECTED,DEVELOPER_REJECTED,READY_FOR_REVIEW"
  editable_resp = asc_get(editable_path, token: token)
  return false unless editable_resp

  editable_versions = editable_resp['data'] || []
  matching = editable_versions.find do |v|
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

  # Check for non-editable active review states that block creating a new version.
  # ASC only allows one active review submission lane per platform.
  active_resp = asc_get("/apps/#{app_id}/appStoreVersions?filter[platform]=#{asc_platform}&limit=200", token: token)
  return false unless active_resp

  active_versions = (active_resp['data'] || []).select do |v|
    state = v.dig('attributes', 'appStoreState').to_s
    SUBMITTED_APP_STORE_STATES.include?(state)
  end
  same_active = active_versions.find { |v| v.dig('attributes', 'versionString') == version_string }
  if same_active
    state = same_active.dig('attributes', 'appStoreState')
    log_info "ASC version-state preflight: #{version_string} is already #{state}; skip new version creation."
    return true
  end

  active_conflict = active_versions.first
  if active_conflict
    conflict_version = active_conflict.dig('attributes', 'versionString') || 'unknown'
    conflict_state = active_conflict.dig('attributes', 'appStoreState') || 'unknown'
    log_error "App Store version conflict: #{conflict_version} is currently #{conflict_state}; target is #{version_string}."
    log_error "Resolve the active submission first (e.g. remove/reject it), or submit against that same version."
    return false
  end

  if editable_versions.empty?
    log_info "ASC version-state preflight passed for #{version_string} (no blocking editable or submitted lanes)."
    return true
  end

  conflict = editable_versions.first
  conflict_version = conflict.dig('attributes', 'versionString') || 'unknown'
  conflict_state = conflict.dig('attributes', 'appStoreState') || 'unknown'
  log_error "Editable App Store version conflict: #{conflict_version} (#{conflict_state}) exists, but release target is #{version_string}."
  log_error "Update the existing draft to version #{version_string}, or clear that draft before submission."
  false
end

def repair_version_state_lane(app_id, asc_platform, version_string, token)
  log_info "Attempting ASC lane repair for #{version_string} (#{asc_platform})..."

  # First: if the target version already exists and is tied to an unresolved review lane, try to resolve it.
  existing = find_version_any_state(app_id, asc_platform, version_string, token)
  if existing
    linked_submission = find_linked_review_submission(app_id, asc_platform, existing['id'], token)
    if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
      log_warn "Found unresolved review submission #{linked_submission[:id]} for existing version #{version_string}."
      clear_stale_version_submission(existing['id'], token)
      attempt_resolve_unresolved_submission(linked_submission[:id], token)
      refreshed_submission = find_linked_review_submission(app_id, asc_platform, existing['id'], token)
      if refreshed_submission && refreshed_submission[:state] == 'UNRESOLVED_ISSUES'
        log_warn "Submission #{refreshed_submission[:id]} is still UNRESOLVED_ISSUES after item repair; attempting stale submission cleanup."
        clear_review_submission(refreshed_submission[:id], token)
        refreshed_submission = find_linked_review_submission(app_id, asc_platform, existing['id'], token)
        if refreshed_submission && refreshed_submission[:state] == 'UNRESOLVED_ISSUES'
          log_error "Lane repair failed: submission #{refreshed_submission[:id]} is still UNRESOLVED_ISSUES."
          return false
        end
      end
      log_info "Lane repair succeeded for existing version #{version_string}."
      return true
    end

    log_info "No unresolved-lane repair needed for existing version #{version_string}."
    return true
  end

  # Second: if target version doesn't exist, try to retarget a single editable draft lane.
  editable_path = "/apps/#{app_id}/appStoreVersions" \
                  "?filter[platform]=#{asc_platform}" \
                  "&filter[appStoreState]=PREPARE_FOR_SUBMISSION,REJECTED,DEVELOPER_REJECTED,READY_FOR_REVIEW"
  editable_resp = asc_get(editable_path, token: token)
  return false unless editable_resp

  editable_versions = editable_resp['data'] || []
  if editable_versions.empty?
    log_info 'No editable draft lane found to repair.'
    return true
  end

  if editable_versions.length > 1
    versions = editable_versions.map { |v| "#{v.dig('attributes', 'versionString')} (#{v.dig('attributes', 'appStoreState')})" }
    log_error "Lane repair aborted: multiple editable versions present: #{versions.join(', ')}."
    return false
  end

  candidate = editable_versions.first
  candidate_id = candidate['id']
  candidate_version = candidate.dig('attributes', 'versionString') || 'unknown'
  candidate_state = candidate.dig('attributes', 'appStoreState') || 'unknown'

  # Don't retarget if another active submission lane exists.
  active_resp = asc_get("/apps/#{app_id}/appStoreVersions?filter[platform]=#{asc_platform}&limit=200", token: token)
  return false unless active_resp
  active_versions = (active_resp['data'] || []).select do |v|
    state = v.dig('attributes', 'appStoreState').to_s
    SUBMITTED_APP_STORE_STATES.include?(state)
  end
  active_conflict = active_versions.find { |v| v.dig('attributes', 'versionString') != version_string }
  if active_conflict
    conflict_version = active_conflict.dig('attributes', 'versionString') || 'unknown'
    conflict_state = active_conflict.dig('attributes', 'appStoreState') || 'unknown'
    log_error "Lane repair blocked by active submission: #{conflict_version} (#{conflict_state})."
    return false
  end

  body = {
    data: {
      type: 'appStoreVersions',
      id: candidate_id,
      attributes: {
        versionString: version_string
      }
    }
  }
  code, resp = asc_patch_with_status("/appStoreVersions/#{candidate_id}", body: body, token: token)
  if [200, 201].include?(code)
    log_info "Retargeted editable lane #{candidate_version} (#{candidate_state}) -> #{version_string}."
    return true
  end

  detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
  log_error "Lane retarget failed for #{candidate_id}: #{detail}"
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
    detail = resp&.dig('errors', 0, 'detail') || resp&.dig('errors', 0, 'title')
    log_error "ASC create-version detail: #{detail}" if detail
    existing_any = find_version_any_state(app_id, asc_platform, version_string, token)
    if existing_any
      state = existing_any.dig('attributes', 'appStoreState') || 'unknown'
      if SUBMITTED_APP_STORE_STATES.include?(state)
        log_info "Version #{version_string} already exists in ASC (#{state}) — treating as already submitted."
        return :already_submitted
      end
      log_error "Version #{version_string} already exists in state #{state}; update that lane instead of creating a new one."
    end
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
  demo_account = contact[:demo_account]
  demo_account_required = !demo_account.nil?
  desired_demo_name = demo_account && demo_account[:name].to_s
  desired_demo_password = demo_account && demo_account[:password].to_s

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
                   existing['demoAccountRequired'] != demo_account_required ||
                   (demo_account_required && existing['demoAccountName'].to_s != desired_demo_name) ||
                   (demo_account_required && existing['demoAccountPassword'].to_s != desired_demo_password) ||
                   (!desired_notes.empty? && existing_notes != desired_notes)

    if needs_update
      log_info 'Updating review contact detail...'
      attributes = {
        contactFirstName: contact[:first_name],
        contactLastName: contact[:last_name],
        contactPhone: contact[:phone],
        contactEmail: contact[:email],
        notes: desired_notes.empty? ? existing_notes : desired_notes,
        demoAccountRequired: demo_account_required
      }
      if demo_account_required
        attributes[:demoAccountName] = desired_demo_name
        attributes[:demoAccountPassword] = desired_demo_password
      end
      body = {
        data: {
          type: 'appStoreReviewDetails',
          id: detail_id,
          attributes: attributes
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
  attributes = {
    contactFirstName: contact[:first_name],
    contactLastName: contact[:last_name],
    contactPhone: contact[:phone],
    contactEmail: contact[:email],
    notes: contact[:notes].to_s,
    demoAccountRequired: demo_account_required
  }
  if demo_account_required
    attributes[:demoAccountName] = desired_demo_name
    attributes[:demoAccountPassword] = desired_demo_password
  end
  body = {
    data: {
      type: 'appStoreReviewDetails',
      attributes: attributes,
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

def fallback_description(app_name)
  "#{app_name} helps you stay productive on Apple devices with a clear free tier and a one-time Pro upgrade."
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

def parse_boolish(value)
  return value if value == true || value == false

  case value
  when Integer
    return value != 0
  when String
    normalized = value.strip.downcase
    return true if %w[true yes y 1 on].include?(normalized)
    return false if %w[false no n 0 off].include?(normalized)
  end

  nil
end

def normalize_accessibility_family(raw_key)
  normalized = raw_key.to_s.strip.downcase.gsub(/[^a-z0-9]/, '')
  return nil if normalized.empty?

  ACCESSIBILITY_DEVICE_FAMILY_MAP[normalized]
end

def normalize_accessibility_attribute(raw_key)
  normalized = raw_key.to_s.strip.downcase.gsub(/[^a-z0-9]/, '')
  return nil if normalized.empty?

  ACCESSIBILITY_ATTRIBUTE_KEY_MAP[normalized]
end

def list_accessibility_declarations(app_id, token)
  resp = asc_get("/apps/#{app_id}/accessibilityDeclarations?limit=200", token: token)
  return [] unless resp && resp['data'].is_a?(Array)

  resp['data']
end

def accessibility_error_detail(resp, code)
  resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
end

def accessibility_publish_requires_live_app?(error_detail)
  detail = error_detail.to_s.downcase
  detail.include?("must be available on the app store to publish")
end

def normalize_attr_name(name)
  name.to_s.gsub(/[^a-z0-9]/i, '').downcase
end

def locked_attribute_from_error(error)
  pointer = error.dig('source', 'pointer').to_s
  if pointer =~ %r{/data/attributes/([^/]+)$}
    return Regexp.last_match(1)
  end

  detail = error['detail'].to_s
  return Regexp.last_match(1) if detail =~ /Attribute '([^']+)' cannot be edited/i
  return Regexp.last_match(1) if detail =~ /field '([^']+)' can not be modified/i

  nil
end

def patch_resource_attrs_with_lock_retry(path:, resource_type:, resource_id:, attrs:, token:, label:)
  pending = attrs.dup
  return true if pending.empty?

  loop do
    body = {
      data: {
        type: resource_type,
        id: resource_id,
        attributes: pending
      }
    }
    code, resp = asc_patch_with_status(path, body: body, token: token)
    return true if [200, 201].include?(code)

    errors = resp&.dig('errors')
    locked_name = Array(errors).map { |e| locked_attribute_from_error(e) }.compact.first

    if locked_name
      normalized_locked = normalize_attr_name(locked_name)
      key_to_drop = pending.keys.find { |k| normalize_attr_name(k) == normalized_locked }
      if key_to_drop
        pending.delete(key_to_drop)
        log_warn "#{label}: '#{key_to_drop}' is locked in current ASC state; skipping for now."
        return true if pending.empty?
        next
      end
    end

    log_error "#{label} update failed: #{accessibility_error_detail(resp, code)}"
    return false
  end
end

def parse_accessibility_decl_specs(raw_cfg)
  return [true, {}] unless raw_cfg.is_a?(Hash)

  publish = raw_cfg.key?('publish') ? parse_boolish(raw_cfg['publish']) : true
  publish = true if publish.nil?
  families = raw_cfg['families'].is_a?(Hash) ? raw_cfg['families'] : raw_cfg

  specs = {}
  families.each do |key, value|
    next if %w[publish families].include?(key.to_s)

    family = normalize_accessibility_family(key)
    unless family
      log_warn "Unknown accessibility family '#{key}' in .saneprocess; skipping."
      next
    end
    unless value.is_a?(Hash)
      log_warn "Accessibility family '#{key}' must map to a dictionary of supports_* flags; skipping."
      next
    end

    attrs = {}
    value.each do |attr_key, attr_value|
      attr_name = normalize_accessibility_attribute(attr_key)
      unless attr_name
        log_warn "Unknown accessibility attribute '#{attr_key}' for family '#{key}'; skipping."
        next
      end
      bool_value = parse_boolish(attr_value)
      if bool_value.nil?
        log_warn "Accessibility attribute '#{attr_key}' for family '#{key}' is not boolean; skipping."
        next
      end
      attrs[attr_name.to_sym] = bool_value
    end

    if attrs.empty?
      log_warn "No valid accessibility flags configured for family '#{key}'; skipping."
      next
    end

    specs[family] = attrs
  end

  [publish, specs]
end

def accessibility_attrs_match?(decl_attrs, desired_attrs)
  desired_attrs.all? do |key, value|
    decl_attrs[key.to_s] == value
  end
end

def accessibility_unmodifiable_state?(state)
  %w[PUBLISHED REPLACED].include?(state.to_s.upcase)
end

def ensure_accessibility_declarations(app_id, config, token, asc_platform: nil)
  raw_cfg = config.dig('appstore', 'accessibility_declarations')
  return true if raw_cfg.nil?

  publish, specs = parse_accessibility_decl_specs(raw_cfg)
  if asc_platform
    allowed = ACCESSIBILITY_FAMILIES_BY_PLATFORM[asc_platform] || []
    specs = specs.select { |family, _| allowed.include?(family) }
  end
  if specs.empty?
    log_warn 'appstore.accessibility_declarations is configured, but no valid family specs were found.'
    return true
  end

  existing = list_accessibility_declarations(app_id, token).each_with_object({}) do |decl, acc|
    family = decl.dig('attributes', 'deviceFamily')
    acc[family] = decl if family
  end

  ok = true
  specs.each do |family, attrs|
    existing_decl = existing[family]
    declaration_id = existing_decl&.dig('id')
    declaration_state = existing_decl&.dig('attributes', 'state').to_s
    declaration_attrs = existing_decl&.dig('attributes') || {}

    if declaration_id && accessibility_unmodifiable_state?(declaration_state)
      if accessibility_attrs_match?(declaration_attrs, attrs)
        log_info "Accessibility declaration #{declaration_id} (#{family}) already #{declaration_state} with requested attributes."
        next
      end

      # Published declarations are immutable; create a replacement draft.
      log_info "Accessibility declaration #{declaration_id} (#{family}) is #{declaration_state}; creating replacement declaration."
      declaration_id = nil
    end

    if declaration_id.nil?
      create_body = {
        data: {
          type: 'accessibilityDeclarations',
          attributes: attrs.merge(deviceFamily: family),
          relationships: {
            app: {
              data: { type: 'apps', id: app_id }
            }
          }
        }
      }
      create_code, create_resp = asc_post_with_status('/accessibilityDeclarations', body: create_body, token: token)
      if create_code == 201
        declaration_id = create_resp.dig('data', 'id')
        log_info "Created accessibility declaration for #{family}."
      else
        log_error "Failed to create accessibility declaration for #{family}: #{accessibility_error_detail(create_resp, create_code)}"
        ok = false
        next
      end
    end

    update_attrs = attrs.dup
    update_attrs[:publish] = true if publish
    update_body = {
      data: {
        type: 'accessibilityDeclarations',
        id: declaration_id,
        attributes: update_attrs
      }
    }
    update_code, update_resp = asc_patch_with_status("/accessibilityDeclarations/#{declaration_id}", body: update_body, token: token)
    if [200, 201].include?(update_code)
      action = publish ? 'updated + published' : 'updated'
      log_info "Accessibility declaration #{declaration_id} (#{family}) #{action}."
    else
      detail = accessibility_error_detail(update_resp, update_code)
      if publish && accessibility_publish_requires_live_app?(detail)
        log_warn "Accessibility declaration #{declaration_id} (#{family}) updated as draft; publish deferred until this platform is live."
        next
      end
      if update_code == 409 && accessibility_unmodifiable_state?(declaration_state) && accessibility_attrs_match?(declaration_attrs, attrs)
        log_info "Accessibility declaration #{declaration_id} (#{family}) is immutable but already matches desired attributes."
        next
      end
      log_error "Failed to update accessibility declaration #{declaration_id} (#{family}): #{detail}"
      ok = false
    end
  end

  ok
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

def ensure_app_info_localization(app_info_id, privacy_policy_url, token, locale: 'en-US', subtitle: nil)
  return true if app_info_id.to_s.empty?

  loc = find_locale_record("/appInfos/#{app_info_id}/appInfoLocalizations?limit=50", token, locale: locale)
  return false unless loc

  attrs = {}

  desired_privacy = privacy_policy_url.to_s.strip
  current_privacy = loc.dig('attributes', 'privacyPolicyUrl').to_s.strip
  attrs[:privacyPolicyUrl] = desired_privacy if !desired_privacy.empty? && current_privacy != desired_privacy

  desired_subtitle = subtitle.to_s.strip
  current_subtitle = loc.dig('attributes', 'subtitle').to_s.strip
  attrs[:subtitle] = desired_subtitle if !desired_subtitle.empty? && current_subtitle != desired_subtitle

  return true if attrs.empty?

  patch_resource_attrs_with_lock_retry(
    path: "/appInfoLocalizations/#{loc['id']}",
    resource_type: 'appInfoLocalizations',
    resource_id: loc['id'],
    attrs: attrs,
    token: token,
    label: 'App info localization'
  )
end

def ensure_version_localization(version_id, metadata, token, locale: 'en-US')
  loc = find_locale_record("/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50", token, locale: locale)
  return false unless loc

  attrs = {}
  {
    description: 'description',
    keywords: 'keywords',
    promotionalText: 'promotionalText',
    supportUrl: 'supportUrl',
    marketingUrl: 'marketingUrl',
    whatsNew: 'whatsNew'
  }.each do |target_key, metadata_key|
    value = present_value(metadata[metadata_key]) || present_value(metadata[target_key])
    attrs[target_key] = value if value
  end
  return true if attrs.empty?

  log_info "Updating version localization fields: #{attrs.keys.join(', ')}"
  patch_resource_attrs_with_lock_retry(
    path: "/appStoreVersionLocalizations/#{loc['id']}",
    resource_type: 'appStoreVersionLocalizations',
    resource_id: loc['id'],
    attrs: attrs,
    token: token,
    label: 'Version localization'
  )
end

def version_build_id(version_id, token)
  resp = asc_get("/appStoreVersions/#{version_id}/build", token: token)
  resp&.dig('data', 'id')
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
  code, resp = asc_get_with_status("/appStoreVersions/#{version_id}/ageRatingDeclaration", token: token)
  return if code == 404

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

def ensure_build_export_compliance(build_id, token, config:)
  return if build_id.to_s.empty?

  export_cfg = config.dig('appstore', 'export_compliance')
  unless export_cfg.is_a?(Hash) && (export_cfg.key?('uses_non_exempt_encryption') || export_cfg.key?(:uses_non_exempt_encryption))
    log_error 'Missing appstore.export_compliance.uses_non_exempt_encryption; refusing to assume Apple export compliance answers.'
    return false
  end
  declared_value = export_cfg.key?('uses_non_exempt_encryption') ? export_cfg['uses_non_exempt_encryption'] : export_cfg[:uses_non_exempt_encryption]
  declared_bool = parse_boolish(declared_value)
  if declared_bool.nil?
    log_error 'appstore.export_compliance.uses_non_exempt_encryption must be true or false.'
    return false
  end

  build_resp = asc_get("/builds/#{build_id}", token: token)
  uses_non_exempt = build_resp&.dig('data', 'attributes', 'usesNonExemptEncryption')
  return true if uses_non_exempt == declared_bool

  body = {
    data: {
      type: 'builds',
      id: build_id,
      attributes: { usesNonExemptEncryption: declared_bool }
    }
  }
  !!asc_patch("/builds/#{build_id}", body: body, token: token)
end

def ensure_minimum_review_metadata(app_id:, version_id:, build_id:, config:, token:, asc_platform:, project_root:)
  appstore_cfg = config['appstore'] || {}
  app_name = config['name'].to_s.strip
  app_name = 'SaneApps' if app_name.empty?

  readiness = metadata_review_readiness_report(
    config: config,
    asc_platform: asc_platform,
    app_name: app_name,
    project_root: project_root
  )
  readiness[:warnings].each { |msg| log_warn msg }
  unless readiness[:issues].empty?
    readiness[:issues].each { |msg| log_error msg }
    return false
  end

  content_rights = appstore_cfg['content_rights_declaration'].to_s.strip
  content_rights = 'DOES_NOT_USE_THIRD_PARTY_CONTENT' if content_rights.empty?
  ensure_content_rights_declaration(app_id, content_rights, token)

  app_info_id = latest_app_info_id(app_id, token)
  category_id = CATEGORY_ID_MAP[appstore_cfg['category'].to_s.strip]
  ensure_primary_category(app_info_id, category_id, token) if app_info_id && category_id

  metadata = resolve_version_metadata(
    appstore_cfg: appstore_cfg,
    app_name: app_name,
    asc_platform: asc_platform
  )
  subtitle = metadata[:subtitle] || metadata['subtitle']
  unless ensure_app_info_localization(app_info_id, appstore_cfg['privacy_policy_url'], token, subtitle: subtitle)
    log_error 'Failed to update app info localization.'
    return false
  end
  return false unless ensure_version_localization(version_id, metadata, token)

  return false unless ensure_accessibility_declarations(app_id, config, token, asc_platform: asc_platform)

  default_copyright = "#{Time.now.year} SaneApps"
  ensure_version_copyright(version_id, appstore_cfg['copyright'].to_s.strip.empty? ? default_copyright : appstore_cfg['copyright'], token)
  ensure_age_rating_declaration(version_id, token)
  return false unless ensure_build_export_compliance(build_id, token, config: config)
  true
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

def wait_for_app_screenshot_removal(screenshot_id:, token:, timeout_seconds: 20)
  deadline = Time.now + timeout_seconds

  loop do
    code, resp = asc_get_with_status("/appScreenshots/#{screenshot_id}", token: token)
    return true if code == 404 || resp['data'].nil?
    return false if Time.now >= deadline

    sleep 2
  end
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
        screenshot_id = ss['id']
        state = ss.dig('attributes', 'assetDeliveryState', 'state')
        delete_code, delete_resp = asc_delete_with_status("/appScreenshots/#{screenshot_id}", token: token)
        unless [200, 202, 204, 404].include?(delete_code)
          detail = delete_resp.dig('errors', 0, 'detail') || delete_resp.dig('errors', 0, 'title') || 'unknown error'
          log_warn "Failed to remove existing screenshot #{screenshot_id} (#{state || 'unknown'}): #{detail}"
          next
        end

        wait_for_app_screenshot_removal(screenshot_id: screenshot_id, token: token, timeout_seconds: 20)
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

# ─── IAP Readiness ───

def first_matching_file(project_root, globs)
  globs.each do |glob|
    next if glob.to_s.strip.empty?

    pattern = File.join(project_root, glob.to_s)
    match = Dir.glob(pattern).sort.first
    return match if match && File.file?(match)
  end
  nil
end

def image_dimensions(path)
  out, status = Open3.capture2('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path)
  return [0, 0] unless status.success?

  width = out[/pixelWidth:\s+(\d+)/, 1].to_i
  height = out[/pixelHeight:\s+(\d+)/, 1].to_i
  [width, height]
rescue StandardError
  [0, 0]
end

def largest_matching_file(project_root, globs)
  candidates = globs.flat_map do |glob|
    next [] if glob.to_s.strip.empty?

    Dir.glob(File.join(project_root, glob.to_s)).select { |path| File.file?(path) }
  end

  candidates.max_by do |path|
    width, height = image_dimensions(path)
    width * height
  end
end

def iap_review_screenshot_target(config)
  platforms = Array(config.dig('appstore', 'platforms')).map { |entry| entry.to_s.downcase }
  project_type = config['type'].to_s.downcase

  if project_type == 'macos_app' || platforms.include?('macos')
    IAP_REVIEW_SCREENSHOT_TARGETS['macos']
  elsif platforms.include?('ipad')
    IAP_REVIEW_SCREENSHOT_TARGETS['ipad']
  else
    IAP_REVIEW_SCREENSHOT_TARGETS['ios']
  end
end

def resolve_iap_review_screenshot(project_root, config)
  screenshots = config.dig('appstore', 'screenshots') || {}
  target = iap_review_screenshot_target(config)
  preferred_globs =
    if target == IAP_REVIEW_SCREENSHOT_TARGETS['macos']
      [screenshots['macos'], screenshots['ipad'], screenshots['ios'], screenshots['ios_67'], screenshots['ios_65']]
    elsif target == IAP_REVIEW_SCREENSHOT_TARGETS['ipad']
      [screenshots['ipad'], screenshots['ios'], screenshots['ios_67'], screenshots['ios_65'], screenshots['macos']]
    else
      [screenshots['ios'], screenshots['ios_67'], screenshots['ios_65'], screenshots['ipad'], screenshots['macos']]
    end.compact

  [largest_matching_file(project_root, preferred_globs), target]
end

def normalized_iap_localization_name(name)
  value = name.to_s.strip.gsub(/\s+/, ' ')
  return value if value.length <= IAP_LOCALIZATION_NAME_MAX

  value[0, IAP_LOCALIZATION_NAME_MAX].rstrip
end

def normalized_iap_localization_description(description = nil)
  value = description.to_s.strip
  value = IAP_DEFAULT_LOCALIZATION_DESCRIPTION if value.empty?
  value = value.gsub(/\s+/, ' ')
  value[0, IAP_LOCALIZATION_DESCRIPTION_MAX].rstrip
end

def iap_localization_locked_for_active_state?(code, detail)
  return false unless code == 409

  message = detail.to_s
  return false if message.empty?

  message.match?(/ACTIVE state/i) && message.match?(/cannot edit|cannot be edited|can not be modified/i)
end

def upload_presigned_chunk(upload_url, headers, chunk)
  uri = URI(upload_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.read_timeout = 120

  req = Net::HTTP::Put.new(uri)
  headers.each { |h| req[h['name']] = h['value'] }
  req.body = chunk

  response = http.request(req)
  response.code.to_i
end

def ensure_iap_localization(iap_id:, iap_name:, iap_description:, token:)
  desired_name = normalized_iap_localization_name(iap_name)
  desired_description = normalized_iap_localization_description(iap_description)

  code, resp = asc_get_v2("/inAppPurchases/#{iap_id}/inAppPurchaseLocalizations?limit=50", token: token)
  unless code == 200
    log_error "Could not read IAP localizations (HTTP #{code})."
    return false
  end

  existing = resp.fetch('data', []).find { |loc| loc.dig('attributes', 'locale') == 'en-US' }
  if existing && existing.dig('attributes', 'state') == 'REJECTED'
    log_error 'ASC has this IAP localization in REJECTED state.'
    log_error 'Apple requires a new In-App Purchase for rejected IAP metadata. Rotate appstore.product_id and rerun.'
    return false
  end

  if existing
    attrs = {}
    current_name = existing.dig('attributes', 'name').to_s.strip
    current_description = existing.dig('attributes', 'description').to_s.strip
    attrs[:name] = desired_name if current_name != desired_name
    attrs[:description] = desired_description if current_description != desired_description
    return true if attrs.empty?

    patch_body = {
      data: {
        type: 'inAppPurchaseLocalizations',
        id: existing['id'],
        attributes: attrs
      }
    }
    patch_code, patch_resp = asc_patch_with_status(
      "/inAppPurchaseLocalizations/#{existing['id']}",
      body: patch_body,
      token: token
    )
    if [200, 201].include?(patch_code)
      log_info 'Updated IAP localization (en-US).'
      return true
    end

    detail = patch_resp.dig('errors', 0, 'detail') || patch_resp.dig('errors', 0, 'title') || 'unknown error'
    if iap_localization_locked_for_active_state?(patch_code, detail)
      state = existing.dig('attributes', 'state').to_s
      log_warn "IAP localization (en-US) is locked in ASC state #{state}; leaving the current live copy unchanged."
      return true
    end
    log_error "Failed to update IAP localization (HTTP #{patch_code}): #{detail}"
    return false
  end

  body = {
    data: {
      type: 'inAppPurchaseLocalizations',
      attributes: {
        locale: 'en-US',
        name: desired_name,
        description: desired_description
      },
      relationships: {
        inAppPurchaseV2: {
          data: { type: 'inAppPurchases', id: iap_id }
        }
      }
    }
  }

  create_code, create_resp = asc_post_with_status('/inAppPurchaseLocalizations', body: body, token: token)
  if [200, 201].include?(create_code)
    log_info 'Created IAP localization (en-US).'
    true
  else
    detail = create_resp.dig('errors', 0, 'detail') || create_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to create IAP localization (HTTP #{create_code}): #{detail}"
    false
  end
end

def ensure_iap_price_schedule(iap_id:, target_price_usd:, token:)
  code, schedule = asc_get_v2("/inAppPurchases/#{iap_id}/iapPriceSchedule", token: token)
  if code == 200 && !schedule['data'].nil?
    schedule_id = schedule.dig('data', 'id')
    manual_code, manual_prices = asc_get_with_status(
      "/inAppPurchasePriceSchedules/#{schedule_id}/manualPrices?include=inAppPurchasePricePoint,territory&filter%5Bterritory%5D=USA&fields%5BinAppPurchasePricePoints%5D=customerPrice&limit=50",
      token: token
    )

    unless manual_code == 200
      log_error "Could not verify existing IAP price schedule (HTTP #{manual_code})."
      return false
    end

    price_points = manual_prices.fetch('included', [])
                                .select { |entry| entry['type'] == 'inAppPurchasePricePoints' }
                                .each_with_object({}) do |entry, acc|
                                  acc[entry['id']] = entry.dig('attributes', 'customerPrice').to_s
                                end
    now_date = Date.today
    matching_price = manual_prices.fetch('data', []).find do |price|
      attrs = price['attributes'] || {}
      start_date = attrs['startDate'].to_s
      end_date = attrs['endDate'].to_s
      starts_now = start_date.empty? || Date.parse(start_date) <= now_date
      ends_later = end_date.empty? || Date.parse(end_date) >= now_date
      price_point_id = price.dig('relationships', 'inAppPurchasePricePoint', 'data', 'id')

      starts_now && ends_later && price_points[price_point_id] == target_price_usd.to_s
    rescue ArgumentError
      false
    end

    if matching_price
      log_info "Existing IAP price schedule verified (USA #{target_price_usd})."
      return true
    end

    observed_prices = price_points.values.uniq.reject(&:empty?).join(', ')
    observed_prices = 'none' if observed_prices.empty?
    log_warn "Existing IAP price schedule does not match USA #{target_price_usd} (observed: #{observed_prices}); creating requested schedule."
  end

  pp_code, point = find_iap_price_point(iap_id: iap_id, target_price_usd: target_price_usd, token: token)
  unless pp_code == 200
    log_error "Could not read IAP price points (HTTP #{pp_code})."
    return false
  end

  unless point
    log_error "No USA price point found for #{target_price_usd}."
    return false
  end

  local_id = '${price-usd}'
  body = {
    data: {
      type: 'inAppPurchasePriceSchedules',
      relationships: {
        inAppPurchase: { data: { type: 'inAppPurchases', id: iap_id } },
        baseTerritory: { data: { type: 'territories', id: 'USA' } },
        manualPrices: { data: [{ type: 'inAppPurchasePrices', id: local_id }] }
      }
    },
    included: [
      {
        type: 'inAppPurchasePrices',
        id: local_id,
        attributes: { startDate: nil },
        relationships: {
          inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap_id } },
          inAppPurchasePricePoint: { data: { type: 'inAppPurchasePricePoints', id: point['id'] } }
        }
      }
    ]
  }

  create_code, create_resp = asc_post_with_status('/inAppPurchasePriceSchedules', body: body, token: token)
  if [200, 201].include?(create_code)
    log_info "Created IAP price schedule (USA #{target_price_usd})."
    true
  else
    detail = create_resp.dig('errors', 0, 'detail') || create_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to create IAP price schedule (HTTP #{create_code}): #{detail}"
    false
  end
end

def resolve_iap_price_usd(config, options)
  explicit = options[:iap_price_usd].to_s.strip
  return explicit unless explicit.empty?

  configured = config.dig('appstore', 'iap_price_usd').to_s.strip
  return configured unless configured.empty?

  IAP_DEFAULT_USD_PRICE
end

def find_iap_price_point(iap_id:, target_price_usd:, token:)
  path = "/inAppPurchases/#{iap_id}/pricePoints?filter%5Bterritory%5D=USA&limit=200"

  loop do
    code, points = asc_get_v2(path, token: token)
    return [code, nil] unless code == 200

    entries = points.fetch('data', [])
    point = entries.find { |entry| entry.dig('attributes', 'customerPrice').to_s == target_price_usd.to_s }
    return [200, point] if point

    next_url = points.dig('links', 'next').to_s
    break if entries.empty?
    break if next_url.empty?

    uri = URI(next_url)
    path = uri.path.sub(%r{\A/v2}, '')
    path = "#{path}?#{uri.query}" if uri.query
  end

  [200, nil]
end

def iap_review_screenshot_state(screenshot_resp)
  data = screenshot_resp['data']
  return [nil, nil] unless data.is_a?(Hash)

  attrs = data['attributes'] || {}
  state =
    attrs.dig('assetDeliveryState', 'state') ||
    attrs['fileStatus'] ||
    attrs.dig('assetDeliveryState', 'errors', 0, 'code')

  [data['id'], state]
end

def iap_review_screenshot_ready?(state)
  %w[UPLOAD_COMPLETE COMPLETE].include?(state.to_s)
end

def prepare_iap_review_screenshot(src, target_w:, target_h:)
  resized = resize_screenshot(src, target_w, target_h)
  return nil unless resized && File.file?(resized)

  dims = `sips -g pixelWidth -g pixelHeight #{Shellwords.escape(resized)} 2>/dev/null`
  return resized if dims.include?("pixelWidth: #{target_w}") && dims.include?("pixelHeight: #{target_h}")

  File.delete(resized) if File.exist?(resized)
  nil
end

def wait_for_iap_review_screenshot_removal(iap_id:, token:, timeout_seconds: 20)
  deadline = Time.now + timeout_seconds

  loop do
    code, resp = asc_get_v2("/inAppPurchases/#{iap_id}/appStoreReviewScreenshot", token: token)
    return true if code == 404 || resp['data'].nil?
    return false if Time.now >= deadline

    sleep 2
  end
end

def reserve_iap_review_screenshot_upload(iap_id:, screenshot_path:, token:)
  reservation_body = {
    data: {
      type: 'inAppPurchaseAppStoreReviewScreenshots',
      attributes: {
        fileName: File.basename(screenshot_path),
        fileSize: File.size(screenshot_path)
      },
      relationships: {
        inAppPurchaseV2: {
          data: { type: 'inAppPurchases', id: iap_id }
        }
      }
    }
  }

  reserve_code, reserve_resp = asc_post_with_status(
    '/inAppPurchaseAppStoreReviewScreenshots',
    body: reservation_body,
    token: token
  )
  return [reserve_code, reserve_resp] unless reserve_code == 409

  detail = reserve_resp.dig('errors', 0, 'detail').to_s
  return [reserve_code, reserve_resp] unless detail.match?(/Screenshot already exists/i)

  if wait_for_iap_review_screenshot_removal(iap_id: iap_id, token: token, timeout_seconds: 20)
    asc_post_with_status('/inAppPurchaseAppStoreReviewScreenshots', body: reservation_body, token: token)
  else
    [reserve_code, reserve_resp]
  end
end

def ensure_iap_review_screenshot(iap_id:, screenshot_path:, screenshot_target:, token:)
  code, screenshot_resp = asc_get_v2("/inAppPurchases/#{iap_id}/appStoreReviewScreenshot", token: token)
  prepared_path = nil

  if code == 200 && !screenshot_resp['data'].nil?
    screenshot_id, state = iap_review_screenshot_state(screenshot_resp)
    return true if iap_review_screenshot_ready?(state)

    if screenshot_id
      delete_code, delete_resp = asc_delete_with_status(
        "/inAppPurchaseAppStoreReviewScreenshots/#{screenshot_id}",
        token: token
      )
      unless [200, 202, 204, 404].include?(delete_code)
        detail = delete_resp.dig('errors', 0, 'detail') || delete_resp.dig('errors', 0, 'title') || 'unknown error'
        log_error "Failed to replace existing IAP review screenshot (HTTP #{delete_code}): #{detail}"
        return false
      end
      unless wait_for_iap_review_screenshot_removal(iap_id: iap_id, token: token, timeout_seconds: 20)
        log_error 'Timed out waiting for old IAP review screenshot to be removed.'
        return false
      end
      log_warn "Replacing existing IAP review screenshot in state #{state || 'unknown'}."
    end
  end

  unless screenshot_path && File.file?(screenshot_path)
    log_error 'IAP review screenshot is missing and no screenshot file was found from appstore.screenshots.'
    return false
  end

  prepared_path = prepare_iap_review_screenshot(
    screenshot_path,
    target_w: screenshot_target.fetch(:width),
    target_h: screenshot_target.fetch(:height)
  )
  unless prepared_path && File.file?(prepared_path)
    log_error "Failed to prepare a valid #{screenshot_target[:width]}x#{screenshot_target[:height]} IAP review screenshot."
    return false
  end

  reserve_code, reserve_resp = reserve_iap_review_screenshot_upload(
    iap_id: iap_id,
    screenshot_path: prepared_path,
    token: token
  )
  unless reserve_code == 201
    detail = reserve_resp.dig('errors', 0, 'detail') || reserve_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to reserve IAP review screenshot upload (HTTP #{reserve_code}): #{detail}"
    return false
  end

  screenshot_id = reserve_resp.dig('data', 'id')
  upload_ops = reserve_resp.dig('data', 'attributes', 'uploadOperations') || []

  upload_ops.each_with_index do |op, idx|
    chunk = File.binread(prepared_path, op['length'], op['offset'])
    upload_code = upload_presigned_chunk(op['url'], op['requestHeaders'] || [], chunk)
    unless upload_code.between?(200, 299)
      log_error "IAP review screenshot chunk #{idx} upload failed (HTTP #{upload_code})."
      return false
    end
  end

  commit_body = {
    data: {
      type: 'inAppPurchaseAppStoreReviewScreenshots',
      id: screenshot_id,
      attributes: {
        uploaded: true,
        sourceFileChecksum: Digest::MD5.hexdigest(File.binread(prepared_path))
      }
    }
  }

  commit_code, commit_resp = asc_patch_with_status("/inAppPurchaseAppStoreReviewScreenshots/#{screenshot_id}", body: commit_body, token: token)
  if [200, 201].include?(commit_code)
    verify_code, verify_resp = asc_get_v2("/inAppPurchases/#{iap_id}/appStoreReviewScreenshot", token: token)
    _, verify_state = iap_review_screenshot_state(verify_resp)
    if verify_code == 200 && !verify_state.to_s.empty? && !iap_review_screenshot_ready?(verify_state)
      log_error "IAP review screenshot uploaded, but ASC reports state #{verify_state}."
      false
    else
      log_info "Uploaded IAP review screenshot (#{File.basename(prepared_path)})."
      true
    end
  else
    detail = commit_resp.dig('errors', 0, 'detail') || commit_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to commit IAP review screenshot (HTTP #{commit_code}): #{detail}"
    false
  end
ensure
  File.delete(prepared_path) if prepared_path && prepared_path.start_with?('/tmp/screenshot_canvas_') && File.exist?(prepared_path)
end

def subscription_review_screenshot_rows(subscription_id:, token:)
  code, resp = asc_get_with_status(
    "/subscriptions/#{subscription_id}?include=appStoreReviewScreenshot",
    token: token
  )
  return [] unless code == 200

  Array(resp['included']).select { |entry| entry['type'] == 'subscriptionAppStoreReviewScreenshots' }
end

def review_screenshot_asset_state(row)
  attrs = row['attributes'] || {}
  attrs.dig('assetDeliveryState', 'state') ||
    attrs['fileStatus'] ||
    attrs.dig('assetDeliveryState', 'errors', 0, 'code')
end

def reserve_subscription_review_screenshot_upload(subscription_id:, screenshot_path:, token:)
  reservation_body = {
    data: {
      type: 'subscriptionAppStoreReviewScreenshots',
      attributes: {
        fileName: File.basename(screenshot_path),
        fileSize: File.size(screenshot_path)
      },
      relationships: {
        subscription: {
          data: { type: 'subscriptions', id: subscription_id }
        }
      }
    }
  }

  asc_post_with_status('/subscriptionAppStoreReviewScreenshots', body: reservation_body, token: token)
end

def ensure_subscription_review_screenshot(subscription_id:, screenshot_path:, screenshot_target:, token:)
  rows = subscription_review_screenshot_rows(subscription_id: subscription_id, token: token)
  ready_row = rows.find { |row| iap_review_screenshot_ready?(review_screenshot_asset_state(row)) }
  return true if ready_row

  rows.each do |row|
    screenshot_id = row['id'].to_s
    next if screenshot_id.empty?

    delete_code, delete_resp = asc_delete_with_status(
      "/subscriptionAppStoreReviewScreenshots/#{screenshot_id}",
      token: token
    )
    unless [200, 202, 204, 404].include?(delete_code)
      detail = delete_resp.dig('errors', 0, 'detail') || delete_resp.dig('errors', 0, 'title') || 'unknown error'
      log_error "Failed to replace existing subscription review screenshot (HTTP #{delete_code}): #{detail}"
      return false
    end
  end

  unless screenshot_path && File.file?(screenshot_path)
    log_error 'Subscription review screenshot is missing and no screenshot file was found from appstore.screenshots.'
    return false
  end

  prepared_path = prepare_iap_review_screenshot(
    screenshot_path,
    target_w: screenshot_target.fetch(:width),
    target_h: screenshot_target.fetch(:height)
  )
  unless prepared_path && File.file?(prepared_path)
    log_error "Failed to prepare a valid #{screenshot_target[:width]}x#{screenshot_target[:height]} subscription review screenshot."
    return false
  end

  reserve_code, reserve_resp = reserve_subscription_review_screenshot_upload(
    subscription_id: subscription_id,
    screenshot_path: prepared_path,
    token: token
  )
  unless reserve_code == 201
    detail = reserve_resp.dig('errors', 0, 'detail') || reserve_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to reserve subscription review screenshot upload (HTTP #{reserve_code}): #{detail}"
    return false
  end

  screenshot_id = reserve_resp.dig('data', 'id')
  upload_ops = reserve_resp.dig('data', 'attributes', 'uploadOperations') || []

  upload_ops.each_with_index do |op, idx|
    chunk = File.binread(prepared_path, op['length'], op['offset'])
    upload_code = upload_presigned_chunk(op['url'], op['requestHeaders'] || [], chunk)
    unless upload_code.between?(200, 299)
      log_error "Subscription review screenshot chunk #{idx} upload failed (HTTP #{upload_code})."
      return false
    end
  end

  commit_body = {
    data: {
      type: 'subscriptionAppStoreReviewScreenshots',
      id: screenshot_id,
      attributes: {
        uploaded: true,
        sourceFileChecksum: Digest::MD5.hexdigest(File.binread(prepared_path))
      }
    }
  }

  commit_code, commit_resp = asc_patch_with_status(
    "/subscriptionAppStoreReviewScreenshots/#{screenshot_id}",
    body: commit_body,
    token: token
  )
  if [200, 201].include?(commit_code)
    log_info "Uploaded subscription review screenshot (#{File.basename(prepared_path)})."
    true
  else
    detail = commit_resp.dig('errors', 0, 'detail') || commit_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to commit subscription review screenshot (HTTP #{commit_code}): #{detail}"
    false
  end
ensure
  File.delete(prepared_path) if prepared_path && prepared_path.start_with?('/tmp/screenshot_canvas_') && File.exist?(prepared_path)
end

def ensure_iap_availability(iap_id:, token:)
  code, availability_resp = asc_get_v2("/inAppPurchases/#{iap_id}/inAppPurchaseAvailability", token: token)
  return true if code == 200 && !availability_resp['data'].nil?

  body = {
    data: {
      type: 'inAppPurchaseAvailabilities',
      attributes: { availableInNewTerritories: true },
      relationships: {
        inAppPurchase: { data: { type: 'inAppPurchases', id: iap_id } },
        availableTerritories: { data: [{ type: 'territories', id: 'USA' }] }
      }
    }
  }

  create_code, create_resp = asc_post_with_status('/inAppPurchaseAvailabilities', body: body, token: token)
  if [200, 201].include?(create_code)
    log_info 'Created IAP availability.'
    true
  else
    detail = create_resp.dig('errors', 0, 'detail') || create_resp.dig('errors', 0, 'title') || 'unknown error'
    log_error "Failed to create IAP availability (HTTP #{create_code}): #{detail}"
    false
  end
end

def app_availability_local_id(index)
  "territory-#{index}"
end

def list_app_store_territory_ids(token:)
  territory_ids = []
  path = '/territories?limit=200'

  loop do
    code, resp = asc_get_with_status(path, token: token)
    unless code == 200 && resp.is_a?(Hash)
      detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || 'unknown error'
      log_error "Failed to list App Store territories (HTTP #{code}): #{detail}"
      return []
    end

    territory_ids.concat(Array(resp['data']).map { |row| row['id'].to_s.strip }.reject(&:empty?))
    next_url = resp.dig('links', 'next').to_s
    break if next_url.empty?

    uri = URI(next_url)
    path = uri.query.to_s.empty? ? uri.path : "#{uri.path}?#{uri.query}"
  end

  territory_ids.uniq.sort
end

def ensure_app_availability(app_id:, token:)
  code, availability_resp = asc_get_with_status("/apps/#{app_id}/appAvailabilityV2", token: token)
  if code == 200 && availability_resp['data']
    log_info 'App availability exists.'
    return true
  end

  unless code == 404
    detail = availability_resp.dig('errors', 0, 'detail') ||
             availability_resp.dig('errors', 0, 'title') ||
             availability_resp['error'] ||
             'unknown error'
    log_error "Failed to read app availability (HTTP #{code}): #{detail}"
    return false
  end

  territory_ids = list_app_store_territory_ids(token: token)
  if territory_ids.empty?
    log_error 'No App Store territories returned; refusing to create empty app availability.'
    return false
  end

  linkages = []
  included = []
  territory_ids.each_with_index do |territory_id, index|
    local_id = app_availability_local_id(index)
    linkages << { type: 'territoryAvailabilities', lid: local_id }
    included << {
      type: 'territoryAvailabilities',
      lid: local_id,
      attributes: {
        available: true,
        preOrderEnabled: false
      },
      relationships: {
        territory: { data: { type: 'territories', id: territory_id } }
      }
    }
  end

  body = {
    data: {
      type: 'appAvailabilities',
      attributes: { availableInNewTerritories: true },
      relationships: {
        app: { data: { type: 'apps', id: app_id } },
        territoryAvailabilities: { data: linkages }
      }
    },
    included: included
  }

  create_code, create_resp = asc_post_with_status(
    '/appAvailabilities',
    body: body,
    token: token,
    base: ASC_V2_BASE
  )
  if [200, 201].include?(create_code)
    log_info "Created app availability for #{territory_ids.length} territories."
    return true
  end

  detail = create_resp.dig('errors', 0, 'detail') || create_resp.dig('errors', 0, 'title') || 'unknown error'
  log_error "Failed to create app availability (HTTP #{create_code}): #{detail}"
  false
end

def ensure_iap_review_note(iap_id:, review_note:, token:)
  body = {
    data: {
      type: 'inAppPurchases',
      id: iap_id,
      attributes: {
        reviewNote: review_note.to_s.strip.empty? ? IAP_DEFAULT_REVIEW_NOTE : review_note.to_s.strip
      }
    }
  }

  patch_code, patch_resp = asc_patch_with_status("/inAppPurchases/#{iap_id}", body: body, token: token, base: ASC_V2_BASE)
  if [200, 201].include?(patch_code)
    true
  else
    detail = patch_resp.dig('errors', 0, 'detail') || patch_resp.dig('errors', 0, 'title') || 'unknown error'
    if patch_code == 409 && detail.to_s.match?(/APP_STORE_REVIEW_INFO|can not be modified|cannot be edited/i)
      log_warn "IAP review note is locked in the current ASC state; leaving it unchanged."
      return true
    end
    log_error "Failed to patch IAP review note (HTTP #{patch_code}): #{detail}"
    false
  end
end

def find_iap_by_product_id(app_id:, product_id:, token:)
  resp = asc_get("/apps/#{app_id}/inAppPurchasesV2?limit=200", token: token)
  return nil unless resp && resp['data'].is_a?(Array)

  resp['data'].find { |entry| entry.dig('attributes', 'productId') == product_id }
end

def list_app_iaps(app_id:, token:)
  resp = asc_get("/apps/#{app_id}/inAppPurchasesV2?limit=200", token: token)
  return [] unless resp && resp['data'].is_a?(Array)

  resp['data']
end

def auto_renewable_subscription_config?(config)
  type = config.dig('appstore', 'iap', 'type').to_s.strip
  type == 'auto_renewable_subscription' || type == 'subscription' || type.include?('auto_renewable')
end

def list_app_subscriptions(app_id:, token:)
  resp = asc_get("/apps/#{app_id}/subscriptionGroups?include=subscriptions&limit=200", token: token)
  included = Array(resp&.dig('included')).select { |entry| entry['type'] == 'subscriptions' }
  return included unless included.empty?

  Array(resp&.dig('data')).flat_map do |group|
    group_id = group['id'].to_s
    next [] if group_id.empty?

    group_resp = asc_get("/subscriptionGroups/#{group_id}/subscriptions?limit=200", token: token)
    Array(group_resp&.dig('data'))
  end
end

def no_iap_policy?(config)
  config.dig('appstore', 'iap_policy').to_s.strip.downcase == 'none'
end

def retired_iap_product_ids(config)
  Array(config.dig('appstore', 'retired_product_ids'))
    .map { |value| value.to_s.strip }
    .reject(&:empty?)
    .uniq
end

def retired_subscription_names(config, subscriptions)
  ids = retired_iap_product_ids(config)
  subscriptions.select { |entry| ids.include?(entry.dig('attributes', 'productId').to_s.strip) }
               .map { |entry| entry.dig('attributes', 'name').to_s.strip }
               .reject(&:empty?)
end

def included_assets_iap_section_text(body)
  text = body.to_s
  return '' if text.empty?

  start = text.index('Included Assets')
  return '' unless start

  chunk = text[start..]
  end_markers = [
    'App Review Information', 'Version Information', 'Routing App Coverage',
    'App Store Version Release', 'Phased Release', 'Reset Summary Rating'
  ]
  ends = end_markers.map { |marker| chunk.index(marker) }.compact
  chunk = ends.empty? ? chunk : chunk[0...ends.min]
  chunk.strip
end

def included_assets_section_lists_retired_iap?(section_text, retired_product_ids:, retired_names: [])
  section = section_text.to_s
  return false if section.empty?

  if retired_product_ids.any? { |product_id| section.include?(product_id.to_s) }
    return true
  end
  if retired_names.any? { |name| !name.empty? && section.include?(name) }
    return true
  end

  help_only = section.include?('can now be submitted for review from the In-App Purchases')
  section.match?(/monthly subscription/i) && !help_only
end

def subscription_has_rejected_version?(subscription_id:, token:)
  code, response = asc_get_with_status("/subscriptions/#{subscription_id}/versions?limit=200", token: token)
  return true unless code == 200

  Array(response['data']).any? do |entry|
    entry.dig('attributes', 'state').to_s == 'DEVELOPER_REJECTED'
  end
end

def write_no_iap_readiness_receipt(project_root:, app_id:, version_id:, subscriptions:)
  root = File.expand_path(project_root)
  path = File.join(root, 'outputs', 'appstore_no_iap_readiness_receipt.json')
  FileUtils.mkdir_p(File.dirname(path))
  payload = {
    'generated_at' => Time.now.utc.iso8601,
    'app_id' => app_id.to_s,
    'version_id' => version_id.to_s,
    'iap_policy' => 'none',
    'retired_subscriptions' => subscriptions.map do |entry|
      {
        'id' => entry['id'].to_s,
        'product_id' => entry.dig('attributes', 'productId').to_s,
        'name' => entry.dig('attributes', 'name').to_s,
        'state' => entry.dig('attributes', 'state').to_s
      }
    end,
    'included_assets_empty' => true
  }
  File.write(path, JSON.pretty_generate(payload))
  path
end

def ensure_no_iap_readiness(
  app_id:,
  version_id:,
  platform:,
  config:,
  token:,
  linked_submission: nil,
  project_root: Dir.pwd
)
  unless no_iap_policy?(config)
    log_error 'No-IAP readiness requires appstore.iap_policy: none.'
    return false
  end

  retired_ids = retired_iap_product_ids(config)
  subscriptions = list_app_subscriptions(app_id: app_id, token: token)
  subscription_ids = subscriptions.map { |entry| entry.dig('attributes', 'productId').to_s.strip }
  unexpected_subscriptions = subscription_ids.reject { |product_id| retired_ids.include?(product_id) }
  unless unexpected_subscriptions.empty?
    log_error "No-IAP policy found unapproved subscriptions: #{unexpected_subscriptions.join(', ')}"
    return false
  end

  iaps = list_app_iaps(app_id: app_id, token: token)
  unless iaps.empty?
    product_ids = iaps.map { |entry| entry.dig('attributes', 'productId').to_s.strip }
    log_error "No-IAP policy found in-app purchases: #{product_ids.join(', ')}"
    return false
  end

  subscriptions.each do |subscription|
    subscription_id = subscription['id'].to_s
    product_id = subscription.dig('attributes', 'productId').to_s.strip
    code, availability = asc_get_with_status(
      "/subscriptions/#{subscription_id}/subscriptionAvailability" \
      '?include=availableTerritories&limit[availableTerritories]=50',
      token: token
    )
    available_in_new = availability.dig('data', 'attributes', 'availableInNewTerritories')
    territory_total = availability.dig(
      'data', 'relationships', 'availableTerritories', 'meta', 'paging', 'total'
    )
    territory_rows = Array(availability.dig(
      'data', 'relationships', 'availableTerritories', 'data'
    ))
    unless code == 200 && available_in_new == false &&
           territory_total.to_i.zero? && territory_rows.empty?
      log_error(
        "Retired subscription #{product_id} is still available " \
        "(HTTP #{code}, newTerritories=#{available_in_new.inspect}, territories=#{territory_total.inspect})."
      )
      return false
    end

    attachment = iap_version_attachment_status(
      app_id: app_id,
      platform: platform,
      product_id: product_id
    )
    unless attachment == :not_attached
      log_error(
        "Retired subscription #{product_id} attachment state is #{attachment}; " \
        'Included Assets must prove it is absent in signed-in Brave.'
      )
      return false
    end

    if subscription_has_rejected_version?(subscription_id: subscription_id, token: token)
      # App Store Connect refuses permanent deletion after a subscription version is
      # DEVELOPER_REJECTED. Unavailable + detached is the strongest tombstone ASC allows.
      log_warn(
        "Retired subscription #{product_id} still exists with a DEVELOPER_REJECTED version " \
        '(ASC will not delete it). Confirmed unavailable and absent from Included Assets; ' \
        'Resolution Center must state the product is retired/not offered.'
      )
    end
    log_info "Retired subscription #{product_id} is unavailable and absent from Included Assets."
  end

  if linked_submission && linked_submission[:id]
    path = "/reviewSubmissions/#{linked_submission[:id]}/items?include=appStoreVersion&limit=200"
    code, response = asc_get_with_status(path, token: token)
    items = Array(response['data'])
    only_version = code == 200 && !items.empty? && items.all? do |item|
      relationships = item.fetch('relationships', {})
      relationships.keys == ['appStoreVersion'] &&
        relationships.dig('appStoreVersion', 'data', 'id').to_s == version_id.to_s
    end
    unless only_version
      log_error 'Review submission contains an item other than the selected app version.'
      return false
    end
    log_info "Review submission #{linked_submission[:id]} contains only app version #{version_id}."
  end

  platform_path = platform.to_s.downcase == 'ios' ? 'ios' : 'macos'
  snapshot = brave_page_snapshot(
    url: "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/#{platform_path}/version/inflight",
    delay_seconds: 10
  )
  section = included_assets_iap_section_text(snapshot['body'])
  retired_names = retired_subscription_names(config, subscriptions)
  if included_assets_section_lists_retired_iap?(
    section,
    retired_product_ids: retired_ids,
    retired_names: retired_names
  )
    log_error(
      'Included Assets still lists a retired in-app purchase or subscription on the inflight version page. ' \
      'Open App Store Connect in Brave, clear Included Assets, save, and rerun --iap-only before submission.'
    )
    return false
  end

  receipt_path = write_no_iap_readiness_receipt(
    project_root: project_root,
    app_id: app_id,
    version_id: version_id,
    subscriptions: subscriptions.select do |entry|
      retired_ids.include?(entry.dig('attributes', 'productId').to_s.strip)
    end
  )
  log_info "No-IAP readiness receipt: #{receipt_path}"

  true
end

def find_subscription_by_product_id(app_id:, product_id:, token:)
  list_app_subscriptions(app_id: app_id, token: token).find do |entry|
    entry.dig('attributes', 'productId').to_s.strip == product_id.to_s.strip
  end
end

def delete_obsolete_draft_subscription_and_group(
  app_id:,
  subscription_id:,
  group_id:,
  expected_product_id:,
  expected_name:,
  token:
)
  subscription_code, subscription_response = asc_get_with_status(
    "/subscriptions/#{subscription_id}",
    token: token
  )
  unless subscription_code == 200
    raise "Refusing deletion: subscription #{subscription_id} read returned HTTP #{subscription_code}."
  end

  subscription = subscription_response['data']
  attributes = subscription&.fetch('attributes', {}) || {}
  identity_matches =
    subscription&.fetch('id', nil).to_s == subscription_id.to_s &&
    subscription&.fetch('type', nil).to_s == 'subscriptions' &&
    attributes['productId'].to_s == expected_product_id.to_s &&
    attributes['name'].to_s == expected_name.to_s &&
    attributes['state'].to_s == 'READY_TO_SUBMIT'
  unless identity_matches
    raise(
      "Refusing deletion: subscription identity/state mismatch " \
      "(id=#{subscription&.fetch('id', nil)}, productId=#{attributes['productId']}, " \
      "name=#{attributes['name']}, state=#{attributes['state']})."
    )
  end

  versions_code, versions_response = asc_get_with_status(
    "/subscriptions/#{subscription_id}/versions?limit=200",
    token: token
  )
  version_states = Array(versions_response['data']).map do |entry|
    entry.dig('attributes', 'state').to_s
  end
  unless versions_code == 200
    raise "Refusing deletion: subscription version state read returned HTTP #{versions_code}."
  end
  if version_states.include?('DEVELOPER_REJECTED')
    raise(
      "Refusing deletion: subscription #{subscription_id} has a DEVELOPER_REJECTED version. " \
      "App Store Connect does not permit permanent deletion in this state; remove it from sale " \
      "and exclude it from the app version instead."
    )
  end

  group_code, group_response = asc_get_with_status("/subscriptionGroups/#{group_id}", token: token)
  unless group_code == 200 &&
         group_response.dig('data', 'id').to_s == group_id.to_s &&
         group_response.dig('data', 'type').to_s == 'subscriptionGroups'
    raise "Refusing deletion: subscription group #{group_id} identity check failed (HTTP #{group_code})."
  end

  members_path = "/subscriptionGroups/#{group_id}/subscriptions?limit=200"
  members_code, members_response = asc_get_with_status(members_path, token: token)
  members = Array(members_response['data'])
  unless members_code == 200 &&
         members.length == 1 &&
         members.first['id'].to_s == subscription_id.to_s &&
         members.first.dig('attributes', 'productId').to_s == expected_product_id.to_s
    member_ids = members.map { |entry| entry['id'].to_s }
    raise(
      "Refusing deletion: group #{group_id} must contain only subscription #{subscription_id}; " \
      "found #{member_ids.inspect} (HTTP #{members_code})."
    )
  end

  app_groups_path = "/apps/#{app_id}/subscriptionGroups?include=subscriptions&limit=200"
  app_groups_code, app_groups_response = asc_get_with_status(app_groups_path, token: token)
  app_group_ids = Array(app_groups_response['data']).map { |entry| entry['id'].to_s }
  included_subscription_ids = Array(app_groups_response['included'])
                              .select { |entry| entry['type'] == 'subscriptions' }
                              .map { |entry| entry['id'].to_s }
  unless app_groups_code == 200 &&
         app_group_ids.include?(group_id.to_s) &&
         included_subscription_ids.include?(subscription_id.to_s)
    raise(
      "Refusing deletion: exact subscription/group is not linked to app #{app_id} " \
      "(HTTP #{app_groups_code})."
    )
  end

  delete_subscription_code, delete_subscription_response = asc_delete_with_status(
    "/subscriptions/#{subscription_id}",
    token: token
  )
  unless delete_subscription_code == 204
    detail = delete_subscription_response.dig('errors', 0, 'detail') ||
             delete_subscription_response.dig('errors', 0, 'title') ||
             'unknown error'
    raise "Subscription deletion failed (HTTP #{delete_subscription_code}): #{detail}"
  end

  subscription_readback_code, = asc_get_with_status("/subscriptions/#{subscription_id}", token: token)
  unless subscription_readback_code == 404
    raise(
      "Subscription deletion was not confirmed: expected HTTP 404 read-back, " \
      "got #{subscription_readback_code}."
    )
  end

  empty_members_code, empty_members_response = asc_get_with_status(members_path, token: token)
  unless empty_members_code == 200 && Array(empty_members_response['data']).empty?
    raise(
      "Subscription group #{group_id} is not empty after subscription deletion " \
      "(HTTP #{empty_members_code}); refusing group deletion."
    )
  end

  delete_group_code, delete_group_response = asc_delete_with_status(
    "/subscriptionGroups/#{group_id}",
    token: token
  )
  unless delete_group_code == 204
    detail = delete_group_response.dig('errors', 0, 'detail') ||
             delete_group_response.dig('errors', 0, 'title') ||
             'unknown error'
    raise "Subscription group deletion failed (HTTP #{delete_group_code}): #{detail}"
  end

  group_readback_code, = asc_get_with_status("/subscriptionGroups/#{group_id}", token: token)
  final_app_groups_code, final_app_groups_response = asc_get_with_status(app_groups_path, token: token)
  remaining_group_ids = Array(final_app_groups_response['data']).map { |entry| entry['id'].to_s }
  unless group_readback_code == 404 &&
         final_app_groups_code == 200 &&
         !remaining_group_ids.include?(group_id.to_s)
    raise(
      "Subscription group deletion was not confirmed " \
      "(group HTTP #{group_readback_code}, app groups HTTP #{final_app_groups_code})."
    )
  end

  {
    app_id: app_id.to_s,
    deleted_subscription_id: subscription_id.to_s,
    deleted_subscription_group_id: group_id.to_s,
    product_id: expected_product_id.to_s,
    subscription_readback_http: subscription_readback_code,
    group_readback_http: group_readback_code,
    remaining_group_ids: remaining_group_ids
  }
end

def extra_active_iaps(app_id:, product_id:, token:)
  active_states = %w[
    READY_TO_SUBMIT
    WAITING_FOR_REVIEW
    IN_REVIEW
    APPROVED
    READY_FOR_SALE
    DEVELOPER_ACTION_NEEDED
  ]

  list_app_iaps(app_id: app_id, token: token).select do |entry|
    attrs = entry.fetch('attributes', {})
    next false if attrs['productId'] == product_id

    active_states.include?(attrs['state'].to_s)
  end
end

def default_iap_name(config:, project_root:, product_id:)
  explicit = config.dig('appstore', 'iap', 'display_name').to_s.strip
  return explicit unless explicit.empty?

  explicit = config.dig('appstore', 'iap_name').to_s.strip
  return explicit unless explicit.empty?

  app_name = config['name'].to_s.strip
  app_name = File.basename(project_root.to_s) if app_name.empty?
  app_name = product_id.split('.').map(&:capitalize).join(' ') if app_name.empty?
  "#{app_name} Pro Unlock"
end

def create_iap(app_id:, product_id:, project_root:, config:, token:)
  iap_name = default_iap_name(config: config, project_root: project_root, product_id: product_id)
  review_note = config.dig('appstore', 'iap', 'review_note').to_s.strip
  review_note = config.dig('appstore', 'review_notes').to_s.strip if review_note.empty?

  body = {
    data: {
      type: 'inAppPurchases',
      attributes: {
        name: iap_name,
        productId: product_id,
        inAppPurchaseType: 'NON_CONSUMABLE',
        reviewNote: review_note.empty? ? IAP_DEFAULT_REVIEW_NOTE : review_note,
        familySharable: false
      },
      relationships: {
        app: {
          data: {
            type: 'apps',
            id: app_id
          }
        }
      }
    }
  }

  code, response = asc_post_with_status('/inAppPurchases', body: body, token: token, base: ASC_V2_BASE)
  if [200, 201].include?(code)
    log_info "Created IAP #{product_id}."
    response['data']
  else
    detail = response.dig('errors', 0, 'detail') || response.dig('errors', 0, 'title') || 'unknown error'
    if code == 409 && detail.match?(/name is already being used by another in-app purchase/i)
      log_error "Failed to create IAP #{product_id}: the display name \"#{iap_name}\" is already in use for this app."
      log_error 'Change appstore.iap.display_name in .saneprocess, then rerun the IAP readiness step.'
      return nil
    end
    log_error "Failed to create IAP #{product_id} (HTTP #{code}): #{detail}"
    nil
  end
end

def ensure_subscription_readiness(app_id:, product_id:, project_root:, config:, token:, platform: nil, version_string: nil)
  subscription = find_subscription_by_product_id(app_id: app_id, product_id: product_id, token: token)
  unless subscription
    log_error "No App Store Connect subscription found with product_id #{product_id}."
    return false
  end

  subscription_id = subscription['id'].to_s
  screenshot_path, screenshot_target = resolve_iap_review_screenshot(project_root, config)
  unless ensure_subscription_review_screenshot(
    subscription_id: subscription_id,
    screenshot_path: screenshot_path,
    screenshot_target: screenshot_target,
    token: token
  )
    return false
  end

  state = subscription.dig('attributes', 'state').to_s.strip
  subscription = find_subscription_by_product_id(app_id: app_id, product_id: product_id, token: token)
  state = subscription.dig('attributes', 'state').to_s.strip
  log_info "Subscription state for #{product_id}: #{state}"
  return true if %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_BINARY_APPROVAL APPROVED READY_FOR_SALE].include?(state)

  if state == 'READY_TO_SUBMIT'
    log_warn "Subscription #{product_id} is READY_TO_SUBMIT."
    attachment_status = if platform
                          iap_version_attachment_status(app_id: app_id, platform: platform, product_id: product_id)
                        else
                          :unknown
                        end
    if attachment_status == :attached
      lane = [platform, version_string].compact.reject(&:empty?).join(' ')
      label = lane.empty? ? product_id : "#{product_id} (attached on #{lane} version page)"
      log_warn "Subscription #{label} is selected under Included Assets; continuing so the app binary submission carries the first subscription."
      return true
    elsif attachment_status == :unknown
      log_error "Could not verify whether #{product_id} is attached to the app version in Brave."
      log_error 'Open App Store Connect and inspect Included Assets before retrying.'
      return :version_attachment_unknown
    end

    log_first_iap_submission_blocker(
      product_id: product_id,
      platform: platform,
      version_string: version_string
    )
    return :needs_version_attachment
  end

  log_error "Subscription #{product_id} is not review-ready (state=#{state.empty? ? 'unknown' : state})."
  false
end

def iap_associated_error_codes(submit_resp)
  associated = submit_resp.dig('errors', 0, 'meta', 'associatedErrors')
  return [] unless associated.is_a?(Hash)

  associated.values.flatten.map { |entry| entry['code'] }.compact
end

def log_first_iap_submission_blocker(product_id:, platform:, version_string:)
  lane = [platform, version_string].compact.reject(&:empty?).join(' ')
  log_error "IAP #{product_id} is still READY_TO_SUBMIT."
  log_error 'Apple requires the first In-App Purchase to be added to the app version before review submission.'
  if lane.empty?
    log_error "Open App Store Connect, add #{product_id} under the version's In-App Purchases and Subscriptions section, then resubmit."
  else
    log_error "Open App Store Connect for #{lane}, add #{product_id} under In-App Purchases and Subscriptions, then resubmit that version."
  end
end

def ensure_iap_readiness(app_id:, product_id:, project_root:, config:, token:, price_usd:, platform: nil, version_string: nil)
  extras = extra_active_iaps(app_id: app_id, product_id: product_id, token: token)
  unless extras.empty?
    log_error "ASC has #{extras.length} extra active/pending IAP record(s) for app #{app_id}."
    extras.each do |entry|
      attrs = entry.fetch('attributes', {})
      log_error "Extra IAP: #{attrs['name']} | #{attrs['productId']} | #{attrs['state']}"
    end
    log_error "Delete or retire the extra IAPs before submitting. Review should only see the configured product #{product_id}."
    return false
  end

  iap = find_iap_by_product_id(app_id: app_id, product_id: product_id, token: token)
  unless iap
    log_warn "Configured appstore.product_id #{product_id} was not found in ASC for app #{app_id}; creating it now."
    iap = create_iap(
      app_id: app_id,
      product_id: product_id,
      project_root: project_root,
      config: config,
      token: token
    )
    return false unless iap
  end

  iap_id = iap['id']
  configured_iap = config.dig('appstore', 'iap') || {}
  iap_name = configured_iap['display_name'].to_s.strip
  iap_name = configured_iap[:display_name].to_s.strip if iap_name.empty?
  iap_name = iap.dig('attributes', 'name').to_s.strip if iap_name.empty?
  iap_name = product_id.split('.').map(&:capitalize).join(' ') if iap_name.empty?
  iap_description = configured_iap['description'].to_s.strip
  iap_description = configured_iap[:description].to_s.strip if iap_description.empty?
  iap_review_note = configured_iap['review_note'].to_s.strip
  iap_review_note = configured_iap[:review_note].to_s.strip if iap_review_note.empty?
  iap_review_note = config.dig('appstore', 'review_notes').to_s.strip if iap_review_note.empty?

  log_info "Ensuring IAP readiness for #{product_id} (#{iap_id})..."

  screenshot_path, screenshot_target = resolve_iap_review_screenshot(project_root, config)
  unless screenshot_path
    log_warn 'No screenshot file found for IAP review screenshot from appstore.screenshots globs.'
  end

  checks = []
  checks << ensure_iap_localization(
    iap_id: iap_id,
    iap_name: iap_name,
    iap_description: iap_description,
    token: token
  )
  checks << ensure_iap_price_schedule(iap_id: iap_id, target_price_usd: price_usd, token: token)
  checks << ensure_iap_review_screenshot(
    iap_id: iap_id,
    screenshot_path: screenshot_path,
    screenshot_target: screenshot_target,
    token: token
  )
  checks << ensure_iap_availability(iap_id: iap_id, token: token)
  checks << ensure_iap_review_note(iap_id: iap_id, review_note: iap_review_note, token: token)

  return false unless checks.all?

  final = find_iap_by_product_id(app_id: app_id, product_id: product_id, token: generate_jwt)
  state = final.dig('attributes', 'state')
  log_info "IAP state after readiness pass: #{state}"

  if state == 'DEVELOPER_ACTION_NEEDED'
    log_error "IAP #{product_id} is DEVELOPER_ACTION_NEEDED."
    log_error 'Open App Store Connect, finish the missing IAP fields Apple still expects, then rerun submit.'
    return false
  end

  return true if %w[WAITING_FOR_REVIEW IN_REVIEW APPROVED READY_FOR_SALE].include?(state)
  return false unless state == 'READY_TO_SUBMIT'

  submit_body = {
    data: {
      type: 'inAppPurchaseSubmissions',
      relationships: {
        inAppPurchaseV2: {
          data: { type: 'inAppPurchases', id: iap_id }
        }
      }
    }
  }
  submit_code, submit_resp = asc_post_with_status('/inAppPurchaseSubmissions', body: submit_body, token: generate_jwt)
  if [200, 201, 202].include?(submit_code)
    log_info 'IAP submission created.'
    return true
  end

  if submit_code == 409
    codes = iap_associated_error_codes(submit_resp)
    if codes.all? { |code| code == 'STATE_ERROR.FIRST_IAP_MUST_BE_SUBMITTED_ON_VERSION' }
      attachment_status = iap_version_attachment_status(app_id: app_id, platform: platform, product_id: product_id)
      if attachment_status == :attached
        lane = [platform, version_string].compact.reject(&:empty?).join(' ')
        label = lane.empty? ? product_id : "#{product_id} (attached on #{lane} version page)"
        log_warn "IAP #{label} is already attached under Included Assets; continuing with app submission."
        return true
      elsif attachment_status == :unknown
        log_error "Could not verify whether #{product_id} is attached to the app version in Brave."
        log_error 'Open App Store Connect and inspect Included Assets before retrying.'
        return false
      end
      log_first_iap_submission_blocker(
        product_id: product_id,
        platform: platform,
        version_string: version_string
      )
      return :needs_version_attachment
    end
    log_error "IAP submission still blocked: #{codes.join(', ')}"
    return false
  end

  detail = submit_resp.dig('errors', 0, 'detail') || submit_resp.dig('errors', 0, 'title') || 'unknown error'
  log_error "IAP submission probe failed (HTTP #{submit_code}): #{detail}"
  false
end

# ─── Submit for Review ───

def submit_for_review(app_id, asc_platform, version_id, token, draft_repair_attempted: false)
  log_info 'Submitting for App Review...'

  linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
  if linked_submission && linked_submission[:state] == 'READY_FOR_REVIEW'
    log_info "Detected existing READY_FOR_REVIEW submission #{linked_submission[:id]} for version #{version_id}; submitting..."
    if mark_review_submission_submitted(linked_submission[:id], token)
      return verify_submitted_state(version_id, token)
    end

    return false
  end

  if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
    log_warn "Detected unresolved review submission #{linked_submission[:id]} for version #{version_id}."
    clear_stale_version_submission(version_id, token)
    token = generate_jwt
    attempt_resolve_unresolved_submission(linked_submission[:id], token)

    # If item-level resolve moved it to READY_FOR_REVIEW, submit the lane directly.
    submission_state = review_submission_state(linked_submission[:id], token)
    if submission_state == 'READY_FOR_REVIEW'
      log_info "Resolved submission #{linked_submission[:id]} is READY_FOR_REVIEW; submitting..."
      if mark_review_submission_submitted(linked_submission[:id], token)
        return verify_submitted_state(version_id, token)
      end
    end

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
    processing_retry_deadline = Time.now + 300

    loop do
      item_code, item_resp = asc_post_with_status('/reviewSubmissionItems', body: item_body, token: token)
      if [200, 201, 202].include?(item_code)
        log_info 'Review submission item created.'
        break

      end

      conflict_submission_id = extract_conflict_submission_id(item_resp)
      if conflict_submission_id && conflict_submission_id != submission_id
        log_warn "Version belongs to existing review submission #{conflict_submission_id}; switching target."
        submission_id = conflict_submission_id
        break
      end

      if item_code == 409
        conflict_submission_id = extract_conflict_submission_id(item_resp)
        if conflict_submission_id && conflict_submission_id != submission_id
          log_warn "Version belongs to existing review submission #{conflict_submission_id}; switching target."
          submission_id = conflict_submission_id
          break
        elsif invalid_review_item_response?(item_resp)
          detail = item_resp.dig('errors', 0, 'detail') || item_resp.dig('errors', 0, 'title') || 'Item is invalid for review'
          associated = item_resp.dig('errors', 0, 'meta', 'associatedErrors')
          blockers = review_item_processing_blockers(item_resp)

          if !blockers.empty? && Time.now < processing_retry_deadline
            log_warn 'Review submission item blocked by screenshot processing. Waiting 8s and retrying.'
            summarize_associated_errors(associated) if associated.is_a?(Hash)
            sleep 8
            token = generate_jwt
            next
          end

          log_error "Review submission item invalid: #{detail}"
          summarize_associated_errors(associated) if associated.is_a?(Hash)
          return false
        else
          log_warn 'Review submission item already exists (409).'
          break
        end
      else
        detail = item_resp.dig('errors', 0, 'detail') || item_resp.dig('errors', 0, 'title') || "HTTP #{item_code}"
        log_error "Could not create reviewSubmissionItem: #{detail}"
        return false
      end
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
    attempt_resolve_unresolved_submission(linked_submission[:id], token)
    token = generate_jwt
    linked_submission = find_linked_review_submission(app_id, asc_platform, version_id, token)
    if linked_submission && linked_submission[:state] == 'UNRESOLVED_ISSUES'
      log_unresolved_submission_blocker(app_id, version_id, linked_submission)
      return false
    end
  end

  submission_state = review_submission_state(submission_id, token)
  if submission_state != 'READY_FOR_REVIEW'
    if !draft_repair_attempted && %w[COMPLETE UNRESOLVED_ISSUES].include?(submission_state.to_s)
      log_warn "Review submission #{submission_id} is #{submission_state}; stale Draft Submissions may be blocking review."
      if ENV['SANEPROCESS_APPROVE_ASC_DRAFT_CLEANUP'] == '1' && clear_draft_submissions_ui_for_submit(app_id)
        token = generate_jwt
        return submit_for_review(app_id, asc_platform, version_id, token, draft_repair_attempted: true)
      end
      log_warn 'Automatic Draft Submission cleanup is disabled. Set SANEPROCESS_APPROVE_ASC_DRAFT_CLEANUP=1 only after confirming visible drafts are empty/stale.'
    end

    log_error "Review submission #{submission_id} is #{submission_state || 'unknown'}; expected READY_FOR_REVIEW."
    log_error 'App Store Connect API cannot auto-submit this submission state with the current key.'
    log_error "Open App Store Connect for app #{app_id}, delete stale Draft Submissions, then submit version #{version_id} manually."
    return false
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

def clear_draft_submissions_ui_for_submit(app_id)
  result = delete_empty_draft_submissions_from_brave(app_id: app_id)
  if result[:remaining_count].positive?
    log_warn "Deleted #{result[:deleted_count]} draft submission(s), but #{result[:remaining_count]} still remain."
    return false
  end

  log_warn "Deleted #{result[:deleted_count]} stale draft submission(s)."
  true
rescue StandardError => e
  log_warn "Could not clear stale Draft Submissions via Brave: #{e.message}"
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

def review_submission_state(submission_id, token)
  resp = asc_get("/reviewSubmissions/#{submission_id}", token: token)
  resp&.dig('data', 'attributes', 'state')
end

def review_submission_items(submission_id, token)
  resp = asc_get("/reviewSubmissions/#{submission_id}/items?limit=200", token: token)
  return [] unless resp && resp['data'].is_a?(Array)

  resp['data'].map do |item|
    {
      id: item['id'],
      state: item.dig('attributes', 'state')
    }
  end
end

def attempt_resolve_unresolved_submission(submission_id, token)
  items = review_submission_items(submission_id, token)
  if items.empty?
    log_warn "No review submission items found for #{submission_id}; cannot auto-resolve."
    return false
  end

  any_changed = false
  items.each do |item|
    next unless item[:state] == 'REJECTED' || item[:state] == 'UNRESOLVED_ISSUES'

    body = {
      data: {
        type: 'reviewSubmissionItems',
        id: item[:id],
        attributes: {
          resolved: true
        }
      }
    }
    code, resp = asc_patch_with_status("/reviewSubmissionItems/#{item[:id]}", body: body, token: token)
    if [200, 201].include?(code)
      any_changed = true
      new_state = resp.dig('data', 'attributes', 'state')
      log_info "Marked reviewSubmissionItem #{item[:id]} as resolved (state: #{new_state})."
    else
      detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
      log_warn "Could not resolve reviewSubmissionItem #{item[:id]}: #{detail}"
    end
  end

  any_changed
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
  log_error 'Automatic unresolved-lane recovery was attempted but ASC still blocks submission.'
  log_error "Open App Store Connect for app #{app_id}, resolve/remove the rejected item in that submission,"
  log_error 'then rerun appstore_submit.rb to submit the updated build.'
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

def clear_review_submission(submission_id, token)
  code, resp = asc_delete_with_status("/reviewSubmissions/#{submission_id}", token: token)
  case code
  when 204
    log_warn "Cleared stale review submission #{submission_id}."
    true
  when 404
    log_warn "Review submission #{submission_id} was already absent."
    true
  else
    detail = resp.dig('errors', 0, 'detail') || resp.dig('errors', 0, 'title') || "HTTP #{code}"
    log_warn "Could not clear review submission #{submission_id}: #{detail}"
    log_warn 'If App Review still shows empty Draft Submissions, run appstore_submit.rb --clear-draft-submissions-ui on the signed-in Brave host.'
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
    texts = [err['detail'].to_s]
    associated = err.dig('meta', 'associatedErrors')
    if associated.is_a?(Hash)
      associated.each_value do |entries|
        Array(entries).each do |entry|
          next unless entry.is_a?(Hash)

          texts << entry['detail'].to_s
          texts << entry['title'].to_s
        end
      end
    end

    texts.each do |detail|
      next if detail.empty?

      match = detail.match(/reviewSubmission with id ([0-9a-f-]+)/i)
      return match[1] if match
    end
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

def review_item_processing_blockers(item_resp)
  return [] unless item_resp.is_a?(Hash)

  associated = item_resp.dig('errors', 0, 'meta', 'associatedErrors')
  return [] unless associated.is_a?(Hash)

  blockers = []
  associated.each do |resource, errors|
    next unless resource.to_s.include?('/appScreenshots/')

    Array(errors).each do |entry|
      message = entry['detail'] || entry['title'] || entry['code'] || 'Unknown screenshot processing blocker'
      next unless message.to_s.match?(/still in progress/i)

      blockers << "#{resource}: #{message}"
    end
  end

  blockers.uniq
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
  extract_app_info_from_package(pkg_path)&.dig(:build_number)
end

def wait_for_version_state_transition(app_id:, asc_platform:, version_string:, timeout_seconds: 300, interval_seconds: 8)
  deadline = Time.now + timeout_seconds
  last_state = nil

  while Time.now < deadline
    token = generate_jwt
    refreshed = find_version_any_state(app_id, asc_platform, version_string, token)
    state = refreshed&.dig('attributes', 'appStoreState')
    last_state = state
    return state if state.nil? || !SUBMITTED_APP_STORE_STATES.include?(state)

    log_warn "Awaiting ASC cancellation propagation for #{version_string} (state: #{state})..."
    sleep interval_seconds
  end

  last_state
end

def appstore_fingerprint_entries(project_root, paths)
  root_real = File.realpath(project_root)
  Array(paths).sort.map do |relative_path|
    next if relative_path == 'outputs/appstore_preflight_status.json'
    next if relative_path.start_with?('outputs/appstore-preflight-bindings/')

    absolute_path = File.expand_path(relative_path, root_real)
    raise "fingerprint path escapes project root: #{relative_path}" unless absolute_path.start_with?("#{root_real}/")

    metadata = File.lstat(absolute_path)
    if metadata.symlink?
      "L:#{relative_path}:#{File.readlink(absolute_path)}"
    elsif metadata.file?
      "F:#{relative_path}:#{Digest::SHA256.file(absolute_path).hexdigest}"
    else
      "O:#{relative_path}:#{metadata.mode}"
    end
  end.compact
end

def appstore_worktree_fingerprint(project_root)
  git_dir, git_status = Open3.capture2e('git', '-C', project_root, 'rev-parse', '--git-dir')
  unless git_status.success? && !git_dir.to_s.strip.empty?
    paths = Dir.glob(File.join(project_root, '**/*'), File::FNM_DOTMATCH)
      .reject { |path| %w[. ..].include?(File.basename(path)) }
      .select { |path| File.file?(path) || File.symlink?(path) }
      .map { |path| path.sub(%r{\A#{Regexp.escape(File.expand_path(project_root))}/?}, '') }
    material = appstore_fingerprint_entries(project_root, paths).join("\n")
    return Digest::SHA256.hexdigest(material)
  end

  parts = []
  %w[rev-parse\ HEAD status\ --porcelain=v1 diff\ --binary diff\ --cached\ --binary].each do |command|
    out, = Open3.capture2e('git', '-C', project_root, *command.split(' '))
    parts << out
  end
  untracked, untracked_status = Open3.capture2e(
    'git', '-C', project_root, 'ls-files', '-z', '--others', '--exclude-standard'
  )
  raise 'git ls-files failed while fingerprinting untracked content' unless untracked_status.success?

  parts << appstore_fingerprint_entries(project_root, untracked.split("\0").reject(&:empty?)).join("\n")
  Digest::SHA256.hexdigest(parts.join("\n---\n"))
rescue StandardError
  'unknown'
end

def appstore_package_submission_target(pkg_path, platform:)
  info = extract_app_info_from_package(pkg_path)
  return nil unless info

  {
    'type' => 'package',
    'platform' => platform.to_s.downcase,
    'fileName' => File.basename(pkg_path),
    'sha256' => Digest::SHA256.file(pkg_path).hexdigest,
    'size' => File.size(pkg_path),
    'bundleId' => info[:bundle_id].to_s,
    'version' => info[:short_version].to_s,
    'build' => info[:build_number].to_s,
    'path' => File.expand_path(pkg_path)
  }
rescue StandardError
  nil
end

def appstore_submission_targets_match?(receipt_target, expected_target)
  return false unless receipt_target.is_a?(Hash) && expected_target.is_a?(Hash)
  return false unless expected_target['type'].to_s == 'package'

  keys = %w[type platform fileName sha256 size bundleId version build]
  keys.all? { |key| receipt_target[key].to_s == expected_target[key].to_s }
end

def appstore_package_bytes_match_target?(pkg_path, submission_target)
  return false unless submission_target.is_a?(Hash) && submission_target['type'].to_s == 'package'
  return false unless File.file?(pkg_path)

  Digest::SHA256.file(pkg_path).hexdigest == submission_target['sha256'].to_s &&
    File.size(pkg_path).to_s == submission_target['size'].to_s
rescue StandardError
  false
end

def stage_appstore_package(pkg_path, project_root:)
  return false unless File.file?(pkg_path)

  project = File.realpath(project_root)
  bindings_root = File.join(project, 'outputs', 'appstore-preflight-bindings')
  FileUtils.mkdir_p(bindings_root, mode: 0o700)
  metadata = File.lstat(bindings_root)
  return false unless metadata.directory? && !metadata.symlink?
  return false unless File.realpath(bindings_root).start_with?("#{project}/")

  File.chmod(0o700, bindings_root)
  dir = Dir.mktmpdir('upload-', bindings_root)
  File.chmod(0o700, dir)
  staged_path = File.join(dir, File.basename(pkg_path))
  FileUtils.copy_file(pkg_path, staged_path)
  File.chmod(0o400, staged_path)
  at_exit do
    FileUtils.remove_entry_secure(dir) if Dir.exist?(dir)
    Dir.rmdir(bindings_root) if Dir.exist?(bindings_root) && Dir.empty?(bindings_root)
  rescue SystemCallError
    nil
  end
  staged_path
rescue StandardError => e
  log_error "Could not create immutable verified upload staging copy: #{e.message}"
  false
end

def refresh_appstore_preflight_binding(project_root:, submission_target:, command_runner: nil)
  script = File.join(project_root, 'scripts', 'SaneMaster.rb')
  return [false, "missing canonical preflight command: #{script}"] unless File.file?(script)

  command = sanemaster_invocation(script)
  command += ['appstore_preflight', '--platform', submission_target.fetch('platform')]
  command += ['--pkg', submission_target.fetch('path')]

  success = command_runner ? command_runner.call(command) : system(*command)
  [success == true, success == true ? command : 'App Store preflight submission binding failed']
end

def fresh_appstore_preflight_receipt?(project_root:, app_id:, version:, platform:, max_age_seconds: 14_400,
                                      submission_target:, receipt_signer: nil)
  path = File.join(project_root, 'outputs', 'appstore_preflight_status.json')
  return [false, "missing #{path}; run ./scripts/SaneMaster.rb appstore_preflight"] unless File.exist?(path)

  signer = receipt_signer || ReleaseReceiptSigner.production
  receipt = signer.read(path, producer: 'saneprocess.appstore_preflight.v1')
  return [false, 'appstore_preflight receipt is not signed or its signature is invalid'] unless receipt.is_a?(Hash)
  return [false, "latest appstore_preflight is #{receipt['status'].inspect}, expected \"passed\""] unless receipt['status'].to_s == 'passed'
  return [false, 'appstore_preflight receipt contains issues despite passed status'] unless Array(receipt['issues']).empty?

  receipt_app_id = receipt['appId'].to_s
  if receipt_app_id.empty? || app_id.to_s.empty? || receipt_app_id != app_id.to_s
    return [false, "appstore_preflight appId mismatch: receipt=#{receipt_app_id}, submit=#{app_id}"]
  end

  receipt_version = receipt['version'].to_s
  if receipt_version.empty? || version.to_s.empty? || receipt_version != version.to_s
    return [false, "appstore_preflight version mismatch: receipt=#{receipt_version}, submit=#{version}"]
  end

  receipt_platforms = Array(receipt['platforms']).map { |p| p.to_s.downcase }
  if platform.to_s.empty? || receipt_platforms.empty? || !receipt_platforms.include?(platform.to_s.downcase)
    return [false, "appstore_preflight platform mismatch: receipt=#{receipt_platforms.join(',')}, submit=#{platform}"]
  end

  unless appstore_submission_targets_match?(receipt['submissionTarget'], submission_target)
    return [false, 'appstore_preflight receipt is not bound to the exact fresh package selected for submission']
  end

  generated_at = Time.parse(receipt['generatedAt'].to_s)
  age = Time.now - generated_at
  return [false, 'appstore_preflight receipt is future-dated'] if age < -APPSTORE_PREFLIGHT_CLOCK_SKEW_SECONDS
  return [false, "appstore_preflight receipt is stale (#{(age / 60).round} minutes old)"] if age > max_age_seconds

  expected_fingerprint = receipt['worktreeFingerprint'].to_s
  current_fingerprint = appstore_worktree_fingerprint(project_root)
  unless expected_fingerprint.match?(/\A[0-9a-f]{64}\z/) && current_fingerprint.match?(/\A[0-9a-f]{64}\z/)
    return [false, 'appstore_preflight worktree fingerprint is missing or invalid']
  end
  if expected_fingerprint != current_fingerprint
    return [false, 'appstore_preflight receipt does not match current worktree; rerun preflight after code/metadata changes']
  end

  [true, path]
rescue StandardError => e
  [false, "could not read appstore_preflight receipt: #{e.message}"]
end

# ─── Main ───

if __FILE__ == $PROGRAM_NAME
options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: appstore_submit.rb [options]'

  opts.on('--pkg PATH', 'Path to .pkg or .ipa') { |v| options[:pkg] = v }
  opts.on('--app-id ID', 'App Store Connect app ID') { |v| options[:app_id] = v }
  opts.on('--version VERSION', 'Version string (e.g. 1.0.1)') { |v| options[:version] = v }
  opts.on('--build-number NUMBER', 'Build number override (CFBundleVersion)') { |v| options[:build_number] = v }
  opts.on('--platform PLATFORM', 'macos or ios') { |v| options[:platform] = v }
  opts.on('--project-root PATH', 'Project root directory') { |v| options[:project_root] = v }
  opts.on('--skip-upload', 'Retired: existing ASC build reuse is not safely supported') { options[:skip_upload] = true }
  opts.on('--skip-screenshots', 'Skip screenshot upload; use screenshots already present in ASC') { options[:skip_screenshots] = true }
  opts.on('--screenshots-only', 'Upload screenshots to an existing ASC version (no upload, no build attach, no submission)') { options[:screenshots_only] = true }
  opts.on('--iap-only', 'Ensure configured IAP or explicit no-IAP policy is ready and exit') { options[:iap_only] = true }
  opts.on('--iap-price-usd PRICE', 'Target US IAP price for auto-created price schedule (default: 6.99)') { |v| options[:iap_price_usd] = v }
  opts.on('--preflight-version-state', 'Check editable ASC version state only (no upload, no submission)') { options[:preflight_version_state] = true }
  opts.on('--repair-version-state', 'Attempt ASC lane repair before version-state preflight') { options[:repair_version_state] = true }
  opts.on('--withdraw-version VERSION', 'Withdraw an existing ASC app version lane (clears submission + linked review submission)') { |v| options[:withdraw_version] = v }
  opts.on('--list-builds', 'List ASC builds for app/platform (diagnostic)') { options[:list_builds] = true }
  opts.on('--list-versions', 'List ASC app versions and review states (diagnostic)') { options[:list_versions] = true }
  opts.on('--fetch-review-message', 'Open linked App Review detail in signed-in Brave and print the visible reviewer message text') { options[:fetch_review_message] = true }
  opts.on('--fetch-review-package', 'Open linked App Review detail in signed-in Brave, click visible Download actions, and save reviewer evidence locally') { options[:fetch_review_package] = true }
  opts.on('--review-package-dir PATH', 'Output directory for --fetch-review-package (default: PROJECT_ROOT/outputs/appreview-...)') { |v| options[:review_package_dir] = v }
  opts.on('--clear-draft-submissions-ui', 'Delete empty Draft Submissions for this app using signed-in Brave') { options[:clear_draft_submissions_ui] = true }
  opts.on('--remove-app-ui', 'Remove this app from App Store Connect using signed-in Brave') { options[:remove_app_ui] = true }
  opts.on('--delete-obsolete-subscription ID', 'Permanently delete one exact READY_TO_SUBMIT subscription and its now-empty group') { |v| options[:delete_obsolete_subscription] = v }
  opts.on('--subscription-group-id ID', 'Exact subscription group for --delete-obsolete-subscription') { |v| options[:subscription_group_id] = v }
  opts.on('--expected-product-id ID', 'Expected product ID for guarded subscription deletion') { |v| options[:expected_product_id] = v }
  opts.on('--expected-subscription-name NAME', 'Expected reference name for guarded subscription deletion') { |v| options[:expected_subscription_name] = v }
  opts.on('--confirm-delete-obsolete-subscription', 'Confirm permanent deletion after exact live identity/state checks') { options[:confirm_delete_obsolete_subscription] = true }
  opts.on('--sync-metadata-only', 'Sync metadata/accessibility/review fields for an existing version (no upload, no submission)') { options[:sync_metadata_only] = true }
  opts.on('--test-screenshots', 'Test screenshot resize only (no API calls)') { options[:test_screenshots] = true }
end.parse!

if options[:skip_upload]
  log_error '--skip-upload is retired because the exact remote ASC bytes cannot be proven.'
  log_error 'Increment the build number, create a fresh package, and use the normal upload path.'
  exit 1
end

if options[:delete_obsolete_subscription]
  required = %i[
    app_id
    subscription_group_id
    expected_product_id
    expected_subscription_name
    confirm_delete_obsolete_subscription
  ]
  missing = required.reject { |key| options[key] }
  unless missing.empty?
    log_error(
      "Guarded deletion requires: " \
      "#{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}"
    )
    exit 1
  end

  begin
    result = delete_obsolete_draft_subscription_and_group(
      app_id: options[:app_id],
      subscription_id: options[:delete_obsolete_subscription],
      group_id: options[:subscription_group_id],
      expected_product_id: options[:expected_product_id],
      expected_name: options[:expected_subscription_name],
      token: generate_jwt
    )
  rescue StandardError => e
    log_error e.message
    exit 1
  end

  log_info(
    "Deleted obsolete READY_TO_SUBMIT subscription " \
    "#{result[:deleted_subscription_id]} (#{result[:product_id]})."
  )
  log_info(
    "Deleted now-empty subscription group #{result[:deleted_subscription_group_id]}; " \
    "read-back HTTP #{result[:group_readback_http]}."
  )
  puts JSON.pretty_generate(result)
  exit 0
end

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
  if options[:repair_version_state]
    unless repair_version_state_lane(options[:app_id], asc_platform, options[:version], token)
      exit 1
    end
    token = generate_jwt
  end
  if check_version_state_preflight(options[:app_id], asc_platform, options[:version], token)
    exit 0
  end
  exit 1
end

if options[:withdraw_version]
  required = %i[app_id platform]
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
  version_string = options[:withdraw_version].to_s.strip
  version_record = find_version_any_state(options[:app_id], asc_platform, version_string, token)
  unless version_record
    log_error "Could not find version #{version_string} on #{options[:platform]} for app #{options[:app_id]}."
    exit 1
  end

  version_id = version_record['id']
  current_state = version_record.dig('attributes', 'appStoreState') || 'unknown'
  log_info "Withdrawing version #{version_string} (#{current_state}) id=#{version_id}..."

  cleared_any = false
  cleared_any ||= clear_stale_version_submission(version_id, token)

  linked_submission = find_linked_review_submission(options[:app_id], asc_platform, version_id, token)
  if linked_submission
    log_warn "Clearing linked review submission #{linked_submission[:id]} (#{linked_submission[:state]})..."
    cleared_any ||= clear_review_submission(linked_submission[:id], token)
  end

  token = generate_jwt
  refreshed = find_version_any_state(options[:app_id], asc_platform, version_string, token)
  refreshed_state = refreshed&.dig('attributes', 'appStoreState')
  if refreshed_state && SUBMITTED_APP_STORE_STATES.include?(refreshed_state)
    final_state = wait_for_version_state_transition(
      app_id: options[:app_id],
      asc_platform: asc_platform,
      version_string: version_string,
      timeout_seconds: 300,
      interval_seconds: 8
    )
    if final_state && SUBMITTED_APP_STORE_STATES.include?(final_state)
      log_error "Withdraw failed: version #{version_string} still in active submission state #{final_state}."
      exit 1
    end
    refreshed_state = final_state
  end

  if cleared_any
    log_info "Withdraw complete for version #{version_string} (current state: #{refreshed_state || 'not found'})."
  else
    log_warn "No submission resources were cleared for version #{version_string}."
  end
  exit 0
end

if options[:list_builds]
  required = %i[app_id platform]
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
  path = "/builds?filter[app]=#{options[:app_id]}&filter[preReleaseVersion.platform]=#{asc_platform}&include=preReleaseVersion&limit=200"
  resp = asc_get(path, token: token)
  unless resp && resp['data']
    log_error 'Failed to list builds from ASC.'
    exit 1
  end

  pre_versions = {}
  (resp['included'] || []).each do |inc|
    next unless inc['type'] == 'preReleaseVersions'
    pre_versions[inc['id']] = inc.dig('attributes', 'version')
  end

  rows = (resp['data'] || []).map do |b|
    attrs = b['attributes'] || {}
    pre_id = b.dig('relationships', 'preReleaseVersion', 'data', 'id')
    {
      id: b['id'],
      build: attrs['version'],
      processing: attrs['processingState'],
      expired: attrs['expired'],
      uploaded: attrs['uploadedDate'],
      prerelease: pre_versions[pre_id]
    }
  end

  if rows.empty?
    log_warn "No builds found for app #{options[:app_id]} on #{options[:platform]}."
    exit 0
  end

  rows.sort_by { |r| [r[:uploaded].to_s, r[:build].to_s] }.reverse.each do |r|
    log_info "build=#{r[:build]} prerelease=#{r[:prerelease]} state=#{r[:processing]} expired=#{r[:expired]} uploaded=#{r[:uploaded]} id=#{r[:id]}"
  end
  exit 0
end

if options[:list_versions]
  unless options[:app_id]
    log_error 'Missing required option: --app-id'
    exit 1
  end

  asc_platform = nil
  if options[:platform]
    asc_platform = PLATFORM_MAP[options[:platform]]
    unless asc_platform
      log_error "Unknown platform: #{options[:platform]} (use macos or ios)"
      exit 1
    end
  end

  token = generate_jwt
  rows = list_versions(options[:app_id], asc_platform, token)
  unless rows
    log_error 'Failed to list app versions from ASC.'
    exit 1
  end

  if rows.empty?
    log_warn "No app versions found for app #{options[:app_id]}#{options[:platform] ? " on #{options[:platform]}" : ''}."
    exit 0
  end

  rows.each do |row|
    suffix = []
    suffix << "submission=#{row[:submission_state]}" if row[:submission_state]
    suffix << "submission_id=#{row[:submission_id]}" if row[:submission_id]
    detail = suffix.empty? ? '' : " (#{suffix.join(', ')})"
    log_info "platform=#{row[:platform]} version=#{row[:version]} state=#{row[:state]} created=#{row[:created]} id=#{row[:id]}#{detail}"
  end
  exit 0
end

if options[:fetch_review_message]
  required = %i[app_id platform version]
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
  version_record = find_version_any_state(options[:app_id], asc_platform, options[:version], token)
  unless version_record
    log_error "Could not find version #{options[:version]} on #{options[:platform]} for app #{options[:app_id]}."
    exit 1
  end

  submission = find_linked_review_submission(options[:app_id], asc_platform, version_record['id'], token)
  unless submission && submission[:id]
    log_error "No linked review submission found for version #{options[:version]} on #{options[:platform]}."
    exit 1
  end

  begin
    text = fetch_review_message_from_brave(app_id: options[:app_id], submission_id: submission[:id])
  rescue StandardError => e
    log_error "Failed to fetch review message from Brave: #{e.message}"
    log_error 'Requirement: sign in to App Store Connect in an existing Brave tab on the Mini.'
    exit 1
  end

  puts text
  exit 0
end

if options[:fetch_review_package]
  required = %i[app_id platform version]
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
  version_record = find_version_any_state(options[:app_id], asc_platform, options[:version], token)
  unless version_record
    log_error "Could not find version #{options[:version]} on #{options[:platform]} for app #{options[:app_id]}."
    exit 1
  end

  submission = find_linked_review_submission(options[:app_id], asc_platform, version_record['id'], token)
  unless submission && submission[:id]
    log_error "No linked review submission found for version #{options[:version]} on #{options[:platform]}."
    exit 1
  end

  begin
    package = fetch_review_package_from_brave(
      app_id: options[:app_id],
      submission_id: submission[:id]
    )
  rescue StandardError => e
    log_error "Failed to fetch review package from Brave: #{e.message}"
    log_error 'Requirement: sign in to App Store Connect in an existing Brave tab on the Mini.'
    exit 1
  end

  output_dir = options[:review_package_dir].to_s.strip
  output_dir = review_package_output_dir(
    project_root: options[:project_root],
    platform: options[:platform],
    version: options[:version],
    submission_id: submission[:id]
  ) if output_dir.empty?
  summary = persist_review_package(package: package.merge(
    'app_id' => options[:app_id],
    'platform' => options[:platform],
    'version' => options[:version],
    'version_id' => version_record['id'],
    'version_state' => version_record.dig('attributes', 'appStoreState'),
    'submission_id' => submission[:id],
    'submission_state' => submission[:state]
  ), output_dir: output_dir)

  log_info "Saved review package to #{output_dir}"
  log_info "Review submission #{submission[:id]} (#{submission[:state] || 'unknown'})"
  log_info "Download clicks: #{Array(summary['download_clicks']).length}"
  Array(summary['copied_files']).each { |path| log_info "Attachment: #{path}" }
  puts summary['review_text'].to_s
  exit 0
end

if options[:clear_draft_submissions_ui]
  unless options[:app_id]
    log_error 'Missing required option: --app-id'
    exit 1
  end

  begin
    result = delete_empty_draft_submissions_from_brave(app_id: options[:app_id])
  rescue StandardError => e
    log_error "Failed to clear draft submissions in Brave: #{e.message}"
    log_error 'Requirement: run this on the Mini with an authenticated App Store Connect tab open in Brave.'
    exit 1
  end

  if result[:remaining_count].positive?
    log_warn "Deleted #{result[:deleted_count]} draft submission(s), but #{result[:remaining_count]} still remain."
    log_warn result[:body].lines.first(20).join
    exit 1
  end

  log_info "Deleted #{result[:deleted_count]} empty draft submission(s). No draft submissions remain."
  exit 0
end

if options[:remove_app_ui]
  unless options[:app_id]
    log_error 'Missing required option: --app-id'
    exit 1
  end

  begin
    result = remove_app_from_brave(app_id: options[:app_id])
  rescue StandardError => e
    log_error "Failed to remove app in Brave: #{e.message}"
    log_error 'Requirement: run this on the Mini with an authenticated App Store Connect tab open in Brave.'
    exit 1
  end

  case result[:stage]
  when 'completed'
    log_info "Remove App completed for app #{options[:app_id]}."
    exit 0
  when 'blocked'
    log_error "App #{options[:app_id]} still cannot be removed."
    log_error result[:body].lines.first(20).join
    exit 1
  else
    log_error "Could not complete Remove App for #{options[:app_id]} (stage=#{result[:stage]})."
    log_error result[:body].to_s.lines.first(20).join unless result[:body].to_s.empty?
    exit 1
  end
end

if options[:screenshots_only]
  required = %i[app_id version platform project_root]
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

  project_root = options[:project_root]
  app_id = options[:app_id]
  version = options[:version]

  config_path = File.join(project_root, '.saneprocess')
  config = if File.exist?(config_path)
             YAML.safe_load(File.read(config_path)) || {}
           else
             {}
           end

  token = generate_jwt
  version_record = find_version_any_state(app_id, asc_platform, version, token)
  unless version_record
    log_error "Could not find App Store version #{version} on #{options[:platform]} for app #{app_id}."
    exit 1
  end
  version_id = version_record['id']
  version_state = version_record.dig('attributes', 'appStoreState')
  log_info "Uploading screenshots to version #{version} (#{version_state})..."

  if options[:skip_screenshots]
    log_info 'Skipping screenshot upload (--skip-screenshots).'
  else
    upload_screenshots(version_id, asc_platform, project_root, config, token)
  end

  log_info 'Screenshot-only operation complete.'
  exit 0
end

if options[:sync_metadata_only]
  required = %i[app_id version platform project_root]
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

  project_root = options[:project_root]
  app_id = options[:app_id]
  version = options[:version]
  config_path = File.join(project_root, '.saneprocess')
  config = if File.exist?(config_path)
             YAML.safe_load(File.read(config_path)) || {}
           else
             {}
           end

  token = generate_jwt
  version_record = find_version_any_state(app_id, asc_platform, version, token)
  unless version_record
    log_error "Could not find App Store version #{version} on #{options[:platform]} for app #{app_id}."
    exit 1
  end

  version_id = version_record['id']
  build_id = version_build_id(version_id, token)
  log_info "Syncing metadata for app=#{app_id} version=#{version} platform=#{options[:platform]} (state=#{version_record.dig('attributes', 'appStoreState')})"

  token = generate_jwt
  metadata_ok = ensure_minimum_review_metadata(
    app_id: app_id,
    version_id: version_id,
    build_id: build_id,
    config: config,
    token: token,
    asc_platform: asc_platform,
    project_root: project_root
  )

  contact = resolve_review_contact(config)
  contact[:notes] = resolve_review_notes(config, asc_platform)
  contact[:demo_account] = resolve_review_demo_account(config, project_root: project_root)
  ensure_review_detail(version_id, contact, token)

  unless metadata_ok
    log_error 'Metadata sync failed. Resolve listed issues and retry.'
    exit 1
  end

  log_info 'Metadata sync complete.'
  exit 0
end

if options[:iap_only]
  required = %i[app_id project_root]
  required.each do |key|
    unless options[key]
      log_error "Missing required option: --#{key.to_s.tr('_', '-')}"
      exit 1
    end
  end

  project_root = options[:project_root]
  app_id = options[:app_id]
  config_path = File.join(project_root, '.saneprocess')
  config = if File.exist?(config_path)
             YAML.safe_load(File.read(config_path)) || {}
           else
             {}
           end

  product_id = config.dig('appstore', 'product_id').to_s.strip
  if product_id.empty? && !no_iap_policy?(config)
    log_error 'No appstore.product_id configured in .saneprocess.'
    exit 1
  end

  price_usd = resolve_iap_price_usd(config, options)

  token = generate_jwt
  ok = if no_iap_policy?(config)
         unless options[:platform] && options[:version]
           log_error 'No-IAP verification requires --platform and --version.'
           exit 1
         end
         asc_platform = PLATFORM_MAP[options[:platform]]
         version_record = asc_platform &&
                          find_version_any_state(app_id, asc_platform, options[:version], token)
         unless version_record
           log_error "Could not find version #{options[:version]} on #{options[:platform]}."
           exit 1
         end
         linked = find_linked_review_submission(
           app_id, asc_platform, version_record['id'], token
         )
         ensure_no_iap_readiness(
           app_id: app_id,
           version_id: version_record['id'],
           platform: options[:platform],
           config: config,
           token: token,
           linked_submission: linked,
           project_root: project_root
         )
       elsif auto_renewable_subscription_config?(config)
         ensure_subscription_readiness(
           app_id: app_id,
           product_id: product_id,
           project_root: project_root,
           config: config,
           token: token,
           platform: options[:platform],
           version_string: options[:version]
         )
       else
         ensure_iap_readiness(
           app_id: app_id,
           product_id: product_id,
           project_root: project_root,
           config: config,
           token: token,
           price_usd: price_usd,
           platform: options[:platform],
           version_string: options[:version]
         )
       end
  exit(ok == true ? 0 : 1)
end

# Validate required options
required = %i[pkg app_id version platform project_root]
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

unless File.exist?(pkg_path)
  log_error "Package not found: #{pkg_path}"
  exit 1
end

unless ensure_strict_customer_ui_contract!(project_root)
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

log_info "App Store submission: #{File.basename(pkg_path)} v#{version} (#{platform})"
log_info "App ID: #{app_id}"

build_number = options[:build_number]&.to_s

staged_pkg_path = stage_appstore_package(pkg_path, project_root: project_root)
unless staged_pkg_path
  log_error 'Could not stage a private immutable copy of the App Store package.'
  exit 1
end
pkg_path = staged_pkg_path
package_target = appstore_package_submission_target(pkg_path, platform: platform)
unless package_target
  log_error 'Could not extract one exact top-level app identity from the App Store package. Refusing submission.'
  exit 1
end
expected_package_platform = pkg_path.end_with?('.ipa') ? 'ios' : (pkg_path.end_with?('.pkg') ? 'macos' : '')
if expected_package_platform != platform.to_s.downcase
  log_error "Package type does not match submission platform: package=#{expected_package_platform.inspect}, submit=#{platform}"
  exit 1
end
if package_target['version'] != version.to_s
  log_error "Package version #{package_target['version']} does not match requested version #{version}."
  exit 1
end
if build_number && package_target['build'] != build_number
  log_error "Package build #{package_target['build']} does not match --build-number #{build_number}."
  exit 1
end
build_number = package_target['build']

token = nil
build_id = nil
submission_target = package_target

preflight_ok, preflight_detail = fresh_appstore_preflight_receipt?(
  project_root: project_root,
  app_id: app_id,
  version: version,
  platform: platform,
  submission_target: submission_target
)
unless preflight_ok
  log_info "Refreshing App Store preflight for the exact submission target: #{preflight_detail}"
  refresh_ok, refresh_detail = refresh_appstore_preflight_binding(
    project_root: project_root,
    submission_target: submission_target
  )
  unless refresh_ok
    log_error "App Store submission blocked: #{refresh_detail}"
    log_error 'Run the canonical Mini App Store preflight for this exact package/build and fix every blocking issue.'
    exit 1
  end
  preflight_ok, preflight_detail = fresh_appstore_preflight_receipt?(
    project_root: project_root,
    app_id: app_id,
    version: version,
    platform: platform,
    submission_target: submission_target
  )
  unless preflight_ok
    log_error "App Store submission blocked after exact-target preflight: #{preflight_detail}"
    exit 1
  end
end
log_info "Fresh App Store preflight receipt: #{preflight_detail}"

# Step 1: Upload build
unless appstore_package_bytes_match_target?(pkg_path, package_target)
  log_error 'App Store package bytes changed after exact-target preflight. Refusing to upload an unaudited package.'
  exit 1
end
upload_outcome = upload_build(pkg_path, app_id: app_id, version: version)
if upload_outcome == :duplicate
  log_error 'Existing-build reuse is disabled because exact remote bytes cannot be proven.'
  log_error 'Increment the build number, create a fresh package, and retry the normal upload.'
  exit 1
elsif upload_outcome == :failed
  log_error 'Build upload failed. Aborting.'
  exit 1
end

# Step 2: Wait for processing
token = generate_jwt
build_id = wait_for_build(
  app_id, build_number, asc_platform, token,
  expected_marketing_version: version
)
unless build_id
  log_error "Uploaded build #{build_number} was not found by exact build number, marketing version, and platform."
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
contact = resolve_review_contact(config)
contact[:notes] = resolve_review_notes(config, asc_platform)
contact[:demo_account] = resolve_review_demo_account(config, project_root: project_root)
ensure_review_detail(version_id, contact, token)

# Step 6: Upload screenshots (if configured)
if options[:skip_screenshots]
  log_info 'Skipping screenshot upload (--skip-screenshots).'
else
  upload_screenshots(version_id, asc_platform, project_root, config, token)
end

# Step 7: Fill required listing/build metadata before submission
token = generate_jwt
metadata_ok = ensure_minimum_review_metadata(
  app_id: app_id,
  version_id: version_id,
  build_id: build_id,
  config: config,
  token: token,
  asc_platform: asc_platform,
  project_root: project_root
)
unless metadata_ok
  log_error 'App metadata/accessibility readiness failed. Resolve ASC metadata issues before submission.'
  exit 1
end

# Step 7b: Ensure app-level territory availability before submission.
token = generate_jwt
unless ensure_app_availability(app_id: app_id, token: token)
  log_error 'App availability readiness failed. Resolve App Store territory availability before submission.'
  exit 1
end

# Step 7c: Ensure App Store IAP metadata/submission readiness (if configured)
configured_product_id = config.dig('appstore', 'product_id').to_s.strip
if no_iap_policy?(config)
  token = generate_jwt
  linked_submission = find_linked_review_submission(
    app_id, asc_platform, version_id, token
  )
  unless ensure_no_iap_readiness(
    app_id: app_id,
    version_id: version_id,
    platform: platform,
    config: config,
    token: token,
    linked_submission: linked_submission,
    project_root: project_root
  )
    log_error 'No-IAP readiness failed. Resolve App Store product attachment or availability state.'
    exit 1
  end
elsif !configured_product_id.empty?
  iap_price_usd = resolve_iap_price_usd(config, options)
  token = generate_jwt
  iap_ok = if auto_renewable_subscription_config?(config)
             ensure_subscription_readiness(
               app_id: app_id,
               product_id: configured_product_id,
               project_root: project_root,
               config: config,
               token: token,
               platform: platform,
               version_string: version
             )
           else
             ensure_iap_readiness(
               app_id: app_id,
               product_id: configured_product_id,
               project_root: project_root,
               config: config,
               token: token,
               price_usd: iap_price_usd,
               platform: platform,
               version_string: version
             )
           end
  unless iap_ok == true
    log_error 'IAP readiness failed. Resolve IAP metadata/state before app review submission.'
    exit 1
  end
end

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
end
