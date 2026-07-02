# frozen_string_literal: true

require 'yaml'

module SaneMasterModules
  module SaneUIGuard
    module_function

    LICENSE_SETTINGS_VIEW_PATTERN = /LicenseSettingsView(?:<[^>]+>)?\s*\(/.freeze

    Finding = Struct.new(:severity, :label, :detail, :fix, keyword_init: true)

    MACOS_APP_TYPES = %w[macos_app universal_app].freeze
    SETTINGS_UI_MATCHERS = [
      /\/Settings(?:\/|View|Tab|Screen|Window)/i,
      /SettingsView\.swift$/i,
      /About.*View\.swift$/i,
      /DirectDistributionSupport\.swift$/i,
      /License.*View\.swift$/i
    ].freeze
    SOURCE_OF_TRUTH_HINT = [
      'Extend shared SaneUI instead of app-local settings chrome.',
      'Inspect ~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift first.',
      'Use shared SaneSettingsContainer, SaneAboutView, and LicenseSettingsView.'
    ].join(' ')

    # SaneSparkleRow deliberately left the shared library (2026-07-01): the
    # Setapp archive scanner forbids Sparkle settings-UI symbols in Setapp
    # binaries, and a shared-library public type reaches every consumer binary
    # regardless of app-side call-site gating. App-local copies are therefore
    # the CORRECT pattern — but only when the ENTIRE defining file is wrapped
    # in `#if !APP_STORE && !SETAPP` so the symbol cannot ship in gated
    # channels. Ungated definitions stay forbidden.
    SPARKLE_ROW_GATE_PATTERN = /#if\s+!APP_STORE\s*&&\s*!SETAPP/.freeze
    SPARKLE_ROW_STRUCT_PATTERN = /^\s*struct\s+SaneSparkleRow\b/m.freeze

    def channel_gated_sparkle_row?(content)
      gate_index = content =~ SPARKLE_ROW_GATE_PATTERN
      struct_index = content =~ SPARKLE_ROW_STRUCT_PATTERN
      return false unless gate_index && struct_index

      gate_index < struct_index
    end

    def report_for_path(path)
      root = File.expand_path(path)
      manifest = load_manifest(root)
      applicable = saneui_guard_applicable?(root, manifest)

      return {
        applicable: false,
        manifest: manifest,
        errors: [],
        warnings: []
      } unless applicable

      files = swift_source_files(root)
      contents = files.to_h do |file|
        content = File.read(file, encoding: 'UTF-8')
        content = content.scrub('?') unless content.valid_encoding?
        [file, content]
      end
      settings_files = files.select { |file| settings_ui_file?(file) }

      errors = []
      warnings = []

      contents.each do |file, content|
        relative = relative_path(root, file)

        if content.match?(SPARKLE_ROW_STRUCT_PATTERN) && !channel_gated_sparkle_row?(content)
          errors << Finding.new(
            severity: :error,
            label: 'Ungated SaneSparkleRow definition',
            detail: relative,
            fix: 'SaneSparkleRow is app-local by design (Setapp scanner forbids the symbol in Setapp binaries), but the ENTIRE defining file must be wrapped in #if !APP_STORE && !SETAPP — see SaneClip UI/Settings/SaneSparkleRow.swift.'
          )
        end

        if settings_ui_file?(file) && content.match?(/^\s*(?:private\s+)?(?:struct|final\s+class|class)\s+SettingsResizeGrip\b/m)
          errors << Finding.new(
            severity: :error,
            label: 'Local settings resize grip clone',
            detail: relative,
            fix: 'Use shared SaneUI.SaneSettingsResizeGrip instead of app-local settings resize chrome.'
          )
        end

        next unless settings_ui_file?(file)

        content.each_line.with_index(1) do |line, line_number|
          detail = "#{relative}:#{line_number}"

          if line.match?(/mailto:hi@saneapps\.com/i)
            errors << Finding.new(
              severity: :error,
              label: 'Email support link in settings UI',
              detail: detail,
              fix: 'Route bug/support actions through shared SaneAboutView and SaneFeedbackView GitHub flows.'
            )
          end

          if line.include?('Manage Access')
            errors << Finding.new(
              severity: :error,
              label: 'Legacy Manage Access copy',
              detail: detail,
              fix: 'Use the shared SaneUI license labels: Basic/Pro, Unlock Pro, Enter License Key, Deactivate Pro.'
            )
          end

          if line.match?(/\.buttonStyle\(\.bordered\)/)
            errors << Finding.new(
              severity: :error,
              label: 'Default bordered button in settings UI',
              detail: detail,
              fix: 'Use shared SaneUI button styling instead of .buttonStyle(.bordered) in settings/about/license/update surfaces.'
            )
          end
        end
      end

      if settings_files.any? && macos_app_manifest?(manifest) && !contents.values.any? { |content| content.include?('SaneSettingsContainer(') }
        warnings << Finding.new(
          severity: :warning,
          label: 'Settings container not using shared SaneUI shell',
          detail: File.basename(root),
          fix: 'Adopt SaneSettingsContainer so tab order and layout come from the shared source of truth.'
        )
      end

      if settings_files.any? && !contents.values.any? { |content| content.include?('SaneAboutView(') }
        warnings << Finding.new(
          severity: :warning,
          label: 'About pane not using shared SaneAboutView',
          detail: File.basename(root),
          fix: 'Move About/support actions to shared SaneAboutView so button layout and bug flow stay consistent.'
        )
      end

      if contents.values.any? { |content| content.include?('LicenseService(') } &&
         !contents.values.any? { |content| content.match?(LICENSE_SETTINGS_VIEW_PATTERN) }
        warnings << Finding.new(
          severity: :warning,
          label: 'License pane not using shared LicenseSettingsView',
          detail: File.basename(root),
          fix: 'Adopt shared LicenseSettingsView instead of app-local purchase or status rows.'
        )
      end

      {
        applicable: true,
        manifest: manifest,
        errors: dedupe(errors),
        warnings: dedupe(warnings)
      }
    end

    def format_report(report)
      lines = []
      warnings = report[:warnings] || []
      errors = report[:errors] || []

      if warnings.any?
        lines << 'Warnings:'
        warnings.each { |finding| lines << "  - #{finding.label}: #{finding.detail}" }
      end

      if errors.any?
        lines << 'Errors:'
        errors.each { |finding| lines << "  - #{finding.label}: #{finding.detail}" }
      end

      lines
    end

    def run_cli(path, io: $stdout, fail_on_errors: true)
      report = report_for_path(path)

      unless report[:applicable]
        io.puts 'SaneUI guard: skipped — not an app repo'
        return true
      end

      io.puts 'SaneUI guard:'
      format_report(report).each { |line| io.puts(line) }

      has_errors = (report[:errors] || []).any?
      return true unless fail_on_errors
      !has_errors
    end

    def load_manifest(root)
      manifest_path = File.join(root, '.saneprocess')
      return nil unless File.exist?(manifest_path)

      YAML.safe_load(File.read(manifest_path))
    rescue Psych::SyntaxError
      nil
    end

    def saneui_guard_applicable?(root, manifest)
      return false if root.include?('/infra/SaneUI') || root.include?('/infra/SaneProcess')
      return false unless manifest.is_a?(Hash)

      type = manifest['type'].to_s
      type.include?('app')
    end

    def macos_app_manifest?(manifest)
      MACOS_APP_TYPES.include?(manifest['type'].to_s)
    end

    def swift_source_files(root)
      Dir.glob(File.join(root, '**', '*.swift')).reject do |file|
        file.include?('/.build/') ||
          file.include?('/build/') ||
          file.include?('/DerivedData/') ||
          file.include?('/SourcePackages/') ||
          file.include?('/Packages/') ||
          file.include?('/docs/') ||
          file.include?('/Tests/')
      end
    end

    def settings_ui_file?(file)
      SETTINGS_UI_MATCHERS.any? { |pattern| file.match?(pattern) }
    end

    def relative_path(root, file)
      file.delete_prefix("#{root}/")
    end

    def dedupe(findings)
      findings.uniq { |finding| [finding.severity, finding.label, finding.detail] }
    end
  end
end
