# frozen_string_literal: true

require 'shellwords'

module SaneMasterModules
  module UniversalControl
    UNIVERSAL_CONTROL_MINI_HOST = 'mini'

    def universal_control_reset(args = [])
      options = parse_universal_control_reset_options(args)
      targets = []
      targets << universal_control_status(:local) if options[:local]
      targets << universal_control_status(:mini) if options[:mini]

      if options[:status]
        print_universal_control_status(targets)
        return
      end

      puts '🖱️  --- [ UNIVERSAL CONTROL RECOVERY ] ---'
      print_universal_control_status(targets)

      targets.each do |target|
        execute_universal_control_reset(target, options)
      end

      puts ''
      puts 'Next:'
      puts '  1) Try the pointer edge again for 2-3 seconds.'
      puts '  2) If it still fails, rerun with --reboot-mini.'
      puts '  3) If it still fails after that, reboot the Air.'
    end

    private

    def parse_universal_control_reset_options(args)
      options = {
        local: true,
        mini: true,
        status: false,
        dry_run: false,
        cleanup_mini: false,
        reboot_mini: false
      }

      OptionParser.new do |opts|
        opts.on('--status', 'Print Universal Control state only') { options[:status] = true }
        opts.on('--dry-run', 'Print commands without executing them') { options[:dry_run] = true }
        opts.on('--local-only', 'Reset only this Mac') do
          options[:local] = true
          options[:mini] = false
        end
        opts.on('--mini-only', 'Reset only the Mini') do
          options[:local] = false
          options[:mini] = true
        end
        opts.on('--cleanup-mini', 'Hide Mini Terminal/Codex and close Preview/Safari') do
          options[:cleanup_mini] = true
          options[:mini] = true
        end
        opts.on('--reboot-mini', 'Restart the Mini after the reset') do
          options[:reboot_mini] = true
          options[:mini] = true
        end
      end.parse!(args)

      options
    end

    def universal_control_status(target)
      if target == :mini
        unless mini_reachable?
          return {
            target: :mini,
            reachable: false,
            host_label: 'Mini'
          }
        end

        output, status = Open3.capture2e(
          'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', UNIVERSAL_CONTROL_MINI_HOST,
          universal_control_status_probe
        )
        return parse_universal_control_probe(:mini, output, status.success?)
      end

      output, status = Open3.capture2e('/bin/zsh', '-lc', universal_control_status_probe)
      parse_universal_control_probe(:local, output, status.success?)
    end

    def universal_control_status_probe
      <<~SH
        wifi_device=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
        wifi_power=""
        if [ -n "$wifi_device" ]; then
          wifi_power=$(networksetup -getairportpower "$wifi_device" 2>/dev/null | awk '{print $NF}')
        fi
        ip_addr=""
        if [ -n "$wifi_device" ]; then
          ip_addr=$(ipconfig getifaddr "$wifi_device" 2>/dev/null || true)
        fi
        handoff_adv=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null || echo missing)
        handoff_recv=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null || echo missing)
        if defaults -currentHost read com.apple.UniversalControl >/dev/null 2>&1; then
          uc_present=yes
        else
          uc_present=no
        fi
        printf "computer_name=%s\n" "$(scutil --get ComputerName 2>/dev/null || hostname)"
        printf "wifi_device=%s\n" "$wifi_device"
        printf "wifi_power=%s\n" "$wifi_power"
        printf "ip_addr=%s\n" "$ip_addr"
        printf "handoff_adv=%s\n" "$handoff_adv"
        printf "handoff_recv=%s\n" "$handoff_recv"
        printf "uc_present=%s\n" "$uc_present"
      SH
    end

    def parse_universal_control_probe(target, output, success)
      data = {
        target: target,
        reachable: success,
        host_label: target == :mini ? 'Mini' : 'Local'
      }
      output.to_s.each_line do |line|
        key, value = line.strip.split('=', 2)
        next if key.to_s.empty?

        data[key.to_sym] = value.to_s
      end
      data
    end

    def print_universal_control_status(targets)
      puts ''
      targets.each do |target|
        if target[:reachable] == false
          puts "  #{target[:host_label]}: unreachable"
          next
        end

        puts "  #{target[:host_label]}: #{target[:computer_name]}"
        puts "    Wi-Fi: #{target[:wifi_device]} power=#{target[:wifi_power]} ip=#{target[:ip_addr]}"
        puts "    Handoff: advertise=#{target[:handoff_adv]} receive=#{target[:handoff_recv]}"
        puts "    UC prefs present: #{target[:uc_present]}"
      end
      puts ''
    end

    def execute_universal_control_reset(target, options)
      if target[:reachable] == false
        warn "⚠️  Skipping #{target[:host_label]} reset: host is unreachable."
        return
      end

      script = universal_control_reset_script(
        wifi_device: target[:wifi_device],
        cleanup_windows: options[:cleanup_mini] && target[:target] == :mini
      )

      puts "▶ #{target[:host_label]} reset"
      if options[:dry_run]
        script.each_line { |line| puts "    #{line.rstrip}" }
      elsif target[:target] == :mini
        ok = ssh_system('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', UNIVERSAL_CONTROL_MINI_HOST, script)
        warn '⚠️  Mini Universal Control reset reported a failure.' unless ok
      else
        ok = system('/bin/zsh', '-lc', script)
        warn '⚠️  Local Universal Control reset reported a failure.' unless ok
      end

      return unless options[:reboot_mini] && target[:target] == :mini

      reboot_cmd = "osascript -e 'tell application \"System Events\" to restart'"
      if options[:dry_run]
        puts "    #{reboot_cmd}"
      else
        puts '▶ Mini reboot requested'
        ssh_system('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', UNIVERSAL_CONTROL_MINI_HOST, reboot_cmd)
      end
    end

    def universal_control_reset_script(wifi_device:, cleanup_windows:)
      wifi_reset = if wifi_device.to_s.empty?
                     ':'
                   else
                     <<~SH.chomp
                       networksetup -setairportpower #{Shellwords.escape(wifi_device)} off || true
                       sleep 2
                       networksetup -setairportpower #{Shellwords.escape(wifi_device)} on || true
                     SH
                   end

      cleanup_script = if cleanup_windows
                         <<~SH
                           pkill -x Preview 2>/dev/null || true
                           pkill -x Safari 2>/dev/null || true
                           osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' 2>/dev/null || true
                           osascript -e 'tell application "System Events" to set visible of process "Codex" to false' 2>/dev/null || true
                         SH
                       else
                         ''
                       end

      <<~SH
        defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true
        defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true
        defaults -currentHost delete com.apple.UniversalControl 2>/dev/null || true
        killall UniversalControl sharingd useractivityd bluetoothd ControlCenter 2>/dev/null || true
        sleep 3
        #{wifi_reset}
        #{cleanup_script}
      SH
    end
  end
end
