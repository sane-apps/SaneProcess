#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'app_review_watch'
require_relative 'internal_report'

include TestFramework

def cws_change(overrides = {})
  {
    'entity_key' => 'item:chrome_web_store_submission:item',
    'entity_type' => 'chrome_web_store_submission',
    'entity_id' => 'item',
    'app_id' => 'item',
    'app_name' => 'SaneLot Auction Pricing',
    'previous_state' => 'REJECTED',
    'state' => 'PENDING_REVIEW',
    'previous_version' => '1.2.0',
    'version' => '1.2.1'
  }.merge(overrides)
end

exit(run_tests('Internal Report Render Tests') do
  test('resubmit after rejection reads in plain English') do
    event = SaneAppReviewWatch.pending_event(
      [cws_change],
      at: Time.utc(2026, 8, 19, 22, 18),
      kind: SaneInternalReport::CWS_REVIEW_KIND
    )
    envelope = SaneInternalReport.render(event)

    assert_eq(envelope['subject'], 'SaneLot Auction Pricing: waiting for Chrome Web Store review')
    assert_includes(envelope['body'], 'SaneLot Auction Pricing was submitted again and is now waiting for Chrome Web Store review.')
    assert_includes(envelope['body'], 'Previous status: rejected.')
    assert_includes(envelope['body'], 'Current status: waiting for review.')
    assert_includes(envelope['body'], 'Version 1.2.1 (previously 1.2.0)')
    assert_includes(envelope['body'], "Nothing right now. You'll get another email when Chrome Web Store approves or rejects it.")
    assert(!envelope['body'].include?('REJECTED -> PENDING_REVIEW'))
    assert(!envelope['body'].include?('review-state transition'))
    true
  end

  test('rejection email tells owner what to do next') do
    event = SaneAppReviewWatch.pending_event(
      [cws_change('previous_state' => 'PENDING_REVIEW', 'state' => 'REJECTED')],
      at: Time.utc(2026, 8, 19, 22, 18),
      kind: SaneInternalReport::CWS_REVIEW_KIND
    )
    envelope = SaneInternalReport.render(event)

    assert_eq(envelope['subject'], 'SaneLot Auction Pricing: rejected by Chrome Web Store')
    assert_includes(envelope['body'], 'SaneLot Auction Pricing was rejected by the Chrome Web Store.')
    assert_includes(envelope['body'], 'Open the Chrome Web Store developer dashboard')
    true
  end

  test('approval email uses live wording') do
    event = SaneAppReviewWatch.pending_event(
      [cws_change('previous_state' => 'PENDING_REVIEW', 'state' => 'PUBLISHED')],
      at: Time.utc(2026, 8, 19, 22, 18),
      kind: SaneInternalReport::CWS_REVIEW_KIND
    )
    envelope = SaneInternalReport.render(event)

    assert_eq(envelope['subject'], 'SaneLot Auction Pricing: live on Chrome Web Store')
    assert_includes(envelope['body'], 'SaneLot Auction Pricing is approved and live on the Chrome Web Store.')
    true
  end
end)
