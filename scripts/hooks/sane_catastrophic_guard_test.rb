#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'test/test_framework'

include TestFramework

HOOK = File.expand_path('sane_catastrophic_guard.rb', __dir__)

def run_payload(payload)
  Open3.capture3('ruby', HOOK, stdin_data: JSON.generate(payload))
end

def run_bash(command, cwd: '/Users/stephansmac/SaneApps/infra/SaneProcess')
  run_payload('tool_name' => 'Bash', 'tool_input' => { 'command' => command, 'cwd' => cwd })
end

BLOCKED_COMMANDS = [
  'gh repo delete MrSaneApps/SaneBar --yes',
  'git push --force origin main',
  'git push --force-with-lease origin release',
  'git push -f origin main',
  'git push origin --delete main',
  'git push origin :refs/heads/main',
  'git push origin :main',
  'git reset --hard HEAD~3',
  'git clean -fdx',
  'wrangler pages project delete saneclip-site',
  'wrangler r2 bucket delete sanebar-downloads',
  'wrangler d1 delete support-production',
  'wrangler kv namespace delete abc',
  'wrangler delete production-worker',
  'terraform destroy -auto-approve',
  'pulumi destroy --yes',
  'curl -X DELETE https://api.github.com/repos/MrSaneApps/SaneBar',
  'gh api -X DELETE /repos/MrSaneApps/SaneBar',
  "psql -c 'DROP DATABASE production'",
  "sqlite3 data.db 'TRUNCATE TABLE customers'",
  "mysql -e 'DELETE FROM customers;'",
  'ruby scripts/SaneMaster.rb sales --refund order_123',
  'ruby scripts/SaneMaster.rb sales --disable-license-key abc',
  'rm -rf /Users/stephansmac/SaneApps',
  'rm -rf .',
  "bash -lc 'gh repo delete MrSaneApps/SaneBar --yes'",
  "ssh mini 'git push --force origin main'",
  "ssh -o BatchMode=yes mini 'git push --force origin main'",
  "rg 'gh repo delete' README.md; gh repo delete MrSaneApps/SaneBar --yes"
].freeze

ALLOWED_COMMANDS = [
  'git status --short',
  'git diff --check',
  'git add scripts/hooks/sane_catastrophic_guard.rb',
  "git commit -m 'document gh repo delete protection'",
  'git push -u origin codex/agent-safety',
  'gh pr create --draft --title Safety --body-file /tmp/body.md',
  'ruby scripts/SaneMaster.rb verify',
  'ruby scripts/SaneMaster.rb release_preflight',
  'bash scripts/release.sh --project . --website-only',
  'wrangler pages deploy website --project-name=saneclip-site',
  'aws s3 cp build.zip s3://releases/build.zip',
  "psql -c 'DELETE FROM jobs WHERE id = 42'",
  "rg 'gh repo delete' scripts/hooks",
  "printf '%s' 'git push --force origin main'",
  "git commit -m 'block wrangler pages project delete'",
  'rm -rf .build',
  "ssh mini 'cd ~/SaneApps && git status --short'"
].freeze

BLOCKED_TOOLS = %w[
  mcp__github__delete_repository
  mcp__cloudflare__destroy_project
  mcp__cloudflare__delete_bucket
  mcp__admin__transfer_organization
  mcp__iam__revoke_account_role
  mcp__provider__delete_api_token
  mcp__provider__delete_api_token_file
].freeze

ALLOWED_TOOLS = %w[
  mcp__serena__safe_delete_symbol
  mcp__filesystem__delete_file
  mcp__gmail__delete_message
  mcp__calendar__delete_event
  mcp__codex__delete_thread
  mcp__memory__delete_entities
  mcp__automation__archive_automation
  mcp__github__create_pull_request
].freeze

exit(run_tests('Catastrophic Operation Guard Tests') do
  BLOCKED_COMMANDS.each do |command|
    test("blocks inert command: #{command}") do
      _out, err, status = run_bash(command)
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'manual user-only action')
      true
    end
  end

  ALLOWED_COMMANDS.each do |command|
    test("allows ordinary command: #{command}") do
      _out, err, status = run_bash(command)
      assert_eq(status.exitstatus, 0)
      assert_eq(err, '')
      true
    end
  end

  BLOCKED_TOOLS.each do |tool_name|
    test("blocks catastrophic tool: #{tool_name}") do
      _out, err, status = run_payload('tool_name' => tool_name, 'tool_input' => {})
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'catastrophic external resource operation')
      true
    end
  end

  ALLOWED_TOOLS.each do |tool_name|
    test("allows reversible tool: #{tool_name}") do
      _out, err, status = run_payload('tool_name' => tool_name, 'tool_input' => {})
      assert_eq(status.exitstatus, 0)
      assert_eq(err, '')
      true
    end
  end

  test('malformed payload fails open without executing anything') do
    _out, err, status = Open3.capture3('ruby', HOOK, stdin_data: '{')
    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
    true
  end
end)
