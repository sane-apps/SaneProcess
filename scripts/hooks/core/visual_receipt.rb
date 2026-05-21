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

    receipt = JSON.parse(File.read(absolute))
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
    (default + visual).uniq
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

  def customer_ui_receipt_valid?(cwd, receipt)
    return false unless receipt['status'].to_s == 'passed'
    return false unless receipt['host'].to_s.downcase.include?('mini')
    return false if Array(receipt['screenshots']).empty?

    Array(receipt['screenshots']).all? { |path| screenshot_file?(cwd, path) }
  end

  def visual_audit_receipt_valid?(cwd, receipt, receipt_path)
    return false unless receipt['type'].to_s == 'visual_audit' || receipt['schema'].to_s == 'saneprocess.visual_audit'
    return false unless %w[passed pass clean].include?((receipt['status'] || receipt['verdict']).to_s.downcase)
    return false unless receipt['host'].to_s.downcase.include?('mini')
    return false unless receipt['inspected'] == true || receipt['audit_recorded'] == true

    screenshots = Array(receipt['screenshots'] || receipt['screenshot_paths'])
    screenshots = screenshots.map { |item| item.is_a?(Hash) ? item['path'] : item }
    return false if screenshots.empty?

    screenshots.all? do |path|
      screenshot_file?(cwd, path) || screenshot_file?(File.dirname(receipt_path), path)
    end
  end

  def screenshot_file?(base, path)
    absolute = expand_path(base, path)
    return false unless absolute && File.file?(absolute)

    IMAGE_EXTENSIONS.include?(File.extname(absolute).downcase)
  end
end
