#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'fileutils'
require 'optparse'
require 'uri'
require 'yaml'
require 'date'
require 'time'

class AppStorePublicScreenshotAudit
  LIVE_URL_PATTERN = %r{https://is\d-ssl\.mzstatic\.com/image/thumb/[^\s"'<>]+}.freeze
  SCREENSHOT_FILENAME_PATTERN = %r{/([^/]+\.png)}.freeze
  SCREENSHOT_SIZE_PATTERN = %r{/(\d+)x(\d+)bb}.freeze
  SKIP_TOKENS = %w[AppIcon Placeholder Features].freeze
  TEMPLATE_SIZE_BY_PLATFORM = {
    'macos' => [1286, 804],
    'ipad' => [600, 800],
    'ios' => [600, 1300],
    'watch' => [396, 484],
    'unknown' => [1286, 804]
  }.freeze

  attr_reader :project_root, :country, :output_dir

  def initialize(project_root:, country: 'us', output_dir: nil)
    @project_root = File.expand_path(project_root)
    @country = country
    @output_dir = File.expand_path(output_dir || File.join(project_root, 'outputs', 'appstore-public-audit'))
  end

  def run
    FileUtils.rm_rf(output_dir)
    FileUtils.mkdir_p(output_dir)

    live_entries = extract_live_entries(fetch_public_html)
    storyboard = storyboard_entries_by_platform
    downloaded_live = download_live_entries(live_entries)
    issues = audit_issues(storyboard, live_entries)

    report = {
      generated_at: Time.now.utc.iso8601,
      app_name: manifest['name'],
      app_id: app_id,
      public_url: public_url,
      storyboard_path: storyboard_path,
      platforms: platform_report(storyboard, live_entries, downloaded_live),
      issues: issues
    }

    File.write(File.join(output_dir, 'report.json'), JSON.pretty_generate(report))
    File.write(File.join(output_dir, 'report.html'), build_html_report(report))
    issues
  end

  def fetch_public_html
    http_get_text(public_url)
  end

  def extract_live_entries(html)
    ordered = []
    seen = {}

    html.scan(LIVE_URL_PATTERN) do |raw|
      url = raw.is_a?(Array) ? raw.first : raw
      next if SKIP_TOKENS.any? { |token| url.include?(token) }
      basename = screenshot_basename(url)
      next unless basename

      platform = classify_live_basename(basename)
      download_url = materialize_live_url(url, platform)
      width = screenshot_width(download_url)
      current = seen[basename]

      if current.nil?
        entry = {
          basename: basename,
          url: download_url,
          width: width,
          platform: platform,
          order: ordered.length
        }
        seen[basename] = entry
        ordered << entry
      elsif width > current[:width]
        current[:url] = download_url
        current[:width] = width
      end
    end

    ordered
  end

  def storyboard_entries_by_platform
    if File.exist?(storyboard_path)
      data = load_yaml(storyboard_path)
      platforms = data['platforms'] || {}
      return platforms.each_with_object({}) do |(platform, entries), acc|
        acc[platform.to_s] = Array(entries).map do |entry|
          {
            file: File.expand_path(entry.fetch('file'), project_root),
            title: entry.fetch('title'),
            purpose: entry.fetch('purpose'),
            must_show: Array(entry['must_show']).map(&:to_s)
          }
        end
      end
    end

    screenshot_patterns = manifest.dig('appstore', 'screenshots') || {}
    screenshot_patterns.each_with_object({}) do |(platform, pattern), acc|
      files = Dir.glob(File.join(project_root, pattern.to_s)).sort
      acc[platform.to_s] = files.map.with_index do |file, index|
        {
          file: File.expand_path(file),
          title: "Configured screenshot #{index + 1}",
          purpose: 'Fallback from .saneprocess appstore.screenshots. Add docs/appstore_screenshot_storyboard.yml for richer per-slot intent.',
          must_show: []
        }
      end
    end
  end

  def audit_issues(storyboard, live_entries)
    live_by_platform = live_entries.group_by { |entry| entry[:platform] }
    platforms = (storyboard.keys + live_by_platform.keys).uniq.sort
    issues = []

    platforms.each do |platform|
      expected = storyboard.fetch(platform, [])
      live = live_by_platform.fetch(platform, [])

      if expected.empty?
        issues << "[#{platform}] live public page has #{live.length} screenshot(s) but the storyboard has no entries"
        next
      end

      if live.length != expected.length
        issues << "[#{platform}] live public page shows #{live.length} screenshot(s); storyboard expects #{expected.length}"
      end

      [expected.length, live.length].max.times do |idx|
        expected_entry = expected[idx]
        live_entry = live[idx]
        next unless expected_entry || live_entry

        if expected_entry.nil?
          issues << "[#{platform}] slot #{idx + 1} has unexpected live screenshot #{live_entry[:basename]}"
          next
        end

        if live_entry.nil?
          issues << "[#{platform}] slot #{idx + 1} is missing live screenshot for #{File.basename(expected_entry[:file])}"
          next
        end

        expected_basename = File.basename(expected_entry[:file])
        if expected_basename != live_entry[:basename]
          issues << "[#{platform}] slot #{idx + 1} mismatch: live #{live_entry[:basename]} vs expected #{expected_basename}"
        end
      end
    end

    issues
  end

  def download_live_entries(entries)
    entries.each_with_object({}) do |entry, acc|
      platform_dir = File.join(output_dir, 'live', entry[:platform])
      FileUtils.mkdir_p(platform_dir)
      ext = screenshot_extension(entry[:url])
      path = File.join(platform_dir, format('%02d-%s%s', entry[:order] + 1, entry[:basename], ext))
      File.binwrite(path, http_get_binary(entry[:url]))
      acc[entry[:basename]] = path
    end
  end

  def platform_report(storyboard, live_entries, downloaded_live)
    live_by_platform = live_entries.group_by { |entry| entry[:platform] }
    platforms = (storyboard.keys + live_by_platform.keys).uniq.sort

    platforms.each_with_object({}) do |platform, acc|
      expected = storyboard.fetch(platform, [])
      live = live_by_platform.fetch(platform, [])
      rows = [expected.length, live.length].max.times.map do |idx|
        expected_entry = expected[idx]
        live_entry = live[idx]
        {
          index: idx + 1,
          expected_file: expected_entry && File.basename(expected_entry[:file]),
          expected_path: expected_entry && expected_entry[:file],
          expected_title: expected_entry && expected_entry[:title],
          expected_purpose: expected_entry && expected_entry[:purpose],
          expected_must_show: expected_entry && expected_entry[:must_show],
          live_file: live_entry && live_entry[:basename],
          live_url: live_entry && live_entry[:url],
          live_path: live_entry && downloaded_live[live_entry[:basename]]
        }
      end

      acc[platform] = {
        expected_count: expected.length,
        live_count: live.length,
        rows: rows
      }
    end
  end

  def build_html_report(report)
    sections = report.fetch(:platforms).map do |platform, data|
      rows = data.fetch(:rows).map do |row|
        <<~HTML
          <div class="row">
            <div class="meta">
              <div class="slot">#{platform} ##{row[:index]}</div>
              <div><strong>Expected:</strong> #{row[:expected_file] || 'none'}</div>
              <div><strong>Title:</strong> #{row[:expected_title] || 'n/a'}</div>
              <div><strong>Purpose:</strong> #{row[:expected_purpose] || 'n/a'}</div>
              <div><strong>Must show:</strong> #{Array(row[:expected_must_show]).join(', ')}</div>
              <div><strong>Live:</strong> #{row[:live_file] || 'missing'}</div>
            </div>
            <div class="images">
              <figure>
                <figcaption>Expected local</figcaption>
                #{row[:expected_path] ? "<img src=\"file://#{row[:expected_path]}\" />" : '<div class="missing">No expected local file</div>'}
              </figure>
              <figure>
                <figcaption>Live public page</figcaption>
                #{row[:live_path] ? "<img src=\"file://#{row[:live_path]}\" />" : '<div class="missing">No live screenshot</div>'}
              </figure>
            </div>
          </div>
        HTML
      end.join("\n")

      <<~HTML
        <section>
          <h2>#{platform}</h2>
          <p>Expected #{data[:expected_count]} screenshot(s). Live public page shows #{data[:live_count]}.</p>
          #{rows}
        </section>
      HTML
    end.join("\n")

    issues = if report[:issues].empty?
               '<li>No mismatches detected.</li>'
             else
               report[:issues].map { |issue| "<li>#{escape_html(issue)}</li>" }.join("\n")
             end

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <title>#{escape_html(report[:app_name])} public App Store screenshot audit</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #09101f; color: #f5f7fb; margin: 0; padding: 32px; }
            a { color: #73d7ff; }
            h1, h2 { margin: 0 0 12px; }
            p, li { line-height: 1.5; }
            .summary { margin-bottom: 32px; }
            .issues { background: #10192e; border: 1px solid #1c2b49; border-radius: 16px; padding: 20px 24px; margin-bottom: 32px; }
            section { margin-bottom: 40px; }
            .row { background: #10192e; border: 1px solid #1c2b49; border-radius: 16px; padding: 20px; margin-bottom: 20px; }
            .meta { margin-bottom: 16px; }
            .slot { font-size: 18px; font-weight: 700; margin-bottom: 10px; }
            .images { display: grid; grid-template-columns: repeat(2, minmax(320px, 1fr)); gap: 20px; }
            figure { margin: 0; }
            figcaption { font-size: 14px; color: #9db0d8; margin-bottom: 8px; }
            img { width: 100%; border-radius: 12px; background: #050913; }
            .missing { min-height: 180px; display: grid; place-items: center; border: 1px dashed #456; border-radius: 12px; color: #9db0d8; }
          </style>
        </head>
        <body>
          <div class="summary">
            <h1>#{escape_html(report[:app_name])} public App Store screenshot audit</h1>
            <p><strong>App ID:</strong> #{escape_html(report[:app_id])}</p>
            <p><strong>Public URL:</strong> <a href="#{escape_html(report[:public_url])}">#{escape_html(report[:public_url])}</a></p>
            <p><strong>Storyboard:</strong> #{escape_html(report[:storyboard_path])}</p>
          </div>
          <div class="issues">
            <h2>Issues</h2>
            <ul>
              #{issues}
            </ul>
          </div>
          #{sections}
        </body>
      </html>
    HTML
  end

  def load_manifest
    @load_manifest ||= load_yaml(File.join(project_root, '.saneprocess'))
  end
  alias manifest load_manifest

  def storyboard_path
    File.join(project_root, 'docs', 'appstore_screenshot_storyboard.yml')
  end

  def app_id
    manifest.dig('appstore', 'app_id').to_s
  end

  def public_url
    "https://apps.apple.com/#{country}/app/id#{app_id}"
  end

  def configured_storyboard_platforms
    @configured_storyboard_platforms ||= storyboard_entries_by_platform.keys
  end

  def classify_live_basename(basename)
    name = basename.downcase
    return 'watch' if name.include?('watch')
    return 'ipad' if name.include?('ipad')
    return 'macos' if name.include?('mac')
    return configured_storyboard_platforms.first if configured_storyboard_platforms.length == 1
    if configured_storyboard_platforms.include?('macos') &&
       name.start_with?('screenshot-') &&
       !name.include?('ios') &&
       !name.include?('ipad')
      return 'macos'
    end
    return 'ios' if name.include?('ios') || name.include?('6.7') || name.match?(/\A\d+_.*dark\.png\z/)

    'unknown'
  end

  def screenshot_basename(url)
    match = url.match(SCREENSHOT_FILENAME_PATTERN)
    match && match[1]
  end

  def screenshot_width(url)
    match = url.match(SCREENSHOT_SIZE_PATTERN)
    match ? match[1].to_i : 0
  end

  def materialize_live_url(url, platform)
    return url unless url.include?('{w}x{h}')

    width, height = TEMPLATE_SIZE_BY_PLATFORM.fetch(platform, TEMPLATE_SIZE_BY_PLATFORM['unknown'])
    url.gsub('{w}', width.to_s)
       .gsub('{h}', height.to_s)
       .gsub('{c}', 'bb-60')
       .gsub('{f}', 'jpg')
  end

  def screenshot_extension(url)
    return '.jpg' if url.include?('.jpg')
    return '.webp' if url.include?('.webp')

    '.png'
  end

  def http_get_binary(url)
    response = http_response(url)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to download #{url}: #{response.code} #{response.message}"
    end

    response.body
  end

  def http_get_text(url)
    response = http_response(url)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to fetch #{url}: #{response.code} #{response.message}"
    end

    response.body
  end

  def http_response(url, limit = 5)
    raise "Too many redirects while fetching #{url}" if limit <= 0

    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    if response.is_a?(Net::HTTPRedirection)
      location = response['location']
      raise "Redirect without location while fetching #{url}" if location.to_s.strip.empty?

      return http_response(URI.join(url, location).to_s, limit - 1)
    end

    response
  end

  def load_yaml(path)
    YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: true) || {}
  rescue Errno::ENOENT
    raise "Missing required file: #{path}"
  end

  def escape_html(text)
    text.to_s
        .gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    project_root: Dir.pwd,
    country: 'us'
  }

  OptionParser.new do |opts|
    opts.banner = 'Usage: appstore_public_screenshot_audit.rb [options]'
    opts.on('--project-root PATH', 'App project root (default: current directory)') { |value| options[:project_root] = value }
    opts.on('--country CODE', 'Public App Store country code (default: us)') { |value| options[:country] = value }
    opts.on('--output-dir PATH', 'Output directory for the audit report and downloaded live screenshots') { |value| options[:output_dir] = value }
  end.parse!

  audit = AppStorePublicScreenshotAudit.new(
    project_root: options[:project_root],
    country: options[:country],
    output_dir: options[:output_dir]
  )
  issues = audit.run
  puts "Report written to #{audit.output_dir}"
  if issues.empty?
    puts 'Public App Store screenshot audit passed.'
    exit 0
  end

  warn 'Public App Store screenshot audit found mismatches:'
  issues.each { |issue| warn " - #{issue}" }
  exit 1
end
