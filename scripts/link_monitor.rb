#!/usr/bin/env ruby
# frozen_string_literal: true

# Hook/launchd/ssh shells often run with a C locale, which makes Ruby default
# to US-ASCII and raise "invalid byte sequence" when UTF-8 file or tool
# content hits a regex or parser. Force UTF-8 before anything reads content.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# =============================================================================
# SaneApps Link Monitor
# Checks critical URLs (checkout, download, website) and alerts on failures.
# Run manually: ruby link_monitor.rb
# Run via launchd: see com.saneapps.link-monitor.plist
# =============================================================================

require "net/http"
require "uri"
require "json"
require "yaml"
require "time"
require "fileutils"
require "shellwords"

SANEAPPS_ROOT = File.expand_path("../../..", __dir__)
CONFIG_FILE = File.join(SANEAPPS_ROOT, "infra/SaneProcess/config/products.yml")
LOG_FILE = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor.log")
STATE_FILE = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor_state.json")
LAUNCHD_STDOUT_LOG = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor_stdout.log")
LAUNCHD_STDERR_LOG = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor_stderr.log")
MAX_LAUNCHD_LOG_BYTES = 1_000_000
ENV_CACHE_FILE = File.expand_path(ENV.fetch("SANE_ENV_CACHE_FILE", "~/.config/nv/env"))
KEYCHAIN_FALLBACK_ENABLED = ENV.fetch("SANE_KEYCHAIN_FALLBACK", "1") == "1" && ENV["SANE_NO_KEYCHAIN"] != "1"

# Load product config — single source of truth for UUIDs, domains, etc.
CONFIG = YAML.safe_load(File.read(CONFIG_FILE), permitted_classes: [])
PRODUCTS = CONFIG.fetch("products")
BUNDLES = CONFIG.fetch("bundles", {})
STORE = CONFIG.fetch("store")
REDIRECT = CONFIG.fetch("redirect")

def product_checkout_url(product)
  explicit_url = product["checkout_url"].to_s.strip
  return explicit_url unless explicit_url.empty?

  checkout_uuid = product["checkout_uuid"].to_s.strip
  return "" if checkout_uuid.empty?

  "#{STORE['checkout_base']}/#{checkout_uuid}"
end

# Build critical URLs dynamically from config
CRITICAL_URLS = {}.tap do |urls|
  PRODUCTS.each do |slug, product|
    # Only monitor release links for products that are actually live.
    # Products without checkout_uuid or checkout_url are not public yet.
    checkout_url = product_checkout_url(product)
    monitor_links = product.fetch("monitor_links", true)
    next if checkout_url.empty? || monitor_links == false

    urls["#{product['name']} checkout"] = checkout_url
    urls[product["domain"]] = "https://#{product['domain']}"
    urls["#{product['name']} redirect"] = "#{REDIRECT['base_url']}/#{slug}"
    urls["#{product['name']} download"] = "https://go.saneapps.com/download/#{slug}"
    urls["#{product['name']} appcast"] = product["appcast"]
    urls["#{product['name']} dist worker"] = "https://#{product['dist_domain']}/"
  end
  BUNDLES.each do |slug, bundle|
    checkout_url = bundle["checkout_url"].to_s.strip
    route_url = bundle["route"].to_s.strip
    next if checkout_url.empty? && route_url.empty?

    name = bundle["name"].to_s.strip
    name = slug if name.empty?
    urls["#{name} checkout"] = checkout_url unless checkout_url.empty?
    urls["#{name} redirect"] = route_url unless route_url.empty?
  end
  urls["saneapps.com"] = "https://saneapps.com"
  urls["LemonSqueezy store"] = STORE["base_url"]
end.freeze

# Also scan HTML files for checkout links and verify they match CRITICAL_URLS
WEBSITE_DIRS = %w[
  apps/SaneBar/docs
  apps/SaneClip/docs
  apps/SaneClick/docs
  apps/SaneHosts/website
].freeze

TIMEOUT = 10
MAX_REDIRECTS = 3

def load_env_cache
  return unless File.exist?(ENV_CACHE_FILE)

  File.foreach(ENV_CACHE_FILE) do |raw_line|
    line = raw_line.strip
    next if line.empty? || line.start_with?("#")

    line = line.delete_prefix("export ").strip
    next unless line.include?("=")

    key, raw_value = line.split("=", 2)
    next if key.nil? || key.empty? || ENV.key?(key)

    value = Shellwords.split(raw_value.to_s).first || raw_value.to_s.strip
    ENV[key] = File.expand_path(value) if key.end_with?("_PATH") && value.start_with?("~")
    ENV[key] ||= value
  end
rescue StandardError
  nil
end

def persist_secret_to_env_cache(value, *env_names)
  return if value.nil? || value.empty?
  return if ENV.fetch("SANE_ENV_CACHE_WRITE", "0") == "0"

  names = env_names.compact.reject(&:empty?)
  return if names.empty?

  env_dir = File.dirname(ENV_CACHE_FILE)
  FileUtils.mkdir_p(env_dir)
  File.chmod(0o700, env_dir) rescue nil

  lines = File.exist?(ENV_CACHE_FILE) ? File.readlines(ENV_CACHE_FILE, chomp: true) : []
  filtered = lines.reject do |line|
    stripped = line.strip
    names.any? { |name| stripped.start_with?("export #{name}=") }
  end
  names.each do |name|
    filtered << "export #{name}=#{Shellwords.escape(value)}"
  end
  File.write(ENV_CACHE_FILE, filtered.join("\n") + "\n")
  File.chmod(0o600, ENV_CACHE_FILE)
rescue StandardError
  nil
end

def resolve_secret_value(service, account, *env_names)
  load_env_cache

  env_names.flatten.each do |env_name|
    value = ENV[env_name].to_s.strip
    return value unless value.empty?
  end

  return "" unless KEYCHAIN_FALLBACK_ENABLED

  value = `security find-generic-password -s "#{service}" -a "#{account}" -w 2>/dev/null`.strip
  persist_secret_to_env_cache(value, *env_names) unless value.empty?
  value
rescue StandardError
  ""
end

def check_url(url, max_redirects: MAX_REDIRECTS, attempts: 3)
  attempts.times do |attempt|
    begin
      uri = URI.parse(url)
      redirects = 0

      loop do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        response = http.request_head(uri.request_uri)
        code = response.code.to_i

        if [301, 302, 303, 307, 308].include?(code)
          redirects += 1
          return { status: :error, code: code, message: "Too many redirects" } if redirects > max_redirects
          uri = URI.parse(response["location"])
          next
        end

        return { status: :ok, code: code } if code >= 200 && code < 400

        # Transient server errors are common during deploy propagation.
        if code >= 500 && attempt < attempts - 1
          sleep(0.4 * (attempt + 1))
          break
        end

        return { status: :error, code: code, message: "HTTP #{code}" }
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      return { status: :error, code: 0, message: "Timeout: #{e.message}" } if attempt >= attempts - 1
      sleep(0.4 * (attempt + 1))
    rescue StandardError => e
      return { status: :error, code: 0, message: e.message } if attempt >= attempts - 1
      sleep(0.4 * (attempt + 1))
    end
  end

  { status: :error, code: 0, message: "Unknown check failure" }
end

def check_redirect_mapping(slug, product)
  expected_prefix = product_checkout_url(product)
  return { status: :error, message: "Missing checkout URL for #{slug}" } if expected_prefix.empty?

  redirect_url = "#{REDIRECT['base_url']}/#{slug}"

  uri = URI.parse(redirect_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT

  response = http.request_head(uri.request_uri)
  code = response.code.to_i
  location = response["location"].to_s

  unless [301, 302, 303, 307, 308].include?(code)
    return { status: :error, message: "Expected redirect, got HTTP #{code}" }
  end

  return { status: :error, message: "Redirect location missing" } if location.empty?

  unless location.start_with?(expected_prefix)
    return { status: :error, message: "Redirect target mismatch (expected prefix #{expected_prefix}, got #{location})" }
  end

  { status: :ok, code: code, location: location }
rescue StandardError => e
  { status: :error, message: e.message }
end

def fetch_url_content(url)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT

  response = http.get(uri.request_uri)
  response.code.to_i >= 200 && response.code.to_i < 400 ? response.body : nil
rescue StandardError => e
  nil
end

def check_appcast_and_download(appcast_url, name)
  # First check the appcast itself
  result = check_url(appcast_url)
  return { status: :error, message: "Appcast unreachable: #{result[:message]}" } if result[:status] == :error

  # Fetch and parse XML
  xml_content = fetch_url_content(appcast_url)
  return { status: :error, message: "Failed to fetch appcast content" } unless xml_content

  # Verify it's valid XML
  unless xml_content.include?('<rss') || xml_content.include?('<item')
    return { status: :error, message: "Appcast is not valid XML" }
  end

  # Extract latest Sparkle enclosure URL (ZIP/DMG/PKG supported)
  enclosure_url = xml_content.scan(/<enclosure[^>]*url="([^"]+)"/i).flatten.first
  return { status: :error, message: "No enclosure URL found in appcast" } unless enclosure_url

  # Check if the enclosure URL is accessible
  enclosure_result = check_url(enclosure_url)
  if enclosure_result[:status] == :error
    { status: :error, message: "Enclosure URL broken: #{enclosure_url} (#{enclosure_result[:message]})" }
  else
    { status: :ok, enclosure_url: enclosure_url }
  end
rescue StandardError => e
  { status: :error, message: "Parse error: #{e.message}" }
end

def scan_html_for_checkout_links
  bad_links = []
  WEBSITE_DIRS.each do |dir|
    full_dir = File.join(SANEAPPS_ROOT, dir)
    next unless Dir.exist?(full_dir)

    Dir.glob(File.join(full_dir, "**/*.html")).each do |html_file|
      content = File.read(html_file).encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
      # Find all lemonsqueezy checkout URLs
      content.scan(%r{https?://[a-z]+\.lemonsqueezy\.com/checkout/buy/[^"'\s]+}).each do |url|
        unless url.start_with?("https://saneapps.lemonsqueezy.com/")
          rel_path = html_file.sub("#{SANEAPPS_ROOT}/", "")
          bad_links << { file: rel_path, url: url }
        end
      end
    end
  end
  bad_links
end

# Domain expiry checking — from config
DOMAINS_TO_MONITOR = CONFIG.fetch("all_domains").freeze

def check_domain_expiry(domain)
  # Try Cloudflare API first (if available)
  cf_token = resolve_secret_value("cloudflare", "api_token", "CLOUDFLARE_API_TOKEN")
  if !cf_token.empty?
    cf_expiry = check_cf_domain_expiry(domain, cf_token)
    return cf_expiry if cf_expiry
  end

  # Fallback to whois
  check_whois_expiry(domain)
rescue StandardError => e
  { status: :error, message: e.message }
end

def check_cf_domain_expiry(domain, token)
  # Get zone ID (use Net::HTTP to avoid shell injection via domain/token)
  uri = URI("https://api.cloudflare.com/client/v4/zones?name=#{URI.encode_www_form_component(domain)}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{token}"
  zones_response = http.request(req)
  return nil unless zones_response.is_a?(Net::HTTPSuccess)
  zones_data = JSON.parse(zones_response.body)
  return nil unless zones_data["success"] && zones_data["result"]&.any?

  zone_id = zones_data["result"][0]["id"]
  reg_uri = URI("https://api.cloudflare.com/client/v4/zones/#{zone_id}")
  reg_req = Net::HTTP::Get.new(reg_uri)
  reg_req["Authorization"] = "Bearer #{token}"
  registrar_response = http.request(reg_req)
  return nil unless registrar_response.is_a?(Net::HTTPSuccess)
  registrar_data = JSON.parse(registrar_response.body)

  if registrar_data["success"]
    # Cloudflare API doesn't directly expose expiry, but we can check status
    # Return success indicator - actual expiry would need Registrar API access
    { status: :ok, managed: true }
  else
    nil
  end
rescue StandardError
  nil
end

def check_whois_expiry(domain)
  whois_output = `whois #{Shellwords.shellescape(domain)} 2>/dev/null`
  return { status: :error, message: "whois command failed" } if whois_output.empty?

  # Parse expiry date (format varies by registrar)
  expiry_patterns = [
    /Registry Expiry Date:\s*(\d{4}-\d{2}-\d{2})/i,
    /Expiration Date:\s*(\d{4}-\d{2}-\d{2})/i,
    /Expiry.*?:\s*(\d{4}-\d{2}-\d{2})/i,
    /paid-till:\s*(\d{4}\.\d{2}\.\d{2})/i, # .ru domains
  ]

  expiry_date = nil
  expiry_patterns.each do |pattern|
    match = whois_output.match(pattern)
    if match
      date_str = match[1].tr(".", "-")
      expiry_date = Time.parse(date_str)
      break
    end
  end

  return { status: :error, message: "Could not parse expiry date" } unless expiry_date

  days_until_expiry = ((expiry_date - Time.now) / 86400).to_i
  { status: :ok, expiry_date: expiry_date, days_until_expiry: days_until_expiry }
rescue StandardError => e
  { status: :error, message: e.message }
end

def notify(title, message)
  safe_title = title.gsub('"', '\\"').gsub('\\', '\\\\')
  safe_message = message.gsub('"', '\\"').gsub('\\', '\\\\')
  system("osascript", "-e", %[display notification "#{safe_message}" with title "#{safe_title}" sound name "Sosumi"])
end

def log(message)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{timestamp}] #{message}"
  puts line
  File.open(LOG_FILE, "a") { |f| f.puts(line) }
end

def truncate_large_launchd_logs
  [LAUNCHD_STDOUT_LOG, LAUNCHD_STDERR_LOG].each do |path|
    next unless File.exist?(path)
    next unless File.size(path) > MAX_LAUNCHD_LOG_BYTES

    File.truncate(path, 0)
  rescue StandardError
    nil
  end
end

def load_state
  return {} unless File.exist?(STATE_FILE)
  JSON.parse(File.read(STATE_FILE))
rescue StandardError
  {}
end

def save_state(state)
  File.write(STATE_FILE, JSON.pretty_generate(state))
end

# --- Main ---

FileUtils.mkdir_p(File.dirname(LOG_FILE))
truncate_large_launchd_logs

failures = []
successes = []

# 1. Check critical URLs
CRITICAL_URLS.each do |name, url|
  # Special handling for appcast feeds - verify XML and DMG URLs
  if name.include?("appcast")
    result = check_appcast_and_download(url, name)
    if result[:status] == :ok
      successes << name
      log "OK  #{name} (XML valid, enclosure accessible: #{result[:enclosure_url]})"
    else
      failures << { name: name, url: url, error: result[:message] }
      log "FAIL #{name}: #{result[:message]} — #{url}"
    end
  else
    result = check_url(url)

    # Special case: dist workers return 404 at root (but work for actual files)
    # Also acceptable: 403 (means worker is running but requires auth/token)
    if name.include?("dist worker") && [404, 403].include?(result[:code])
      successes << name
      log "OK  #{name} (#{result[:code]} - worker responding)"
    elsif result[:status] == :ok
      successes << name
      log "OK  #{name} (#{result[:code]})"
    else
      failures << { name: name, url: url, error: result[:message] }
      log "FAIL #{name}: #{result[:message]} — #{url}"
    end
  end
end

# 2. Scan HTML for wrong checkout domains
bad_links = scan_html_for_checkout_links
bad_links.each do |bl|
  failures << { name: "Wrong checkout domain in #{bl[:file]}", url: bl[:url], error: "Expected saneapps.lemonsqueezy.com" }
  log "FAIL Wrong domain: #{bl[:url]} in #{bl[:file]}"
end

# 2b. Verify go.saneapps.com redirect maps to exact configured checkout UUID
PRODUCTS.each do |slug, product|
  checkout_url = product_checkout_url(product)
  monitor_links = product.fetch("monitor_links", true)
  next if checkout_url.empty? || monitor_links == false

  result = check_redirect_mapping(slug, product)
  name = "#{product['name']} redirect mapping"
  redirect_url = "#{REDIRECT['base_url']}/#{slug}"
  if result[:status] == :ok
    successes << name
    log "OK  #{name} (#{result[:code]} -> #{result[:location]})"
  else
    failures << { name: name, url: redirect_url, error: result[:message] }
    log "FAIL #{name}: #{result[:message]} — #{redirect_url}"
  end
end

# 3. Check domain expiry dates
domain_warnings = []
DOMAINS_TO_MONITOR.each do |domain|
  result = check_domain_expiry(domain)
  if result[:status] == :ok
    if result[:days_until_expiry]
      days = result[:days_until_expiry]
      if days < 30
        domain_warnings << { domain: domain, days: days, severity: :critical }
        log "WARN Domain #{domain} expires in #{days} days!"
      elsif days < 60
        domain_warnings << { domain: domain, days: days, severity: :warning }
        log "INFO Domain #{domain} expires in #{days} days"
      else
        log "OK   Domain #{domain} expires in #{days} days"
      end
    elsif result[:managed]
      log "OK   Domain #{domain} managed via Cloudflare"
    end
  elsif result[:status] == :error
    domain_warnings << { domain: domain, message: result[:message], severity: :unknown }
    log "WARN Could not check expiry for #{domain}: #{result[:message]}"
  end
end

# 3b. Check GitHub repo accessibility
if system('which gh > /dev/null 2>&1')
  repo_check = `gh repo view sane-apps/SaneBar 2>&1`
  if repo_check.include?('not found') || repo_check.include?('Could not resolve')
    failures << { name: "GitHub repo sane-apps/SaneBar", url: "https://github.com/sane-apps/SaneBar", error: "Repo not accessible" }
    log "FAIL GitHub repo sane-apps/SaneBar not accessible"
  else
    successes << "GitHub repo check"
    log "OK   GitHub repo sane-apps/SaneBar accessible"
  end
end

# 4. Report results
state = load_state
now = Time.now.iso8601

# Add domain expiry warnings to failures if critical
domain_warnings.select { |w| w[:severity] == :critical }.each do |w|
  failures << {
    name: "Domain #{w[:domain]} expires soon",
    url: "https://#{w[:domain]}",
    error: "Expires in #{w[:days]} days (< 30 day threshold)"
  }
end

if failures.empty?
  if domain_warnings.empty?
    log "All #{successes.size} checks passed"
  else
    log "All #{successes.size} critical link checks passed; #{domain_warnings.size} domain expiry warning(s)"
  end
  state["last_success"] = now
  state["consecutive_failures"] = 0
  state.delete("last_failure")
  state.delete("last_failure_details")
  if state["alerted"]
    notify("SaneApps Monitor", "All links recovered and working!")
    state.delete("alerted")
  end
else
  state["consecutive_failures"] = (state["consecutive_failures"] || 0) + 1
  state["last_failure"] = now
  state["last_failure_details"] = failures.map { |f| f[:name] }

  # Alert on first failure or every 6 hours
  last_alert = state["last_alert_time"] ? Time.parse(state["last_alert_time"]) : Time.at(0)
  if !state["alerted"] || (Time.now - last_alert > 6 * 3600)
    names = failures.map { |f| f[:name] }.join(", ")
    notify("SaneApps ALERT", "Broken: #{names}")
    state["alerted"] = true
    state["last_alert_time"] = now
  end

  warn ""
  warn "BROKEN LINKS:"
  failures.each do |f|
    warn "  #{f[:name]}: #{f[:error]}"
    warn "    #{f[:url]}"
  end
end

# Report domain warnings even if not critical
unless domain_warnings.empty?
  warn ""
  warn "DOMAIN EXPIRY STATUS:"
  domain_warnings.each do |w|
    symbol = w[:severity] == :critical ? "CRITICAL" : "WARN"
    detail = w[:days] ? "#{w[:days]} days until expiry" : w[:message]
    warn "  #{symbol} #{w[:domain]}: #{detail}"
  end
end

save_state(state)
exit(failures.empty? ? 0 : 1)
