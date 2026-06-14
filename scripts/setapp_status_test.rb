#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require_relative 'hooks/test/test_framework'

include TestFramework

SCRIPT_PATH = File.expand_path('setapp_status.rb', __dir__)
SANEMASTER_PATH = File.expand_path('SaneMaster.rb', __dir__)

def fixture_file(payload)
  file = Tempfile.new(['setapp-status-fixture', '.json'])
  file.write(JSON.pretty_generate(payload))
  file.flush
  file
end

exit(run_tests('Setapp Status Tests') do
  test_category('review status reporting') do
    test('fixture mode reports in-review apps without action') do
      fixture = fixture_file(
        '46886' => {
          'data' => {
            'status' => 5,
            'version' => '2309',
            'ui_version' => '2.3.9',
            'archive_url' => 'https://store.setapp.com/app/1847.zip',
            'vendor_comment' => 'Reviewer note'
          }
        },
        '46885' => {
          'data' => {
            'status' => 5,
            'version' => '2168',
            'ui_version' => '2.1.68',
            'archive_url' => 'https://store.setapp.com/app/1848.zip',
            'vendor_comment' => 'Reviewer note'
          }
        }
      )
      output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--fixture', fixture.path, '--json')

      assert(status.success?, output)
      payload = JSON.parse(output)
      assert_eq(false, payload['action_required'])
      assert_eq(%w[SaneClip SaneBar], payload['apps'].map { |row| row['app'] })
      assert(payload['apps'].all? { |row| row['status'] == 'In Review' }, output)
    ensure
      fixture&.close!
    end

    test('needs revision exits nonzero and names the blocker') do
      fixture = fixture_file(
        '46886' => { 'data' => { 'status' => 5, 'version' => '2309', 'ui_version' => '2.3.9' } },
        '46885' => { 'data' => { 'status' => 2, 'version' => '2168', 'ui_version' => '2.1.68' } }
      )
      output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--fixture', fixture.path)

      assert(!status.success?, output)
      assert_eq(2, status.exitstatus)
      assert_includes(output, 'SaneBar')
      assert_includes(output, 'Needs Revision')
      assert_includes(output, 'ACTION REQUIRED')
      assert_includes(output, 'Uploading/replacing an archive is not enough')
    ensure
      fixture&.close!
    end

    test('soft mode keeps broad status reports green while still showing the blocker') do
      fixture = fixture_file(
        '46886' => { 'data' => { 'status' => 5, 'version' => '2309', 'ui_version' => '2.3.9' } },
        '46885' => { 'data' => { 'status' => 2, 'version' => '2168', 'ui_version' => '2.1.68' } }
      )
      output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--fixture', fixture.path, '--soft')

      assert(status.success?, output)
      assert_includes(output, 'Needs Revision')
      assert_includes(output, 'ACTION REQUIRED')
    ensure
      fixture&.close!
    end
  end

  test_category('SaneMaster integration') do
    test('SaneMaster exposes setapp_status') do
      source = File.read(SANEMASTER_PATH)

      assert_includes(source, "'setapp_status'")
      assert_includes(source, "when 'setapp_status', 'setapp-status'")
      assert_includes(source, 'setapp_status.rb')
      assert_includes(source, 'Setapp review status')
      true
    end
  end
end)
