# frozen_string_literal: true

module SaneMasterModules
  # Download analytics reporting — wraps dl-report.py for unified CLI access.
  # Mirrors the sales.rb pattern.
  #
  # Usage:
  #   SaneMaster.rb downloads              # Today/yesterday/week/all-time (default)
  #   SaneMaster.rb downloads --days 7     # Last 7 days
  #   SaneMaster.rb downloads --app sanebar # Filter by app
  #   SaneMaster.rb downloads --json       # Raw JSON for piping
  module Downloads
    def downloads(args)
      dl_report = File.join(__dir__, '..', 'automation', 'dl-report.py')

      unless File.exist?(dl_report)
        puts "❌ dl-report.py not found at #{dl_report}"
        exit 1
      end

      # Default to --daily if no flags given
      if args.empty?
        system('python3', dl_report, '--daily')
      else
        system('python3', dl_report, *args)
      end
    end
  end
end
