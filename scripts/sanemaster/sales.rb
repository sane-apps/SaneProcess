# frozen_string_literal: true

module SaneMasterModules
  # Sales reporting — wraps ls-sales.py for unified CLI access.
  # Replaces manual curl + python parsing in the outreach skill.
  #
  # Usage:
  #   SaneMaster.rb sales              # Today/yesterday/week/all-time (default)
  #   SaneMaster.rb sales --month      # Current month breakdown
  #   SaneMaster.rb sales --products   # Revenue by product
  #   SaneMaster.rb sales --fees       # Fee breakdown
  #   SaneMaster.rb sales --json       # Raw JSON for piping
  module Sales
    def sales(args)
      ls_sales = File.join(__dir__, '..', 'automation', 'ls-sales.py')

      unless File.exist?(ls_sales)
        puts "❌ ls-sales.py not found at #{ls_sales}"
        exit 1
      end

      # Default to --daily if no flags given
      if args.empty?
        system('python3', ls_sales, '--daily')
      else
        system('python3', ls_sales, *args)
      end
    end
  end
end
