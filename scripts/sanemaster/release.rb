# frozen_string_literal: true

module SaneMasterModules
  # Unified release entrypoint (delegates to SaneProcess release.sh)
  module Release
    def release(args)
      release_script = File.expand_path('../release.sh', __dir__)
      unless File.exist?(release_script)
        puts "❌ Release script not found: #{release_script}"
        exit 1
      end

      cmd = [release_script]
      unless args.include?('--project')
        cmd += ['--project', Dir.pwd]
      end
      cmd.concat(args)

      puts '🚀 --- [ SANEMASTER RELEASE ] ---'
      puts "Using: #{release_script}"
      puts "Project: #{Dir.pwd}" unless args.include?('--project')
      puts ''

      exec(*cmd)
    end

    # Standalone release preflight — runs all safety checks without building.
    # Derived from 46 GitHub issues, 200+ customer emails, 34 documented burns.
    def release_preflight(_args)
      require 'json'
      require 'open3'

      puts '🛫 --- [ RELEASE PREFLIGHT ] ---'
      puts "Project: #{Dir.pwd}"
      puts ''

      issues = []
      warnings = []

      # 1. Tests pass
      print '  Tests... '
      out, status = Open3.capture2e('./scripts/SaneMaster.rb', 'verify', '--quiet')
      if status.success?
        puts '✅'
      else
        puts '❌ FAIL'
        issues << 'Tests failing'
      end

      # 2. Git clean
      print '  Git clean... '
      dirty, = Open3.capture2('git', 'status', '--porcelain')
      dirty = dirty.strip
      if dirty.empty?
        puts '✅'
      else
        puts "⚠️  #{dirty.lines.count} uncommitted changes"
        warnings << "#{dirty.lines.count} uncommitted files"
      end

      # 3. UserDefaults / migration changes
      print '  Defaults/migration changes... '
      changed_files, = Open3.capture2('git', 'diff', 'HEAD~5..HEAD', '--name-only', '--', '*.swift')
      defaults_files = changed_files.strip.split("\n")
        .select { |f| File.exist?(f) }
        .select do |f|
          content = File.read(f) rescue ''
          content.match?(/UserDefaults|setDefaultsIfNeeded|registerDefaults|migration|migrate/i)
        end
      if defaults_files.any?
        puts "⚠️  #{defaults_files.count} file(s)"
        defaults_files.each { |f| puts "    - #{f}" }
        warnings << 'UserDefaults/migration code changed — upgrade path test required'
      else
        puts '✅ none'
      end

      # 4. Sparkle key in project config
      print '  Sparkle public key... '
      plist_paths = Dir.glob('**/Info.plist').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      expected_key = '7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU='
      checked_key = false
      plist_paths.each do |plist|
        key, = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :SUPublicEDKey', plist)
        key = key.strip
        next if key.empty? || key.include?('Does Not Exist')

        checked_key = true
        if key == expected_key
          puts "✅ (#{plist})"
        else
          puts "❌ MISMATCH in #{plist}"
          issues << "SUPublicEDKey mismatch: #{key}"
        end
      end
      puts '⏭️  no Info.plist with SUPublicEDKey found' unless checked_key

      # 5. Open GitHub issues
      print '  Open GitHub issues... '
      saneprocess_path = File.join(Dir.pwd, '.saneprocess')
      app_name = nil
      if File.exist?(saneprocess_path)
        match = File.read(saneprocess_path).match(/^name:\s*(.+)/)
        app_name = match[1].strip if match
      end
      repo = "sane-apps/#{app_name || File.basename(Dir.pwd)}"
      issue_json, = Open3.capture2('gh', 'issue', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
      open_count = begin
        JSON.parse(issue_json).length
      rescue StandardError
        0
      end
      if open_count.positive?
        puts "⚠️  #{open_count} open"
        warnings << "#{open_count} open GitHub issues"
      else
        puts '✅ none'
      end

      # 6. Pending customer emails
      print '  Pending emails... '
      api_key, = Open3.capture2('security', 'find-generic-password', '-s', 'sane-email-automation', '-a', 'api_key', '-w')
      api_key = api_key.strip
      if api_key.empty?
        puts '⏭️  skipped (no API key)'
      else
        pending_json, = Open3.capture2('curl', '-s',
                                       'https://email-api.saneapps.com/api/emails/pending',
                                       '-H', "Authorization: Bearer #{api_key}")
        pending_count = begin
          JSON.parse(pending_json).length
        rescue StandardError
          0
        end
        if pending_count.positive?
          puts "⚠️  #{pending_count} pending"
          warnings << "#{pending_count} pending customer emails"
        else
          puts '✅ none'
        end
      end

      # 7. Release timing
      print '  Release timing... '
      hour = Time.now.hour
      if hour >= 17 || hour < 6
        puts "⚠️  evening/night (#{Time.now.strftime('%H:%M')})"
        warnings << 'Evening release — 8-18hr discovery window if broken'
      else
        puts "✅ daytime (#{Time.now.strftime('%H:%M')})"
      end

      # Summary
      puts ''
      puts '═' * 50
      if issues.any?
        puts "❌ BLOCKED: #{issues.count} issue(s)"
        issues.each { |i| puts "   🔴 #{i}" }
      end
      if warnings.any?
        puts "⚠️  #{warnings.count} warning(s):"
        warnings.each { |w| puts "   🟡 #{w}" }
      end
      if issues.empty? && warnings.empty?
        puts '✅ ALL CLEAR — safe to release'
      elsif issues.empty?
        puts '🟡 PROCEED WITH CAUTION — review warnings above'
      end
      puts '═' * 50

      exit 1 if issues.any?
    end
  end
end
