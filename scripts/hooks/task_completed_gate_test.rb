#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'time'
require 'digest'

require_relative 'test/test_framework'

include TestFramework

SCRIPT = File.expand_path('task_completed_gate.rb', __dir__)

def run_task_completed_gate(app_name: nil, repo_name: nil, state: nil, metrics_rows: nil, mutate_after_metrics: nil, create_edit_files: true, edits_committed: false, extra_env: {})
  Dir.mktmpdir('task-completed-gate-') do |dir|
    app_dir = if app_name
                File.join(dir, 'SaneApps', 'apps', app_name)
              else
                File.join(dir, 'SaneApps', 'infra', repo_name)
              end
    FileUtils.mkdir_p(app_dir)
    File.write(File.join(app_dir, '.saneprocess'), "name: #{repo_name || app_name}\ntype: infrastructure\n") unless app_name
    if state
      state_dir = File.join(app_dir, '.claude')
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, 'state.json'), JSON.pretty_generate(state))
    end

    write_edit_files = lambda do
      Array(state&.dig('edits', 'unique_files')).each do |relative|
        next unless create_edit_files
        next if relative.to_s.start_with?('/')

        path = File.join(app_dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "fixture #{relative}\n")
      end
    end

    # Net-diff semantics: session edit fixtures are UNCOMMITTED (written after
    # the init commit) unless the test models already-committed work.
    write_edit_files.call if edits_committed
    init_git_repo(app_dir)
    write_edit_files.call unless edits_committed
    metrics_path = File.join(dir, 'metrics.jsonl')
    if metrics_rows
      rows = metrics_rows.call(app_dir)
      File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    end
    mutate_after_metrics&.call(app_dir)

    Open3.capture3(
      {
        'PATH' => ENV.fetch('PATH', ''),
        'SANEMASTER_PROCESS_METRICS_PATH' => metrics_path
      }.merge(extra_env),
      'ruby',
      SCRIPT,
      stdin_data: JSON.generate('task_subject' => 'fixture task'),
      chdir: app_dir
    )
  end
end

def init_git_repo(dir)
  system('git', 'init', '-q', chdir: dir)
  system('git', 'config', 'user.email', 'test@example.com', chdir: dir)
  system('git', 'config', 'user.name', 'Test', chdir: dir)
  File.write(File.join(dir, 'README.md'), "fixture\n")
  system('git', 'add', '.', chdir: dir)
  system('git', 'commit', '-q', '-m', 'init', chdir: dir)
end

def source_fingerprint(dir)
  parts = []
  [
    %w[rev-parse HEAD],
    %w[status --porcelain=v1 --untracked-files=all],
    %w[diff --binary],
    %w[diff --cached --binary]
  ].each do |command|
    out = `git -C "#{dir}" #{command.join(' ')}`
    parts << out
  end
  Digest::SHA256.hexdigest(parts.join("\n---\n"))
end

def verified_metrics(project, timestamp: Time.now.utc.iso8601)
  lambda do |dir|
    [
      {
        timestamp: timestamp,
        type: 'verify',
        project: project,
        cwd: dir,
        success: true,
        tests_run: 12,
        evidence_strength: 'tested',
        host: 'mini',
        source_fingerprint: source_fingerprint(dir)
      }
    ]
  end
end

def edit_state(files, verified: false, last_edit_at: nil)
  {
    'edits' => {
      'count' => files.length,
      'unique_files' => files,
      'last_edit_at' => last_edit_at
    },
    'verification' => {
      'tests_passed' => verified,
      'verification_succeeded' => verified,
      'last_test_at' => verified ? Time.now.iso8601 : nil
    }
  }
end

def write_visual_receipt(dir, generated_at: Time.now.utc.iso8601)
  output_dir = File.join(dir, 'outputs', 'visual-audit-test')
  FileUtils.mkdir_p(output_dir)
  screenshot = File.join(output_dir, 'screen.png')
  File.write(screenshot, "png fixture\n")
  receipt = File.join(output_dir, 'receipt.json')
  File.write(
    receipt,
    JSON.pretty_generate(
      type: 'visual_audit',
      status: 'passed',
      host: 'mini',
      inspected: true,
      generated_at: generated_at,
      screenshots: [screenshot],
      claims: [
        {
          id: 'fixture-ui-claim',
          claim: 'Fixture visual claim has a matching inspected screenshot',
          status: 'passed',
          screenshots: [screenshot]
        }
      ]
    )
  )
  receipt
end

exit(run_tests('TaskCompleted Gate Tests') do
  test_category('Verification enforcement') do
    test('blocks app task completion without recent verification') do
      app_name = 'TaskGateNoVerify'

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift'])
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'without recent test verification')
      true
    end

    test('allows app task completion with recent structured verify metric') do
      app_name = 'TaskGateMetricPass'
      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift']),
        metrics_rows: verified_metrics(app_name)
      )

      assert_eq(status.exitstatus, 0, stderr)
      assert_includes(stderr, 'verified by structured SaneMaster metric')
      true
    end

    test('blocks local verify metric without structured fallback approval') do
      app_name = 'TaskGateLocalMetric'
      rows = lambda do |dir|
        [{
          timestamp: Time.now.utc.iso8601,
          type: 'verify',
          project: app_name,
          cwd: dir,
          success: true,
          tests_run: 12,
          evidence_strength: 'tested',
          host: 'MacBook-Air',
          source_fingerprint: source_fingerprint(dir)
        }]
      end

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift']),
        metrics_rows: rows
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'without recent test verification')
      true
    end

    test('allows local verify metric only with structured fallback approval') do
      app_name = 'TaskGateFallbackMetric'
      rows = lambda do |dir|
        [{
          timestamp: Time.now.utc.iso8601,
          type: 'verify',
          project: app_name,
          cwd: dir,
          success: true,
          tests_run: 12,
          evidence_strength: 'tested',
          host: 'MacBook-Air',
          source_fingerprint: source_fingerprint(dir),
          local_fallback: {
            approved: true,
            approved_by: 'user',
            reason: 'mini unreachable',
            user_quote: 'use local for this run'
          }
        }]
      end

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift']),
        metrics_rows: rows
      )

      assert_eq(status.exitstatus, 0, stderr)
      true
    end

    test('blocks hand-written legacy tmp pass files') do
      app_name = 'TaskGateTmpPass'
      File.write("/tmp/mini-build-#{app_name}.result", "PASS\n#{Time.now.iso8601}\n")

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift'])
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'Required proof: a fresh SaneMaster verify metric')
      true
    ensure
      FileUtils.rm_f("/tmp/mini-build-#{app_name}.result") if app_name
    end

    test('blocks stale verify metric after a later source change') do
      app_name = 'TaskGateStaleMetric'

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift']),
        metrics_rows: verified_metrics(app_name),
        mutate_after_metrics: lambda do |dir|
          File.write(File.join(dir, 'Sources', 'Other.swift'), "changed after verify\n")
        end
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'without recent test verification')
      true
    end

    test('blocks required visual work without screenshot audit evidence') do
      app_name = 'TaskGateVisual'
      state = { 'visual_verification' => { 'required' => true } }

      _stdout, stderr, status = run_task_completed_gate(app_name: app_name, state: state)

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'required visual screenshot audit')
      true
    end

    test('blocks loose visual state without structured receipt') do
      app_name = 'TaskGateLooseVisual'
      state = {
        'visual_verification' => {
          'required' => true,
          'evidence_commands' => ['screenshot outputs/visual-audit/fake.png'],
          'screenshot_paths' => ['outputs/visual-audit/fake.png'],
          'audit_recorded' => true,
          'audit_files' => ['SESSION_HANDOFF.md']
        }
      }

      _stdout, stderr, status = run_task_completed_gate(app_name: app_name, state: state)

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'structured JSON receipt')
      true
    end

    test('blocks visual audit receipts that do not map screenshots to claims') do
      app_name = 'TaskGateUnmappedVisual'
      state = {
        'visual_verification' => {
          'required' => true,
          'audit_files' => ['outputs/visual-audit-test/receipt.json']
        }
      }

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: state,
        mutate_after_metrics: lambda do |dir|
          output_dir = File.join(dir, 'outputs', 'visual-audit-test')
          FileUtils.mkdir_p(output_dir)
          screenshot = File.join(output_dir, 'screen.png')
          File.write(screenshot, "png fixture\n")
          File.write(
            File.join(output_dir, 'receipt.json'),
            JSON.pretty_generate(
              type: 'visual_audit',
              status: 'passed',
              host: 'mini',
              inspected: true,
              generated_at: Time.now.utc.iso8601,
              screenshots: [screenshot]
            )
          )
        end
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'required visual screenshot audit')
      true
    end

    test('allows visual task completion with structured Mini visual receipt') do
      app_name = 'TaskGateStructuredVisual'
      state = {
        'visual_verification' => {
          'required' => true,
          'audit_files' => ['outputs/visual-audit-test/receipt.json']
        }
      }

      _stdout, _stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: state,
        mutate_after_metrics: ->(dir) { write_visual_receipt(dir) }
      )

      assert_eq(status.exitstatus, 0)
      true
    end

    test('blocks visual receipt generated before later UI edit') do
      app_name = 'TaskGateStaleVisual'
      state = {
        'edits' => {
          'count' => 1,
          'unique_files' => ['Sources/ContentView.swift'],
          'last_edit_at' => Time.now.utc.iso8601
        },
        'visual_verification' => {
          'required' => true,
          'audit_files' => ['outputs/visual-audit-test/receipt.json']
        }
      }

      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: state,
        mutate_after_metrics: ->(dir) { write_visual_receipt(dir, generated_at: (Time.now.utc - 3600).iso8601) }
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'required visual screenshot audit')
      true
    end

    test('blocks infra task completion with non-doc edits and no verification') do
      _stdout, stderr, status = run_task_completed_gate(
        repo_name: 'SaneProcess',
        state: edit_state(['scripts/hooks/task_completed_gate.rb'])
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'without recent test verification')
      assert_includes(stderr, 'task_completed_gate.rb')
      true
    end

    test('blocks infra task completion with hook-state booleans but no structured metric') do
      _stdout, stderr, status = run_task_completed_gate(
        repo_name: 'SaneProcess',
        state: edit_state(['scripts/hooks/task_completed_gate.rb'], verified: true)
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'Required proof: a fresh SaneMaster verify metric')
      true
    end

    test('allows docs-only infra task completion without verification') do
      _stdout, _stderr, status = run_task_completed_gate(
        repo_name: 'SaneProcess',
        state: edit_state(['README.md', 'SESSION_HANDOFF.md'])
      )

      assert_eq(status.exitstatus, 0)
      true
    end

    test('ignores stale non-doc edit paths that are absent and not git changes') do
      _stdout, _stderr, status = run_task_completed_gate(
        repo_name: 'SaneProcess',
        state: edit_state(['scripts/hooks/stale_from_old_session.rb']),
        create_edit_files: false
      )

      assert_eq(status.exitstatus, 0)
      true
    end

    test('blocks real git deletions even when the edited file is absent') do
      _stdout, stderr, status = run_task_completed_gate(
        repo_name: 'SaneProcess',
        state: edit_state(['scripts/hooks/deleted_current_session.rb']),
        edits_committed: true,
        mutate_after_metrics: lambda do |dir|
          FileUtils.rm_f(File.join(dir, 'scripts', 'hooks', 'deleted_current_session.rb'))
        end
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, 'without recent test verification')
      assert_includes(stderr, 'deleted_current_session.rb')
      true
    end

    test('allows task completion when session non-doc edits are all committed (clean tree)') do
      _stdout, stderr, status = run_task_completed_gate(
        app_name: 'TaskGateCleanTree',
        state: edit_state(['Sources/App.swift']),
        edits_committed: true
      )

      assert_eq(status.exitstatus, 0, stderr)
      true
    end

    test('committed session edits stay resolved even when unrelated files are dirty') do
      _stdout, stderr, status = run_task_completed_gate(
        app_name: 'TaskGateUnrelatedDirty',
        state: edit_state(['Sources/App.swift']),
        edits_committed: true,
        mutate_after_metrics: lambda do |dir|
          File.write(File.join(dir, 'scratch-unrelated.txt'), "not a session edit\n")
          File.write(File.join(dir, 'unrelated.swift'), "// dirty but never edited by this session\n")
        end
      )

      assert_eq(status.exitstatus, 0, stderr)
      true
    end

    test('block message names the resolved gate scope project and repo') do
      app_name = 'TaskGateScopeMsg'
      _stdout, stderr, status = run_task_completed_gate(
        app_name: app_name,
        state: edit_state(['Sources/App.swift'])
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(stderr, "Gate scope: project '#{app_name}'")
      assert_includes(stderr, 'clean working tree')
      true
    end

    test('fails open for an umbrella cwd without a .saneprocess manifest') do
      Dir.mktmpdir('task-completed-umbrella-') do |dir|
        umbrella = File.join(dir, 'SaneApps')
        FileUtils.mkdir_p(File.join(umbrella, '.claude'))
        File.write(File.join(umbrella, '.claude', 'state.json'), JSON.pretty_generate(edit_state(['scripts/anything.rb'])))
        # No .saneprocess manifest, not a git repo: the gate has no project to
        # resolve and must fail open rather than hard-block unsatisfiably.
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, '')

        _stdout, stderr, status = Open3.capture3(
          {
            'PATH' => ENV.fetch('PATH', ''),
            'SANEMASTER_PROCESS_METRICS_PATH' => metrics_path,
            'CLAUDE_PROJECT_DIR' => umbrella
          },
          'ruby',
          SCRIPT,
          stdin_data: JSON.generate('task_subject' => 'fixture task'),
          chdir: umbrella
        )

        assert_eq(status.exitstatus, 0, stderr)
      end
      true
    end

    test('uses cwd project state over a different marked CLAUDE_PROJECT_DIR') do
      Dir.mktmpdir('task-completed-cross-repo-') do |dir|
        repo_a = File.join(dir, 'SaneApps', 'infra', 'RepoA')
        repo_b = File.join(dir, 'SaneApps', 'infra', 'RepoB')
        [repo_a, repo_b].each do |repo|
          FileUtils.mkdir_p(File.join(repo, '.claude'))
          File.write(File.join(repo, '.saneprocess'), "name: #{File.basename(repo)}\ntype: infrastructure\n")
        end
        File.write(File.join(repo_a, '.claude', 'state.json'), JSON.pretty_generate(edit_state(['README.md'])))
        File.write(File.join(repo_b, '.claude', 'state.json'), JSON.pretty_generate(edit_state(['scripts/hooks/live_repo.rb'])))
        init_git_repo(repo_a)
        init_git_repo(repo_b)
        # Written after the init commit so the session edit is genuinely uncommitted.
        FileUtils.mkdir_p(File.join(repo_b, 'scripts', 'hooks'))
        File.write(File.join(repo_b, 'scripts', 'hooks', 'live_repo.rb'), "fixture\n")

        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, '')
        _stdout, stderr, status = Open3.capture3(
          {
            'PATH' => ENV.fetch('PATH', ''),
            'SANEMASTER_PROCESS_METRICS_PATH' => metrics_path,
            'CLAUDE_PROJECT_DIR' => repo_a
          },
          'ruby',
          SCRIPT,
          stdin_data: JSON.generate('task_subject' => 'fixture task'),
          chdir: repo_b
        )

        assert_eq(status.exitstatus, 2)
        assert_includes(stderr, 'without recent test verification')
        assert_includes(stderr, 'live_repo.rb')
      end
      true
    end
  end
end)
