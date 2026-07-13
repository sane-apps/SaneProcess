# frozen_string_literal: true

require 'fileutils'
require 'time'
require 'tmpdir'

module SaneMasterModules
  # Verify permission-monitoring helpers (split from verify_support.rb for
  # Rule #10). Reopens the same module nesting so these stay instance methods of
  # the mixed-in VerifyHarness/SaneMaster class (they rely on @bundle_id,
  # project_name, saneprocess_config, project_xcodeproj, project_workspace).
  #
  # As of the TCC-preservation fix these methods arm a first-run permission
  # monitor WITHOUT resetting the app's real TCC grants. The test build shares
  # the release bundle id, so resetting on every verify wiped the installed
  # app's user grants AND ran the suite against a reset-then-auto-granted state
  # instead of the real granted path a user has. The rare clean-install reset is
  # still available via the explicit `reset_permissions` command in verify.rb.
  module Verify
    private

    def grant_test_permissions(timeout_seconds:)
      print '🔐 Arming permission monitor (preserving existing grants)... '

      permission_pid = nil
      log_path = nil
      script_path = File.join(__dir__, '..', 'grant_permissions.applescript')
      if File.exist?(script_path)
        log_path = File.join(Dir.tmpdir, "sanemaster_permission_monitor_#{project_name}.log")
        File.write(log_path, "Permission monitor for #{project_name} started at #{Time.now.utc.iso8601}\n")
        monitor_duration = [timeout_seconds.to_i + 120, 300].max
        permission_pid = Process.spawn(
          'osascript',
          script_path,
          project_name,
          monitor_duration.to_s,
          out: log_path,
          err: [:child, :out]
        )
        Process.detach(permission_pid)
      end

      puts '✅'
      { pid: permission_pid, log_path: log_path }
    end

    def enforce_no_unresolved_permission_prompt!(permission_monitor)
      log_path = permission_monitor.is_a?(Hash) ? permission_monitor[:log_path] : nil
      return unless log_path && File.exist?(log_path)

      log = File.read(log_path)
      return unless permission_monitor_blocked?(log)

      puts "\n❌ Permission prompt/manual grant detected during verify."
      puts "   Permission monitor log: #{log_path}"
      puts '   Resolve the Mini prompt, then rerun verify. Do not treat this run as release evidence.'
      exit 1
    end

    def permission_monitor_blocked?(log)
      log.include?('manual grant may be needed') ||
        log.include?('PROTECTED_FOLDER_PROMPT')
    end

    def verify_permission_services
      services = %w[Camera Microphone ScreenRecording]
      services += protected_folder_permission_services if reset_protected_folder_permissions_for_verify?
      services
    end

    def protected_folder_permission_services
      %w[
        SystemPolicyDocumentsFolder
        SystemPolicyDesktopFolder
        SystemPolicyDownloadsFolder
      ]
    end

    def reset_protected_folder_permissions_for_verify?
      return false if saneprocess_config['type'].to_s == 'infra'

      has_xcode_project = project_xcodeproj && !project_xcodeproj.to_s.empty?
      has_workspace = project_workspace && !project_workspace.to_s.empty?
      has_xcode_project || has_workspace
    end
  end
end
