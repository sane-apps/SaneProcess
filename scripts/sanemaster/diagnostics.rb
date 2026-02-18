# frozen_string_literal: true

module SaneMasterModules
  # Crash analysis, xcresult diagnosis, log analysis
  module Diagnostics
    # Detect project name from current directory (context-specific)
    def project_name
      @project_name ||= File.basename(Dir.pwd)
    end

    def diagnose(path, dump: false)
      puts '🔬 --- [ SANEMASTER DIAGNOSE ] ---'

      # Project-specific diagnostics directory
      @diagnostics_dir = File.join(Dir.tmpdir, "#{project_name}_Diagnostics")
      FileUtils.mkdir_p(@diagnostics_dir)

      # AUTO-CLEANUP: Keep only last 3 exports to prevent stale log accumulation
      cleanup_old_exports

      xcresult = path || find_latest_xcresult
      unless xcresult && File.exist?(xcresult)
        puts '❌ No .xcresult bundle found.'
        puts '   Run tests first: ./Scripts/SaneMaster.rb verify'
        return
      end

      puts "📦 Analyzing result: #{xcresult}"
      export_path = export_xcresult(xcresult)
      return unless export_path

      puts "  ✅ Exported to: #{export_path}"
      analyze_app_logs(export_path)
      analyze_test_logs(export_path) if dump
      puts "\n✅ Diagnosis complete."
    end

    def cleanup_old_exports
      exports = Dir.glob(File.join(@diagnostics_dir, 'diagnostics_*')).sort_by { |f| File.mtime(f) }
      return if exports.count <= 3

      # Remove all but the 3 most recent
      exports[0...-3].each do |old_export|
        FileUtils.rm_rf(old_export)
      end
      puts "  🧹 Cleaned #{exports.count - 3} old diagnostic exports"
    end

    def analyze_crashes(args)
      puts '💥 --- [ CRASH REPORT ANALYSIS ] ---'
      puts "Analyzing #{project_name} crash reports for patterns..."
      puts ''

      crash_dir = File.expand_path('~/Library/Logs/DiagnosticReports')
      # Project-specific crash files
      crash_files = Dir.glob(File.join(crash_dir, "#{project_name}-*.ips")).sort_by { |f| File.mtime(f) }.reverse

      if crash_files.empty?
        puts '✅ No crash reports found. The app appears stable!'
        return
      end

      show_details = args.include?('--details') || args.include?('-d')
      recent_only = args.include?('--recent') || args.include?('-r')

      crash_files = filter_recent_crashes(crash_files) if recent_only
      puts "📊 Found #{crash_files.count} crash report(s)"
      puts ''

      crash_data = parse_crash_files(crash_files.first(50))
      print_crash_analysis(crash_data, show_details)
    end

    # Menu bar diagnostics for detection regressions.
    # Prints three sections so issues are quickly triaged:
    #   1) detected (raw AX items)
    #   2) normalized (items we can act on)
    #   3) excluded (dropped with reason)
    def menu_scan(args = [])
      json_output = args.include?('--json')
      owners = []

      args.each_with_index do |arg, index|
        if arg == '--owners'
          owners = args[index + 1].to_s.split(',')
        elsif arg.start_with?('--owners=')
          owners = arg.split('=', 2).last.to_s.split(',')
        end
      end

      owners = owners.map(&:strip).reject(&:empty?).uniq
      owners_env = owners.join(',')

      swift_script = <<~'SWIFT'
        import AppKit
        import ApplicationServices
        import Foundation

        struct RawItem: Codable {
            let ownerBundleId: String
            let ownerName: String
            let pid: Int32
            let root: String
            let index: Int
            let identifier: String?
            let title: String?
            let detail: String?
            let x: Double
            let width: Double
            let role: String?
            let subrole: String?
        }

        struct NormalizedItem: Codable {
            let ownerBundleId: String
            let ownerName: String
            let pid: Int32
            let canonicalIdentifier: String
            let sourceIdentifier: String?
            let sourceLabel: String?
            let x: Double
            let width: Double
            let reason: String
        }

        struct ExcludedItem: Codable {
            let ownerBundleId: String
            let ownerName: String
            let pid: Int32
            let index: Int
            let identifier: String?
            let title: String?
            let detail: String?
            let x: Double
            let width: Double
            let reason: String
        }

        struct ScanOutput: Codable {
            let detected: [RawItem]
            let normalized: [NormalizedItem]
            let excluded: [ExcludedItem]
        }

        func axString(_ value: CFTypeRef?) -> String? {
            if let s = value as? String { return s }
            if let a = value as? NSAttributedString { return a.string }
            return nil
        }

        func safeAXUIElement(_ ref: CFTypeRef?) -> AXUIElement? {
            guard let ref else { return nil }
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
        }

        func safeAXValue(_ ref: CFTypeRef?) -> AXValue? {
            guard let ref else { return nil }
            guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
            return unsafeDowncast(ref as AnyObject, to: AXValue.self)
        }

        func mapKnownAppleMenuExtra(from raw: String) -> String? {
            let lower = raw.lowercased()
            let compact = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
            let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

            let aliases: [String: String] = [
                "battery": "com.apple.menuextra.battery",
                "wifi": "com.apple.menuextra.wifi",
                "bluetooth": "com.apple.menuextra.bluetooth",
                "clock": "com.apple.menuextra.clock",
                "airdrop": "com.apple.menuextra.airdrop",
                "focus": "com.apple.menuextra.focusmode",
                "focusmode": "com.apple.menuextra.focusmode",
                "controlcenter": "com.apple.menuextra.controlcenter",
                "display": "com.apple.menuextra.display",
                "sound": "com.apple.menuextra.sound",
                "airplay": "com.apple.menuextra.airplay",
                "nowplaying": "com.apple.menuextra.now-playing",
                "siri": "com.apple.menuextra.siri",
                "spotlight": "com.apple.menuextra.spotlight"
            ]

            for (token, canonical) in aliases {
                if lower == token || compact == token || tokens.contains(token) {
                    return canonical
                }
            }

            return nil
        }

        func canonicalIdentifier(
            ownerBundleId: String,
            rawIdentifier: String?,
            label: String?,
            width: CGFloat
        ) -> (String?, String) {
            let normalizedIdentifier = rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAppleOwner = ownerBundleId.hasPrefix("com.apple.")

            if !isAppleOwner {
                guard let normalizedIdentifier, !normalizedIdentifier.isEmpty else {
                    return (nil, "missing_identifier")
                }
                return (normalizedIdentifier, "non_apple_identifier")
            }

            if let normalizedIdentifier, !normalizedIdentifier.isEmpty {
                if normalizedIdentifier.hasPrefix("com.apple.menuextra.") {
                    return (normalizedIdentifier.lowercased(), "apple_identifier")
                }
                if let mapped = mapKnownAppleMenuExtra(from: normalizedIdentifier) {
                    return (mapped, "apple_identifier_mapped")
                }
            }

            if width > 0, let normalizedLabel, let mapped = mapKnownAppleMenuExtra(from: normalizedLabel) {
                return (mapped, "apple_label_fallback")
            }

            if width <= 0 {
                return (nil, "missing_identifier_zero_width")
            }

            return (nil, "unknown_apple_extra")
        }

        func menuBarRoots(for appElement: AXUIElement, ownerBundleId: String) -> [(String, AXUIElement)] {
            var roots: [(String, AXUIElement)] = []

            var extrasBar: CFTypeRef?
            let extrasResult = AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasBar)
            if extrasResult == .success, let extrasElement = safeAXUIElement(extrasBar) {
                roots.append(("AXExtrasMenuBar", extrasElement))
            }

            let allowFallback = ownerBundleId == "com.apple.systemuiserver" || ownerBundleId == "com.apple.controlcenter"
            if roots.isEmpty && allowFallback {
                var menuBar: CFTypeRef?
                let menuResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBar)
                if menuResult == .success, let menuElement = safeAXUIElement(menuBar) {
                    roots.append(("AXMenuBar", menuElement))
                }
            }

            return roots
        }

        func collectMenuBarItems(from root: AXUIElement) -> [AXUIElement] {
            var result: [AXUIElement] = []

            func visit(_ node: AXUIElement) {
                var roleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue)
                let role = axString(roleValue)
                if role == (kAXMenuBarItemRole as String) || role == "AXMenuBarItem" {
                    result.append(node)
                    return
                }

                var childrenValue: CFTypeRef?
                let childrenResult = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenValue)
                guard childrenResult == .success, let children = childrenValue as? [AXUIElement] else { return }
                for child in children {
                    visit(child)
                }
            }

            visit(root)
            return result
        }

        let jsonOutput = ProcessInfo.processInfo.environment["SANEMASTER_MENU_SCAN_JSON"] == "1"
        let ownerFilterRaw = ProcessInfo.processInfo.environment["SANEMASTER_MENU_SCAN_OWNERS"] ?? ""
        let ownerFilter = Set(ownerFilterRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        if !AXIsProcessTrusted() {
            fputs("ERROR: Accessibility permission is required for menu_scan.\n", stderr)
            exit(2)
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != selfPID }

        var detected: [RawItem] = []
        var normalized: [NormalizedItem] = []
        var excluded: [ExcludedItem] = []

        for runningApp in runningApps {
            let pid = runningApp.processIdentifier
            let ownerBundleId = (runningApp.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ownerBundleId.isEmpty { continue }
            if !ownerFilter.isEmpty && !ownerFilter.contains(ownerBundleId) { continue }

            let ownerName = runningApp.localizedName ?? ownerBundleId
            let appElement = AXUIElementCreateApplication(pid)
            let roots = menuBarRoots(for: appElement, ownerBundleId: ownerBundleId)
            guard !roots.isEmpty else { continue }

            for (rootName, root) in roots {
                let items = collectMenuBarItems(from: root)
                for (index, item) in items.enumerated() {
                    var identifierValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXIdentifierAttribute as CFString, &identifierValue)
                    let identifier = axString(identifierValue)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    var titleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue)
                    let title = axString(titleValue)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    var detailValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &detailValue)
                    let detail = axString(detailValue)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    var roleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleValue)
                    let role = axString(roleValue)

                    var subroleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subroleValue)
                    let subrole = axString(subroleValue)

                    var positionValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue)
                    var point = CGPoint.zero
                    if let pos = safeAXValue(positionValue) {
                        AXValueGetValue(pos, .cgPoint, &point)
                    }

                    var sizeValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue)
                    var size = CGSize.zero
                    if let axSize = safeAXValue(sizeValue) {
                        AXValueGetValue(axSize, .cgSize, &size)
                    }

                    let raw = RawItem(
                        ownerBundleId: ownerBundleId,
                        ownerName: ownerName,
                        pid: pid,
                        root: rootName,
                        index: index,
                        identifier: identifier,
                        title: title,
                        detail: detail,
                        x: Double(point.x),
                        width: Double(size.width),
                        role: role,
                        subrole: subrole
                    )
                    detected.append(raw)

                    let label = (title?.isEmpty == false ? title : detail)
                    let (canonical, reason) = canonicalIdentifier(
                        ownerBundleId: ownerBundleId,
                        rawIdentifier: identifier,
                        label: label,
                        width: size.width
                    )

                    if let canonical {
                        normalized.append(
                            NormalizedItem(
                                ownerBundleId: ownerBundleId,
                                ownerName: ownerName,
                                pid: pid,
                                canonicalIdentifier: canonical,
                                sourceIdentifier: identifier,
                                sourceLabel: label,
                                x: Double(point.x),
                                width: Double(size.width),
                                reason: reason
                            )
                        )
                    } else {
                        excluded.append(
                            ExcludedItem(
                                ownerBundleId: ownerBundleId,
                                ownerName: ownerName,
                                pid: pid,
                                index: index,
                                identifier: identifier,
                                title: title,
                                detail: detail,
                                x: Double(point.x),
                                width: Double(size.width),
                                reason: reason
                            )
                        )
                    }
                }
            }
        }

        detected.sort { lhs, rhs in
            if lhs.ownerBundleId != rhs.ownerBundleId { return lhs.ownerBundleId < rhs.ownerBundleId }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.index < rhs.index
        }
        normalized.sort { lhs, rhs in
            if lhs.ownerBundleId != rhs.ownerBundleId { return lhs.ownerBundleId < rhs.ownerBundleId }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.canonicalIdentifier < rhs.canonicalIdentifier
        }
        excluded.sort { lhs, rhs in
            if lhs.ownerBundleId != rhs.ownerBundleId { return lhs.ownerBundleId < rhs.ownerBundleId }
            if lhs.reason != rhs.reason { return lhs.reason < rhs.reason }
            return lhs.index < rhs.index
        }

        if jsonOutput {
            let output = ScanOutput(detected: detected, normalized: normalized, excluded: excluded)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            print(String(data: data, encoding: .utf8) ?? "{}")
            exit(0)
        }

        print("--- [ MENU BAR DIAGNOSTICS ] ---")
        print("")
        print("Detected: \(detected.count)")
        for item in detected {
            let id = item.identifier ?? "nil"
            let label = item.title ?? item.detail ?? ""
            print("  [\(item.ownerBundleId)] root=\(item.root) i=\(item.index) id=\(id) label=\(label) x=\(Int(item.x)) w=\(Int(item.width))")
        }

        print("")
        print("Normalized: \(normalized.count)")
        for item in normalized {
            let source = item.sourceIdentifier ?? "nil"
            let label = item.sourceLabel ?? ""
            print("  [\(item.ownerBundleId)] canonical=\(item.canonicalIdentifier) via=\(item.reason) source=\(source) label=\(label) x=\(Int(item.x)) w=\(Int(item.width))")
        }

        print("")
        print("Excluded: \(excluded.count)")
        for item in excluded {
            let id = item.identifier ?? "nil"
            let label = item.title ?? item.detail ?? ""
            print("  [\(item.ownerBundleId)] reason=\(item.reason) i=\(item.index) id=\(id) label=\(label) x=\(Int(item.x)) w=\(Int(item.width))")
        }
      SWIFT

      Tempfile.create(%w[sanemaster_menu_scan .swift]) do |tmp|
        tmp.write(swift_script)
        tmp.flush

        env = {
          'SANEMASTER_MENU_SCAN_JSON' => json_output ? '1' : '0',
          'SANEMASTER_MENU_SCAN_OWNERS' => owners_env
        }
        stdout, stderr, status = Open3.capture3(env, 'swift', tmp.path)

        if status.success?
          puts stdout
        else
          puts '❌ menu_scan failed'
          puts stderr unless stderr.to_s.strip.empty?
          puts stdout unless stdout.to_s.strip.empty?
          puts ''
          puts 'Tip: Ensure Accessibility permission is granted to the terminal/Codex app.'
          exit 1
        end
      end
    end

    private

    def export_xcresult(xcresult)
      export_path = File.join(@diagnostics_dir, "diagnostics_#{Time.now.strftime('%Y%m%d_%H%M%S')}")
      FileUtils.mkdir_p(export_path)

      # Try new API first, fall back to legacy
      export_cmd = "xcrun xcresulttool export diagnostics --path '#{xcresult}' --output-path '#{export_path}' 2>&1"
      export_result = `#{export_cmd}`

      if export_result.include?('error') || export_result.include?('Error')
        export_cmd = "xcrun xcresulttool export --legacy --type directory --path '#{xcresult}' --output-path '#{export_path}' 2>&1"
        export_result = `#{export_cmd}`
      end

      if export_result.include?('error') || export_result.include?('Error')
        puts "  Cannot read xcresult: #{export_result.lines.first}"
        puts '❌ Failed to export diagnostics.'
        return nil
      end

      export_path
    end

    def analyze_app_logs(export_path)
      app_log = find_app_log(export_path)
      if app_log
        puts "\n  📱 App Log: #{app_log}"
        puts '  --- App Runtime Insights ---'

        File.foreach(app_log) do |line|
          case line
          when /error|Error|ERROR|crash|Crash|CRASH|exception|Exception/
            puts "  ❌ #{line.strip}"
          when /warning|Warning|WARNING/
            puts "  ⚠️  #{line.strip}"
          when /✅|🎬|📊|🔍/
            puts "  ℹ️  #{line.strip}"
          end
        end
      else
        puts '  ⚠️  No App Log found in current export.'
      end
    end

    def analyze_test_logs(export_path)
      test_log = find_test_log(export_path)
      if test_log
        puts "\n  📄 Test Log: #{test_log}"
        puts '  --- Test Runner Insights ---'
        process_test_log(test_log)
      else
        puts '  ⚠️  No Test Runner Log found in current export.'
      end
    end

    def process_test_log(test_log)
      printing_hierarchy = false
      hierarchy_lines_count = 0

      File.foreach(test_log) do |line|
        if line.match?(/dumping.*hierarchy|dumping.*descendants|dumping.*sheet/i)
          puts "  📄 ... Hierarchy Dump Start [matches '#{line.strip}'] ..."
          printing_hierarchy = true
          hierarchy_lines_count = 0
          next
        end

        if printing_hierarchy
          if line.include?("Test Case '-[") || hierarchy_lines_count > 1000
            printing_hierarchy = false
            puts '  📄 ... Hierarchy Dump End ...'
          else
            puts "    #{line}"
            hierarchy_lines_count += 1
            next
          end
        end

        puts "  🔍 #{line.strip}" if line.match?(/debug:/i)
        puts "  ❌ #{line.strip}" if line.include?('failure') || line.include?('Assertion failed')
        puts "  ⏳ #{line.strip}" if line.include?('Waiting') && line.include?('for')
      end
    end

    def find_app_log(export_path)
      # Search ONLY in the current export, not historical ones
      logs = Dir.glob(File.join(export_path, '**', 'StandardOutputAndStandardError*.txt'))
      # Project-specific log detection
      logs.find { |f| f.include?(project_name) } || logs.first
    end

    def find_test_log(export_path)
      # Search ONLY in the current export, not historical ones
      logs = Dir.glob(File.join(export_path, '**', 'StandardOutputAndStandardError*.txt'))
      logs.find { |f| f.include?('xctest') || f.include?('Test') }
    end

    def find_latest_xcresult
      # Project-specific DerivedData path
      system_dd_logs = Dir.glob(File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*/Logs/Test/*.xcresult"))
      dd_logs = Dir.glob('.derivedData/Logs/Test/*.xcresult')
      fl_logs = Dir.glob('fastlane/test_output/*.xcresult')
      tmp_logs = Dir.glob('/tmp/*.xcresult')

      (system_dd_logs + dd_logs + fl_logs + tmp_logs).max_by { |f| File.mtime(f) }
    end

    def filter_recent_crashes(crash_files)
      cutoff = Time.now - (24 * 60 * 60)
      puts '📅 Showing crashes from last 24 hours only'
      crash_files.select { |f| File.mtime(f) > cutoff }
    end

    def parse_crash_files(crash_files)
      crash_data = []
      crash_files.each do |file|
        data = parse_single_crash(file)
        crash_data << data if data
      rescue StandardError
        # Skip unparseable files
      end
      crash_data
    end

    def parse_single_crash(file)
      content = File.read(file)
      json_start = content.index("\n{")
      return nil unless json_start

      json_data = JSON.parse(content[json_start..])
      exception = json_data['exception'] || {}
      threads = json_data['threads'] || []
      faulting_thread = threads.find { |t| t['triggered'] }

      return nil unless faulting_thread

      frames = faulting_thread['frames'] || []
      signature = frames.first(4).map { |f| (f['symbol'] || '?')[0..35] }.join(' -> ')
      app_frame = find_app_frame(frames)

      {
        file: File.basename(file),
        time: File.mtime(file),
        type: exception['type'] || 'Unknown',
        signal: exception['signal'] || 'Unknown',
        subtype: exception['subtype'],
        signature: signature,
        queue: faulting_thread['queue'] || 'unknown',
        app_frame: app_frame,
        thread_index: json_data['faultingThread'] || 0
      }
    end

    def find_app_frame(frames)
      app_frame = frames.first(15).find do |f|
        src = f['sourceFile'] || ''
        sym = f['symbol'] || ''
        # Project-specific frame detection
        src.include?(project_name) || sym.include?(project_name)
      end

      return nil unless app_frame

      "#{app_frame['symbol']} (#{File.basename(app_frame['sourceFile'] || 'unknown')}:#{app_frame['sourceLine']})"
    end

    def print_crash_analysis(crash_data, show_details)
      print_crash_distribution(crash_data)
      print_thread_distribution(crash_data)
      print_top_signatures(crash_data)
      print_app_frames(crash_data)
      print_known_patterns(crash_data)
      print_crash_details(crash_data) if show_details
      print_crash_summary(crash_data)
    end

    def print_crash_distribution(crash_data)
      puts '📈 CRASH TYPE DISTRIBUTION'
      puts '─' * 50
      type_counts = crash_data.group_by { |c| c[:type] }.transform_values(&:count)
      type_counts.sort_by { |_, count| -count }.each do |type, count|
        pct = (count.to_f / crash_data.count * 100).round(1)
        puts "  #{type}: #{count} (#{pct}%)"
      end
      puts ''
    end

    def print_thread_distribution(crash_data)
      puts '🧵 FAULTING THREAD DISTRIBUTION'
      puts '─' * 50
      thread_counts = crash_data.group_by { |c| c[:thread_index] }.transform_values(&:count)
      thread_counts.sort_by { |_, count| -count }.each do |thread, count|
        pct = (count.to_f / crash_data.count * 100).round(1)
        label = thread.zero? ? 'Main Thread' : "Thread #{thread}"
        puts "  #{label}: #{count} (#{pct}%)"
      end
      puts ''
    end

    def print_top_signatures(crash_data)
      puts '🔍 TOP CRASH SIGNATURES (Pattern Detection)'
      puts '─' * 50
      sig_counts = crash_data.group_by { |c| c[:signature] }.transform_values(&:count)
      sig_counts.sort_by { |_, count| -count }.first(8).each do |sig, count|
        puts "  [#{count}x] #{sig}"
      end
      puts ''
    end

    def print_app_frames(crash_data)
      app_frames = crash_data.map { |c| c[:app_frame] }.compact
      return unless app_frames.any?

      puts '📱 SANEVIDEO CODE FRAMES'
      puts '─' * 50
      frame_counts = app_frames.group_by(&:itself).transform_values(&:count)
      frame_counts.sort_by { |_, count| -count }.first(10).each do |frame, count|
        puts "  [#{count}x] #{frame}"
      end
      puts ''
    end

    def print_known_patterns(crash_data)
      puts '⚠️  KNOWN ISSUE PATTERNS'
      puts '─' * 50

      patterns = {
        'Actor Isolation (MainActor.assumeIsolated)' => crash_data.count { |c| c[:signature].include?('dispatch_assert_queue') },
        'Object Deallocated (Timer/Publisher)' => crash_data.count do |c|
          c[:signature].include?('isMainExecutor') && c[:subtype]&.include?('0x000000000000001')
        end,
        'Test Cleanup (XCTMemoryChecker)' => crash_data.count { |c| c[:signature].include?('XCTMemoryChecker') },
        'Memory Corruption (objc_release)' => crash_data.count { |c| c[:signature].start_with?('objc_release') && !c[:signature].include?('XCTMemoryChecker') }
      }

      patterns.each do |pattern, count|
        next if count.zero?

        pct = (count.to_f / crash_data.count * 100).round(1)
        puts "  #{pattern}: #{count} (#{pct}%)"
      end
      puts ''
    end

    def print_crash_details(crash_data)
      puts '📋 RECENT CRASHES (Details)'
      puts '─' * 50
      crash_data.first(10).each do |crash|
        puts "  📄 #{crash[:file]}"
        puts "     Time: #{crash[:time].strftime('%Y-%m-%d %H:%M:%S')}"
        puts "     Type: #{crash[:type]} (#{crash[:signal]})"
        puts "     Queue: #{crash[:queue]}"
        puts "     Signature: #{crash[:signature]}"
        puts "     App Frame: #{crash[:app_frame]}" if crash[:app_frame]
        puts ''
      end
    end

    def print_crash_summary(crash_data)
      puts '📊 SUMMARY'
      puts '─' * 50
      puts "  Total crashes analyzed: #{crash_data.count}"
      puts "  Oldest: #{crash_data.last[:time].strftime('%Y-%m-%d %H:%M')}" if crash_data.any?
      puts "  Newest: #{crash_data.first[:time].strftime('%Y-%m-%d %H:%M')}" if crash_data.any?

      main_thread_crashes = crash_data.count { |c| c[:thread_index].zero? }
      puts "  ⚠️  #{main_thread_crashes}/#{crash_data.count} crashes on Main Thread - check UI/state code" if main_thread_crashes > crash_data.count * 0.5

      test_crashes = crash_data.count { |c| c[:signature].include?('XCT') }
      return unless test_crashes.positive?

      puts "  ℹ️  #{test_crashes} crash(es) in test cleanup - review async test handling"
    end
  end
end
# rubocop:enable Metrics/ModuleLength
