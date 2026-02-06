#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# SaneApps Link Monitor
# Checks critical URLs (checkout, download, website) and alerts on failures.
# Run manually: ruby link_monitor.rb
# Run via launchd: see com.saneapps.link-monitor.plist
# =============================================================================

require "net/http"
require "uri"
require "json"
require "time"
require "fileutils"

SANEAPPS_ROOT = File.expand_path("../../..", __dir__)
LOG_FILE = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor.log")
STATE_FILE = File.join(SANEAPPS_ROOT, "infra/SaneProcess/outputs/link_monitor_state.json")

# Critical URLs to monitor - these are revenue/download paths
CRITICAL_URLS = {
  # Checkout links (from LemonSqueezy API - ALL products)
  "SaneBar checkout" => "https://saneapps.lemonsqueezy.com/checkout/buy/8a6ddf02-574e-4b20-8c94-d3fa15c1cc8e",
  "SaneClick checkout" => "https://saneapps.lemonsqueezy.com/checkout/buy/679dbd1d-b808-44e7-98c8-8e679b592e93",
  "SaneClip checkout" => "https://saneapps.lemonsqueezy.com/checkout/buy/e0d71010-bd20-49b6-b841-5522b39df95f",
  "SaneHosts checkout" => "https://saneapps.lemonsqueezy.com/checkout/buy/83977cc9-900f-407f-a098-959141d474f2",

  # Website homepages
  "sanebar.com" => "https://sanebar.com",
  "saneclip.com" => "https://saneclip.com",
  "saneclick.com" => "https://saneclick.com",
  "sanehosts.com" => "https://sanehosts.com",
  "saneapps.com" => "https://saneapps.com",

  # LemonSqueezy store
  "LemonSqueezy store" => "https://saneapps.lemonsqueezy.com",
}.freeze

# Also scan HTML files for checkout links and verify they match CRITICAL_URLS
WEBSITE_DIRS = %w[
  apps/SaneBar/docs
  apps/SaneClip/docs
  apps/SaneClick/docs
  apps/SaneHosts/website
].freeze

TIMEOUT = 10
MAX_REDIRECTS = 3

def check_url(url, max_redirects: MAX_REDIRECTS)
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

    if code >= 200 && code < 400
      { status: :ok, code: code }
    else
      { status: :error, code: code, message: "HTTP #{code}" }
    end

    break { status: :ok, code: code } if code >= 200 && code < 400
    break { status: :error, code: code, message: "HTTP #{code}" }
  end
rescue Net::OpenTimeout, Net::ReadTimeout => e
  { status: :error, code: 0, message: "Timeout: #{e.message}" }
rescue StandardError => e
  { status: :error, code: 0, message: e.message }
end

def scan_html_for_checkout_links
  bad_links = []
  WEBSITE_DIRS.each do |dir|
    full_dir = File.join(SANEAPPS_ROOT, dir)
    next unless Dir.exist?(full_dir)

    Dir.glob(File.join(full_dir, "**/*.html")).each do |html_file|
      content = File.read(html_file)
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

def notify(title, message)
  system("osascript", "-e", %[display notification "#{message}" with title "#{title}" sound name "Sosumi"])
end

def log(message)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{timestamp}] #{message}"
  warn line
  File.open(LOG_FILE, "a") { |f| f.puts(line) }
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

failures = []
successes = []

# 1. Check critical URLs
CRITICAL_URLS.each do |name, url|
  result = check_url(url)
  if result[:status] == :ok
    successes << name
    log "OK  #{name} (#{result[:code]})"
  else
    failures << { name: name, url: url, error: result[:message] }
    log "FAIL #{name}: #{result[:message]} — #{url}"
  end
end

# 2. Scan HTML for wrong checkout domains
bad_links = scan_html_for_checkout_links
bad_links.each do |bl|
  failures << { name: "Wrong checkout domain in #{bl[:file]}", url: bl[:url], error: "Expected saneapps.lemonsqueezy.com" }
  log "FAIL Wrong domain: #{bl[:url]} in #{bl[:file]}"
end

# 3. Report results
state = load_state
now = Time.now.iso8601

if failures.empty?
  log "All #{successes.size} checks passed"
  state["last_success"] = now
  state["consecutive_failures"] = 0
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

save_state(state)
exit(failures.empty? ? 0 : 1)
