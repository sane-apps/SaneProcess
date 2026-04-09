# frozen_string_literal: true

module SaneMasterModules
  # Listing action export — wraps listing-actions.py for a reusable inbox-to-XLSX tracker.
  #
  # Usage:
  #   SaneMaster.rb listing_actions
  #   SaneMaster.rb listing_actions --json
  #   SaneMaster.rb listing_actions --xlsx /tmp/listings.xlsx
  module ListingActions
    def listing_actions(args)
      script = File.join(__dir__, '..', 'automation', 'listing-actions.py')

      unless File.exist?(script)
        puts "❌ listing-actions.py not found at #{script}"
        exit 1
      end

      system('python3', script, *args)
    end
  end
end
