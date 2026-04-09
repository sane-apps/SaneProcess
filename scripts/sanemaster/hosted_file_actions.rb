# frozen_string_literal: true

module SaneMasterModules
  # Hosted-file action export — wraps hosted-file-actions.py so dashboard-only
  # Lemon Squeezy sync work has a canonical JSON/XLSX output.
  module HostedFileActions
    def hosted_file_actions(args)
      script = File.join(__dir__, '..', 'automation', 'hosted-file-actions.py')

      unless File.exist?(script)
        puts "❌ hosted-file-actions.py not found at #{script}"
        exit 1
      end

      system('python3', script, *args)
    end
  end
end
