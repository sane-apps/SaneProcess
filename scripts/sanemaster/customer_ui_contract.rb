# frozen_string_literal: true

require 'digest'
require 'date'
require 'json'
require 'open3'
require 'socket'
require 'time'
require 'yaml'

module SaneMasterModules
  # Release-blocking customer-facing UI/UX action contract.
  module CustomerUIContract
    CUSTOMER_UI_MANIFEST_PATHS = [
      'Tests/CustomerUIActions.yml',
      'tests/customer_ui_actions.yml',
      'config/customer_ui_actions.yml',
      '.sane/customer_ui_actions.yml'
    ].freeze
    CUSTOMER_UI_RECEIPT_PATHS = [
      'outputs/customer_ui_action_receipt.json',
      '.sane/customer_ui_action_receipt.json'
    ].freeze
    CUSTOMER_UI_SWEEP_PATHS = [
      'scripts/customer_ui_action_sweep.rb',
      'Scripts/customer_ui_action_sweep.rb',
      'scripts/customer_ui_qa.rb',
      'Scripts/customer_ui_qa.rb'
    ].freeze
    CUSTOMER_UI_PROOF_LEVELS = %w[
      source_guard
      unit_guard
      fixture_completion
      safe_first_surface
      runtime_visual
      full_runtime_completion
      manual_verification
    ].freeze
    CUSTOMER_UI_FAILURE_CLASSES = %w[
      activation_noop
      context_menu_extension_missing
      data_loss_or_unexpected_mutation
      docs_promise_drift
      duplicate_or_stale_menu_item
      external_integration_stub
      hardware_or_tcc_runtime
      install_update_packaging
      layout_visual_regression
      menu_entry_missing
      permission_recovery_dead_end
      persistence_or_relaunch_reset
      pro_basic_gate_drift
      shortcut_focus_or_dispatch
      state_count_drift
    ].freeze
    CUSTOMER_UI_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg].freeze
    CUSTOMER_UI_MIN_SCREENSHOT_WIDTH = 80
    CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT = 80
    CUSTOMER_UI_PATH_BACKED_EVIDENCE_TYPES = %w[
      actual_output
      api_response
      automation_transcript
      file_state
      fixture
      log
      mini_click
      mini_screenshot
      model_response
      screenshot
      visual_screenshot
      visual_smoke
    ].freeze
    CUSTOMER_UI_WORKFLOW_PROOF_LEVELS = %w[
      runtime_visual
      full_runtime_completion
    ].freeze
    CUSTOMER_UI_VISUAL_PRECHECK_REQUIRED_PROOF_LEVELS = %w[
      safe_first_surface
      runtime_visual
      full_runtime_completion
    ].freeze
    CUSTOMER_UI_SOURCE_EXTENSIONS = %w[
      .swift .rb .sh .yml .yaml .json .plist .xcconfig .entitlements .xcstrings
    ].freeze

    def customer_ui_contract(args = [])
      report = customer_ui_contract_report(config: current_saneprocess_config)
      if args.include?('--json')
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_contract_report(report)
      end
      exit 1 unless report[:ok] || args.include?('--no-exit')
      report
    end

    def customer_ui_sweep(args = [])
      json = args.include?('--json')
      dry_run = args.include?('--dry-run')
      report = customer_ui_sweep_report(dry_run: dry_run)
      if json
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_sweep_report(report)
      end
      exit 1 unless report[:ok] || args.include?('--no-exit')
      report
    end

    def customer_ui_sweep_report(dry_run: false)
      config = current_saneprocess_config
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      script_path = CUSTOMER_UI_SWEEP_PATHS.find { |path| File.file?(path) }
      unless script_path
        return {
          ok: false,
          app: app_name,
          script_path: nil,
          issues: ["Missing customer UI workflow runner (expected one of: #{CUSTOMER_UI_SWEEP_PATHS.join(', ')})"]
        }
      end

      unless customer_ui_mini_host? || dry_run
        return {
          ok: false,
          app: app_name,
          script_path: script_path,
          issues: ["customer_ui_sweep must run on the Mini; current host=#{Socket.gethostname.inspect} user=#{ENV.fetch('USER', '')}"]
        }
      end

      if dry_run
        return {
          ok: true,
          app: app_name,
          script_path: script_path,
          dry_run: true,
          issues: []
        }
      end

      cleanup_issues = customer_ui_cleanup_before_sweep(app_name)
      return { ok: false, app: app_name, script_path: script_path, issues: cleanup_issues } unless cleanup_issues.empty?

      visual_precheck = customer_ui_visual_precheck(app_name)
      return { ok: false, app: app_name, script_path: script_path, issues: visual_precheck[:issues] } unless visual_precheck[:ok]

      output, status = customer_ui_run_command('ruby', script_path)
      return { ok: false, app: app_name, script_path: script_path, issues: ["Customer UI workflow runner failed: #{output}"] } unless status.success?

      contract = customer_ui_contract_report(config: config)
      {
        ok: contract[:ok],
        app: app_name,
        script_path: script_path,
        contract: contract,
        runner_output: output,
        issues: Array(contract[:issues])
      }
    end

    def customer_ui_contract_report(config:)
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      receipt_path = CUSTOMER_UI_RECEIPT_PATHS.find { |path| File.exist?(path) }
      issues = []
      warnings = []

      unless manifest_path
        return {
          ok: false,
          app: app_name,
          manifest_path: nil,
          receipt_path: receipt_path,
          issues: ["Missing customer UI action contract (expected one of: #{CUSTOMER_UI_MANIFEST_PATHS.join(', ')})"],
          warnings: warnings
        }
      end

      manifest = read_customer_ui_yaml(manifest_path)
      actions = Array(manifest['actions'])
      required_actions = actions.reject { |action| action['release_required'] == false }

      issues << 'Customer UI action contract has no release-required actions' if required_actions.empty?
      issues.concat(customer_ui_manifest_issues(manifest_path, manifest, required_actions))

      manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
      source_fingerprint = customer_ui_source_fingerprint

      unless receipt_path
        issues << 'Missing fresh customer UI QA receipt (run the app-specific Mini click/screenshot sweep)'
        return {
          ok: false,
          app: app_name,
          manifest_path: manifest_path,
          receipt_path: nil,
          manifest_sha256: manifest_sha,
          source_fingerprint: source_fingerprint,
          action_count: required_actions.length,
          issues: issues,
          warnings: warnings
        }
      end

      receipt = read_customer_ui_json(receipt_path)
      issues.concat(customer_ui_receipt_issues(
        app_name: app_name,
        manifest_sha: manifest_sha,
        source_fingerprint: source_fingerprint,
        required_actions: required_actions,
        receipt: receipt
      ))

      {
        ok: issues.empty?,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        manifest_sha256: manifest_sha,
        source_fingerprint: source_fingerprint,
        action_count: required_actions.length,
        receipt_generated_at: receipt['generated_at'],
        issues: issues,
        warnings: warnings
      }
    rescue Psych::SyntaxError, JSON::ParserError => e
      {
        ok: false,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        issues: ["Customer UI QA contract parse failure: #{e.message}"],
        warnings: warnings
      }
    end

    def format_customer_ui_contract_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI ACTION CONTRACT ] ---'
      lines << "App: #{report[:app]}"
      if report[:ok]
        lines << "✅ #{report[:action_count]} release-required action(s) covered"
        lines << "   Manifest: #{report[:manifest_path]}"
        lines << "   Receipt: #{report[:receipt_path]}"
        lines << "   Generated: #{report[:receipt_generated_at]}"
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      Array(report[:warnings]).each { |warning| lines << "⚠️  #{warning}" }
      lines.join("\n")
    end

    def format_customer_ui_sweep_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI WORKFLOW SWEEP ] ---'
      lines << "App: #{report[:app]}"
      lines << "Runner: #{report[:script_path] || 'missing'}"
      if report[:dry_run]
        lines << '✅ Dry run: runner found'
      elsif report[:ok]
        lines << '✅ Workflow sweep and contract passed'
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      lines.join("\n")
    end

    private

    def customer_ui_mini_host?
      Socket.gethostname.downcase.include?('mini') || ENV.fetch('USER', '').downcase == 'stephansmac'
    end

    def customer_ui_run_command(*command)
      Open3.capture2e(*command)
    end

    def customer_ui_cleanup_before_sweep(app_name)
      guard = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/mini/mini-visual-workspace-guard.sh')
      return [] unless File.file?(guard)

      output, status = customer_ui_run_command(guard, '--cleanup', '--app', app_name, '--json')
      status.success? ? [] : ["Mini visual workspace cleanup failed before customer UI sweep: #{output}"]
    end

    def customer_ui_visual_precheck(app_name)
      return { ok: true, issues: [] } unless customer_ui_visual_precheck_required?

      out, status = customer_ui_run_command(
        './scripts/SaneMaster.rb',
        'visual_smoke',
        '--app',
        app_name,
        '--require-peekaboo',
        '--no-app',
        '--json'
      )
      unless status.success?
        return {
          ok: false,
          issues: ["Mini visual precheck failed before customer UI sweep: #{customer_ui_summarize_visual_precheck_failure(out)}"]
        }
      end

      report = JSON.parse(out)
      image_artifacts = Array(report['artifacts']).select do |path|
        CUSTOMER_UI_IMAGE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
      end
      usable_image_artifacts = image_artifacts.reject.with_index do |path, index|
        customer_ui_single_screenshot_issues(path.to_s, index).any?
      end
      if report['ok'] == true && usable_image_artifacts.any?
        { ok: true, issues: [] }
      else
        image_issues = image_artifacts.flat_map.with_index do |path, index|
          customer_ui_single_screenshot_issues(path.to_s, index)
        end
        reason = [report['reason'].to_s.strip, *image_issues].reject(&:empty?).join('; ')
        {
          ok: false,
          issues: ["Mini visual precheck did not produce usable screenshot evidence: #{reason}"]
        }
      end
    rescue JSON::ParserError => e
      { ok: false, issues: ["Mini visual precheck returned invalid JSON: #{e.message}"] }
    end

    def customer_ui_visual_precheck_required?
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      return false unless manifest_path

      manifest = read_customer_ui_yaml(manifest_path)
      Array(manifest['actions']).any? do |action|
        next false if action['release_required'] == false

        CUSTOMER_UI_VISUAL_PRECHECK_REQUIRED_PROOF_LEVELS.include?(action['required_proof_level'].to_s) ||
          required_evidence_types(action).any? { |type| %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(type) } ||
          action['requires_visual'] == true ||
          action['requires_visual_evidence'] == true
      end
    rescue Psych::SyntaxError
      true
    end

    def customer_ui_summarize_visual_precheck_failure(output)
      parsed = JSON.parse(output)
      reason = parsed['reason'].to_s.strip
      cleanliness = Array(parsed.dig('cleanliness', 'issues')).map(&:to_s).reject(&:empty?)
      summary = ([reason] + cleanliness).reject(&:empty?).join('; ')
      return summary unless summary.empty?

      output.to_s.lines.last(6).map(&:strip).reject(&:empty?).join(' | ')
    rescue JSON::ParserError
      output.to_s.lines.last(6).map(&:strip).reject(&:empty?).join(' | ')
    end

    def current_saneprocess_config
      path = File.join(Dir.pwd, '.saneprocess')
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    def read_customer_ui_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [Time, Date], aliases: false) || {}
    end

    def read_customer_ui_json(path)
      JSON.parse(File.read(path))
    end

    def customer_ui_manifest_issues(manifest_path, manifest, required_actions)
      issues = []
      issues << "Manifest app does not match .saneprocess name" if manifest['app'] && manifest['app'].to_s != (metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd)).to_s

      ids = []
      required_actions.each_with_index do |action, index|
        id = action['id'].to_s.strip
        ids << id
        prefix = id.empty? ? "action ##{index + 1}" : id
        issues << "#{prefix}: missing id" if id.empty?
        issues << "#{prefix}: missing title" if action['title'].to_s.strip.empty?
        issues << "#{prefix}: missing customer surface" if Array(action['surfaces']).empty?
        issues << "#{prefix}: missing click/interaction steps" if Array(action['steps']).empty?
        issues << "#{prefix}: missing assertions" if Array(action['assertions']).empty?
        issues << "#{prefix}: missing evidence requirement" if Array(action['evidence']).empty?
        proof_level = action['required_proof_level'].to_s.strip
        if proof_level.empty?
          issues << "#{prefix}: missing required_proof_level"
        elsif !CUSTOMER_UI_PROOF_LEVELS.include?(proof_level)
          issues << "#{prefix}: invalid required_proof_level #{proof_level.inspect}"
        end
        evidence_types = action['required_evidence_types']
        if evidence_types && !(evidence_types.is_a?(Array) && evidence_types.all? { |item| item.to_s.strip != '' })
          issues << "#{prefix}: required_evidence_types must be a non-empty list when present"
        end
        failure_classes = action['historical_failure_classes']
        if failure_classes.nil?
          issues << "#{prefix}: missing historical_failure_classes; every release action must name the prior customer failure class it guards against"
        elsif !(failure_classes.is_a?(Array) && failure_classes.all? { |item| CUSTOMER_UI_FAILURE_CLASSES.include?(item.to_s.strip) })
          issues << "#{prefix}: historical_failure_classes must use known values: #{CUSTOMER_UI_FAILURE_CLASSES.join(', ')}"
        end
        issues.concat(customer_ui_functional_state_manifest_issues(prefix, action))
      end

      id_counts = Hash.new(0)
      ids.reject(&:empty?).each { |id| id_counts[id] += 1 }
      duplicate_ids = id_counts.select { |_id, count| count > 1 }.keys
      issues << "Duplicate customer UI action ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
      issues << "#{manifest_path}: version must be 1" unless manifest['version'].to_i == 1
      issues
    end

    def customer_ui_functional_state_manifest_issues(prefix, action)
      issues = []
      state = action['functional_state']
      unless state.is_a?(Hash)
        issues << "#{prefix}: missing functional_state; every customer action must declare the seeded app/user state needed to test promised behavior"
        state = {}
      end

      description = state['description'].to_s.strip
      setup_steps = Array(state['setup_steps']).map(&:to_s).map(&:strip).reject(&:empty?)
      fixture_paths = Array(state['fixture_paths']).map(&:to_s).map(&:strip).reject(&:empty?)
      not_required_reason = state['not_required_reason'].to_s.strip

      issues << "#{prefix}: functional_state missing description" if description.empty?
      if setup_steps.empty? && fixture_paths.empty? && not_required_reason.empty?
        issues << "#{prefix}: functional_state must include setup_steps, fixture_paths, or not_required_reason"
      end

      user_inputs = Array(action['user_inputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      expected_outputs = Array(action['expected_outputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      if %w[fixture_completion full_runtime_completion].include?(action['required_proof_level'].to_s)
        issues << "#{prefix}: full/fixture completion actions must declare user_inputs or fixture_paths" if user_inputs.empty? && fixture_paths.empty?
        issues << "#{prefix}: full/fixture completion actions must declare expected_outputs" if expected_outputs.empty?
      end

      issues
    end

    def customer_ui_receipt_issues(app_name:, manifest_sha:, source_fingerprint:, required_actions:, receipt:)
      issues = []
      issues << "Receipt app #{receipt['app']} does not match #{app_name}" if receipt['app'].to_s != app_name.to_s
      issues << "Receipt status is #{receipt['status'].inspect}, expected \"passed\"" unless receipt['status'].to_s == 'passed'
      issues << 'Receipt was not generated on the Mini' unless receipt['host'].to_s.downcase == 'mini'
      issues << 'Receipt manifest hash is stale' unless receipt['manifest_sha256'].to_s == manifest_sha
      issues << 'Receipt source fingerprint is stale; rerun customer UI QA after the latest code change' unless receipt['source_fingerprint'].to_s == source_fingerprint
      issues << 'Receipt is missing screenshot evidence' if Array(receipt['screenshots']).empty?
      issues.concat(customer_ui_screenshot_issues(Array(receipt['screenshots'])))

      tested_ids = Array(receipt['tested_action_ids']).map(&:to_s)
      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      missing_ids = required_ids - tested_ids
      issues << "Receipt does not cover release-required action(s): #{missing_ids.join(', ')}" unless missing_ids.empty?
      issues.concat(customer_ui_action_result_issues(required_actions, receipt))

      begin
        generated_at = Time.parse(receipt['generated_at'].to_s)
        issues << 'Receipt is older than 12 hours; rerun customer UI QA for this release' if Time.now - generated_at > 12 * 60 * 60
      rescue ArgumentError
        issues << 'Receipt generated_at is missing or invalid'
      end

      issues
    end

    def customer_ui_action_result_issues(required_actions, receipt)
      issues = []
      results = receipt['action_results']
      unless results.is_a?(Hash)
        return ['Receipt is missing per-action results; do not mark customer-facing actions covered from a coarse smoke bucket']
      end

      required_actions.each do |action|
        id = action['id'].to_s
        result = results[id]
        if result.nil?
          issues << "#{id}: missing per-action result"
          next
        end

        unless result.is_a?(Hash)
          issues << "#{id}: per-action result must be an object"
          next
        end

        issues << "#{id}: status is #{result['status'].inspect}, expected \"passed\"" unless result['status'].to_s == 'passed'
        required_proof_level = action['required_proof_level'].to_s
        proof_level = result['proof_level'].to_s.strip
        if proof_level.empty?
          issues << "#{id}: missing proof_level; source/test/safe-surface notes cannot silently count as release proof"
        elsif !CUSTOMER_UI_PROOF_LEVELS.include?(proof_level)
          issues << "#{id}: invalid proof_level #{proof_level.inspect}"
        elsif !customer_ui_proof_satisfies?(proof_level, required_proof_level)
          issues << "#{id}: proof_level #{proof_level.inspect} does not satisfy required_proof_level #{required_proof_level.inspect}"
        end

        evidence = Array(result['evidence'])
        issues << "#{id}: missing per-action evidence" if evidence.empty?
        evidence_types = []
        evidence.each_with_index do |item, index|
          if item.is_a?(Hash)
            evidence_type = item['type'].to_s.strip
            evidence_types << evidence_type unless evidence_type.empty?
            issues << "#{id}: evidence ##{index + 1} missing type" if evidence_type.empty?
            issues << "#{id}: evidence ##{index + 1} missing detail" if item['detail'].to_s.strip.empty?
            issues.concat(customer_ui_evidence_artifact_issues(id, item, index))
          elsif item.to_s.strip.empty?
            issues << "#{id}: evidence ##{index + 1} is blank"
          end
        end
        required_evidence_types(action).each do |required_type|
          next if evidence_types.include?(required_type)

          issues << "#{id}: missing required evidence type #{required_type.inspect}"
        end
        if customer_ui_action_requires_visual?(action, result) &&
           evidence_types.none? { |type| %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(type) }
          issues << "#{id}: visual proof required but no screenshot/visual evidence is attached to the action result"
        end
        issues.concat(customer_ui_functional_state_receipt_issues(id, action, result))
        issues.concat(customer_ui_workflow_receipt_issues(id, action, result))
      end

      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      extra_ids = results.keys.map(&:to_s) - required_ids
      issues << "Receipt has per-action result(s) not in manifest: #{extra_ids.join(', ')}" unless extra_ids.empty?
      issues
    end

    def customer_ui_functional_state_receipt_issues(id, action, result)
      issues = []
      state = result['functional_state']
      unless state.is_a?(Hash)
        issues << "#{id}: missing functional_state proof; clicks only count after the required user/app state is established"
        state = {}
      end

      status = state['status'].to_s.strip
      unless %w[established not_required].include?(status)
        issues << "#{id}: functional_state status must be established or not_required"
      end
      issues << "#{id}: functional_state proof missing detail" if state['detail'].to_s.strip.empty?
      if status == 'not_required' && action.dig('functional_state', 'not_required_reason').to_s.strip.empty?
        issues << "#{id}: receipt says functional state is not required but manifest does not declare why"
      end

      if Array(action['user_inputs']).any?
        inputs = Array(result['inputs']).map(&:to_s).map(&:strip).reject(&:empty?)
        issues << "#{id}: missing exercised user inputs from receipt" if inputs.empty?
      end

      expected_outputs = Array(action['expected_outputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      if expected_outputs.any?
        output_assertions = Array(result['output_assertions']).map(&:to_s).map(&:strip).reject(&:empty?)
        issues << "#{id}: missing output_assertions proving expected outcomes" if output_assertions.empty?
      end

      if %w[fixture_completion full_runtime_completion].include?(action['required_proof_level'].to_s)
        evidence_types = Array(result['evidence']).map do |item|
          item['type'].to_s.strip if item.is_a?(Hash)
        end.compact
        unless evidence_types.any? { |type| %w[fixture actual_output log file_state api_response model_response].include?(type) }
          issues << "#{id}: completion proof requires fixture, actual output, log, file state, API response, or model response evidence"
        end
      end

      issues
    end

    def customer_ui_workflow_receipt_issues(id, action, result)
      proof_level = result['proof_level'].to_s
      return [] unless CUSTOMER_UI_WORKFLOW_PROOF_LEVELS.include?(proof_level)

      workflow = result['workflow']
      unless workflow.is_a?(Hash)
        return ["#{id}: missing structured workflow proof; runtime evidence must name the runner, completed steps, outcome, and artifacts"]
      end

      issues = []
      issues << "#{id}: workflow proof missing runner" if workflow['runner'].to_s.strip.empty?
      issues << "#{id}: workflow proof missing outcome" if workflow['outcome'].to_s.strip.empty?

      completed_steps = Array(workflow['steps_completed']).map(&:to_s).map(&:strip).reject(&:empty?)
      issues << "#{id}: workflow proof missing steps_completed" if completed_steps.empty?
      declared_steps = Array(action['steps']).map(&:to_s).map(&:strip).reject(&:empty?)
      missing_steps = declared_steps - completed_steps
      unless missing_steps.empty?
        issues << "#{id}: workflow proof did not complete declared step(s): #{missing_steps.join(' | ')}"
      end

      artifacts = Array(workflow['artifacts']).map(&:to_s).map(&:strip).reject(&:empty?)
      issues << "#{id}: workflow proof missing artifacts" if artifacts.empty?
      artifacts.each_with_index do |path, index|
        issues.concat(customer_ui_generic_artifact_issues(
          path,
          label: "#{id}: workflow artifact ##{index + 1}",
          image_required: false
        ))
      end

      issues
    end

    def customer_ui_evidence_artifact_issues(id, item, index)
      evidence_type = item['type'].to_s.strip
      return [] unless CUSTOMER_UI_PATH_BACKED_EVIDENCE_TYPES.include?(evidence_type)

      paths = customer_ui_evidence_paths(item)
      label = "#{id}: evidence ##{index + 1} #{evidence_type}"
      return ["#{label} missing artifact path"] if paths.empty?

      image_required = %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(evidence_type)
      paths.flat_map.with_index do |path, path_index|
        customer_ui_generic_artifact_issues(
          path,
          label: "#{label} artifact ##{path_index + 1}",
          image_required: image_required
        )
      end
    end

    def customer_ui_evidence_paths(item)
      paths = []
      %w[path artifact file].each do |key|
        value = item[key]
        paths.concat(Array(value)) unless value.nil?
      end
      paths.concat(Array(item['artifacts'])) unless item['artifacts'].nil?
      paths.map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def customer_ui_generic_artifact_issues(path, label:, image_required:)
      return ["#{label}: blank path"] if path.to_s.strip.empty?

      absolute = File.absolute_path(path, Dir.pwd)
      return ["#{label}: file does not exist: #{path}"] unless File.file?(absolute)

      return customer_ui_single_screenshot_issues(path, 0).map { |issue| issue.sub('screenshot #1', label) } if image_required

      []
    end

    def required_evidence_types(action)
      Array(action['required_evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def customer_ui_action_requires_visual?(action, result)
      return true if action['requires_visual'] == true || action['requires_visual_evidence'] == true

      required_evidence_types(action).any? { |type| %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(type) } ||
        Array(action['evidence']).any? { |item| item.to_s.downcase.include?('screenshot') } ||
        %w[runtime_visual full_runtime_completion].include?(result['proof_level'].to_s)
    end

    def customer_ui_proof_satisfies?(actual, required)
      return false unless CUSTOMER_UI_PROOF_LEVELS.include?(actual)
      return false unless CUSTOMER_UI_PROOF_LEVELS.include?(required)

      case required
      when 'source_guard'
        true
      when 'unit_guard'
        %w[unit_guard fixture_completion safe_first_surface runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'fixture_completion'
        %w[fixture_completion full_runtime_completion manual_verification].include?(actual)
      when 'safe_first_surface'
        %w[safe_first_surface runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'runtime_visual'
        %w[runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'full_runtime_completion'
        %w[full_runtime_completion manual_verification].include?(actual)
      when 'manual_verification'
        actual == 'manual_verification'
      else
        false
      end
    end

    def customer_ui_screenshot_issues(screenshots)
      screenshots.flat_map.with_index do |path, index|
        customer_ui_single_screenshot_issues(path.to_s, index)
      end
    end

    def customer_ui_single_screenshot_issues(path, index)
      label = "screenshot ##{index + 1}"
      return ["#{label}: blank path"] if path.strip.empty?

      absolute = File.absolute_path(path, Dir.pwd)
      return ["#{label}: file does not exist: #{path}"] unless File.file?(absolute)

      extension = File.extname(absolute).downcase
      unless CUSTOMER_UI_IMAGE_EXTENSIONS.include?(extension)
        return ["#{label}: unsupported artifact type #{extension.inspect}; expected PNG or JPEG screenshot"]
      end

      width, height = customer_ui_image_dimensions(absolute)
      return ["#{label}: could not read image dimensions"] unless width && height
      if width < CUSTOMER_UI_MIN_SCREENSHOT_WIDTH || height < CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT
        return ["#{label}: image is #{width}x#{height}, below #{CUSTOMER_UI_MIN_SCREENSHOT_WIDTH}x#{CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT}; placeholder screenshots are not release evidence"]
      end

      []
    end

    def customer_ui_image_dimensions(path)
      data = File.binread(path, 32)
      if data.start_with?("\x89PNG\r\n\x1A\n".b) && data.bytesize >= 24
        return data.byteslice(16, 8).unpack('NN')
      end

      output, status = Open3.capture2e('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path)
      return nil unless status.success?

      width = output[/pixelWidth:\s*(\d+)/, 1]&.to_i
      height = output[/pixelHeight:\s*(\d+)/, 1]&.to_i
      return nil unless width&.positive? && height&.positive?

      [width, height]
    rescue StandardError
      nil
    end

    def customer_ui_source_fingerprint
      digest = Digest::SHA256.new
      customer_ui_source_files.each do |path|
        next unless File.file?(path)

        digest.update(path)
        digest.update("\0")
        digest.update(Digest::SHA256.file(path).hexdigest)
        digest.update("\0")
      end
      digest.hexdigest
    end

    def customer_ui_source_files
      files = git_list_customer_ui_files
      files = filesystem_customer_ui_files if files.empty?
      files.select { |path| customer_ui_source_file?(path) }.uniq.sort
    end

    def git_list_customer_ui_files
      tracked, tracked_status = Open3.capture2e('git', 'ls-files', '-z')
      others, others_status = Open3.capture2e('git', 'ls-files', '--others', '--exclude-standard', '-z')
      files = []
      files.concat(tracked.split("\0")) if tracked_status.success?
      files.concat(others.split("\0")) if others_status.success?
      files
    rescue StandardError
      []
    end

    def filesystem_customer_ui_files
      Dir.glob('**/*', File::FNM_DOTMATCH).reject do |path|
        path.start_with?('.git/') || path.start_with?('outputs/') || File.directory?(path)
      end
    end

    def customer_ui_source_file?(path)
      return false if CUSTOMER_UI_RECEIPT_PATHS.include?(path)
      return false if path.start_with?('.sanemaster/')
      return true if CUSTOMER_UI_MANIFEST_PATHS.include?(path)
      return true if path == '.saneprocess' || path == 'project.yml' || path == 'Package.swift'
      return true if path.end_with?('.xcodeproj/project.pbxproj')
      return true if path.start_with?('Sane') || path.start_with?('Shared/')
      return true if path.start_with?('Sources/') || path.start_with?('Tests/')
      return true if path == 'scripts/qa.rb' || path == 'Scripts/qa.rb'
      return true if path.start_with?('scripts/customer_ui_qa') || path.start_with?('Scripts/customer_ui_qa')

      CUSTOMER_UI_SOURCE_EXTENSIONS.include?(File.extname(path)) &&
        !path.start_with?('docs/') &&
        !path.start_with?('website/') &&
        !path.start_with?('outputs/')
    end
  end
end
