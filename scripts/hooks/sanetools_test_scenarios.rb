#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'core/state_manager'
require_relative 'core/project_root'

module SaneToolsTestScenarios
  module_function

  def run_structure_guard_tests(process_tool_proc)
    passed = 0
    failed = 0

    warn ''
    warn 'Testing new-file and component-owner guards:'

    project_dir = SaneProjectRoot.resolve
    orphan_doc = File.join(project_dir, 'TESTING.md')
    readme_doc = File.join(project_dir, 'README.md')
    readme_existed = File.exist?(readme_doc)
    readme_contents = File.binread(readme_doc) if readme_existed
    FileUtils.rm_f(orphan_doc)
    FileUtils.rm_f(readme_doc)

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Write', { 'file_path' => orphan_doc, 'content' => "# Testing\n" })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Orphan markdown document creation blocked',
      "  FAIL: Orphan markdown document should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Write', { 'file_path' => readme_doc, 'content' => "# Readme\n" })
    end
    passed, failed = record_result(
      exit_code == 0,
      '  PASS: Core 5-doc markdown creation allowed',
      "  FAIL: Core markdown document should be allowed, got exit #{exit_code}",
      passed,
      failed
    )

    owner_dir = File.join(project_dir, 'OwnerGuard')
    FileUtils.mkdir_p(owner_dir)
    owner_file = File.join(owner_dir, 'HugeOwner.swift')
    owner_extension = File.join(owner_dir, 'HugeOwner+Feature.swift')
    File.write(owner_file, Array.new(790, '// base').join("\n") + "\n")
    File.write(owner_extension, Array.new(9, '// extension').join("\n") + "\n")
    exit_code = with_quiet_stderr do
      process_tool_proc.call('Edit', {
        'file_path' => owner_extension,
        'old_string' => '// extension',
        'new_string' => "// extension\n// added\n// added"
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Component-owner aggregate over 800 lines blocked',
      "  FAIL: Component-owner aggregate should block over 800 lines, got exit #{exit_code}",
      passed,
      failed
    )

    [passed, failed]
  ensure
    FileUtils.rm_f(orphan_doc) if orphan_doc
    FileUtils.rm_rf(owner_dir) if owner_dir && File.directory?(owner_dir)
    if readme_doc
      if readme_existed
        File.binwrite(readme_doc, readme_contents)
      else
        FileUtils.rm_f(readme_doc)
      end
    end
  end

  def run_deployment_safety_tests(process_tool_proc, research_categories)
    passed = 0
    failed = 0

    warn ''
    warn 'Testing deployment safety:'

    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.reset(:deployment)
    StateManager.update(:mcp_health) { |health| health[:verified_this_session] = true; health }
    StateManager.update(:session_docs) { |docs| docs[:required] = []; docs[:read] = []; docs }
    StateManager.update(:requirements) do |requirements|
      requirements[:is_big_task] = false
      requirements[:is_research_only] = false
      requirements[:requested] = []
      requirements[:satisfied] = []
      requirements
    end
    StateManager.update(:startup_gate) do |gate|
      gate[:open] = true
      gate[:opened_at] = Time.now.iso8601
      gate[:steps] = {
        session_docs: true,
        skills_registry: true,
        validation_report: true,
        orphan_cleanup: true,
        system_clean: true
      }
      gate
    end
    research_categories.keys.each do |category|
      StateManager.update(:research) do |research|
        research[category] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }
        research
      end
    end

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.104.0 r2 object put saneclick-dist/SaneClick-1.0.2.dmg --file="build/SaneClick-1.0.2.dmg"'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: R2 upload with wrong bucket blocked',
      "  FAIL: R2 upload with wrong bucket should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.104.0 r2 object put sanebar-downloads/updates/SaneBar-1.0.17.dmg --file="build/SaneBar-1.0.17.dmg"'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: R2 upload with path prefix in key blocked',
      "  FAIL: R2 upload with path prefix should block, got exit #{exit_code}",
      passed,
      failed
    )

    StateManager.update(:deployment) do |deployment|
      deployment[:sparkle_signed_dmgs] = ['SaneBar-1.0.17.dmg']
      deployment[:staple_verified_dmgs] = ['SaneBar-1.0.17.dmg']
      deployment
    end

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.104.0 r2 object put sanebar-downloads/SaneBar-1.0.17.dmg --file="/nonexistent/SaneBar-1.0.17.dmg"'
      })
    end
    passed, failed = record_result(
      exit_code == 0,
      '  PASS: Correct R2 upload allowed (signed + stapled)',
      "  FAIL: Correct R2 upload should be allowed, got exit #{exit_code}",
      passed,
      failed
    )

    StateManager.reset(:deployment)
    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.104.0 r2 object put sanebar-downloads/SaneBar-1.0.17.dmg --file="/nonexistent/SaneBar-1.0.17.dmg"'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: R2 upload without Sparkle signature blocked',
      "  FAIL: R2 upload without signature should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Edit', {
        'file_path' => '/Users/sj/SaneApps/apps/SaneBar/docs/appcast.xml',
        'old_string' => 'old content',
        'new_string' => '<enclosure url="https://dist.sanebar.com/SaneBar-1.0.17.dmg" edSignature="" length="12345" />'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Appcast edit with empty edSignature blocked',
      "  FAIL: Appcast edit with empty signature should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Edit', {
        'file_path' => '/Users/sj/SaneApps/apps/SaneBar/docs/appcast.xml',
        'old_string' => 'old content',
        'new_string' => '<enclosure url="https://github.com/user/repo/releases/download/v1.0/SaneBar.dmg" edSignature="abc123" length="12345" />'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Appcast edit with GitHub URL blocked',
      "  FAIL: Appcast edit with GitHub URL should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Edit', {
        'file_path' => File.join(SaneProjectRoot.resolve, 'website', 'appcast.xml'),
        'old_string' => 'old content',
        'new_string' => '<enclosure url="https://dist.sanebar.com/SaneBar-9.9.9-test.dmg" edSignature="validSig123==" length="12345" />'
      })
    end
    passed, failed = record_result(
      exit_code == 0,
      '  PASS: Valid appcast edit allowed',
      "  FAIL: Valid appcast edit should be allowed, got exit #{exit_code}",
      passed,
      failed
    )

    test_deploy_dir = Dir.mktmpdir('deploy_test')
    File.write(File.join(test_deploy_dir, 'appcast.xml'), '<enclosure edSignature="" />')
    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => "npx --yes wrangler@4.104.0 pages deploy #{test_deploy_dir} --project-name=sanebar-site"
      })
    end
    FileUtils.rm_rf(test_deploy_dir) rescue nil
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Pages deploy with bad appcast blocked',
      "  FAIL: Pages deploy with bad appcast should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx wrangler pages deploy ./website --project-name=sanecite-site'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Unpinned Wrangler Pages deploy blocked',
      "  FAIL: Unpinned Wrangler Pages deploy should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.65.0 queues create sanecite-intake'
      })
    end
    passed, failed = record_result(
      exit_code == 2,
      '  PASS: Stale Wrangler queue mutation blocked',
      "  FAIL: Stale Wrangler queue mutation should block, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx wrangler queues list'
      })
    end
    passed, failed = record_result(
      exit_code == 0,
      '  PASS: Unpinned Wrangler read-only queue command allowed',
      "  FAIL: Unpinned read-only Wrangler queue command should be allowed, got exit #{exit_code}",
      passed,
      failed
    )

    exit_code = with_quiet_stderr do
      process_tool_proc.call('Bash', {
        'command' => 'npx --yes wrangler@4.104.0 queues list'
      })
    end
    passed, failed = record_result(
      exit_code == 0,
      '  PASS: Pinned current Wrangler queue command allowed',
      "  FAIL: Pinned current Wrangler queue command should be allowed, got exit #{exit_code}",
      passed,
      failed
    )

    StateManager.reset(:deployment)
    StateManager.reset(:edit_attempts)
    [passed, failed]
  end

  def run_json_integration_tests
    passed = 0
    failed = 0

    warn ''
    warn 'Testing JSON parsing (integration):'

    script_path = File.expand_path('sanetools.rb', __dir__)

    json_input = '{"tool_name":"Read","tool_input":{"file_path":"/Users/sj/SaneProcess/test.swift"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    passed, failed = record_result(
      status.exitstatus == 0,
      '  PASS: Valid JSON parsed correctly (Read tool allowed)',
      "  FAIL: Valid JSON parsing - exit #{status.exitstatus}",
      passed,
      failed
    )

    json_input = '{"tool_name":"Read","tool_input":{"file_path":"~/.ssh/id_rsa"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    passed, failed = record_result(
      status.exitstatus == 2,
      '  PASS: Blocked path correctly blocked via JSON',
      "  FAIL: Blocked path should return exit 2, got #{status.exitstatus}",
      passed,
      failed
    )

    json_input = 'not valid json at all'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    passed, failed = record_result(
      status.exitstatus == 0,
      '  PASS: Invalid JSON returns exit 0 (fail safe)',
      "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}",
      passed,
      failed
    )

    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: '')
    passed, failed = record_result(
      status.exitstatus == 0,
      '  PASS: Empty input returns exit 0 (fail safe)',
      "  FAIL: Empty input should return exit 0, got #{status.exitstatus}",
      passed,
      failed
    )

    [passed, failed]
  end

  def with_quiet_stderr
    return yield if ENV['SANE_TEST_DEBUG']

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    yield
  ensure
    $stderr.reopen(original_stderr) if original_stderr
  end

  def record_result(condition, pass_message, fail_message, passed, failed)
    if condition
      warn pass_message
      [passed + 1, failed]
    else
      warn fail_message
      [passed, failed + 1]
    end
  end
end
