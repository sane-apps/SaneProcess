#!/usr/bin/env ruby
# frozen_string_literal: true

#
# SaneProcess Cross-Project Sync Check
# Detects drift between SaneProcess and implementation projects
#
# Usage: ruby scripts/sync_check.rb [project_path]
#
# Examples:
#   ruby scripts/sync_check.rb ~/SaneBar
#   ruby scripts/sync_check.rb ~/SaneVideo
#   ruby scripts/sync_check.rb  # Auto-detect sibling projects
#
# Checks:
# - Hooks in SaneProcess vs project
# - Pattern rules in .claude/rules/
# - Version numbers match
#

require 'digest'
require 'fileutils'
require 'json'

class SyncCheck
  SANEPROCESS_ROOT = File.expand_path('..', __dir__)
  HOOKS_DIR = File.join(SANEPROCESS_ROOT, 'scripts', 'hooks')
  RULES_DIR = File.join(SANEPROCESS_ROOT, '.claude', 'rules')
  GLOBAL_HOOKS_DIR = File.expand_path('~/.claude/hooks')
  SANEMASTER_DIR = File.join(SANEPROCESS_ROOT, 'scripts', 'sanemaster')
  SETTINGS_TEMPLATE = File.join(SANEPROCESS_ROOT, '.claude', 'settings.json')

  # Hooks that should be identical across all projects
  # PRIMARY HOOKS (new unified system)
  SYNC_HOOKS = %w[
    saneprompt.rb
    sanetools.rb
    sanetrack.rb
    sanestop.rb
    session_start.rb
    state_signer.rb
  ].freeze

  # Rules that should be synced
  SYNC_RULES = %w[
    views.md
    tests.md
    services.md
    models.md
    scripts.md
    hooks.md
  ].freeze

  # SaneMaster modules - CORE must be identical, CUSTOMIZABLE can differ
  # C5 FIX: Updated to include all actual modules
  CORE_MODULES = %w[
    base.rb
    bootstrap.rb
    circuit_breaker_state.rb
    compliance_report.rb
    export.rb
    md_export.rb
    memory.rb
    meta.rb
    session.rb
    sop_loop.rb
  ].freeze

  # These modules often have project-specific customizations
  CUSTOMIZABLE_MODULES = %w[
    dependencies.rb
    diagnostics.rb
    generation.rb
    generation_assets.rb
    generation_mocks.rb
    generation_templates.rb
    quality.rb
    test_mode.rb
    verify.rb
  ].freeze

  SYNC_MODULES = (CORE_MODULES + CUSTOMIZABLE_MODULES).freeze

  def initialize(args = [])
    @fix_mode = args.delete('--fix')
    @global_mode = args.delete('--global')
    @project_paths = args.empty? ? detect_sibling_projects : args
    @diffs = []
  end

  def run
    puts "═══════════════════════════════════════════════════════════════"
    puts "              Cross-Project Sync Check"
    puts "═══════════════════════════════════════════════════════════════"
    puts
    puts "SaneProcess: #{SANEPROCESS_ROOT}"

    # DEPRECATED: Global hooks are no longer used
    # Hooks are now project-relative (./scripts/hooks/) in settings.json
    # Legacy global sync kept for backwards compatibility only
    if @global_mode
      puts "Checking global hooks (~/.claude/hooks/) [LEGACY]..."
      sync_global_hooks
    end

    # C6 FIX: Sync settings.json to global
    puts "Checking global settings.json..."
    sync_global_settings

    if @project_paths.empty?
      puts "No sibling projects found to compare."
      puts "Usage: ruby scripts/sync_check.rb ~/SaneBar ~/SaneVideo"
    else
      puts "Comparing with: #{@project_paths.join(', ')}"
      puts

      @project_paths.each do |project|
        check_project(project)
      end
    end

    puts
    puts "═══════════════════════════════════════════════════════════════"

    if @diffs.empty?
      puts "✅ All projects in sync!"
      exit 0
    else
      puts "⚠️  Found #{@diffs.count} differences:"
      puts

      @diffs.group_by { |d| d[:project] }.each do |project, project_diffs|
        puts "#{project}:"
        project_diffs.each do |diff|
          puts "  #{diff[:status]} #{diff[:file]}"
          puts "       #{diff[:reason]}" if diff[:reason]
        end
        puts
      end

      if @fix_mode
        fix_diffs
      else
        puts "Run 'ruby scripts/sync_check.rb --fix' to copy from SaneProcess to projects"
      end
      exit 1
    end
  end

  # Sync hooks to global ~/.claude/hooks/ directory
  def sync_global_hooks
    FileUtils.mkdir_p(GLOBAL_HOOKS_DIR)

    synced = 0
    SYNC_HOOKS.each do |hook|
      src = File.join(HOOKS_DIR, hook)
      dst = File.join(GLOBAL_HOOKS_DIR, hook)

      next unless File.exist?(src)

      # Check if different
      needs_sync = !File.exist?(dst) || Digest::MD5.file(src) != Digest::MD5.file(dst)

      if needs_sync
        if @fix_mode
          FileUtils.cp(src, dst)
          FileUtils.chmod(0o755, dst)
          puts "  ✅ Synced #{hook} to global"
          synced += 1
        else
          status = File.exist?(dst) ? '⚠️  DIFFERS' : '❌ MISSING'
          @diffs << { project: 'GLOBAL', file: hook, status: status, reason: 'Global hook out of sync' }
        end
      end
    end

    puts "  ✅ Global hooks in sync" if synced.zero? && @fix_mode
    puts
  end

  # C6 FIX: Sync settings.json to global ~/.claude/settings.json
  def sync_global_settings
    global_settings = File.expand_path('~/.claude/settings.json')

    unless File.exist?(SETTINGS_TEMPLATE)
      puts "  ⚠️  No settings.json template in SaneProcess"
      return
    end

    needs_sync = !File.exist?(global_settings) ||
                 Digest::MD5.file(SETTINGS_TEMPLATE) != Digest::MD5.file(global_settings)

    if needs_sync
      if @fix_mode
        FileUtils.cp(SETTINGS_TEMPLATE, global_settings)
        puts "  ✅ Synced settings.json to global"
      else
        status = File.exist?(global_settings) ? '⚠️  DIFFERS' : '❌ MISSING'
        @diffs << { project: 'GLOBAL', file: 'settings.json', status: status, reason: 'Global settings out of sync' }
      end
    else
      puts "  ✅ Global settings.json in sync"
    end
    puts
  end

  def fix_diffs
    puts
    puts "Fixing differences..."
    puts

    fixed = 0
    skipped = 0

    @diffs.each do |diff|
      # Skip global diffs - already handled in sync_global_hooks
      next if diff[:project] == 'GLOBAL'

      project_path = detect_project_path(diff[:project])
      next unless project_path

      case diff[:status]
      when '❌ MISSING', '⚠️  DIFFERS'
        # Copy from SaneProcess to project
        if diff[:file] == 'settings.json'
          # C6 FIX: Handle settings.json sync
          src = SETTINGS_TEMPLATE
          dst = File.join(project_path, '.claude', 'settings.json')
        elsif diff[:file].start_with?('rules/')
          src = File.join(RULES_DIR, diff[:file].sub('rules/', ''))
          dst = File.join(project_path, '.claude', diff[:file])
        elsif diff[:file].start_with?('sanemaster/')
          src = File.join(SANEMASTER_DIR, diff[:file].sub('sanemaster/', ''))
          dst = File.join(project_path, 'Scripts', diff[:file])
        else
          src = File.join(HOOKS_DIR, diff[:file])
          dst_dir = find_hooks_dir(project_path)
          dst = File.join(dst_dir, diff[:file]) if dst_dir
        end

        if src && dst && File.exist?(src)
          FileUtils.mkdir_p(File.dirname(dst))
          FileUtils.cp(src, dst)
          FileUtils.chmod(0o755, dst) if dst.end_with?('.rb')
          puts "  ✅ Copied #{diff[:file]} to #{diff[:project]}"
          fixed += 1
        else
          puts "  ⚠️  Skipped #{diff[:file]} (source not found)"
          skipped += 1
        end
      when '➕ EXTRA'
        # Extra files in project - don't delete, just note
        puts "  ⏭️  Skipped #{diff[:file]} (project-specific)"
        skipped += 1
      end
    end

    puts
    puts "Fixed: #{fixed}, Skipped: #{skipped}"
  end

  def detect_project_path(project_name)
    @project_paths.find { |p| File.basename(p) == project_name }
  end

  private

  def detect_sibling_projects
    parent = File.dirname(SANEPROCESS_ROOT)
    siblings = Dir.entries(parent).select do |entry|
      next false if entry.start_with?('.')
      next false if entry == 'SaneProcess'

      path = File.join(parent, entry)
      # Check if it looks like a Sane* project (has Scripts/hooks or .claude/rules)
      File.directory?(path) &&
        (File.directory?(File.join(path, 'Scripts', 'hooks')) ||
         File.directory?(File.join(path, '.claude', 'rules')))
    end

    siblings.map { |s| File.join(parent, s) }
  end

  def check_project(project_path)
    name = File.basename(project_path)
    puts "Checking #{name}..."

    # Find hooks directory (Scripts/hooks or scripts/hooks) - skip, using global hooks
    # project_hooks = find_hooks_dir(project_path)
    # if project_hooks
    #   check_hooks(project_path, project_hooks)
    # else
    #   puts "  ⚠️  No hooks directory found"
    # end

    # Check sanemaster modules
    project_sanemaster = File.join(project_path, 'Scripts', 'sanemaster')
    if File.directory?(project_sanemaster)
      check_sanemaster(project_path, project_sanemaster)
    else
      puts "  ⚠️  No Scripts/sanemaster directory found"
    end

    # Find rules directory
    project_rules = File.join(project_path, '.claude', 'rules')
    if File.directory?(project_rules)
      check_rules(project_path, project_rules)
    else
      puts "  ⚠️  No .claude/rules directory found"
    end

    # C6 FIX: Check project settings.json
    check_settings(project_path)

    puts
  end

  # C6 FIX: Check project's .claude/settings.json
  def check_settings(project_path)
    project_name = File.basename(project_path)
    project_settings = File.join(project_path, '.claude', 'settings.json')

    unless File.exist?(SETTINGS_TEMPLATE)
      return
    end

    unless File.exist?(project_settings)
      @diffs << {
        project: project_name,
        file: 'settings.json',
        status: '❌ MISSING',
        reason: 'settings.json missing from project'
      }
      return
    end

    # Compare hooks section (should be identical)
    sp_settings = JSON.parse(File.read(SETTINGS_TEMPLATE))
    proj_settings = JSON.parse(File.read(project_settings))

    if sp_settings['hooks'] != proj_settings['hooks']
      @diffs << {
        project: project_name,
        file: 'settings.json',
        status: '⚠️  DIFFERS',
        reason: 'hooks section differs from SaneProcess'
      }
    end
  rescue JSON::ParserError => e
    puts "  ⚠️  Invalid JSON in settings.json: #{e.message}"
  end

  def check_sanemaster(project_path, project_sanemaster_dir)
    project_name = File.basename(project_path)

    # Check CORE modules (must be identical)
    CORE_MODULES.each do |mod|
      sp_path = File.join(SANEMASTER_DIR, mod)
      proj_path = File.join(project_sanemaster_dir, mod)

      next unless File.exist?(sp_path)

      unless File.exist?(proj_path)
        @diffs << {
          project: project_name,
          file: "sanemaster/#{mod}",
          status: '❌ MISSING',
          reason: 'Core module missing (will be synced)'
        }
        next
      end

      sp_content = normalize_hook(File.read(sp_path))
      proj_content = normalize_hook(File.read(proj_path))

      next if sp_content == proj_content

      @diffs << {
        project: project_name,
        file: "sanemaster/#{mod}",
        status: '⚠️  DIFFERS',
        reason: 'Core module differs (will be synced)'
      }
    end

    # Check CUSTOMIZABLE modules (warn but don't auto-fix)
    CUSTOMIZABLE_MODULES.each do |mod|
      sp_path = File.join(SANEMASTER_DIR, mod)
      proj_path = File.join(project_sanemaster_dir, mod)

      next unless File.exist?(sp_path)
      next unless File.exist?(proj_path) # Missing is OK for customizable

      sp_content = normalize_hook(File.read(sp_path))
      proj_content = normalize_hook(File.read(proj_path))

      next if sp_content == proj_content

      # Just note the difference, don't add to @diffs for auto-fix
      puts "  ℹ️  #{mod} differs (project-specific OK)"
    end
  end

  def find_hooks_dir(project_path)
    # Check multiple possible hook locations
    %w[
      Scripts/hooks
      scripts/hooks
      Scripts/sanemaster/hooks
      scripts/sanemaster/hooks
    ].each do |rel_path|
      full_path = File.join(project_path, rel_path)
      return full_path if File.directory?(full_path)
    end
    nil
  end

  def check_hooks(project_path, project_hooks_dir)
    project_name = File.basename(project_path)

    SYNC_HOOKS.each do |hook|
      sp_path = File.join(HOOKS_DIR, hook)
      proj_path = File.join(project_hooks_dir, hook)

      unless File.exist?(sp_path)
        # SaneProcess doesn't have this hook (shouldn't happen)
        next
      end

      unless File.exist?(proj_path)
        @diffs << {
          project: project_name,
          file: hook,
          status: '❌ MISSING',
          reason: 'Hook exists in SaneProcess but not in project'
        }
        next
      end

      sp_content = normalize_hook(File.read(sp_path))
      proj_content = normalize_hook(File.read(proj_path))

      next if sp_content == proj_content

      # Content differs - check if it's significant
      sp_hash = Digest::MD5.hexdigest(sp_content)
      proj_hash = Digest::MD5.hexdigest(proj_content)

      @diffs << {
        project: project_name,
        file: hook,
        status: '⚠️  DIFFERS',
        reason: "SP: #{sp_hash[0..7]}... vs Project: #{proj_hash[0..7]}..."
      }
    end

    # Check for extra hooks in project
    Dir.glob(File.join(project_hooks_dir, '*.rb')).each do |proj_hook|
      hook_name = File.basename(proj_hook)
      next if SYNC_HOOKS.include?(hook_name)
      next if hook_name.start_with?('test') # Ignore test files

      sp_path = File.join(HOOKS_DIR, hook_name)
      next if File.exist?(sp_path)

      @diffs << {
        project: project_name,
        file: hook_name,
        status: '➕ EXTRA',
        reason: 'Hook exists in project but not in SaneProcess'
      }
    end
  end

  def check_rules(project_path, project_rules_dir)
    project_name = File.basename(project_path)

    SYNC_RULES.each do |rule|
      sp_path = File.join(RULES_DIR, rule)
      proj_path = File.join(project_rules_dir, rule)

      next unless File.exist?(sp_path)

      unless File.exist?(proj_path)
        @diffs << {
          project: project_name,
          file: "rules/#{rule}",
          status: '❌ MISSING',
          reason: 'Rule exists in SaneProcess but not in project'
        }
        next
      end

      sp_content = File.read(sp_path).strip
      proj_content = File.read(proj_path).strip

      next if sp_content == proj_content

      @diffs << {
        project: project_name,
        file: "rules/#{rule}",
        status: '⚠️  DIFFERS',
        reason: 'Content differs from SaneProcess'
      }
    end
  end

  def normalize_hook(content)
    # Remove comments that might differ (copyright, project-specific)
    # Keep functional code the same
    content
      .gsub(/^#.*Copyright.*$/i, '')
      .gsub(/^#.*SaneBar.*$/i, '')
      .gsub(/^#.*SaneVideo.*$/i, '')
      .gsub(/^#.*SaneProcess.*$/i, '')
      .gsub(/^\s*\n/, "\n")
      .strip
  end
end

# Run if executed directly
SyncCheck.new(ARGV).run if __FILE__ == $PROGRAM_NAME
