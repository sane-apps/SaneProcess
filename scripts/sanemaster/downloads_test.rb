#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'downloads'

class DownloadsHarness
  include SaneMasterModules::Downloads
end

include TestFramework

exit(run_tests('SaneMaster Downloads Tests') do
  test_category('App Store funnel report') do
    test('groups App Store events by app and platform') do
      subject = DownloadsHarness.new
      summary = subject.send(:summarize_appstore_funnel, [
        { 'app' => 'saneclip', 'platform' => 'macos', 'event' => 'paywall_seen', 'count' => 3 },
        { 'app' => 'saneclip', 'platform' => 'macos', 'event' => 'checkout_clicked', 'count' => 2 },
        { 'app' => 'sanescan', 'platform' => 'ios', 'event' => 'purchase_started', 'count' => 1 },
        { 'app' => 'sanescan', 'platform' => 'ios', 'event' => 'purchase_completed', 'count' => 1 }
      ])

      assert_eq(summary.length, 2)
      assert_eq(summary[0][:app], 'saneclip')
      assert_eq(summary[0][:platform], 'macos')
      assert_eq(summary[0][:total_events], 5)
      assert_eq(summary[0][:sellable_signals], { 'checkout_clicked' => 2, 'paywall_seen' => 3 })
      assert_eq(summary[0][:purchase_outcomes], {})

      assert_eq(summary[1][:app], 'sanescan')
      assert_eq(summary[1][:platform], 'ios')
      assert_eq(summary[1][:total_events], 2)
      assert_eq(summary[1][:sellable_signals], { 'purchase_started' => 1 })
      assert_eq(summary[1][:purchase_outcomes], { 'purchase_completed' => 1, 'purchase_started' => 1 })
    end

    test('reports missing StoreKit outcome telemetry') do
      subject = DownloadsHarness.new
      summary = subject.send(:summarize_appstore_funnel, [
        { 'app' => 'sanescan', 'platform' => 'ios', 'event' => 'purchase_started', 'count' => 4 },
        { 'app' => 'sanescan', 'platform' => 'ios', 'event' => 'purchase_failed', 'count' => 1 }
      ])

      missing = summary.first[:missing_outcomes]
      assert(!missing.include?('purchase_started'))
      assert(!missing.include?('purchase_failed'))
      assert(missing.include?('product_loaded'))
      assert(missing.include?('purchase_completed'))
      assert(missing.include?('restore_completed'))
    end
  end
end)
