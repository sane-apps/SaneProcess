# frozen_string_literal: true

module SaneMasterModules
  # Lead research — finds candidate sites with Exa and builds readable
  # site dossiers with Firecrawl.
  module Leads
    def leads(args)
      script = File.join(__dir__, '..', 'automation', 'lead-research.py')

      unless File.exist?(script)
        puts "❌ lead-research.py not found at #{script}"
        exit 1
      end

      system('python3', script, *args)
    end
  end
end
