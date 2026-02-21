#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Cross-Project Contamination Detector
#
# Scans a Sane* project for references to OTHER Sane* projects.
# Catches all variations: SaneBar, sanebar, sane_bar, sane-bar, SANEBAR, etc.
#
# Usage:
#   ruby scripts/contamination_check.rb              # Check current project
#   ruby scripts/contamination_check.rb ~/SaneBar    # Check specific project
#   ruby scripts/contamination_check.rb --all        # Check all Sane* projects
#
# Exit codes:
#   0 = Clean (no contamination)
#   1 = Contamination found
#

require 'pathname'
require 'set'

class ContaminationChecker
  # All Sane* projects and their name variations
  PROJECTS = {
    'SaneProcess' => %w[SaneProcess saneprocess sane_process sane-process SANEPROCESS],
    'SaneBar' => %w[SaneBar sanebar sane_bar sane-bar SANEBAR],
    'SaneVideo' => %w[SaneVideo sanevideo sane_video sane-video SANEVIDEO],
    'SaneSync' => %w[SaneSync sanesync sane_sync sane-sync SANESYNC]
  }.freeze

  # Additional patterns with spaces (grep separately)
  SPACE_PATTERNS = {
    'SaneProcess' => ['Sane Process', 'sane process'],
    'SaneBar' => ['Sane Bar', 'sane bar'],
    'SaneVideo' => ['Sane Video', 'sane video'],
    'SaneSync' => ['Sane Sync', 'sane sync']
  }.freeze

  # Files/patterns that are ALLOWED to reference other projects
  ALLOWED_PATTERNS = [
    # Sync documentation and tools
    'sync_check.rb',
    'contamination_check.rb',
    'PROJECT_SYNC_PLAN.md',
    'SESSION_HANDOFF.md',
    # Documentation about the ecosystem
    'copilot-instructions.md',
    'AUDIT_FINDINGS.md',
    'BUG_TRACKING.md',
    # .claude state files (logs, history, not code)
    '.claude/read_history.json',
    '.claude/memory.json',
    '.claude/state.json',
    '.claude/audit_log.jsonl',
    '.claude/SOP_CONTEXT.md',
    '.claude/hook_fixes.md',
    '.claude/memory_cleanup',
    'saneloop-archive',
    # Test files that use example paths (paths in tests are just examples)
    'TEST_TIERS.md',
    # Log files
    '.log',
    'debug.log',
    # Git
    '.git/',
    # Gemini config (separate AI)
    '.gemini/'
  ].freeze

  # Critical files that should NEVER reference other projects
  # These are the ones that actually affect runtime behavior
  CRITICAL_FILES = [
    'CLAUDE.md',           # Project identity
    'DEVELOPMENT.md',      # SOP (only in header/project-specific sections)
    'SaneMaster.rb',       # Build automation
    'qa.rb',               # QA script
    '.swiftlint.yml',      # Linting config
    '.gitignore',          # Git config
    'project.yml',         # Xcode project
    'generation.rb',       # Code generation
    'generation_mocks.rb', # Mock generation
    'dependencies.rb',     # Dependency management
    '.applescript',        # AppleScript automation
    'monitor_tests.sh',    # Test runner
    'post_mock_generation.sh', # Post-processing
    'enable_tests_for_ci.sh',  # CI config
  ].freeze

  # File extensions to check
  CHECK_EXTENSIONS = %w[
    .rb .swift .sh .yml .yaml .json .md .txt .applescript .py
    .gitignore .swiftlint.yml
  ].freeze

  # Directories to skip entirely
  SKIP_DIRS = %w[
    .git DerivedData .build build .swiftpm node_modules vendor Pods
  ].freeze

  def initialize(project_path)
    @project_path = Pathname.new(project_path).expand_path
    @project_name = detect_project_name
    @findings = []
    @files_scanned = 0
  end

  def detect_project_name
    dir_name = @project_path.basename.to_s
    PROJECTS.keys.find { |p| dir_name.include?(p) } || dir_name
  end

  def other_projects
    PROJECTS.keys - [@project_name]
  end

  def run
    puts "🔍 Scanning #{@project_name} for cross-project contamination..."
    puts "   Path: #{@project_path}"
    puts "   Looking for references to: #{other_projects.join(', ')}"
    puts

    scan_directory(@project_path)

    report_findings
  end

  def scan_directory(dir)
    return if SKIP_DIRS.any? { |skip| dir.to_s.include?("/#{skip}") }

    dir.children.each do |child|
      if child.directory?
        scan_directory(child)
      elsif should_check_file?(child)
        scan_file(child)
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    # Skip inaccessible files
  end

  def should_check_file?(file)
    return false if SKIP_DIRS.any? { |skip| file.to_s.include?("/#{skip}/") }

    ext = file.extname.downcase
    name = file.basename.to_s

    # Check by extension or specific filenames
    CHECK_EXTENSIONS.include?(ext) ||
      CHECK_EXTENSIONS.include?(name) ||
      name.end_with?('.rb', '.swift', '.sh', '.md')
  end

  def allowed_file?(file)
    rel_path = file.relative_path_from(@project_path).to_s
    ALLOWED_PATTERNS.any? { |pattern| rel_path.include?(pattern) }
  end

  def scan_file(file)
    @files_scanned += 1
    return if allowed_file?(file)

    content = File.read(file, encoding: 'UTF-8', invalid: :replace)
    rel_path = file.relative_path_from(@project_path).to_s

    other_projects.each do |other_project|
      # Check standard variations
      PROJECTS[other_project].each do |variation|
        scan_for_pattern(content, variation, rel_path, other_project)
      end

      # Check space variations
      SPACE_PATTERNS[other_project].each do |variation|
        scan_for_pattern(content, variation, rel_path, other_project)
      end
    end
  rescue Errno::ENOENT, Errno::EACCES, ArgumentError
    # Skip unreadable files
  end

  def scan_for_pattern(content, pattern, file_path, other_project)
    content.each_line.with_index(1) do |line, line_num|
      next unless line.include?(pattern)

      # Skip if it's in an allowed context (like a comment explaining the contamination)
      next if line.strip.start_with?('#') && line.include?('contamination')
      next if line.strip.start_with?('#') && line.include?('cross-project')

      @findings << {
        file: file_path,
        line: line_num,
        content: line.strip[0, 100],
        pattern: pattern,
        other_project: other_project
      }
    end
  end

  def report_findings
    puts "=" * 70
    puts "CONTAMINATION REPORT: #{@project_name}"
    puts "=" * 70
    puts
    puts "Files scanned: #{@files_scanned}"
    puts

    if @findings.empty?
      puts "✅ CLEAN - No cross-project contamination found!"
      return 0
    end

    # Group by file
    by_file = @findings.group_by { |f| f[:file] }

    puts "🔴 CONTAMINATION FOUND: #{@findings.size} instances in #{by_file.size} files"
    puts

    by_file.each do |file, findings|
      puts "📄 #{file}"
      findings.each do |f|
        puts "   Line #{f[:line]}: [#{f[:other_project]}] \"#{f[:pattern]}\""
        puts "      #{f[:content]}"
      end
      puts
    end

    # Summary by project
    puts "-" * 70
    puts "Summary by referenced project:"
    by_project = @findings.group_by { |f| f[:other_project] }
    by_project.each do |project, findings|
      puts "  #{project}: #{findings.size} references"
    end
    puts

    1
  end
end

class AllProjectsChecker
  SANE_PROJECTS = %w[SaneProcess SaneBar SaneVideo SaneSync].freeze

  def run
    home = ENV['HOME']
    total_issues = 0

    SANE_PROJECTS.each do |project|
      path = File.join(home, project)
      next unless File.directory?(path)

      puts
      puts "#{'=' * 70}"
      checker = ContaminationChecker.new(path)
      result = checker.run
      total_issues += result
      puts
    end

    puts
    puts "=" * 70
    puts "OVERALL SUMMARY"
    puts "=" * 70

    if total_issues.zero?
      puts "✅ ALL PROJECTS CLEAN!"
    else
      puts "🔴 #{total_issues} projects have contamination issues"
    end

    total_issues.zero? ? 0 : 1
  end
end

# Main
if __FILE__ == $PROGRAM_NAME
  if ARGV.include?('--all') || ARGV.include?('-a')
    exit AllProjectsChecker.new.run
  elsif ARGV.empty?
    checker = ContaminationChecker.new(Dir.pwd)
    exit checker.run
  else
    checker = ContaminationChecker.new(ARGV[0])
    exit checker.run
  end
end
