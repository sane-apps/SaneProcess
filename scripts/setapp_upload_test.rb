#!/usr/bin/env ruby
# frozen_string_literal: true

# Pin UTF-8 defaults before the source-reads below. This test File.reads the
# Ruby scripts under test (which contain emoji like ✅/❌); under a C locale the
# default US-ASCII external encoding makes assert_includes raise "invalid byte
# sequence in US-ASCII". Mirrors the entry-point pin in the scripts themselves.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'open3'
require 'rbconfig'
require 'fileutils'
require 'stringio'
require 'tempfile'
require 'tmpdir'
require_relative 'hooks/test/test_framework'
require_relative 'setapp_upload'
require_relative 'setapp_package'

include TestFramework

ENV['SETAPP_UPLOAD_SKIP_GATEKEEPER_FOR_TESTS'] = '1'

SCRIPT_PATH = File.expand_path('setapp_upload.rb', __dir__)
PACKAGE_SCRIPT_PATH = File.expand_path('setapp_package.rb', __dir__)
SANEMASTER_PATH = File.expand_path('SaneMaster.rb', __dir__)
SANEMASTER_BASE_PATH = File.expand_path('sanemaster/base.rb', __dir__)

def create_setapp_fixture(dir, app_name: 'SaneClip', bundle_id: 'com.saneclip.app-setapp', entitlements: nil)
  app_root = File.join(dir, "#{app_name}.app")
  app_contents = File.join(app_root, 'Contents')
  app_resources = File.join(app_contents, 'Resources')
  app_macos = File.join(app_contents, 'MacOS')
  FileUtils.mkdir_p([app_resources, app_macos])

  create_root_icon_png(File.join(app_resources, 'AppIcon.icns'))
  File.write(File.join(app_contents, 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>#{app_name}</string>
      <key>CFBundleName</key>
      <string>#{app_name}</string>
      <key>CFBundleIconFile</key>
      <string>AppIcon</string>
      <key>CFBundleIdentifier</key>
      <string>#{bundle_id}</string>
      <key>CFBundleShortVersionString</key>
      <string>2.3.9</string>
      <key>CFBundleVersion</key>
      <string>2309</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>MPSupportedArchitectures</key>
      <array>
        <string>arm64</string>
        <string>x86_64</string>
      </array>
      <key>NSUpdateSecurityPolicy</key>
      <dict>
        <key>AllowProcesses</key>
        <dict>
          <key>MEHY5QF425</key>
          <array>
            <string>com.setapp.DesktopClient.SetappAgent</string>
          </array>
        </dict>
      </dict>
    </dict>
    </plist>
  PLIST
  FileUtils.cp('/bin/echo', File.join(app_macos, app_name))
  FileUtils.chmod('+x', File.join(app_macos, app_name))

  sign_args = ['codesign', '--force', '--sign', '-']
  if entitlements
    entitlements_path = File.join(dir, "#{app_name}.entitlements")
    File.write(entitlements_path, entitlements)
    sign_args += ['--entitlements', entitlements_path]
  end
  output, status = Open3.capture2e(*(sign_args + [app_root]))
  raise "codesign failed: #{output}" unless status.success?

  app_root
end

def zip_app(app_root, zip_path)
  Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
    staged_app = File.join(stage_dir, File.basename(app_root))
    output, status = Open3.capture2e('ditto', '--norsrc', app_root, staged_app)
    raise "stage app failed: #{output}" unless status.success?

    create_root_icon_png(File.join(stage_dir, "#{File.basename(app_root, '.app')}.png"))
    output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
    raise "zip failed: #{output}" unless status.success?
  end
end

def zip_wrapped_app(app_root, zip_path)
  Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
    wrapper = File.join(stage_dir, 'SetappUpload')
    FileUtils.mkdir_p(wrapper)
    staged_app = File.join(wrapper, File.basename(app_root))
    output, status = Open3.capture2e('ditto', '--norsrc', app_root, staged_app)
    raise "stage app failed: #{output}" unless status.success?

    create_root_icon_png(File.join(wrapper, "#{File.basename(app_root, '.app')}.png"))
    output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
    raise "zip failed: #{output}" unless status.success?
  end
end

def zip_app_without_root_icon(app_root, zip_path)
  output, status = Open3.capture2e(
    'ditto',
    '--norsrc',
    '-c',
    '-k',
    '--keepParent',
    app_root,
    zip_path
  )
  raise "zip failed: #{output}" unless status.success?
end

def create_root_icon_png(path, size: 1024)
  output, status = Open3.capture2e(
    'swift',
    File.expand_path('setapp_icon_tool.swift', __dir__),
    'render',
    '--source',
    '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns',
    '--output',
    path,
    '--size',
    size.to_s
  )
  raise "root icon failed: #{output}" unless status.success?
end

def create_full_bleed_root_icon_png(path, size: 1024)
  output, status = Open3.capture2e(
    'sips',
    '-s',
    'format',
    'png',
    '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns',
    '--resampleHeightWidth',
    size.to_s,
    size.to_s,
    '--out',
    path
  )
  raise "root icon failed: #{output}" unless status.success?
end

def create_fake_corner_root_icon_png(path, size: 1024)
  Tempfile.create(['setapp-fake-corners', '.swift']) do |script|
    script.write(<<~SWIFT)
      import AppKit
      import Foundation

      let output = CommandLine.arguments[1]
      let size = Int(CommandLine.arguments[2])!
      let margin = 100
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else { fatalError("bitmap") }
      guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("context") }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
      NSColor.black.setFill()
      NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2).fill()
      NSColor.clear.setFill()
      for point in [NSPoint(x: margin, y: margin), NSPoint(x: size - margin - 1, y: margin), NSPoint(x: margin, y: size - margin - 1), NSPoint(x: size - margin - 1, y: size - margin - 1)] {
        NSRect(x: point.x, y: point.y, width: 1, height: 1).fill(using: .copy)
      }
      NSGraphicsContext.restoreGraphicsState()
      let data = bitmap.representation(using: .png, properties: [:])!
      try! data.write(to: URL(fileURLWithPath: output))
    SWIFT
    script.flush
    output, status = Open3.capture2e('swift', script.path, path, size.to_s)
    raise "fake corner icon failed: #{output}" unless status.success?
  end
end

def expect_abort_includes(expected)
  begin
    yield
  rescue SystemExit => e
    assert(!e.success?, 'Expected abort to exit nonzero')
    assert_includes(e.message, expected)
    return true
  end
  raise "Expected abort containing #{expected.inspect}"
end

def capture_stdout
  original = $stdout
  output = StringIO.new
  $stdout = output
  yield
  output.string
ensure
  $stdout = original
end

class FakeSetappUploadNoBody < SetappUpload
  attr_reader :form_args

  def initialize
    @options = {
      zip: __FILE__,
      release_notes: 'Launch.',
      review_comments: '',
      status: 'review',
      beta: false,
      release_on_approval: false,
      allow_overwrite: true,
      json: true
    }
    @archive_metadata = { app_name: 'SaneBar', bundle_id: 'com.sanebar.app-setapp', version: '2171', ui_version: '2.1.71' }
  end

  private

  def curl_form(_url, _authorization, form_args)
    @form_args = form_args
    { ok: true, status: 204, json: {} }
  end

  def verify_uploaded_archive_matches!(_payload)
    raise 'should not verify hosted archive without proof data'
  end
end

exit(run_tests('Setapp Upload Tests') do
  test_category('standard upload paths') do
    test('script preserves official CI and portal fallback endpoints') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'https://developer-api.setapp.com/v1')
      assert_includes(source, '/ci/version')
      assert_includes(source, '/versions/upload_archive')
      assert_includes(source, 'SETAPP_AUTOMATION_TOKEN')
      assert_includes(source, 'SETAPP_PORTAL_TOKEN')
      assert_includes(source, 'SetappConfig.portal_targets')
      assert_includes(source, '--review-comments-file')
      assert_includes(source, '--no-review-comments-needed')
      assert_includes(source, '"Token #{token}"')
      assert_includes(source, '"Bearer #{token}"')
      assert_includes(source, "data['host'].to_s == 'developer.setapp.com'")
      assert_includes(source, "token.empty?")
      assert_includes(source, 'post-attach review status')
      assert_includes(source, 'Needs Revision')
      assert_includes(source, 'Manual Release Required')
      assert_includes(source, 'NON_ACTION_STATUSES')
      assert_includes(source, '--allow-needs-revision')
      assert_includes(source, '--validate-only')
      assert_includes(source, 'enforce_portal_review_state!')
      assert_includes(source, 'MPSupportedArchitectures')
      assert_includes(source, 'lipo')
      assert_includes(source, 'embedded.provisionprofile')
      assert_includes(source, 'com.apple.developer.icloud-container-identifiers')
      assert_includes(source, 'profile_covers_icloud?')
      assert_includes(source, 'profile_covers_icloud_services?')
      assert_includes(source, 'profile_covers_restricted_entitlements?')
      assert_includes(source, 'codesign')
      assert_includes(source, 'REXML::Document')
      assert_includes(source, "'xml1'")
      assert_includes(source, 'setapp_status')
      assert_includes(source, 'validate_root_icon_png!')
      assert_includes(source, 'validate_setapp_icon_geometry!')
      assert_includes(source, 'validate_portal_target_matches_archive!')
      assert_includes(source, 'validate_upload_proof_data!')
      assert_includes(source, 'verify_uploaded_archive_matches!')
      assert_includes(source, 'enforce_mini_host!')
      assert_includes(source, 'MAX_ARCHIVE_UNCOMPRESSED_BYTES')
      assert_includes(source, 'MAX_ARCHIVE_BYTES')
      assert_includes(source, 'validate_zip_entry_names!')
      assert_includes(source, 'FORBIDDEN_ARCHIVE_ENTRIES')
      assert_includes(source, 'FORBIDDEN_SETAPP_PAYLOAD_PATTERNS')
      assert_includes(source, 'REQUIRED_INFO_PLIST_KEYS')
      assert_includes(source, 'NSUpdateSecurityPolicy')
      assert_includes(source, 'Developer ID Application')
      assert_includes(source, 'spctl')
      assert_includes(source, 'stapler')
      assert_includes(source, 'inside one wrapper directory')
      assert_includes(source, 'enforce_manifest_policies!')
      assert_includes(source, 'validate_listing_screenshots!')
      assert_includes(source, 'release_notes_public')
      assert_includes(source, 'Setapp 824px frame, 100px margins, and curved corners')
      assert_includes(source, 'setapp_icon_tool.swift')
      assert_includes(source, 'capture3_with_timeout')
      assert_includes(source, 'Process.spawn')
      assert_includes(source, 'Process.waitpid2')
      assert_includes(source, '--form-string')
      assert_includes(source, '/[\x00-\x1F\x7F]/')
      assert_includes(source, 'validate_setapp_archive_url!')
      assert_includes(source, 'URI::HTTPS')
      assert_includes(source, 'trusted_redirect_url!')
      assert_includes(source, 'accepted_without_proof')
      assert_includes(source, 'redacted_payload')
      assert(!source.include?("config.puts 'location'"), 'hosted archive verification must not let curl forward auth across redirects')
      download_method = source[/def curl_download.*?^  end/m]
      assert(download_method, 'Expected curl_download method')
      assert(!download_method.include?('Authorization'), 'hosted archive downloads must not forward Setapp auth headers')
      assert_includes(source, 'validate_release_notes!')
      assert_includes(source, 'RELEASE_NOTES_MAX_CHARS')
      assert_includes(source, 'REVIEW_COMMENTS_MAX_CHARS')
      assert_includes(source, 'Setapp release notes are not user-facing')
      true
    end

    test('rejects internal Setapp review notes before upload') do
      upload = SetappUpload.allocate

      expect_abort_includes('release notes are not user-facing') do
        upload.send(
          :validate_release_notes!,
          'Updated app icons per Setapp review: 1024x1024 PNG with artwork inside the 824x824 frame, 100px margins, and rounded design corners.'
        )
      end
      expect_abort_includes('release notes are not user-facing') do
        upload.send(:validate_release_notes!, 'test notes')
      end
      expect_abort_includes('release notes are not user-facing') do
        upload.send(:validate_release_notes!, 'Updated the submitted build archive for Setapp.')
      end
      assert(upload.send(:validate_release_notes!, 'Improves Setapp activation reliability for subscribers.'))
      assert(upload.send(:validate_release_notes!, 'Improves signed-in state recovery.'))
      assert(upload.send(:validate_release_notes!, 'Improves archive search for saved clips.'))
      assert(upload.send(:validate_release_notes!, 'Launch.'))
      true
    end

    test('validates private review comments separately from public release notes') do
      upload = SetappUpload.allocate

      assert(upload.send(:validate_review_comments!, 'Private reviewer context: use the Setapp account already attached to this build.'))
      expect_abort_includes('Setapp review comments are empty') do
        upload.send(:validate_review_comments!, " \n ")
      end
      expect_abort_includes('Setapp review comments must not contain control characters') do
        upload.send(:validate_review_comments!, "Private\x01comment")
      end
    end

    test('portal fallback rejects mismatched app and version ids before upload') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneClip', bundle_id: 'com.saneclip.app-setapp', version: '2309', ui_version: '2.3.9' }
      )
      # The pinned version id lives in the app's .saneprocess manifest and moves
      # with every Setapp release; resolve it at runtime so this test never goes
      # stale (hardcoded 46886 broke when SaneClip advanced to 47647).
      pinned = SetappConfig.portal_targets['1847'][:version_id].to_s
      upload.instance_variable_set(:@options, { app_id: '1847', version_id: "#{pinned}0" })

      expect_abort_includes("expects version id #{pinned}") do
        upload.send(:validate_portal_target_matches_archive!)
      end
    end

    test('manifest policies block automatic release and require explicit private-comment decision') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneClip', bundle_id: 'com.saneclip.app-setapp', version: '2309', ui_version: '2.3.9' }
      )
      upload.instance_variable_set(:@options, { status: 'review', release_on_approval: true, validate_only: false })

      expect_abort_includes('manual release confirmation') do
        upload.send(:enforce_manifest_policies!)
      end

      upload.instance_variable_set(:@options, { status: 'review', release_on_approval: false, validate_only: false })
      expect_abort_includes('private review comments must be supplied') do
        upload.send(:enforce_manifest_policies!)
      end

      upload.instance_variable_set(:@options, { status: 'review', release_on_approval: false, validate_only: false, no_review_comments_needed: true })
      assert(upload.send(:enforce_manifest_policies!))
    end

    test('manifest policies require public release notes to be explicit') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneClip', bundle_id: 'com.example.setapp-missing-public-notes', version: '2309', ui_version: '2.3.9' }
      )
      upload.define_singleton_method(:manifest_target_for_archive) do
        {
          app_name: 'SaneClip',
          release_notes_public: false,
          require_manual_release_confirmation: false,
          review_comments_private: false
        }
      end

      upload.instance_variable_set(:@options, { status: 'review', release_on_approval: false, validate_only: false, no_review_comments_needed: true })
      expect_abort_includes('release_notes_public: true') do
        upload.send(:enforce_manifest_policies!)
      end
    end

    test('portal fallback treats manual release status as action required') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(:@options, { allow_needs_revision: false })

      expect_abort_includes('Manual Release Required') do
        upload.send(:enforce_portal_review_state!, { 'data' => { 'status' => 9 } })
      end
    end

    test('create-version skips the pinned version id check but keeps app/bundle checks') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneClip', bundle_id: 'com.saneclip.app-setapp', version: '2312', ui_version: '2.3.12' }
      )
      # No version_id at all: allowed when creating, because a Released
      # (status 10) version rejects PATCH and a fresh record gets a new id.
      upload.instance_variable_set(:@options, { app_id: '1847', version_id: nil, create_version: true })
      outcome = begin
        upload.send(:validate_portal_target_matches_archive!)
        :no_abort
      rescue SystemExit
        :aborted
      end
      assert_eq(outcome, :no_abort, 'create-version must not require the pinned version id')

      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneClip', bundle_id: 'com.wrong.bundle', version: '2312', ui_version: '2.3.12' }
      )
      expect_abort_includes('expects bundle id com.saneclip.app-setapp') do
        upload.send(:validate_portal_target_matches_archive!)
      end
    end

    test('pending-submission status is action required unless explicitly allowed') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(:@options, { allow_needs_revision: false })

      expect_abort_includes('Pending Submission') do
        upload.send(:enforce_portal_review_state!, { 'data' => { 'status' => 1 } })
      end

      upload.instance_variable_set(:@options, { allow_needs_revision: true })
      outcome = begin
        upload.send(:enforce_portal_review_state!, { 'data' => { 'status' => 1 } })
        :no_abort
      rescue SystemExit
        :aborted
      end
      assert_eq(outcome, :no_abort, '--allow-needs-revision must accept Pending Submission')
    end

    test('CI upload proof data must include hosted archive and matching versions') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(
        :@archive_metadata,
        { app_name: 'SaneBar', bundle_id: 'com.sanebar.app-setapp', version: '2171', ui_version: '2.1.71' }
      )

      expect_abort_includes('did not return proof fields') do
        upload.send(:validate_upload_proof_data!, { 'version' => '2171', 'ui_version' => '2.1.71' }, context: 'Setapp CI upload')
      end
      expect_abort_includes('does not match archive build') do
        upload.send(
          :validate_upload_proof_data!,
          { 'version' => '9999', 'ui_version' => '2.1.71', 'archive_url' => 'https://store.setapp.com/example.zip' },
          context: 'Setapp CI upload'
        )
      end
      assert(
        upload.send(
          :validate_upload_proof_data!,
          { 'version' => '2171', 'ui_version' => '2.1.71', 'archive_url' => 'https://store.setapp.com/example.zip' },
          context: 'Setapp CI upload'
        )
      )
      true
    end

    test('CI upload can report accepted without proof instead of failing on empty 204 response') do
      upload = FakeSetappUploadNoBody.new
      old_token = ENV['SETAPP_AUTOMATION_TOKEN']
      begin
        ENV['SETAPP_AUTOMATION_TOKEN'] = 'fixture-token'
        output = capture_stdout { upload.send(:run_ci_upload) }
        payload = JSON.parse(output)
        assert_eq(true, payload.dig('data', 'accepted_without_proof'))
        assert_includes(payload.dig('data', 'proof_required'), 'setapp_status')
      ensure
        ENV['SETAPP_AUTOMATION_TOKEN'] = old_token
      end
    end

    test('JSON output redacts private reviewer comments') do
      upload = SetappUpload.allocate
      upload.instance_variable_set(:@options, { json: true })
      output = capture_stdout do
        upload.send(
          :print_portal_result,
          { 'data' => { 'version' => '2171', 'vendor_comment' => 'private vendor note' } },
          { 'data' => { 'status' => 10, 'reviewer_comment' => 'private reviewer note' } }
        )
      end
      assert(!output.include?('private vendor note'), output)
      assert(!output.include?('private reviewer note'), output)
      assert_includes(output, '[redacted]')
    end

    test('hosted archive verification only sends portal auth to trusted HTTPS hosts') do
      upload = SetappUpload.allocate

      assert(upload.send(:validate_setapp_archive_url!, 'https://store.setapp.com/example.zip'))
      assert(upload.send(:validate_setapp_archive_url!, 'https://downloads.macpaw.com/example.zip'))
      assert_eq('https://store.setapp.com/redirected.zip', upload.send(:trusted_redirect_url!, 'https://store.setapp.com/app/example.zip', '/redirected.zip'))
      expect_abort_includes('trusted Setapp/MacPaw HTTPS host') do
        upload.send(:validate_setapp_archive_url!, 'https://cdn.store.setapp.com/example.zip')
      end
      expect_abort_includes('must use HTTPS') do
        upload.send(:validate_setapp_archive_url!, 'http://store.setapp.com/example.zip')
      end
      expect_abort_includes('trusted Setapp/MacPaw HTTPS host') do
        upload.send(:validate_setapp_archive_url!, 'https://example.com/archive.zip')
      end
      expect_abort_includes('trusted Setapp/MacPaw HTTPS host') do
        upload.send(:trusted_redirect_url!, 'https://store.setapp.com/example.zip', 'https://example.com/archive.zip')
      end
      true
    end

    test('dry run validates portal fallback without needing a token') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        # Resolve the pinned version id at runtime — it moves with every
        # Setapp release and a hardcoded id makes this test fail on staleness,
        # not on the behavior under test (token-free dry-run validation).
        pinned = SetappConfig.portal_targets['1847'][:version_id].to_s
        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--dry-run',
          '--portal-fallback',
          '--zip',
          zip_path,
          '--app-id',
          '1847',
          '--version-id',
          pinned,
          '--release-notes',
          'Launch.',
          '--no-review-comments-needed'
        )

        assert(status.success?, output)
        assert_includes(output, 'portal_fallback')
        assert_includes(output, 'versions/upload_archive')
        assert_includes(output, 'archive')
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
        zip_app(File.join(dir, 'SaneBar.app'), zip_path)

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
          'Launch.',
          '--no-review-comments-needed',
          '--no-safari-token'
        )

        assert(!status.success?, output)
        assert_includes(output, 'Setapp archive AppIcon.icns is 256x256')
        assert_includes(output, 'Setapp requires at least 512x512')
      end
      true
    end

    test('rejects Setapp archives that are not universal') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = File.join(dir, 'SaneClip.app')
        app_contents = File.join(app_root, 'Contents')
        app_resources = File.join(app_contents, 'Resources')
        app_macos = File.join(app_contents, 'MacOS')
        FileUtils.mkdir_p([app_resources, app_macos])

        create_root_icon_png(File.join(app_resources, 'AppIcon.icns'))

        info_plist = File.join(app_contents, 'Info.plist')
        File.write(info_plist, <<~PLIST)
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>CFBundleExecutable</key>
            <string>SaneClip</string>
            <key>CFBundleName</key>
            <string>SaneClip</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleIdentifier</key>
            <string>com.saneclip.app-setapp</string>
            <key>CFBundleShortVersionString</key>
            <string>2.3.9</string>
            <key>CFBundleVersion</key>
            <string>2309</string>
            <key>MPSupportedArchitectures</key>
            <array>
              <string>arm64</string>
              <string>x86_64</string>
            </array>
            <key>NSUpdateSecurityPolicy</key>
            <dict>
              <key>AllowProcesses</key>
              <dict>
                <key>MEHY5QF425</key>
                <array>
                  <string>com.setapp.DesktopClient.SetappAgent</string>
                </array>
              </dict>
            </dict>
          </dict>
          </plist>
        PLIST

        thin_executable = File.join(app_macos, 'SaneClip')
        output, status = Open3.capture2e(
          'lipo',
          '/bin/echo',
          '-thin',
          'arm64e',
          '-output',
          thin_executable
        )
        assert(status.success?, output)
        FileUtils.chmod('+x', thin_executable)

        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--portal-fallback',
          '--zip',
          zip_path,
          '--app-id',
          '1847',
          '--version-id',
          SetappConfig.portal_targets['1847'][:version_id].to_s,
          '--release-notes',
          'Launch.',
          '--no-review-comments-needed',
          '--no-safari-token'
        )

        assert(!status.success?, output)
        assert_includes(output, 'Setapp archive executable must include arm64 and x86_64')
      end
      true
    end

    test('rejects Setapp archives missing the sibling root app icon PNG') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app_without_root_icon(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'missing sibling app icon PNG')
        assert_includes(output, 'SaneClip.png')
      end
      true
    end

    test('rejects Setapp archives whose sibling root app icon PNG is not 1024px') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
          staged_app = File.join(stage_dir, File.basename(app_root))
          output, status = Open3.capture2e('ditto', '--norsrc', app_root, staged_app)
          assert(status.success?, output)
          create_root_icon_png(File.join(stage_dir, 'SaneClip.png'), size: 512)
          output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
          assert(status.success?, output)
        end

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'sibling app icon PNG is 512x512')
        assert_includes(output, 'Setapp requires 1024x1024')
      end
      true
    end

    test('rejects Setapp archives whose sibling root app icon fills the full square') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
          staged_app = File.join(stage_dir, File.basename(app_root))
          output, status = Open3.capture2e('ditto', '--norsrc', app_root, staged_app)
          assert(status.success?, output)
          create_full_bleed_root_icon_png(File.join(stage_dir, 'SaneClip.png'), size: 1024)
          output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
          assert(status.success?, output)
        end

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'does not meet Setapp frame/corner requirements')
        assert_includes(output, 'centered 824x824 design frame with 100px margins')
      end
      true
    end

    test('rejects Setapp archives with fake single-pixel rounded corners') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
          staged_app = File.join(stage_dir, File.basename(app_root))
          output, status = Open3.capture2e('ditto', '--norsrc', app_root, staged_app)
          assert(status.success?, output)
          create_fake_corner_root_icon_png(File.join(stage_dir, 'SaneClip.png'), size: 1024)
          output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
          assert(status.success?, output)
        end

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'opaque outside-curve pixels')
      end
      true
    end

    test('rejects Setapp archives with multiple top-level apps') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        second_app_root = create_setapp_fixture(dir, app_name: 'SaneBar', bundle_id: 'com.sanebar.app-setapp')
        zip_path = File.join(dir, 'TwoApps-Setapp.zip')
        Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
          [app_root, second_app_root].each do |root|
            output, status = Open3.capture2e('ditto', '--norsrc', root, File.join(stage_dir, File.basename(root)))
            assert(status.success?, output)
            create_root_icon_png(File.join(stage_dir, "#{File.basename(root, '.app')}.png"))
          end
          output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
          assert(status.success?, output)
        end

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'exactly one .app bundle')
      end
      true
    end

    test('rejects Setapp archives with forbidden macOS metadata or Sparkle framework entries') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        Dir.mktmpdir('setapp-upload-zip-stage') do |stage_dir|
          output, status = Open3.capture2e('ditto', '--norsrc', app_root, File.join(stage_dir, File.basename(app_root)))
          assert(status.success?, output)
          create_root_icon_png(File.join(stage_dir, 'SaneClip.png'))
          FileUtils.mkdir_p(File.join(stage_dir, 'SaneClip.app', 'Contents', 'Frameworks', 'Sparkle.framework'))
          File.write(File.join(stage_dir, 'SaneClip.app', 'Contents', 'Frameworks', 'Sparkle.framework', 'marker'), 'Sparkle')
          FileUtils.mkdir_p(File.join(stage_dir, '__MACOSX'))
          output, status = Open3.capture2e('ditto', '--norsrc', '-c', '-k', stage_dir, zip_path)
          assert(status.success?, output)
        end

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert(
          output.include?('forbidden __MACOSX metadata folder') ||
            output.include?('forbidden Sparkle.framework payload'),
          output
        )
      end
      true
    end

    test('rejects Setapp archives missing NSUpdateSecurityPolicy for SetappAgent') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        info_plist = File.join(app_root, 'Contents', 'Info.plist')
        output, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Delete :NSUpdateSecurityPolicy', info_plist)
        assert(status.success?, output)
        output, status = Open3.capture2e('codesign', '--force', '--sign', '-', app_root)
        assert(status.success?, output)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'missing NSUpdateSecurityPolicy')
      end
      true
    end

    test('weak-only Sparkle linkage parser accepts weak links and rejects strong links') do
      require_relative 'setapp_upload' unless defined?(SetappUpload)

      weak_output = <<~OTOOL
        Load command 12
                  cmd LC_LOAD_WEAK_DYLIB
              cmdsize 96
                 name @rpath/Sparkle.framework/Versions/B/Sparkle (offset 24)
        Load command 13
                  cmd LC_LOAD_DYLIB
              cmdsize 56
                 name /usr/lib/libobjc.A.dylib (offset 24)
      OTOOL
      strong_output = <<~OTOOL
        Load command 12
                  cmd LC_LOAD_DYLIB
              cmdsize 96
                 name @rpath/Sparkle.framework/Versions/B/Sparkle (offset 24)
      OTOOL
      no_sparkle_output = <<~OTOOL
        Load command 12
                  cmd LC_LOAD_DYLIB
              cmdsize 56
                 name /usr/lib/libobjc.A.dylib (offset 24)
      OTOOL

      assert(SetappUpload.sparkle_linkage_weak_only_from_otool?(weak_output), 'weak Sparkle link must pass')
      assert(!SetappUpload.sparkle_linkage_weak_only_from_otool?(strong_output), 'strong Sparkle link must fail')
      assert(SetappUpload.sparkle_linkage_weak_only_from_otool?(no_sparkle_output), 'no Sparkle link must pass')
      true
    end

    test('tolerates unreachable direct-license residue in the executable, still rejects it in resources') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        # Build the fixture's own executable (rather than reusing
        # create_setapp_fixture, which signs before this test could append
        # bytes — a post-sign append fails strict validation on re-sign) so
        # the extra string bytes are present in the Mach-O BEFORE the one and
        # only codesign call, mirroring how "Enter License Key"/"checkoutURL"
        # land in the compiled binary as unreachable LicenseService residue.
        app_root = File.join(dir, 'SaneClip.app')
        app_contents = File.join(app_root, 'Contents')
        app_resources = File.join(app_contents, 'Resources')
        app_macos = File.join(app_contents, 'MacOS')
        FileUtils.mkdir_p([app_resources, app_macos])
        create_root_icon_png(File.join(app_resources, 'AppIcon.icns'))
        File.write(File.join(app_contents, 'Info.plist'), <<~PLIST)
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>CFBundleExecutable</key>
            <string>SaneClip</string>
            <key>CFBundleName</key>
            <string>SaneClip</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleIdentifier</key>
            <string>com.saneclip.app-setapp</string>
            <key>CFBundleShortVersionString</key>
            <string>2.3.9</string>
            <key>CFBundleVersion</key>
            <string>2309</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>MPSupportedArchitectures</key>
            <array>
              <string>arm64</string>
              <string>x86_64</string>
            </array>
            <key>NSUpdateSecurityPolicy</key>
            <dict>
              <key>AllowProcesses</key>
              <dict>
                <key>MEHY5QF425</key>
                <array>
                  <string>com.setapp.DesktopClient.SetappAgent</string>
                </array>
              </dict>
            </dict>
          </dict>
          </plist>
        PLIST
        exe_path = File.join(app_macos, 'SaneClip')
        # Compile a real Mach-O containing the strings as proper literals —
        # macOS codesign's strict validation rejects any Mach-O with bytes
        # appended past what its load commands declare (a hardening against
        # exactly the "smuggle extra bytes into a signed binary" trick),
        # so the string must be genuinely compiled in, not appended.
        source_path = File.join(dir, 'residue.c')
        File.write(source_path, <<~C)
          const char *residue = "Enter License Key checkoutURL";
          int main(void) { return residue[0] == 0 ? 1 : 0; }
        C
        compile_output, compile_status = Open3.capture2e(
          'clang', '-arch', 'arm64', '-arch', 'x86_64', '-o', exe_path, source_path
        )
        assert(compile_status.success?, compile_output)

        output, status = Open3.capture2e('codesign', '--force', '--sign', '-', app_root)
        assert(status.success?, output)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--validate-only', '--zip', zip_path)

        assert(status.success?, output)
        assert_includes(output, 'inert direct-channel residue tolerated')
        assert_includes(output, 'direct license-key UI copy')
      end
      true
    end

    test('rejects direct-license residue in a resource file even though the executable tolerance exists') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        File.write(File.join(app_root, 'Contents', 'Resources', 'residue.txt'), 'checkoutURL lives here')
        output, status = Open3.capture2e('codesign', '--force', '--sign', '-', app_root)
        assert(status.success?, output)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--validate-only', '--zip', zip_path)

        assert(!status.success?, output)
        assert_includes(output, 'forbidden direct-channel residue')
        assert_includes(output, 'non-binary file')
      end
      true
    end

    test('inert Sparkle strings in non-binary files remain fatal') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        # A framework-reference string in a RESOURCE is configuration, not
        # linker fallout — must stay fatal even under the weak-link tolerance.
        File.write(File.join(app_root, 'Contents', 'Resources', 'residue.txt'), 'loads Sparkle.framework at runtime')
        output, status = Open3.capture2e('codesign', '--force', '--sign', '-', app_root)
        assert(status.success?, output)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'forbidden direct-channel residue')
        assert_includes(output, 'non-binary file')
      end
      true
    end

    test('rejects Setapp archives containing direct-license or checkout strings') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        File.write(File.join(app_root, 'Contents', 'Resources', 'direct-channel.txt'), 'Enter License Key via Lemon Squeezy checkoutURL')
        output, status = Open3.capture2e('codesign', '--force', '--sign', '-', app_root)
        assert(status.success?, output)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'forbidden direct-channel residue')
      end
      true
    end

    test('validate-only accepts a universal Setapp archive without portal credentials') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(status.success?, output)
        assert_includes(output, 'Setapp archive validation passed')
        assert_includes(output, 'app: SaneClip')
        assert_includes(output, 'root icon: ok visible_pixels=')
      end
      true
    end

    test('validate-only accepts Setapp archives with one wrapper directory') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        app_root = create_setapp_fixture(dir)
        zip_path = File.join(dir, 'SaneClip-Setapp-Wrapped.zip')
        zip_wrapped_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(status.success?, output)
        assert_includes(output, 'Setapp archive validation passed')
      end
      true
    end

    test('direct-channel scanner includes nested bundle executables') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        nested_executable = File.join(dir, 'SaneClip.app', 'Contents', 'PlugIns', 'Widget.appex', 'Contents', 'MacOS', 'Widget')
        FileUtils.mkdir_p(File.dirname(nested_executable))
        FileUtils.cp('/bin/echo', nested_executable)

        upload = SetappUpload.allocate
        assert(upload.send(:setapp_payload_scan_candidate?, nested_executable))
      end
      true
    end

    test('profile matching covers restricted entitlement arrays') do
      upload = SetappUpload.allocate
      package = SetappPackage.allocate
      matching = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48',
        'com.apple.developer.icloud-services' => ['CloudKit'],
        'com.apple.security.application-groups' => ['group.com.saneclip.app'],
        'keychain-access-groups' => ['M78L6FXD48.com.saneclip.*']
      }
      team_wildcard_groups = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48',
        'com.apple.developer.icloud-services' => '*',
        'com.apple.security.application-groups' => ['M78L6FXD48.*'],
        'keychain-access-groups' => ['M78L6FXD48.*']
      }
      unrelated = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.other.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48'
      }
      wrong_team = {
        'com.apple.application-identifier' => 'OTHERTEAM.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48'
      }
      signed = {
        'com.apple.developer.icloud-services' => ['CloudKit'],
        'com.apple.security.application-groups' => ['group.com.saneclip.app'],
        'keychain-access-groups' => ['M78L6FXD48.com.saneclip.app']
      }
      missing_groups = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48',
        'keychain-access-groups' => ['M78L6FXD48.com.saneclip.*']
      }
      missing_services = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48',
        'com.apple.security.application-groups' => ['group.com.saneclip.app'],
        'keychain-access-groups' => ['M78L6FXD48.com.saneclip.*']
      }

      assert(upload.send(:profile_bundle_id_matches?, matching, 'com.saneclip.app-setapp'))
      assert(package.send(:profile_bundle_id_matches?, matching, 'com.saneclip.app-setapp'))
      assert(!upload.send(:profile_bundle_id_matches?, unrelated, 'com.saneclip.app-setapp'))
      assert(!package.send(:profile_bundle_id_matches?, unrelated, 'com.saneclip.app-setapp'))
      assert(!upload.send(:profile_bundle_id_matches?, wrong_team, 'com.saneclip.app-setapp'))
      assert(!package.send(:profile_bundle_id_matches?, wrong_team, 'com.saneclip.app-setapp'))
      assert(upload.send(:profile_covers_restricted_entitlements?, matching, signed))
      assert(package.send(:profile_covers_restricted_entitlements?, matching, signed))
      assert(upload.send(:profile_covers_restricted_entitlements?, team_wildcard_groups, signed))
      assert(package.send(:profile_covers_restricted_entitlements?, team_wildcard_groups, signed))
      assert(!upload.send(:profile_covers_restricted_entitlements?, missing_services, signed))
      assert(!package.send(:profile_covers_restricted_entitlements?, missing_services, signed))
      assert(!upload.send(:profile_covers_restricted_entitlements?, missing_groups, signed))
      assert(!package.send(:profile_covers_restricted_entitlements?, missing_groups, signed))
      true
    end

    test('rejects restricted-entitlement archives without embedded provisioning profiles') do
      Dir.mktmpdir('setapp-upload-test') do |dir|
        entitlements = <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>com.apple.developer.icloud-container-identifiers</key>
            <array>
              <string>iCloud.com.saneclip.app</string>
            </array>
            <key>com.apple.security.application-groups</key>
            <array>
              <string>group.com.saneclip.app</string>
            </array>
          </dict>
          </plist>
        PLIST
        app_root = create_setapp_fixture(dir, entitlements: entitlements)
        zip_path = File.join(dir, 'SaneClip-Setapp.zip')
        zip_app(app_root, zip_path)

        output, status = Open3.capture2e(
          'ruby',
          SCRIPT_PATH,
          '--validate-only',
          '--zip',
          zip_path
        )

        assert(!status.success?, output)
        assert_includes(output, 'signs restricted entitlements')
        assert_includes(output, 'embedded.provisionprofile')
      end
      true
    end

    test('SaneMaster exposes setapp_upload as a Mini-first command') do
      source = File.read(SANEMASTER_PATH)
      base_source = File.read(SANEMASTER_BASE_PATH)
      package_source = File.read(PACKAGE_SCRIPT_PATH)

      assert_includes(source, "'setapp_package'")
      assert_includes(source, "'setapp_upload'")
      assert_includes(source, "'setapp_status'")
      assert_includes(source, "when 'setapp_package', 'setapp-package'")
      assert_includes(source, "when 'setapp_upload', 'setapp-upload'")
      assert_includes(source, "when 'setapp_status', 'setapp-status'")
      assert_includes(source, "setapp_package\n                                  setapp-package")
      assert_includes(source, 'setapp_package.rb')
      assert_includes(source, 'setapp_package')
      assert_includes(source, 'setapp_upload')
      assert_includes(source, 'setapp_status')
      assert_includes(base_source, 'setapp_package')
      assert_includes(base_source, 'setapp_upload')
      assert_includes(base_source, 'setapp_status')
      assert_includes(package_source, '--validate-only')
      assert_includes(package_source, 'notarytool')
      assert_includes(package_source, 'embed_provisioning_profiles')
      assert_includes(package_source, 'write_root_icon_png')
      assert_includes(package_source, 'root_icon_png_path')
      assert_includes(package_source, 'setapp_icon_tool.swift')
      assert_includes(package_source, 'ICONSET_REPRESENTATIONS')
      assert_includes(package_source, 'validate_setapp_icon_geometry')
      assert_includes(package_source, 'verify_quarantined_launch')
      assert_includes(package_source, 'enforce_mini_host!')
      assert_includes(package_source, 'app_icon_manifest_pngs')
      assert_includes(package_source, 'redacted_shelljoin')
      assert_includes(package_source, 'did not observe a new')
      assert_includes(package_source, 'profile_covers_icloud_services?')
      assert_includes(package_source, 'REXML::Document')
      assert_includes(package_source, "'xml1'")
      assert_includes(package_source, 'before_pids')
      assert_includes(package_source, 'pids_for_process_name')
      assert(!package_source.include?('filter_map'), 'Setapp package script must stay Ruby 2.6-compatible on the Mini')
      true
    end

    test('setapp_package rebuilds AppIcon from source catalog before signing') do
      package_source = File.read(PACKAGE_SCRIPT_PATH)

      assert_includes(package_source, 'normalize_app_icon')
      assert_includes(package_source, 'AppIcon.appiconset')
      assert_includes(package_source, 'AppIcon.iconset')
      assert_includes(package_source, 'setapp_icon_source_png')
      assert_includes(package_source, 'app_icon_manifest_pngs')
      assert_includes(package_source, 'root-icon-validate.log')
      assert_includes(package_source, 'iconutil')
      assert_includes(package_source, 'Setapp packaging requires a 1024x1024 source')
      assert_includes(package_source, 'embedded.provisionprofile')
      assert(
        package_source.index('normalize_app_icon') < package_source.index('prepare_signing_session'),
        'AppIcon must be rebuilt before signing so the signature covers the final icon'
      )
      assert(
        package_source.index('write_root_icon_png') < package_source.index('package_final_zip'),
        'Setapp root PNG must exist before the final ZIP is created'
      )
      assert(
        package_source.index('embed_provisioning_profiles') < package_source.index('sign_nested_extensions'),
        'Provisioning profiles must be embedded before signing so the signature covers the profile'
      )
      assert(
        package_source.index('validate_final_zip') < package_source.index('verify_quarantined_launch'),
        'The final Setapp ZIP must pass upload validation before the quarantined launch proof'
      )
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
        'Launch.'
      )

      assert(!status.success?, output)
      assert_includes(output, 'ZIP not found')
      true
    end
  end

  # Regression: setapp_upload.rb and this test File.read Ruby sources that carry
  # emoji (✅/❌). Under a locale-less shell the US-ASCII default external encoding
  # makes a later string match raise "invalid byte sequence in US-ASCII". Same
  # family as sane_test_locale_test.rb. Probes run in C-locale subprocesses.
  test_category('C-locale survival (UTF-8 encoding pin)') do
    c_locale_env = { 'LC_ALL' => 'C', 'LANG' => 'C', 'LC_CTYPE' => nil }.freeze
    run_c_locale_probe = lambda do |probe|
      Open3.capture3(c_locale_env, RbConfig.ruby, '-e', probe)
    end

    test('unpinned source read of setapp_upload.rb raises under a C locale (the bug)') do
      probe = <<~RUBY
        source = File.read(#{SCRIPT_PATH.dump})
        # Regex ops (not include?) are what raise on an invalid-US-ASCII string.
        source.match?(/codesign/)
        print 'NO_RAISE'
      RUBY
      stdout, stderr, status = run_c_locale_probe.call(probe)
      combined = "#{stdout}#{stderr}"
      assert(!status.success?, "expected unpinned read to raise under C locale, got: #{combined}")
      assert_includes(combined, 'invalid byte sequence in US-ASCII')
      true
    end

    test('explicit UTF-8 source read survives a C locale (the fix)') do
      probe = <<~RUBY
        source = File.read(#{SCRIPT_PATH.dump}, encoding: Encoding::UTF_8)
        abort 'match failed' unless source.match?(/codesign/)
        print 'READ_OK'
      RUBY
      stdout, stderr, status = run_c_locale_probe.call(probe)
      assert(status.success?, "probe failed: #{stderr}")
      assert_includes(stdout, 'READ_OK')
      true
    end

    test('setapp_upload.rb pins UTF-8 defaults when loaded under a C locale') do
      probe = <<~RUBY
        load #{SCRIPT_PATH.dump}
        abort 'default_external not UTF-8' unless Encoding.default_external == Encoding::UTF_8
        abort 'default_internal not UTF-8' unless Encoding.default_internal == Encoding::UTF_8
        print 'ENC_OK'
      RUBY
      stdout, stderr, status = run_c_locale_probe.call(probe)
      assert(status.success?, "probe failed: #{stderr}")
      assert_includes(stdout, 'ENC_OK')
      true
    end
  end
end)
