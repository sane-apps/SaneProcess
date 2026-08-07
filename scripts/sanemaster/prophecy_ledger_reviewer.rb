# frozen_string_literal: true

require 'json'
require 'open3'
require 'shellwords'
require 'socket'

module SaneMasterModules
  # Canonical Prophecy Ledger reviewer click E2E lane.
  # Agents must use this instead of /tmp Brave OTP scripts or ad-hoc Playwright.
  module ProphecyLedgerReviewer
    REPO_MINI = '~/SaneApps/websites/prophecy-ledger'
    REPO_ABS_MINI = '/Users/stephansmac/SaneApps/websites/prophecy-ledger'
    DOC = 'docs/REVIEWER_CLICK_E2E.md'

    module_function

    def prophecy_ledger_reviewer_click(args = [])
      options = parse_prophecy_reviewer_args(args)
      mode = options[:mode]
      allow_submit = options[:allow_live_submit]

      puts <<~BANNER
        Prophecy Ledger reviewer click E2E
        mode=#{mode}
        doc=#{DOC}
        host_routing=#{on_mini? ? 'local-mini' : 'ssh-mini'}
      BANNER

      cmd = build_remote_command(mode: mode, allow_live_submit: allow_submit)
      status = run_on_mini(cmd)
      if status.zero?
        puts 'PROPHECY_REVIEWER_CLICK_PASSED'
        true
      else
        warn "PROPHECY_REVIEWER_CLICK_FAILED exit=#{status}"
        warn "See #{REPO_ABS_MINI}/#{DOC}"
        false
      end
    end

    def parse_prophecy_reviewer_args(args)
      mode = 'local'
      allow = false
      args.each_with_index do |arg, i|
        case arg
        when '--mode'
          mode = args[i + 1].to_s if args[i + 1]
        when /^--mode=(.+)$/
          mode = Regexp.last_match(1)
        when '--live'
          mode = 'live'
        when '--local'
          mode = 'local'
        when '--allow-live-submit'
          allow = true
        end
      end
      mode = 'live' if mode == 'prod'
      unless %w[local live].include?(mode)
        raise ArgumentError, "mode must be local|live (got #{mode.inspect})"
      end

      { mode: mode, allow_live_submit: allow }
    end

    def on_mini?
      Socket.gethostname.to_s.downcase.include?('mini')
    rescue StandardError
      false
    end

    def build_remote_command(mode:, allow_live_submit:)
      env_prefix = allow_live_submit ? 'ALLOW_LIVE_SUBMIT=1 ' : ''
      npm = mode == 'live' ? 'e2e:reviewer:live' : 'e2e:reviewer'
      <<~SH.gsub(/\s+/, ' ').strip
        export PATH="/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:$PATH";
        cd #{REPO_ABS_MINI} &&
        test -f scripts/reviewer-click-e2e.mjs &&
        test -f #{DOC} &&
        #{env_prefix}npm run #{npm}
      SH
    end

    def run_on_mini(command)
      if on_mini?
        system('bash', '-lc', command)
        return $?.exitstatus || 1
      end

      ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'mini', command]
      system(*ssh)
      $?.exitstatus || 1
    end
  end
end
