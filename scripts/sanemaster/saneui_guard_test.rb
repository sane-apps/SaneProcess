#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../hooks/test/test_framework'
require_relative 'saneui_guard'

include TestFramework

def with_repo(manifest_type:, files:)
  Dir.mktmpdir('saneui-guard') do |dir|
    File.write(File.join(dir, '.saneprocess'), <<~YAML)
      name: TestApp
      type: #{manifest_type}
      commands: {}
      docs: []
    YAML

    files.each do |relative, content|
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    yield dir
  end
end

exit(run_tests('SaneUI Guard Tests') do
  test_category('Blocking drift patterns') do
    test('flags local settings clones and legacy support paths') do
      with_repo(
        manifest_type: 'macos_app',
        files: {
          'UI/Settings/AboutSettingsView.swift' => <<~SWIFT,
            import SwiftUI

            struct AboutSettingsView: View {
                var body: some View {
                    VStack {
                        Link("Email", destination: URL(string: "mailto:hi@saneapps.com")!)
                        Button("Check Now") {}
                            .buttonStyle(.bordered)
                        Text("Manage Access")
                    }
                }
            }

            private struct SettingsResizeGrip: NSViewRepresentable {
                var body: some View { EmptyView() }
            }
          SWIFT
          'DirectDistributionSupport.swift' => <<~SWIFT
            import SwiftUI

            struct SaneSparkleRow: View {
                var body: some View { Text("dup") }
            }
          SWIFT
        }
      ) do |dir|
        report = SaneMasterModules::SaneUIGuard.report_for_path(dir)
        labels = report[:errors].map(&:label)

        assert(report[:applicable], 'expected app repo to be checked')
        assert_includes(labels, 'Local SaneSparkleRow clone')
        assert_includes(labels, 'Email support link in settings UI')
        assert_includes(labels, 'Default bordered button in settings UI')
        assert_includes(labels, 'Legacy Manage Access copy')
        assert_includes(labels, 'Local settings resize grip clone')
        true
      end
    end
  end

  test_category('Migration warnings') do
    test('warns when macOS settings skip shared SaneUI shells') do
      with_repo(
        manifest_type: 'macos_app',
        files: {
          'UI/Settings/SettingsView.swift' => <<~SWIFT
            import SwiftUI

            struct SettingsView: View {
                var body: some View { Text("custom settings") }
            }
          SWIFT
        }
      ) do |dir|
        report = SaneMasterModules::SaneUIGuard.report_for_path(dir)
        labels = report[:warnings].map(&:label)

        assert_includes(labels, 'Settings container not using shared SaneUI shell')
        assert_includes(labels, 'About pane not using shared SaneAboutView')
        true
      end
    end

    test('does not warn when the shared license view is specialized with a bridged service') do
      with_repo(
        manifest_type: 'macos_app',
        files: {
          'UI/Settings/SettingsView.swift' => <<~SWIFT
            import SaneUI
            import SwiftUI

            final class LicenseService {}
            final class SaneBarLicenseSettingsAdapter {}

            struct SettingsView: View {
                var body: some View {
                    LicenseSettingsView<SaneBarLicenseSettingsAdapter>(
                        licenseService: SaneBarLicenseSettingsAdapter(),
                        style: .panel
                    )
                }
            }
          SWIFT
        }
      ) do |dir|
        report = SaneMasterModules::SaneUIGuard.report_for_path(dir)
        labels = report[:warnings].map(&:label)

        assert(!labels.include?('License pane not using shared LicenseSettingsView'))
        true
      end
    end
  end

  test_category('Scope') do
    test('ignores build and vendored checkout scratch trees') do
      with_repo(
        manifest_type: 'macos_app',
        files: {
          'UI/Settings/SettingsView.swift' => <<~SWIFT,
            import SaneUI
            import SwiftUI

            struct SettingsView: View {
                var body: some View {
                    SaneSettingsContainer(defaultTab: Tab.general) { _ in
                        Text("Shared")
                    }
                }

                enum Tab: String, SaneSettingsTab {
                    case general = "General"
                    var icon: String { "gearshape" }
                    var iconColor: Color { .white }
                }
            }
          SWIFT
          'build/AppStoreLaunchProbe/SourcePackages/checkouts/SaneUI/Sources/SaneUI/Components/SaneAboutView.swift' => <<~SWIFT
            import SwiftUI

            struct VendoredAboutView: View {
                var body: some View {
                    VStack {
                        Link("Email", destination: URL(string: "mailto:hi@saneapps.com")!)
                        Button("Check Now") {}
                            .buttonStyle(.bordered)
                    }
                }
            }
          SWIFT
        }
      ) do |dir|
        report = SaneMasterModules::SaneUIGuard.report_for_path(dir)

        assert_eq(report[:errors], [])
        true
      end
    end

    test('skips non-app repos') do
      with_repo(
        manifest_type: 'infra',
        files: {
          'Sources/Tool.swift' => 'struct Tool {}'
        }
      ) do |dir|
        report = SaneMasterModules::SaneUIGuard.report_for_path(dir)

        assert(!report[:applicable], 'expected infra repo to be skipped')
        assert_eq(report[:errors], [])
        assert_eq(report[:warnings], [])
        true
      end
    end
  end
end)
