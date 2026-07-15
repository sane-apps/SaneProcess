#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'minitest/autorun'

class SaneOpenGuardTest < Minitest::Test
  SCRIPT = File.expand_path('sane_open_guard.sh', __dir__)

  def run_guard(*args, env: {})
    base_env = {
      'CODEX_SHELL' => '1',
      'SANE_OPEN_GUARD_TEST' => '1',
      'SANE_FORCE_MACBOOK_AIR_FOR_TEST' => '1',
      'SANE_FORCE_MAC_MINI_FOR_TEST' => nil,
      'SANE_APPROVE_LOCAL_UI_ON_AIR' => nil,
      'SANE_MINI_UNAVAILABLE' => nil
    }.merge(env)

    Open3.capture3(base_env.compact, 'bash', SCRIPT, *args)
  end

  def test_blocks_lemon_dashboard_on_macbook_air
    _stdout, stderr, status = run_guard('https://app.lemonsqueezy.com/products/778575')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'Mini-first SaneApps GUI guard'
    assert_includes stderr, 'Lemon Squeezy dashboard URL'
    # Corrected 2026-07-15: the owner retired the ASC Safari exception, so the
    # guard must steer to Brave, never the legacy mini-safari.sh wrapper.
    assert_includes stderr, 'Brave on the Mini'
    refute_includes stderr, 'mini-safari.sh'
  end

  def test_blocks_local_lemon_upload_reveal_on_macbook_air
    _stdout, stderr, status = run_guard('-R', '/Users/sj/Desktop/LemonSqueezy-Uploads/SaneBar-2.1.56.zip')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'Lemon Squeezy upload artifact path'
    assert_includes stderr, "ssh mini 'open -R /path/on/mini'"
  end

  def test_blocks_saneapp_bundle_open_on_macbook_air
    _stdout, stderr, status = run_guard('/Applications/SaneBar.app')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'SaneApps app bundle'
  end

  def test_allows_regular_open
    stdout, stderr, status = run_guard('https://example.com')

    assert status.success?, stderr
    assert_includes stdout, 'OPEN_ALLOWED https://example.com'
  end

  def test_allows_on_mini
    stdout, stderr, status = run_guard(
      'https://app.lemonsqueezy.com/products/778575',
      env: {
        'SANE_FORCE_MACBOOK_AIR_FOR_TEST' => nil,
        'SANE_FORCE_MAC_MINI_FOR_TEST' => '1'
      }
    )

    assert status.success?, stderr
    assert_includes stdout, 'OPEN_ALLOWED https://app.lemonsqueezy.com/products/778575'
  end
end
