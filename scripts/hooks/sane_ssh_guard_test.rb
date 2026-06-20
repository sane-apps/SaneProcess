#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'minitest/autorun'

class SaneSshGuardTest < Minitest::Test
  SCRIPT = File.expand_path('sane_ssh_guard.sh', __dir__)

  def run_guard(*args, env: {})
    base_env = {
      'CODEX_SHELL' => '1',
      'SANE_SSH_GUARD_TEST' => '1',
      'SANE_SSH_GUARD_DRY_RUN' => '1',
      'SANE_ALLOW_RAW_MINI_SCREENSHOT' => nil
    }.merge(env)

    Open3.capture3(base_env.compact, 'bash', SCRIPT, *args)
  end

  def test_blocks_raw_mini_screencapture
    _stdout, stderr, status = run_guard('mini', 'screencapture -x /tmp/sanebar.png')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'raw Mini screenshot over ssh'
    assert_includes stderr, 'capture-mini-screenshot.sh desktop'
  end

  def test_blocks_raw_mini_screencapture_with_ssh_options
    _stdout, stderr, status = run_guard(
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=2',
      'mini',
      'mkdir -p ~/Desktop/Screenshots && /usr/sbin/screencapture -x ~/Desktop/Screenshots/proof.png'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'canonical Mini GUI-session screenshot wrapper'
  end

  def test_blocks_raw_mini_local_screencapture
    _stdout, stderr, status = run_guard('user@mini.local', 'screencapture -x /tmp/sanebar.png')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'raw Mini screenshot over ssh'
  end

  def test_blocks_quoted_raw_mini_screencapture
    _stdout, stderr, status = run_guard(
      'mini',
      'bash -lc \'screencapture -x /tmp/proof.png\''
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'raw Mini screenshot over ssh'
  end

  def test_blocks_raw_mini_screencapture_mixed_with_canonical_wrapper_name
    _stdout, stderr, status = run_guard(
      'mini',
      '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop; screencapture -x /tmp/proof.png'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'raw Mini screenshot over ssh'
  end

  def test_allows_canonical_mini_screenshot_wrapper
    stdout, stderr, status = run_guard(
      'mini',
      '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop'
    )

    assert status.success?, stderr
    assert_includes stdout, 'SSH_ALLOWED mini'
  end

  def test_blocks_detached_launchctl_qa_runner
    _stdout, stderr, status = run_guard(
      'mini',
      'launchctl submit -l sanebar.qa.2174 -- /bin/bash ~/SaneApps/apps/SaneBar/outputs/run_sanebar_qa_2174.sh'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'detached Mini SaneApps QA via launchctl'
    assert_includes stderr, 'release_preflight'
  end

  def test_allows_regular_mini_ssh
    stdout, stderr, status = run_guard('mini', 'date')

    assert status.success?, stderr
    assert_includes stdout, 'SSH_ALLOWED mini date'
  end

  def test_allows_plain_mini_ssh_without_remote_command
    stdout, stderr, status = run_guard('mini')

    assert status.success?, stderr
    assert_includes stdout, 'SSH_ALLOWED mini'
  end

  def test_allows_non_mini_screencapture
    stdout, stderr, status = run_guard('example.com', 'screencapture -x /tmp/proof.png')

    assert status.success?, stderr
    assert_includes stdout, 'SSH_ALLOWED example.com'
  end

  def test_explicit_override_allows_raw_mini_screenshot_for_tool_diagnosis
    stdout, stderr, status = run_guard(
      'mini',
      'screencapture -x /tmp/sanebar.png',
      env: { 'SANE_ALLOW_RAW_MINI_SCREENSHOT' => 'MR. SANE APPROVES RAW MINI SCREENSHOT' }
    )

    assert status.success?, stderr
    assert_includes stdout, 'SSH_ALLOWED mini'
  end

  def test_raw_screenshot_override_does_not_allow_detached_qa
    _stdout, stderr, status = run_guard(
      'mini',
      'launchctl submit -l sanebar.qa.2174 -- /bin/bash ~/SaneApps/apps/SaneBar/outputs/run_sanebar_qa_2174.sh',
      env: { 'SANE_ALLOW_RAW_MINI_SCREENSHOT' => 'MR. SANE APPROVES RAW MINI SCREENSHOT' }
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'detached Mini SaneApps QA via launchctl'
  end
end
