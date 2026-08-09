# frozen_string_literal: true

require 'digest'
require 'json'

module SaneMasterModules
  module AppStoreStorefrontReceipts
    def appstore_storefront_receipt_report(root:, screenshots_config:, source_identity:, ios_supports_ipad:)
      issues = []
      issues << 'storefront receipts require clean source' unless source_identity[:clean] == true
      issues << 'storefront receipts require exact live pushed source' unless source_identity[:pushed] == true
      families = [['iphone', 'ios']]
      if ios_supports_ipad
        ipad_key = %w[ipad ipad_13 ipad_12.9 ipad_12_9 ipad_11].find do |key|
          !screenshots_config[key].to_s.empty?
        end
        families << ['ipad', ipad_key]
      end

      families.each do |family, key|
        if key.to_s.empty?
          issues << "#{family} storefront receipt cannot be resolved without a screenshot glob"
          next
        end
        pattern = screenshots_config[key].to_s
        files = Dir.glob(File.join(root, pattern)).sort
        issues << "#{family} screenshot glob matched no files" if files.empty?
        receipt_path = storefront_receipt_path(root, screenshots_config, key, pattern)
        issues.concat(storefront_receipt_issues(
          root: root, family: family, receipt_path: receipt_path,
          screenshot_paths: files, source_identity: source_identity
        ))
      end
      if ios_supports_ipad
        issues.concat(storefront_ipad_visual_issues(
          root: root, screenshots_config: screenshots_config, source_identity: source_identity
        ))
      end

      { ok: issues.empty?, issues: issues, family_count: families.length }
    end

    private

    def storefront_receipt_path(root, config, key, pattern)
      explicit = config["#{key}_receipt"].to_s
      return File.expand_path(explicit, root) unless explicit.empty?

      directory = File.dirname(pattern)
      File.expand_path(File.join(File.dirname(directory), "#{File.basename(directory)}-receipt.json"), root)
    end

    def storefront_receipt_issues(root:, family:, receipt_path:, screenshot_paths:, source_identity:)
      prefix = "#{family} storefront receipt"
      issues = safe_storefront_file_issues(root, receipt_path, prefix, require_private: true)
      return issues unless issues.empty?

      receipt = JSON.parse(File.read(receipt_path, encoding: Encoding::UTF_8))
      commit = source_identity[:commit].to_s
      branch = source_identity[:branch].to_s
      issues << "#{prefix} status is not passed" unless receipt['status'].to_s == 'passed'
      issues << "#{prefix} commit does not match current pushed source" unless
        !commit.empty? && receipt['git_commit'].to_s == commit
      issues << "#{prefix} branch does not match current pushed source" unless
        !branch.empty? && receipt['git_branch'].to_s == branch
      issues << "#{prefix} is not bound to its pushed upstream commit" unless
        receipt['git_pushed'] == true && receipt['git_upstream_commit'].to_s == commit
      issues << "#{prefix} reports dirty source" unless receipt['git_dirty'] == false

      evidence, evidence_issues = storefront_image_evidence(receipt, prefix)
      issues.concat(evidence_issues)
      selected = {}
      screenshot_paths.each do |path|
        file_issues = safe_storefront_file_issues(root, path, "#{family} screenshot", require_private: false)
        issues.concat(file_issues)
        next unless file_issues.empty?

        selected[storefront_relative_path(root, path)] = path
      end
      evidence_by_path = Hash.new { |hash, key| hash[key] = [] }
      evidence.each do |row|
        evidence_path = File.expand_path(row.fetch('path'), root)
        file_issues = safe_storefront_file_issues(
          root, evidence_path, "#{prefix} image", require_private: false
        )
        issues.concat(file_issues)
        next unless file_issues.empty?

        evidence_by_path[storefront_relative_path(root, evidence_path)] << row
      end
      evidence_by_path.each do |relative, rows|
        issues << "#{prefix} binds screenshot path more than once: #{relative}" if rows.length > 1
        issues << "#{prefix} binds unselected screenshot: #{relative}" unless selected.key?(relative)
      end
      selected.each do |relative, path|
        rows = evidence_by_path.fetch(relative, [])
        if rows.empty?
          issues << "#{prefix} does not bind screenshot #{File.basename(path)}"
          next
        end
        next unless rows.length == 1

        row = rows.first
        issues << "#{prefix} hash does not match #{File.basename(path)}" unless
          row['sha256'].to_s == Digest::SHA256.file(path).hexdigest
        if !row['bytes'].is_a?(Integer)
          issues << "#{prefix} byte count is missing for #{File.basename(path)}"
        elsif row['bytes'] != File.size(path)
          issues << "#{prefix} byte count does not match #{File.basename(path)}"
        end
      end
      issues
    rescue JSON::ParserError => error
      ["#{prefix} is not valid JSON: #{error.message}"]
    rescue StandardError => error
      ["#{prefix} could not be verified: #{error.message}"]
    end

    def storefront_image_evidence(receipt, prefix)
      states = receipt['states']
      entries = receipt['entries']
      if states.is_a?(Array) && entries.is_a?(Array)
        return [[], ["#{prefix} image evidence is ambiguous"]]
      end
      rows = if states.is_a?(Array)
               states
             elsif receipt['schema'].to_s == 'sanelot.app_store_ipad_selection.v1' && entries.is_a?(Array)
               entries
             end
      return [[], ["#{prefix} image evidence is missing or not an array"]] unless rows

      issues = []
      selected_rows = rows.each_with_index.each_with_object([]) do |(row, index), selected|
        unless row.is_a?(Hash) && row['path'].to_s.match?(/\.(?:png|jpe?g)\z/i) &&
               row['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
          issues << "#{prefix} state #{index} lacks one image path and SHA-256"
          next
        end
        selected << row
      end
      [selected_rows, issues]
    end

    def storefront_ipad_visual_issues(root:, screenshots_config:, source_identity:)
      receipt_setting = screenshots_config['ipad_gate_receipt'].to_s
      verdict_setting = screenshots_config['ipad_visual_verdict'].to_s
      issues = []
      issues << 'ipad aggregate receipt path is not configured' if receipt_setting.empty?
      issues << 'ipad visual verdict path is not configured' if verdict_setting.empty?
      return issues unless issues.empty?

      receipt_path = File.expand_path(receipt_setting, root)
      verdict_path = File.expand_path(verdict_setting, root)
      issues.concat(safe_storefront_file_issues(
        root, receipt_path, 'ipad aggregate receipt', require_private: true
      ))
      issues.concat(safe_storefront_file_issues(
        root, verdict_path, 'ipad visual verdict', require_private: true
      ))
      return issues unless issues.empty?

      receipt = JSON.parse(File.read(receipt_path, encoding: Encoding::UTF_8))
      verdict = JSON.parse(File.read(verdict_path, encoding: Encoding::UTF_8))
      commit = source_identity[:commit].to_s
      branch = source_identity[:branch].to_s
      issues << 'ipad aggregate receipt status is not passed' unless receipt['status'].to_s == 'passed'
      issues << 'ipad aggregate receipt commit does not match current pushed source' unless
        receipt['git_commit'].to_s == commit
      issues << 'ipad aggregate receipt branch does not match current pushed source' unless
        receipt['git_branch'].to_s == branch
      issues << 'ipad aggregate receipt is not bound to its pushed upstream commit' unless
        receipt['git_pushed'] == true && receipt['git_upstream_commit'].to_s == commit
      issues << 'ipad aggregate receipt reports dirty source' unless receipt['git_dirty'] == false
      state_count = receipt['state_count']
      states = receipt['states']
      issues << 'ipad aggregate receipt state inventory is invalid' unless
        state_count.is_a?(Integer) && state_count.positive? && states.is_a?(Array) && states.length == state_count

      binding = verdict['source_binding'].is_a?(Hash) ? verdict['source_binding'] : {}
      issues << 'ipad visual verdict status is not passed' unless verdict['status'].to_s == 'passed'
      issues << 'ipad visual verdict does not clear release' unless verdict['release_clearance'] == true
      issues << 'ipad visual verdict was not inspected at original size' unless
        verdict['inspected_at_original_size'] == true
      inspected = verdict['inspected_count']
      passed = verdict['passed_count']
      failed = verdict['failed_count']
      failed_states = verdict['failed_states']
      issues << 'ipad visual verdict counts do not prove every aggregate state passed' unless
        inspected == state_count && passed == state_count && failed == 0 && failed_states == []
      issues << 'ipad visual verdict commit does not match current pushed source' unless
        binding['git_commit'].to_s == commit
      issues << 'ipad visual verdict aggregate receipt hash does not match' unless
        binding['aggregate_receipt_sha256'].to_s == Digest::SHA256.file(receipt_path).hexdigest
      issues << 'ipad visual verdict source manifest does not match aggregate receipt' unless
        !receipt['source_manifest_sha256'].to_s.empty? &&
        binding['source_manifest_sha256'].to_s == receipt['source_manifest_sha256'].to_s
      issues
    rescue JSON::ParserError => error
      ["ipad visual evidence is not valid JSON: #{error.message}"]
    rescue StandardError => error
      ["ipad visual evidence could not be verified: #{error.message}"]
    end

    def storefront_relative_path(root, path)
      _real_root, _expanded, relative = storefront_bound_path(root, path)
      raise "storefront image is the project root: #{path}" if relative.empty?

      relative
    end

    def safe_storefront_file_issues(root, path, label, require_private:)
      root, expanded, = storefront_bound_path(root, path)

      cursor = root
      expanded.delete_prefix(root).split('/').reject(&:empty?).each do |component|
        cursor = File.join(cursor, component)
        return ["#{label} path is missing: #{cursor}"] unless File.exist?(cursor) || File.symlink?(cursor)
        stat = File.lstat(cursor)
        return ["#{label} path contains a symlink: #{cursor}"] if stat.symlink?
      end
      stat = File.lstat(expanded)
      return ["#{label} is not a regular file: #{expanded}"] unless stat.file?
      return ["#{label} mode is not 0600"] if require_private && (stat.mode & 0o777) != 0o600

      []
    rescue ArgumentError
      ["#{label} escapes the project root"]
    rescue Errno::ENOENT
      ["#{label} is missing: #{expanded}"]
    end

    def storefront_bound_path(root, path)
      lexical_root = File.expand_path(root.to_s)
      real_root = File.realpath(lexical_root)
      expanded = File.expand_path(path.to_s, lexical_root)
      relative = if expanded == lexical_root
                   ''
                 elsif expanded.start_with?("#{lexical_root}/")
                   expanded.delete_prefix("#{lexical_root}/")
                 elsif expanded.start_with?("#{real_root}/")
                   expanded.delete_prefix("#{real_root}/")
                 end
      raise ArgumentError, "path escapes project root: #{path}" if relative.nil?

      [real_root, File.expand_path(relative, real_root), relative]
    end
  end
end
