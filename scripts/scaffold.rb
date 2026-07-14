#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneApps Project Scaffold
# Creates a new app project with the standard SaneApps structure.
#
# Usage: ruby scripts/scaffold.rb <AppName> [--type macos|ios]
#
# Example:
#   ruby scripts/scaffold.rb SaneNotes
#   ruby scripts/scaffold.rb SaneNotes --type ios
#
# Creates:
#   ~/SaneApps/apps/SaneNotes/
#   ├── .claude/rules/          (synced from SaneProcess)
#   ├── .claude/settings.json   (synced from SaneProcess)
#   ├── .codex/research.md      (active research cache)
#   ├── .github/
#   │   ├── FUNDING.yml
#   │   └── ISSUE_TEMPLATE/bug_report.md
#   ├── scripts/
#   │   └── generate_download_link.rb
#   ├── docs/
#   │   ├── appcast.xml
#   │   └── images/
#   ├── .gitignore              (from template)
#   ├── .swiftlint.yml          (from template)
#   ├── .saneprocess            (generated)
#   ├── lefthook.yml            (from template)
#   ├── Gemfile                 (standard)
#   ├── AGENTS.md               (shared agent source of truth)
#   ├── CLAUDE.md               (stub)
#   ├── README.md               (stub)
#   ├── DEVELOPMENT.md          (stub)
#   ├── ARCHITECTURE.md         (stub)
#   ├── SESSION_HANDOFF.md      (stub)
#   ├── CODE_OF_CONDUCT.md      (from governance)
#   ├── CONTRIBUTING.md         (from template)
#   ├── PRIVACY.md              (stub)
#   └── SECURITY.md             (stub)
# ==============================================================================

require 'fileutils'
require 'yaml'
require 'date'

SANEPROCESS_ROOT = File.expand_path('..', __dir__)
TEMPLATES_DIR = File.join(SANEPROCESS_ROOT, 'templates')
GOVERNANCE_DIR = File.join(File.dirname(File.dirname(SANEPROCESS_ROOT)), 'meta', 'governance')
APPS_DIR = File.join(File.dirname(File.dirname(SANEPROCESS_ROOT)), 'apps')

def main
  if ARGV.empty? || ARGV[0] == '--help'
    warn "Usage: ruby scripts/scaffold.rb <AppName> [--type macos|ios]"
    warn "  e.g. ruby scripts/scaffold.rb SaneNotes"
    exit 1
  end

  app_name = ARGV[0]
  app_type = ARGV.include?('--type') ? ARGV[ARGV.index('--type') + 1] : 'macos'
  app_slug = app_name.downcase
  project_dir = File.join(APPS_DIR, app_name)

  if File.exist?(project_dir)
    warn "#{project_dir} already exists"
    exit 1
  end

  unless app_name.start_with?('Sane')
    warn "Warning: App name '#{app_name}' doesn't follow SaneApps naming convention (Sane*)"
  end

  puts "Scaffolding #{app_name} (#{app_type}) at #{project_dir}"
  puts

  # Create directory structure
  dirs = %w[
    .codex
    .claude/rules
    .github/ISSUE_TEMPLATE
    scripts
    docs/images
    Core/Models
    Core/Services
    UI
    Tests
  ]

  dirs.each do |dir|
    FileUtils.mkdir_p(File.join(project_dir, dir))
  end

  # Copy templates
  copy_template('.swiftlint.yml', 'swiftlint.yml', project_dir)
  copy_template('.gitignore', 'gitignore', project_dir)
  copy_template('lefthook.yml', 'lefthook.yml', project_dir)

  # Copy scripts
  scripts_template = File.join(TEMPLATES_DIR, 'scripts', 'generate_download_link.rb')
  if File.exist?(scripts_template)
    FileUtils.cp(scripts_template, File.join(project_dir, 'scripts', 'generate_download_link.rb'))
  end

  # Copy .claude/rules from SaneProcess
  rules_src = File.join(SANEPROCESS_ROOT, '.claude', 'rules')
  if File.directory?(rules_src)
    Dir.glob(File.join(rules_src, '*.md')).each do |rule|
      FileUtils.cp(rule, File.join(project_dir, '.claude', 'rules', File.basename(rule)))
    end
  end

  # Copy .claude/settings.json from SaneProcess
  settings_src = File.join(SANEPROCESS_ROOT, '.claude', 'settings.json')
  if File.exist?(settings_src)
    FileUtils.cp(settings_src, File.join(project_dir, '.claude', 'settings.json'))
  end

  # Copy governance files
  coc = File.join(GOVERNANCE_DIR, 'CODE_OF_CONDUCT.md')
  FileUtils.cp(coc, File.join(project_dir, 'CODE_OF_CONDUCT.md')) if File.exist?(coc)

  # Generate CONTRIBUTING.md from template
  contributing_template = File.join(GOVERNANCE_DIR, 'CONTRIBUTING.template.md')
  if File.exist?(contributing_template)
    content = File.read(contributing_template).gsub('{{APP_NAME}}', app_name)
    File.write(File.join(project_dir, 'CONTRIBUTING.md'), content)
  end

  # Generate .saneprocess
  min_version = app_type == 'ios' ? '17.0' : '15.0'
  saneprocess = {
    'name' => app_name,
    'type' => "#{app_type}_app",
    'scheme' => app_name,
    'project' => "#{app_name}.xcodeproj",
    'bundle_id' => "com.#{app_slug}.app",
    'build' => { 'xcodegen' => true },
    'release' => {
      'dist_host' => "dist.#{app_slug}.com",
      'site_host' => "#{app_slug}.com",
      'r2_bucket' => 'sanebar-downloads',
      'use_sparkle' => app_type == 'macos',
      'min_system_version' => min_version
    },
    'commands' => {
      'verify' => './scripts/SaneMaster.rb verify',
      'test_mode' => './scripts/SaneMaster.rb tm',
      'lint' => './scripts/SaneMaster.rb lint',
      'clean' => './scripts/SaneMaster.rb clean',
      'launch' => './scripts/SaneMaster.rb launch',
      'logs' => './scripts/SaneMaster.rb logs'
    },
    'docs' => %w[AGENTS.md README.md DEVELOPMENT.md ARCHITECTURE.md SESSION_HANDOFF.md],
    'mcps' => %w[apple-docs context7 github xcode],
    'website' => false
  }
  File.write(File.join(project_dir, '.saneprocess'), saneprocess.to_yaml)

  # Generate appcast.xml (macOS only)
  if app_type == 'macos'
    appcast = <<~XML
      <?xml version="1.0" standalone="yes"?>
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
              <title>#{app_name} Updates</title>
              <link>https://#{app_slug}.com/appcast.xml</link>
              <description>Most recent changes with links to updates.</description>
              <language>en</language>
              <!-- Items will be added by release.sh when first version ships -->
          </channel>
      </rss>
    XML
    File.write(File.join(project_dir, 'docs', 'appcast.xml'), appcast)
  end

  # Generate Codex-first research cache. Other clients should read this unless a
  # project deliberately establishes a different active cache.
  File.write(File.join(project_dir, '.codex', 'research.md'), <<~MD)
    # Research Cache

    Persistent research findings for this project. Limit: 200 lines.
    Graduate verified findings to ARCHITECTURE.md or DEVELOPMENT.md.

    <!-- Sections added by research agents. Format:
    ## Topic Name
    **Updated:** YYYY-MM-DD | **Status:** verified/stale/partial | **TTL:** 7d/30d/90d
    **Source:** tool or URL
    - Finding 1
    - Finding 2
    -->
  MD

  # Generate GitHub files
  File.write(File.join(project_dir, '.github', 'FUNDING.yml'), <<~YML)
    custom:
      - https://saneapps.lemonsqueezy.com
  YML

  File.write(File.join(project_dir, '.github', 'ISSUE_TEMPLATE', 'bug_report.md'), <<~MD)
    ---
    name: Bug Report
    about: Report a bug in #{app_name}
    labels: bug
    ---

    **Describe the bug**
    A clear description of what the bug is.

    **To Reproduce**
    Steps to reproduce:
    1. Go to '...'
    2. Click on '...'
    3. See error

    **Expected behavior**
    What you expected to happen.

    **Environment**
    - macOS version:
    - #{app_name} version:

    **Screenshots**
    If applicable, add screenshots.
  MD

  # Generate Gemfile
  File.write(File.join(project_dir, 'Gemfile'), <<~RUBY)
    source "https://rubygems.org"

    gem "xcodegen", "~> 2.42"
  RUBY

  # Generate 5-doc standard stubs
  today = Date.today.strftime('%Y-%m-%d')
  generate_stub(project_dir, 'AGENTS.md', <<~MD)
    # #{app_name} Agent Instructions

    This file is the shared source of truth for Codex, Claude, Gemini, and other
    compatible coding agents working in this repo.

    ## Defaults

    - Codex is the primary/default toolset.
    - Read this file before changing behavior.
    - Keep active research in `.codex/research.md`.
    - Promote durable decisions into `ARCHITECTURE.md`, `DEVELOPMENT.md`,
      `SESSION_HANDOFF.md`, memory, or AgentMemory.
    - Use `./scripts/SaneMaster.rb` for build, test, release, analytics, and
      other stateful SaneApps workflows.
  MD

  generate_stub(project_dir, 'CLAUDE.md', <<~MD)
    # #{app_name} Claude Compatibility Overlay

    Read [AGENTS.md](AGENTS.md) first. It is the shared source of truth for
    Codex, Claude, Gemini, and other compatible coding agents.

    > **Project Docs:** [AGENTS](AGENTS.md) | [README](README.md) | [DEVELOPMENT](DEVELOPMENT.md) | [ARCHITECTURE](ARCHITECTURE.md) | [SESSION_HANDOFF](SESSION_HANDOFF.md)

    ## Quick Start

    ```bash
    ./scripts/SaneMaster.rb verify   # Build + test
    ./scripts/SaneMaster.rb tm       # Kill, build, launch, stream logs
    ```

    ## Project Structure

    ```
    #{app_name}/
    ├── Core/           # Business logic
    │   ├── Models/
    │   └── Services/
    ├── UI/             # SwiftUI views
    ├── Tests/          # Swift Testing
    ├── scripts/        # Build automation
    └── docs/           # Website, appcast
    ```
  MD

  generate_stub(project_dir, 'README.md', <<~MD)
    # #{app_name}

    A SaneApps macOS application.

    ## Installation

    Download from [#{app_slug}.com](https://#{app_slug}.com).

    ## Features

    <!-- Add features here -->

    ## Privacy

    #{app_name} collects zero user data. See [PRIVACY.md](PRIVACY.md).

    ## License

    Copyright #{Date.today.year} SaneApps. All rights reserved.
  MD

  generate_stub(project_dir, 'DEVELOPMENT.md', <<~MD)
    # #{app_name} Development Guide

    ## Prerequisites

    - macOS 15.0+ (Sequoia)
    - Xcode 16+
    - Ruby 3.0+ (for build scripts)

    ## Build & Run

    ```bash
    bundle install                    # First time only
    ./scripts/SaneMaster.rb verify    # Build + run tests
    ./scripts/SaneMaster.rb tm        # Interactive test mode
    ```

    ## Testing

    Uses Swift Testing framework (`import Testing`, `@Test`, `#expect`).

    ```bash
    ./scripts/SaneMaster.rb verify    # Run all tests
    ```

    ## Release Process

    ```bash
    bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
      --project "$(pwd)" --full --version X.Y.Z --notes "Customer-facing release notes" --deploy
    ```
  MD

  generate_stub(project_dir, 'ARCHITECTURE.md', <<~MD)
    # #{app_name} Architecture

    ## Overview

    <!-- High-level architecture description -->

    ## Key Components

    <!-- Major components and their responsibilities -->

    ## Data Flow

    <!-- How data moves through the app -->
  MD

  generate_stub(project_dir, 'SESSION_HANDOFF.md', <<~MD)
    # Session Handoff

    **Last updated:** #{today}

    ## Done
    - Initial project scaffold

    ## Pending
    - Core implementation

    ## Gotchas
    - None yet
  MD

  generate_stub(project_dir, 'PRIVACY.md', <<~MD)
    # Privacy Policy — #{app_name}

    **Effective Date:** #{today}

    ## Data Collection

    #{app_name} collects **zero** user data:
    - No analytics
    - No telemetry
    - No crash reporting to external services
    - No account required

    ## Local Storage

    All data is stored locally on your Mac.

    ## Contact

    Questions? Email hi@saneapps.com.
  MD

  generate_stub(project_dir, 'SECURITY.md', <<~MD)
    # Security Policy — #{app_name}

    ## Supported Versions

    | Version | Supported |
    | ------- | --------- |
    | 1.0.x   | Yes       |

    ## Reporting a Vulnerability

    **Do NOT report security vulnerabilities through public GitHub issues.**

    Email: hi@saneapps.com

    Include:
    - Description of the vulnerability
    - Steps to reproduce
    - Potential impact

    You should receive a response within 48 hours.
  MD

  puts
  puts "#{app_name} scaffolded at #{project_dir}"
  puts
  puts "Next steps:"
  puts "  1. cd #{project_dir}"
  puts "  2. git init && git add -A && git commit -m 'Initial scaffold'"
  puts "  3. Add #{app_slug} to SaneProcess/config/products.yml"
  puts "  4. Create GitHub repo: gh repo create sane-apps/#{app_name} --private"
  puts "  5. Start building!"
end

def copy_template(dest_name, template_name, project_dir)
  src = File.join(TEMPLATES_DIR, template_name)
  return unless File.exist?(src)

  FileUtils.cp(src, File.join(project_dir, dest_name))
end

def generate_stub(project_dir, filename, content)
  File.write(File.join(project_dir, filename), content)
end

main
