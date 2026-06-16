#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require_relative 'hooks/test/test_framework'
require_relative 'setapp_upload'
require_relative 'setapp_package'

include TestFramework

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

  FileUtils.cp(
    '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns',
    File.join(app_resources, 'AppIcon.icns')
  )
  File.write(File.join(app_contents, 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>#{app_name}</string>
      <key>CFBundleIdentifier</key>
      <string>#{bundle_id}</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>MPSupportedArchitectures</key>
      <array>
        <string>arm64</string>
        <string>x86_64</string>
      </array>
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
      assert_includes(source, '--validate-only')
      assert_includes(source, 'enforce_portal_review_state!')
      assert_includes(source, 'MPSupportedArchitectures')
      assert_includes(source, 'lipo')
      assert_includes(source, 'embedded.provisionprofile')
      assert_includes(source, 'com.apple.developer.icloud-container-identifiers')
      assert_includes(source, 'profile_covers_icloud?')
      assert_includes(source, 'codesign')
      assert_includes(source, 'REXML::Document')
      assert_includes(source, "'xml1'")
      assert_includes(source, 'setapp_status')
      assert_includes(source, 'validate_root_icon_png!')
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
          'test notes',
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

        source_icon = '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns'
        FileUtils.cp(source_icon, File.join(app_resources, 'AppIcon.icns'))

        info_plist = File.join(app_contents, 'Info.plist')
        File.write(info_plist, <<~PLIST)
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>CFBundleExecutable</key>
            <string>SaneClip</string>
            <key>CFBundleIdentifier</key>
            <string>com.saneclip.app-setapp</string>
            <key>MPSupportedArchitectures</key>
            <array>
              <string>arm64</string>
              <string>x86_64</string>
            </array>
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
          '46886',
          '--release-notes',
          'test notes',
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
          zip_path,
          '--release-notes',
          'test notes'
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
          zip_path,
          '--release-notes',
          'test notes'
        )

        assert(!status.success?, output)
        assert_includes(output, 'sibling app icon PNG is 512x512')
        assert_includes(output, 'Setapp requires 1024x1024')
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
          zip_path,
          '--release-notes',
          'test notes'
        )

        assert(status.success?, output)
        assert_includes(output, 'Setapp archive validation passed')
      end
      true
    end

    test('profile matching rejects unrelated wildcard bundle prefixes') do
      upload = SetappUpload.allocate
      package = SetappPackage.allocate
      matching = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48'
      }
      unrelated = {
        'com.apple.application-identifier' => 'M78L6FXD48.com.other.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48'
      }
      wrong_team = {
        'com.apple.application-identifier' => 'OTHERTEAM.com.saneclip.*',
        'com.apple.developer.team-identifier' => 'M78L6FXD48'
      }

      assert(upload.send(:profile_bundle_id_matches?, matching, 'com.saneclip.app-setapp'))
      assert(package.send(:profile_bundle_id_matches?, matching, 'com.saneclip.app-setapp'))
      assert(!upload.send(:profile_bundle_id_matches?, unrelated, 'com.saneclip.app-setapp'))
      assert(!package.send(:profile_bundle_id_matches?, unrelated, 'com.saneclip.app-setapp'))
      assert(!upload.send(:profile_bundle_id_matches?, wrong_team, 'com.saneclip.app-setapp'))
      assert(!package.send(:profile_bundle_id_matches?, wrong_team, 'com.saneclip.app-setapp'))
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
          zip_path,
          '--release-notes',
          'test notes'
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
      assert_includes(package_source, 'verify_quarantined_launch')
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
      assert_includes(package_source, 'iconutil')
      assert_includes(package_source, 'Setapp requires 1024x1024')
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
        'test notes'
      )

      assert(!status.success?, output)
      assert_includes(output, 'ZIP not found')
      true
    end
  end
end)
