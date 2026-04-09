# frozen_string_literal: true

module SaneMasterModules
  # Code quality checks: dead code, deprecations, Swift 6 compliance, test suite
  module Quality
    def find_dead_code
      puts '🔍 --- [ DEAD CODE DETECTION ] ---'

      unless system('which periphery > /dev/null 2>&1')
        puts '❌ Periphery not found. Install with: brew install peripheryapp/periphery/periphery'
        return
      end

      puts 'Scanning for unused code...'
      puts ''

      if project_workspace && !project_workspace.to_s.empty?
        container_path = File.join(Dir.pwd, project_workspace)
        container_args = ['--workspace', container_path]
      else
        container_path = File.join(Dir.pwd, project_xcodeproj)
        container_args = ['--project', container_path]
      end

      unless File.exist?(container_path)
        puts "❌ Project not found at #{container_path}"
        return
      end

      build_args = [
        *container_args,
        '--schemes', project_scheme,
        '--format', 'xcode'
      ]

      system('periphery', 'scan', *build_args)

      exit_code = $CHILD_STATUS.exitstatus

      puts ''
      if exit_code.zero?
        puts '✅ No unused code detected!'
      else
        puts '⚠️  Unused code detected. Review the output above.'
        puts '💡 Tip: Review each item carefully before removing - some may be used via reflection or tests.'
      end
    end

    def check_deprecations
      puts '🔍 --- [ DEPRECATION WARNINGS CHECK ] ---'
      puts 'Scanning for deprecated API usage...'
      puts ''

      if project_workspace && !project_workspace.to_s.empty?
        container_path = File.join(Dir.pwd, project_workspace)
        container_args = ['-workspace', container_path]
      else
        container_path = File.join(Dir.pwd, project_xcodeproj)
        container_args = ['-project', container_path]
      end

      unless File.exist?(container_path)
        puts "❌ Project not found at #{container_path}"
        return
      end

      puts 'Building to capture deprecation warnings...'
      puts ''

      build_output = `xcodebuild #{container_args.join(' ')} -scheme #{project_scheme} -destination 'platform=macOS,arch=arm64' clean build 2>&1`

      deprecation_warnings = extract_deprecation_warnings(build_output)

      if deprecation_warnings.empty?
        puts '✅ No deprecation warnings found!'
        return
      end

      puts "⚠️  Found #{deprecation_warnings.length} deprecation warning(s):"
      puts ''

      warnings_by_file = group_warnings_by_file(deprecation_warnings)
      display_grouped_warnings(warnings_by_file)
      display_fixable_deprecations(deprecation_warnings)

      puts ''
      puts "⚠️  Total: #{deprecation_warnings.length} deprecation warning(s)"
      puts '💡 Tip: Review each warning and update to modern APIs when possible'
    end

    def swift6_check
      puts '🔍 --- [ SWIFT 6 CONCURRENCY COMPLIANCE ] ---'
      puts 'Scanning for concurrency patterns...'
      puts ''

      source_dir = File.join(Dir.pwd, project_app_dir)
      unless File.directory?(source_dir)
        puts "❌ Source directory not found: #{source_dir}"
        return
      end

      patterns = concurrency_patterns
      problems = []

      swift_files = Dir.glob("#{source_dir}/**/*.swift")
      swift_files.each do |file|
        content = File.read(file)
        rel_path = file.sub("#{Dir.pwd}/", '')

        scan_concurrency_patterns(content, rel_path, patterns)
        problems.concat(find_concurrency_problems(content, rel_path))
      end

      display_concurrency_report(patterns, problems)
      check_strict_concurrency_setting
    end

    def run_test_suite(args)
      quick_mode = args.include?('--quick')
      full_mode = args.include?('--full')
      ci_mode = args.include?('--ci')

      puts '🧪 --- [ COMPREHENSIVE TEST SUITE ] ---'
      puts 'Running all available validation tools...'
      puts ''

      results = { passed: [], failed: [], warnings: [], skipped: [] }

      run_fast_validation(results)
      return if results[:failed].include?('Build')

      run_medium_validation(results, quick_mode, full_mode, ci_mode)
      run_deep_analysis(results, full_mode, ci_mode)

      print_test_suite_summary(results)
      exit(results[:failed].any? ? 1 : 0)
    end

    def print_test_suite_summary(results)
      puts "\n#{'=' * 50}"
      puts '📊 TEST SUITE SUMMARY'
      puts '=' * 50

      print_result_section('✅ PASSED', results[:passed]) if results[:passed].any?
      print_result_section('❌ FAILED', results[:failed]) if results[:failed].any?
      print_result_section('⚠️  WARNINGS', results[:warnings]) if results[:warnings].any?
      print_result_section('⏭️  SKIPPED', results[:skipped]) if results[:skipped].any?

      total = results[:passed].count + results[:failed].count + results[:warnings].count
      puts "\n📈 Total Checks: #{total}"
      puts "   ✅ Passed: #{results[:passed].count}"
      puts "   ❌ Failed: #{results[:failed].count}"
      puts "   ⚠️  Warnings: #{results[:warnings].count}"

      print_test_suite_conclusion(results)
    end

    private

    def extract_deprecation_warnings(build_output)
      build_output.lines.select do |line|
        line.downcase.include?('deprecated') ||
          line.include?('was deprecated') ||
          line.include?('is deprecated')
      end.map(&:strip).reject(&:empty?).uniq
    end

    def group_warnings_by_file(warnings)
      warnings_by_file = {}
      warnings.each do |warning|
        if warning =~ /^([^:]+\.swift):(\d+):(\d+):\s+warning:\s+(.+)$/
          file = File.basename(::Regexp.last_match(1))
          line = ::Regexp.last_match(2)
          message = ::Regexp.last_match(4)
          warnings_by_file[file] ||= []
          warnings_by_file[file] << { line: line, message: message }
        elsif warning.include?('warning:') && warning.include?('.swift')
          parts = warning.split(':')
          if parts.length >= 4
            file = File.basename(parts[0])
            line = parts[1]
            message = parts[3..].join(':').strip
            warnings_by_file[file] ||= []
            warnings_by_file[file] << { line: line, message: message }
          end
        else
          warnings_by_file['[Other]'] ||= []
          warnings_by_file['[Other]'] << { line: nil, message: warning }
        end
      end
      warnings_by_file
    end

    def display_grouped_warnings(warnings_by_file)
      warnings_by_file.each do |file, warnings|
        puts "📄 #{file}"
        warnings.each do |w|
          if w[:line]
            puts "   Line #{w[:line]}: #{w[:message]}"
          else
            puts "   #{w[:message]}"
          end
        end
        puts ''
      end
    end

    def display_fixable_deprecations(warnings)
      fixable = []
      warnings.each do |warning|
        if warning.include?('CIColorKernel') && warning.include?('init(source:)')
          fixable << 'CIColorKernel.init(source:) - Consider using Metal-based CIKernel or suppress with CI_SILENCE_GL_DEPRECATION'
        elsif warning.include?('onChange(of:perform:)')
          fixable << 'onChange(of:perform:) - Already fixed (uses new onChange syntax)'
        elsif warning.include?('AVAssetExportSession.export()')
          fixable << 'AVAssetExportSession.export() - Documented with TODO, consider migrating to states(updateInterval:)'
        end
      end

      return unless fixable.any?

      puts '💡 Known deprecations:'
      fixable.uniq.each { |f| puts "   - #{f}" }
      puts ''
    end

    def concurrency_patterns
      {
        '@MainActor' => { count: 0, files: [], description: 'Main actor isolated types/methods' },
        'actor ' => { count: 0, files: [], description: 'Custom actors' },
        'nonisolated' => { count: 0, files: [], description: 'Non-isolated members' },
        '@Sendable' => { count: 0, files: [], description: 'Sendable closures' },
        '@unchecked Sendable' => { count: 0, files: [], description: 'Unchecked Sendable conformances' },
        'nonisolated(unsafe)' => { count: 0, files: [], description: 'Unsafe nonisolated (for threading edge cases)' },
        'Task { @MainActor' => { count: 0, files: [], description: 'Tasks dispatched to MainActor' },
        'Task.detached' => { count: 0, files: [], description: 'Detached tasks' },
        ': Sendable' => { count: 0, files: [], description: 'Sendable protocol conformance' }
      }
    end

    def scan_concurrency_patterns(content, rel_path, patterns)
      patterns.each do |pattern, data|
        matches = content.scan(/#{Regexp.escape(pattern)}/).count
        next unless matches.positive?

        data[:count] += matches
        data[:files] << rel_path unless data[:files].include?(rel_path)
      end
    end

    def find_concurrency_problems(content, rel_path)
      problems = []
      lines = content.lines

      lines.each_with_index do |line, idx|
        line_num = idx + 1

        if line.include?('DispatchQueue.main') && !line.include?('//')
          problems << { file: rel_path, line: line_num, issue: 'DispatchQueue.main - consider Task { @MainActor }' }
        end

        if line =~ /completion:\s*@escaping\s+\(/ && !line.include?('@Sendable')
          problems << { file: rel_path, line: line_num, issue: 'Completion handler may need @Sendable' }
        end

        if line.include?('assumeIsolated') && content.include?('deinit')
          problems << { file: rel_path, line: line_num, issue: 'assumeIsolated near deinit - potential crash' }
        end
      end

      problems
    end

    def display_concurrency_report(patterns, problems)
      puts '📊 Concurrency Pattern Usage:'
      puts ''

      patterns.each_value do |data|
        emoji = data[:count].positive? ? '✅' : '⚪'
        puts "  #{emoji} #{data[:description]}: #{data[:count]} usages in #{data[:files].length} files"
      end

      total_usages = patterns.values.map { |d| d[:count] }.sum
      puts ''
      puts "  📈 Total concurrency annotations: #{total_usages}"

      grade = calculate_swift6_grade(total_usages, patterns)
      puts ''
      puts "  🎯 Swift 6 Readiness Grade: #{grade}"
      puts ''

      display_concurrency_problems(problems)
      display_swift6_recommendations
    end

    def calculate_swift6_grade(total_usages, patterns)
      if total_usages > 400 && patterns['actor '][:count] > 10
        'A'
      elsif total_usages > 200 && patterns['@MainActor'][:count] > 20
        'B'
      elsif total_usages > 50
        'C'
      else
        'D'
      end
    end

    def display_concurrency_problems(problems)
      if problems.any?
        puts '⚠️  Potential Issues Found:'
        problems.group_by { |p| p[:file] }.each do |file, issues|
          puts "  📄 #{file}"
          issues.each do |issue|
            puts "     Line #{issue[:line]}: #{issue[:issue]}"
          end
        end
      else
        puts '✅ No potential concurrency issues detected!'
      end
      puts ''
    end

    def display_swift6_recommendations
      puts '💡 Swift 6 Recommendations:'
      puts '   - All public types with mutable state should be actors or @MainActor'
      puts '   - Use Task { @MainActor in } instead of DispatchQueue.main.async'
      puts '   - Mark completion handlers as @Sendable for cross-actor safety'
      puts '   - Use nonisolated for computed properties that access immutable data'
      puts ''
    end

    def check_strict_concurrency_setting
      project_file = File.join(Dir.pwd, 'project.yml')
      return unless File.exist?(project_file)

      yml_content = File.read(project_file)
      if yml_content.include?('SWIFT_STRICT_CONCURRENCY') && yml_content.include?('complete')
        puts '✅ Strict concurrency checking enabled (complete mode)'
      elsif yml_content.include?('SWIFT_STRICT_CONCURRENCY')
        puts '⚠️  Strict concurrency checking enabled (consider upgrading to complete)'
      else
        puts '⚠️  Consider adding SWIFT_STRICT_CONCURRENCY: complete to project.yml'
      end
    end

    def run_fast_validation(results)
      puts '📋 Phase 1: Fast Validation Checks'
      puts '─' * 50

      check_build(results)
      return if results[:failed].include?('Build')

      check_xcodegen_sync_fast(results)
      check_linting(results)
      check_test_references(results)
      check_documentation_sync(results)
    end

    def check_build(results)
      puts "\n1️⃣  Build Verification..."
      container_arg = if project_workspace && !project_workspace.to_s.empty?
                        "-workspace #{project_workspace}"
                      else
                        "-project #{project_xcodeproj}"
                      end
      build_output = `xcodebuild #{container_arg} -scheme #{project_scheme} -destination "platform=macOS,arch=arm64" build 2>&1`
      if build_output.include?('BUILD SUCCEEDED')
        puts '   ✅ Build successful'
        results[:passed] << 'Build'
      else
        puts '   ❌ Build failed'
        error_lines = build_output.lines.select { |l| l.include?('error:') || l.include?('BUILD FAILED') }.last(3)
        error_lines.each { |line| puts "      #{line.strip}" } if error_lines.any?
        results[:failed] << 'Build'
        puts '   ⚠️  Skipping remaining checks due to build failure'
        print_test_suite_summary(results)
        exit 1
      end
    end

    def check_xcodegen_sync_fast(results)
      puts "\n2️⃣  XcodeGen Project Sync..."
      project_yml = 'project.yml'
      project_pbx = File.join(project_xcodeproj, 'project.pbxproj')
      if File.exist?(project_yml) && File.exist?(project_pbx)
        yml_mtime = File.mtime(project_yml)
        pbx_mtime = File.mtime(project_pbx)
        if yml_mtime <= pbx_mtime
          puts '   ✅ Project in sync'
          results[:passed] << 'XcodeGen'
        else
          puts '   ⚠️  Project out of sync (run: xcodegen generate)'
          results[:warnings] << 'XcodeGen'
        end
      else
        puts '   ⚠️  Cannot verify sync (missing files)'
        results[:warnings] << 'XcodeGen'
      end
    end

    def check_linting(results)
      puts "\n3️⃣  Code Linting..."
      lint_output = `./scripts/SaneMaster.rb lint 2>&1`
      if lint_output.include?('✅') || $CHILD_STATUS.success?
        puts '   ✅ Linting passed'
        results[:passed] << 'Lint'
      else
        puts '   ⚠️  Linting issues found (non-blocking)'
        results[:warnings] << 'Lint'
      end
    end

    def check_test_references(results)
      puts "\n4️⃣  Test Reference Validation..."
      test_ref_output = `./scripts/SaneMaster.rb validate_test_references 2>&1`
      if test_ref_output.include?('✅') && $CHILD_STATUS.success?
        puts '   ✅ All test references valid'
        results[:passed] << 'Test References'
      else
        puts '   ❌ Test reference validation failed'
        results[:failed] << 'Test References'
      end
    end

    def check_documentation_sync(results)
      puts "\n5️⃣  Documentation Sync..."
      docs_output = `./scripts/SaneMaster.rb check_docs 2>&1`
      if docs_output.include?('✅') || !docs_output.include?('drift')
        puts '   ✅ Documentation in sync'
        results[:passed] << 'Documentation'
      else
        puts '   ⚠️  Documentation drift detected (non-blocking)'
        results[:warnings] << 'Documentation'
      end
    end

    def run_medium_validation(results, quick_mode, full_mode, ci_mode)
      if quick_mode
        results[:skipped] << 'Mocks'
        results[:skipped] << 'Deprecations'
        return
      end

      puts "\n📋 Phase 2: Medium Validation Checks"
      puts '─' * 50

      check_mock_sync(results)
      check_deprecations_phase(results, full_mode, ci_mode)
    end

    def check_mock_sync(results)
      puts "\n6️⃣  Mock Synchronization..."
      mock_output = `./scripts/SaneMaster.rb verify_mocks 2>&1`
      if mock_output.include?('✅') || $CHILD_STATUS.success?
        puts '   ✅ Mocks in sync'
        results[:passed] << 'Mocks'
      else
        puts '   ⚠️  Mock sync issues (non-blocking)'
        results[:warnings] << 'Mocks'
      end
    end

    def check_deprecations_phase(results, full_mode, ci_mode)
      if full_mode || ci_mode
        puts "\n7️⃣  Deprecation Check..."
        deprec_output = `./scripts/SaneMaster.rb check_deprecations 2>&1`
        if deprec_output.include?('✅') || !deprec_output.include?('Found')
          puts '   ✅ No deprecations found'
          results[:passed] << 'Deprecations'
        else
          puts '   ⚠️  Deprecations found (non-blocking)'
          results[:warnings] << 'Deprecations'
        end
      else
        puts "\n7️⃣  Deprecation Check... (skipped, use --full to include)"
        results[:skipped] << 'Deprecations'
      end
    end

    def run_deep_analysis(results, full_mode, ci_mode)
      if full_mode && !ci_mode
        puts "\n📋 Phase 3: Deep Analysis Checks"
        puts '─' * 50

        puts "\n8️⃣  Dead Code Detection..."
        dead_code_output = `./scripts/SaneMaster.rb dead_code 2>&1`
        if dead_code_output.include?('✅') || $CHILD_STATUS.success?
          puts '   ✅ No dead code detected'
          results[:passed] << 'Dead Code'
        else
          puts '   ⚠️  Dead code detected (review output)'
          results[:warnings] << 'Dead Code'
        end
      else
        results[:skipped] << 'Dead Code'
      end
    end

    def print_result_section(title, items)
      puts "\n#{title} (#{items.count}):"
      items.each { |item| puts "   • #{item}" }
    end

    def print_test_suite_conclusion(results)
      if results[:failed].any?
        puts "\n❌ Test suite failed. Fix issues above before proceeding."
      elsif results[:warnings].any?
        puts "\n⚠️  Test suite passed with warnings. Review warnings above."
      else
        puts "\n✅ All checks passed!"
      end
    end
  end
end
