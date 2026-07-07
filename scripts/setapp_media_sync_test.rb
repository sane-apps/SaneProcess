#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require_relative 'hooks/test/test_framework'
require_relative 'setapp_media_sync'

include TestFramework

SCRIPT_PATH = File.expand_path('setapp_media_sync.rb', __dir__)
SANEMASTER_PATH = File.expand_path('SaneMaster.rb', __dir__)

# The portal-payload fixtures need a real, currently-enabled Setapp app config
# (its listing screenshots must exist on disk). This was hardcoded to SaneBar,
# which broke every fixture when SaneBar's Setapp listing was retired
# (setapp.enabled: false). Resolve the first enabled app at runtime and fail
# loudly if none is enabled.
def live_setapp_fixture_app
  SetappConfig.apps.first ||
    raise('setapp_media_sync tests need at least one Setapp-enabled app in apps/*/.saneprocess')
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

class FakeSetappMediaSync < SetappMediaSync
  attr_reader :patched_payload

  def initialize(app:, wrong_order: false, drop_preserved: false, allow_pending_public_page: true, public_page_proof_file: nil)
    @fixture_app = app
    @wrong_order = wrong_order
    @drop_preserved = drop_preserved
    @fetch_count = 0
    @uploaded = []
    argv = ['--json']
    argv << '--allow-pending-public-page' if allow_pending_public_page
    argv += ['--public-page-proof-file', public_page_proof_file] if public_page_proof_file
    super(argv)
  end

  private

  def selected_apps
    [@fixture_app]
  end

  def enforce_mini_host!
    true
  end

  def portal_token
    'fixture-token'
  end

  def fetch_version(_version_id, _authorization)
    @fetch_count += 1
    media = if @fetch_count == 1
              [
                { 'id' => 1, 'url' => 'https://setapp.example/old.png', 'type' => 'screenshot' },
                { 'id' => 99, 'url' => 'https://setapp.example/video.mov', 'type' => 'video' }
              ]
            else
              screenshots = @wrong_order ? @uploaded.reverse : @uploaded
              preserved = @drop_preserved ? [] : [{ 'id' => 99, 'url' => 'https://setapp.example/video.mov', 'type' => 'video' }]
              screenshots + preserved
            end
    { 'data' => { 'status' => 10, 'media_files' => media } }
  end

  def sleep(_seconds)
    true
  end

  def upload_screenshot(_app, screenshot, _authorization)
    id = "new-#{@uploaded.length + 1}"
    media = {
      'id' => id,
      'url' => "https://setapp.example/#{File.basename(screenshot.fetch(:path))}",
      'type' => 'screenshot',
      'additional_attributes' => {}
    }
    @uploaded << media
    media
  end

  def curl_json(_url, _authorization, payload)
    @patched_payload = payload
    { ok: true, status: 200, json: { 'data' => {} } }
  end
end

exit(run_tests('Setapp Media Sync Tests') do
  test_category('command wiring') do
    test('script parses and compiles') do
      output, status = Open3.capture2e('ruby', '-c', SCRIPT_PATH)
      assert(status.success?, output)
      assert_includes(output, 'Syntax OK')
    end

    test('SaneMaster exposes setapp_media_sync') do
      source = File.read(SANEMASTER_PATH)
      assert_includes(source, 'setapp_media_sync')
      assert_includes(source, 'setapp_media_sync.rb')
      assert_includes(source, 'Sync Setapp listing screenshots')
      assert_includes(File.read(SCRIPT_PATH), '--public-page-proof-file')
      assert_includes(source, 'SETAPP_ROUTE_COMMANDS')
      assert_includes(source, 'sync_setapp_app_workspaces_to_mini!')
    end
  end

  test_category('manifest validation') do
    test('dry run validates manifest screenshots and prints upload order') do
      output, status = Open3.capture2e('ruby', SCRIPT_PATH, '--dry-run', '--json')
      assert(status.success?, output)
      payload = JSON.parse(output)
      assert_eq(true, payload['dry_run'])
      # The synced set is whatever is Setapp-enabled in live manifests (was
      # hardcoded to [SaneClip, SaneBar] and broke when SaneBar retired).
      enabled = SetappConfig.apps.map { |app| app[:name] }
      assert(enabled.any?, 'expected at least one Setapp-enabled app')
      assert_eq(enabled, payload['apps'].map { |app| app['name'] })
      assert(payload['apps'].all? { |app| app['screenshots'].length == 5 }, output)
      assert(payload['apps'].all? { |app| app['setapp_url'].to_s.start_with?('https://setapp.com/apps/') }, output)
      assert(payload['apps'].all? { |app| app['public_page_verification_required'] == true }, output)
      assert(payload['apps'].all? { |app| app['public_page_verified'] == false }, output)
      assert(payload['apps'].all? { |app| app['screenshots'].all? { |shot| shot['role'].to_s != '' } }, output)
    end

    test('manifest discovery can select one app without parsing an unrelated broken manifest') do
      Dir.mktmpdir('setapp-config-test') do |root|
        sane_bar = File.join(root, 'apps', 'SaneBar')
        broken = File.join(root, 'apps', 'BrokenApp')
        FileUtils.mkdir_p([sane_bar, broken])
        File.write(File.join(broken, '.saneprocess'), "setapp: [\n")
        File.write(File.join(sane_bar, '.saneprocess'), <<~YAML)
          setapp:
            enabled: true
            app_id: "1848"
            version_id: "46885"
            bundle_id: com.sanebar.app-setapp
            listing:
              setapp_url: "https://setapp.com/apps/sanebar"
              screenshot_source: "owned-site app-in-use screenshots"
              screenshot_asset_root: docs/images/setapp
              screenshot_roles:
                - core_workflow_icon_panel
                - core_workflow_second_menu_bar
                - privacy_touch_id
                - workflow_browse_icons
                - settings_appearance
              screenshots:
                - docs/images/setapp/one.png
                - docs/images/setapp/two.png
                - docs/images/setapp/three.png
                - docs/images/setapp/four.png
                - docs/images/setapp/five.png
        YAML
        assert_eq('SaneBar', SetappConfig.app_named('SaneBar', root: root).fetch(:name))
      end
    end

    test('listing screenshot paths cannot escape the app repo') do
      Dir.mktmpdir('setapp-path-test') do |root|
        app = {
          name: 'FixtureApp',
          app_root: File.join(root, 'apps', 'FixtureApp'),
          listing_screenshots: ['../../Desktop/private.png'],
          listing_screenshot_roles: ['core_workflow']
        }
        FileUtils.mkdir_p(app.fetch(:app_root))
        expect_abort_includes('escapes the app repo') do
          SetappConfig.listing_screenshot_paths(app)
        end
      end
    end
  end

  test_category('portal payload') do
    test('sync uploads manifest screenshots, preserves video media, and verifies order') do
      app = live_setapp_fixture_app
      sync = FakeSetappMediaSync.new(app: app)
      assert_eq(0, sync.run)

      media = sync.patched_payload.fetch(:media_files)
      assert_eq(10, sync.patched_payload.fetch(:status))
      assert_eq(6, media.length)
      assert_eq(%w[new-1 new-2 new-3 new-4 new-5], media.first(5).map { |item| item.fetch('id') })
      assert_eq('video', media.last.fetch('type'))
    end

    test('sync returns nonzero until public setapp.com proof is acknowledged') do
      app = live_setapp_fixture_app
      sync = FakeSetappMediaSync.new(app: app, allow_pending_public_page: false)

      assert_eq(4, sync.run)
    end

    test('public setapp.com proof receipt clears the pending listing block') do
      Dir.mktmpdir('setapp-public-proof-') do |dir|
        app = live_setapp_fixture_app
        evidence = File.join(dir, 'sanebar-setapp-public-page.png')
        File.write(evidence, 'screenshot receipt')
        proof = File.join(dir, 'setapp-public-proof.json')
        File.write(
          proof,
          JSON.pretty_generate(
            checked_at: Time.now.utc.iso8601,
            apps: [
              {
                name: app.fetch(:name),
                setapp_url: app.fetch(:setapp_url),
                verified: true,
                screenshot_count: app.fetch(:listing_screenshots).length,
                evidence_path: evidence
              }
            ]
          )
        )

        sync = FakeSetappMediaSync.new(app: app, allow_pending_public_page: false, public_page_proof_file: proof)
        assert_eq(0, sync.run)
      end
    end

    test('mismatched public setapp.com proof receipt keeps the listing block active') do
      Dir.mktmpdir('setapp-public-proof-') do |dir|
        app = live_setapp_fixture_app
        evidence = File.join(dir, 'sanebar-setapp-public-page.png')
        File.write(evidence, 'screenshot receipt')
        proof = File.join(dir, 'setapp-public-proof.json')
        File.write(
          proof,
          JSON.pretty_generate(
            checked_at: Time.now.utc.iso8601,
            apps: [
              {
                name: app.fetch(:name),
                setapp_url: app.fetch(:setapp_url),
                verified: true,
                screenshot_count: 1,
                evidence_path: evidence
              }
            ]
          )
        )

        sync = FakeSetappMediaSync.new(app: app, allow_pending_public_page: false, public_page_proof_file: proof)
        assert_eq(4, sync.run)
      end
    end

    test('sync fails if the portal drops preserved non-screenshot media') do
      app = live_setapp_fixture_app
      sync = FakeSetappMediaSync.new(app: app, drop_preserved: true)
      expect_abort_includes('did not preserve non-screenshot media') { sync.run }
    end

    test('sync fails if the portal does not keep the requested screenshot order') do
      app = live_setapp_fixture_app
      sync = FakeSetappMediaSync.new(app: app, wrong_order: true)
      expect_abort_includes('did not verify') { sync.run }
    end
  end
end)
