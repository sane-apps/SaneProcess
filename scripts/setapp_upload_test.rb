#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require_relative 'hooks/test/test_framework'

include TestFramework

SCRIPT_PATH = File.expand_path('setapp_upload.rb', __dir__)
SANEMASTER_PATH = File.expand_path('SaneMaster.rb', __dir__)
SANEMASTER_BASE_PATH = File.expand_path('sanemaster/base.rb', __dir__)

exit(run_tests('Setapp Upload Tests') do
  test_category('standard upload paths') do
    test('script preserves official CI and portal fallback endpoints') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'https://developer-api.setapp.com/v1')
      assert_includes(source, '/ci/version')
      assert_includes(source, '/versions/upload_archive')
      assert_includes(source, 'SETAPP_AUTOMATION_TOKEN')
      assert_includes(source, 'SETAPP_PORTAL_TOKEN')
      assert_includes(source, '"Token #{token}"')
      assert_includes(source, "data['host'].to_s == 'developer.setapp.com'")
      assert_includes(source, "token.empty?")
      assert_includes(source, 'post-attach review status')
      assert_includes(source, 'Needs Revision')
      assert_includes(source, '--allow-needs-revision')
      assert_includes(source, 'enforce_portal_review_state!')
      assert_includes(source, 'setapp_status')
      assert_includes(source, 'capture3_with_timeout')
      assert_includes(source, 'Process.spawn')
      assert_includes(source, 'Process.waitpid2')
      assert_includes(source, '--form-string')
      assert_includes(source, '/[\x00-\x1F\x7F]/')
      true
    end

    test('dry run validates portal fallback without needing a token') do
      Tempfile.create(['setapp-upload-test', '.zip']) do |zip|
        zip.write('PK')
        zip.flush

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--dry-run',
          '--portal-fallback',
          '--zip',
          zip.path,
          '--app-id',
          '1848',
          '--version-id',
          '46885',
          '--release-notes',
          'test notes'
        )

        assert(status.success?, output)
        assert_includes(output, 'portal_fallback')
        assert_includes(output, 'versions/upload_archive')
      end
      true
    end

    test('rejects Setapp archives whose AppIcon is too small before upload') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_resources = File.join(dir, 'SaneBar.app', 'Contents', 'Resources')
        FileUtils.mkdir_p(app_resources)
        source_icon = '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns'
        small_icon = File.join(app_resources, 'AppIcon.icns')
        output, status = Open3.capture2e(
          'sips',
          '-s',
          'format',
          'png',
          source_icon,
          '--resampleHeightWidth',
          '256',
          '256',
          '--out',
          small_icon
        )
        assert(status.success?, output)

        zip_path = File.join(dir, 'SaneBar-Setapp.zip')
        output, status = Open3.capture2e(
          'ditto',
          '--norsrc',
          '-c',
          '-k',
          '--keepParent',
          File.join(dir, 'SaneBar.app'),
          zip_path
        )
        assert(status.success?, output)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--portal-fallback',
          '--zip',
          zip_path,
          '--app-id',
          '1848',
          '--version-id',
          '46885',
          '--release-notes',
          'test notes',
          '--no-safari-token'
        )

        assert(!status.success?, output)
        assert_includes(output, 'Setapp archive AppIcon.icns is 256x256')
        assert_includes(output, 'Setapp requires at least 512x512')
      end
      true
    end

    test('SaneMaster exposes setapp_upload as a Mini-first command') do
      source = File.read(SANEMASTER_PATH)
      base_source = File.read(SANEMASTER_BASE_PATH)

      assert_includes(source, "'setapp_upload'")
      assert_includes(source, "'setapp_status'")
      assert_includes(source, "when 'setapp_upload', 'setapp-upload'")
      assert_includes(source, "when 'setapp_status', 'setapp-status'")
      assert_includes(source, 'setapp_upload')
      assert_includes(source, 'setapp_status')
      assert_includes(base_source, 'setapp_upload')
      assert_includes(base_source, 'setapp_status')
      true
    end

    test('SaneMaster propagates setapp_upload failures') do
      output, status = Open3.capture2e(
        'ruby',
        SANEMASTER_PATH,
        'setapp_upload',
        '--zip',
        '/tmp/definitely-missing-setapp-upload-test.zip',
        '--release-notes',
        'test notes'
      )

      assert(!status.success?, output)
      assert_includes(output, 'ZIP not found')
      true
    end
  end
end)
