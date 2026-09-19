#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

include TestFramework

exit(run_tests('SaneMaster Operator Brief Tests') do
  test_category('receipt parsing') do
    test('prioritizes nightly failures and handoff blockers') do
      Dir.mktmpdir('operator-brief-') do |root|
        nightly = File.join(root, 'nightly_report.md')
        morning = File.join(root, 'morning_report.md')
        handoff = File.join(root, 'SESSION_HANDOFF.md')
        output = File.join(root, 'operator_brief.md')

        File.write(nightly, <<~MD)
          # Mac Mini Nightly Report

          ## Git Sync
          | Repo | Status | Dirty | Behind | Ahead |
          |------|--------|-------|--------|-------|
          | SaneClip | Dirty (pull skipped) | 1 | 4 | 0 |

          ## Build Results
          ### SaneBar
          **PASS** (10s)
          ### SaneScan
          **FAIL** (exit 70, 0s)

          ## Test Results
          ### SaneVideo
          **FAIL** (exit 65)

          ## SaneAI Workflow Readiness
          **Workflow gate:** FAIL (mac_operator 3/10, 30%, threshold 50%)

          ## Machine Cleanup
          **FAIL** (exit 1) - machine cleanup reported problems
        MD
        File.write(morning, "# Morning\nGenerated 2026-01-01\n")
        File.write(handoff, "- Current hard release blocker: hosted files need manual replacement.\n")

        master = SaneMaster.new
        report = master.send(
          :operator_brief_report,
          nightly_report: nightly,
          morning_report: morning,
          handoff: handoff,
          portfolio_root: root,
          skip_finish_line: true,
          output: output
        )
        markdown = master.send(:operator_brief_markdown, report)

        assert_eq(report[:status], 'needs_attention')
        assert(markdown.include?('Fix failed nightly builds: SaneScan.'))
        assert(markdown.include?('Fix failed nightly tests: SaneVideo.'))
        assert(markdown.include?('Clean up Mini machine cleanup failure'))
        assert(markdown.include?('Current hard release blocker'))
        assert(markdown.include?('Morning report appears stale'))
      end
      true
    end

    test('reports clear when current receipts have no blockers') do
      Dir.mktmpdir('operator-brief-clear-') do |root|
        nightly = File.join(root, 'nightly_report.md')
        morning = File.join(root, 'morning_report.md')
        handoff = File.join(root, 'SESSION_HANDOFF.md')

        File.write(nightly, <<~MD)
          ## Git Sync
          | Repo | Status | Dirty | Behind | Ahead |
          |------|--------|-------|--------|-------|
          | SaneBar | Up to date | 0 | 0 | 0 |

          ## Build Results
          ### SaneBar
          **PASS** (10s)

          ## Test Results
          ### SaneBar
          **PASS**
        MD
        File.write(morning, "# Morning #{Time.now.strftime('%Y-%m-%d')}\n")
        File.write(handoff, "- No active blockers.\n")

        report = SaneMaster.new.send(
          :operator_brief_report,
          nightly_report: nightly,
          morning_report: morning,
          handoff: handoff,
          portfolio_root: root,
          skip_finish_line: true,
          output: File.join(root, 'operator_brief.md')
        )

        assert_eq(report[:status], 'clear')
        assert(report[:priorities].empty?)
      end
      true
    end

    test('flags finish-line dirty and unpushed release surfaces') do
      Dir.mktmpdir('operator-brief-finish-') do |root|
        app = File.join(root, 'apps', 'SaneClip')
        FileUtils.mkdir_p(app)
        system('git', 'init', '-q', app) or raise 'git init failed'
        File.write(File.join(app, 'README.md'), "x\n")
        system('git', '-C', app, 'add', 'README.md') or raise 'git add failed'
        system('git', '-C', app, '-c', 'user.email=t@example.com', '-c', 'user.name=t',
               'commit', '-q', '-m', 'init') or raise 'git commit failed'
        File.write(File.join(app, 'SESSION_HANDOFF.md'), "- Pending release: verify ZIP before calling done.\n")
        File.write(File.join(app, 'dirty.txt'), "n\n")

        nightly = File.join(root, 'nightly_report.md')
        morning = File.join(root, 'morning_report.md')
        handoff = File.join(root, 'SESSION_HANDOFF.md')
        File.write(nightly, "## Build Results\n### SaneBar\n**PASS**\n")
        File.write(morning, "# Morning #{Time.now.strftime('%Y-%m-%d')}\n")
        File.write(handoff, "- No active blockers.\n")

        report = SaneMaster.new.send(
          :operator_brief_report,
          nightly_report: nightly,
          morning_report: morning,
          handoff: handoff,
          portfolio_root: root,
          skip_finish_line: false,
          output: File.join(root, 'operator_brief.md')
        )

        assert_eq(report[:status], 'needs_attention')
        assert(report[:priorities].any? { |p| p.include?('Finish-line: apps/SaneClip') && p.include?('dirty') })
      end
      true
    end
  end
end)
