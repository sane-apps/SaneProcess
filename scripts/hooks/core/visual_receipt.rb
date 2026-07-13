# frozen_string_literal: true

require 'json'
require 'time'

module SaneVisualReceipt
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg].freeze
  DEFAULT_RECEIPTS = [
    'outputs/customer_ui_action_receipt.json',
    '.sane/customer_ui_action_receipt.json'
  ].freeze

  module_function

  def valid_receipt?(cwd:, path:, started_at:)
    absolute = expand_path(cwd, path)
    return false unless absolute && File.file?(absolute)

    receipt = JSON.parse(File.read(absolute, encoding: Encoding::UTF_8))
    generated_at = parse_time(receipt['generated_at'] || receipt['generatedAt'] || receipt['timestamp'])
    return false if generated_at && generated_at < started_at

    customer_ui_receipt_valid?(cwd, receipt) || visual_audit_receipt_valid?(cwd, receipt, absolute)
  rescue JSON::ParserError, Errno::ENOENT
    false
  end

  def valid_receipt_paths(cwd:, candidate_paths:, started_at:)
    paths = (Array(candidate_paths) + discovered_receipt_paths(cwd)).uniq
    paths.select { |path| valid_receipt?(cwd: cwd, path: path, started_at: started_at) }
  end

  def discovered_receipt_paths(cwd)
    default = DEFAULT_RECEIPTS.map { |path| File.join(cwd, path) }
    visual = Dir.glob(File.join(cwd, 'outputs', 'visual-audit*', '*.json')) +
             Dir.glob(File.join(cwd, 'outputs', 'visual_audit*', '*.json'))
    # Umbrella sessions run with cwd = ~/SaneApps while the receipt lives in
    # the app repo that was actually edited (apps/<App>/outputs/...). Without
    # this the Stop gate can NEVER be satisfied from an umbrella session — the
    # receipt exists and validates, but the glob never finds it (hit live
    # 2026-07-02, SaneClip 2.3.12).
    umbrella = Dir.glob(File.join(cwd, 'apps', '*', 'outputs', 'visual-audit*', '*.json')) +
               Dir.glob(File.join(cwd, 'apps', '*', 'outputs', 'visual_audit*', '*.json')) +
               Dir.glob(File.join(cwd, 'apps', '*', 'outputs', 'customer_ui_action_receipt.json'))
    (default + visual + umbrella).uniq
  end

  def expand_path(cwd, path)
    return nil if path.to_s.strip.empty?

    path.to_s.start_with?('/') ? path.to_s : File.join(cwd, path.to_s)
  end

  def parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Visual receipts must come from the Mini by default (release-quality proof).
  # EXCEPTION: notch / built-in-display verification CANNOT be done on the Mini
  # (it has no built-in display and drives notchless externals, so the notch
  # code path is dead there). Such tasks MUST run on the Air, so an 'air' host
  # is accepted only when the receipt explicitly declares itself a notch /
  # built-in-display verification. See SaneBar docs/AIR_UI_TESTING.md and the
  # air-is-users-workstation memory.
  def acceptable_visual_host?(receipt)
    host = receipt['host'].to_s.downcase
    return true if host.include?('mini')

    host.include?('air') &&
      (receipt['notch_verification'] == true || receipt['built_in_display'] == true)
  end

  def customer_ui_receipt_valid?(cwd, receipt)
    return false if visual_audit_receipt?(receipt)
    return false unless receipt['status'].to_s == 'passed'
    return false unless acceptable_visual_host?(receipt)
    return false if Array(receipt['screenshots']).empty?

    Array(receipt['screenshots']).all? { |path| screenshot_file?(cwd, path) }
  end

  def visual_audit_receipt_valid?(cwd, receipt, receipt_path)
    return false unless visual_audit_receipt?(receipt)
    return false unless %w[passed pass clean].include?((receipt['status'] || receipt['verdict']).to_s.downcase)
    return false unless acceptable_visual_host?(receipt)
    return false unless receipt['inspected'] == true || receipt['audit_recorded'] == true

    screenshots = Array(receipt['screenshots'] || receipt['screenshot_paths'])
    screenshots = screenshots.map { |item| item.is_a?(Hash) ? item['path'] : item }
    return false if screenshots.empty?

    screenshots.all? do |path|
      screenshot_file?(cwd, path) || screenshot_file?(File.dirname(receipt_path), path)
    end && claim_mapped_visual_evidence?(cwd, receipt, receipt_path)
  end

  def visual_audit_receipt?(receipt)
    receipt['type'].to_s == 'visual_audit' || receipt['schema'].to_s == 'saneprocess.visual_audit'
  end

  def claim_mapped_visual_evidence?(cwd, receipt, receipt_path)
    claims = Array(receipt['claims'])
    return false if claims.empty?

    claims.all? do |claim|
      next false unless claim.is_a?(Hash)
      next false unless claim['id'].to_s.strip != '' || claim['claim'].to_s.strip != '' || claim['label'].to_s.strip != ''
      next false unless %w[passed pass clean].include?((claim['status'] || claim['verdict']).to_s.downcase)

      paths = Array(claim['screenshots'] || claim['screenshot_paths'] || claim['evidence'])
      paths = paths.map { |item| item.is_a?(Hash) ? item['path'] : item }.compact
      next false if paths.empty?

      paths.all? do |path|
        screenshot_file?(cwd, path) || screenshot_file?(File.dirname(receipt_path), path)
      end
    end
  end

  def screenshot_file?(base, path)
    absolute = expand_path(base, path)
    return false unless absolute && File.file?(absolute)

    IMAGE_EXTENSIONS.include?(File.extname(absolute).downcase)
  end
end
