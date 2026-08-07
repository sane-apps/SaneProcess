#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'socket'
require 'tmpdir'

include TestFramework

PROXY = File.expand_path('saneapps-mini-proxy.sh', __dir__)
INSTALLER = File.expand_path('install-mini-ssh-config.sh', __dir__)
TAILSCALE_CLI = File.expand_path('saneapps-tailscale.sh', __dir__)
AIR_RETURN_INSTALLER = File.expand_path('install-air-return-ssh.sh', __dir__)

def write_executable(path, body)
  File.write(path, body)
  FileUtils.chmod(0o755, path)
end

def run_proxy(lan:, tailscale:)
  Dir.mktmpdir('mini-access-test') do |dir|
    bin = File.join(dir, 'bin')
    log = File.join(dir, 'calls.log')
    FileUtils.mkdir_p(bin)
    write_executable(File.join(bin, 'nc'), <<~SH)
      #!/bin/sh
      echo "nc $*" >> "$PROXY_LOG"
      [ "${1:-}" = "-z" ] && exit "$LAN_OK"
      exit 0
    SH
    write_executable(File.join(bin, 'tailscale'), <<~SH)
      #!/bin/sh
      echo "tailscale $*" >> "$PROXY_LOG"
      [ "${1:-}" = "ping" ] && exit "$TS_OK"
      exit 0
    SH
    env = {
      'HOME' => dir,
      'PATH' => "#{bin}:/usr/bin:/bin",
      'PROXY_LOG' => log,
      'LAN_OK' => lan ? '0' : '1',
      'TS_OK' => tailscale ? '0' : '1'
    }
    stdout, stderr, status = Open3.capture3(env, '/bin/bash', PROXY)
    [stdout, stderr, status, File.exist?(log) ? File.read(log) : '']
  end
end

def run_tailscale_cli(userspace:)
  Dir.mktmpdir('tailscale-cli-test') do |dir|
    native = File.join(dir, 'tailscale-native')
    socket_path = File.join(dir, 'tailscaled.sock')
    log = File.join(dir, 'calls.log')
    write_executable(native, <<~SH)
      #!/bin/sh
      printf '%s\n' "$*" > "$TAILSCALE_LOG"
    SH
    server = userspace ? UNIXServer.new(socket_path) : nil
    env = {
      'HOME' => dir,
      'SANE_TAILSCALE_BIN' => native,
      'SANE_TAILSCALE_SOCKET' => socket_path,
      'TAILSCALE_LOG' => log
    }
    _stdout, stderr, status = Open3.capture3(env, '/bin/bash', TAILSCALE_CLI, 'status')
    [stderr, status, File.read(log)]
  ensure
    server&.close
  end
end

exit(run_tests('Mini Access Tests') do
  test_category('connection ladder') do
    test('uses direct LAN first') do
      _out, err, status, log = run_proxy(lan: true, tailscale: true)
      assert(status.success?, err)
      assert_includes(log, 'nc -z -G 2 stephans-mac-mini.local 22')
      assert_includes(log, 'nc stephans-mac-mini.local 22')
      assert(!log.include?('tailscale'), log)
      true
    end

    test('falls back to authenticated Tailscale') do
      _out, err, status, log = run_proxy(lan: false, tailscale: true)
      assert(status.success?, err)
      assert_includes(log, 'tailscale ping -c 1 --timeout=5s stephans-mac-mini')
      assert_includes(log, 'tailscale nc stephans-mac-mini 22')
      true
    end

    test('fails clearly when both private routes are unavailable') do
      _out, err, status, log = run_proxy(lan: false, tailscale: false)
      assert(status.exitstatus == 255, "status=#{status.exitstatus} log=#{log}")
      assert_includes(err, 'LAN and Tailscale are unavailable')
      true
    end
  end

  test_category('controller installation') do
    test('installs restart-durable private-route config without Cloudflare') do
      Dir.mktmpdir('mini-access-installer') do |home|
        bin = File.join(home, 'bin')
        FileUtils.mkdir_p(bin)
        fake_tailscale = File.join(bin, 'tailscale')
        fake_launchctl = File.join(bin, 'launchctl-must-not-run')
        tailscale_log = File.join(home, 'tailscale-calls.log')
        write_executable(fake_tailscale, "#!/bin/sh\necho \"$*\" >> \"$TAILSCALE_LOG\"\n[ \"${1:-}\" = status ]\n")
        write_executable(fake_launchctl, "#!/bin/sh\necho real-launchctl-path-reached >&2\nexit 97\n")
        env = {
          'HOME' => home,
          'PATH' => "#{bin}:/usr/bin:/bin",
          'SANE_TAILSCALE_BIN' => fake_tailscale,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'TAILSCALE_LOG' => tailscale_log
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(status.success?, err)
        assert(!err.include?('real-launchctl-path-reached'), err)
        assert_includes(File.read(tailscale_log), 'status')
        config = File.read(File.join(home, '.ssh', 'config.d', 'saneapps-mini.conf'))
        proxy = File.read(File.join(home, '.local', 'bin', 'saneapps-mini-proxy'))
        tailscale_cli = File.read(File.join(home, '.local', 'bin', 'tailscale'))
        assert_includes(config, 'Host mini mini-remote')
        assert_includes(config, 'ProxyCommand ~/.local/bin/saneapps-mini-proxy')
        assert_includes(config, 'Host 100.77.120.83 stephans-mac-mini')
        assert_includes(config, 'User stephansmac')
        raw_alias = config.split('Host 100.77.120.83 stephans-mac-mini', 2).last.split("\nHost ", 2).first
        assert_includes(raw_alias, 'ProxyCommand ~/.local/bin/saneapps-mini-proxy')
        assert(!raw_alias.include?('User sj'), raw_alias)
        assert_includes(proxy, 'Tailscale')
        assert_includes(tailscale_cli, 'USERSPACE_SOCKET')
        assert(!config.include?('Cloudflare'))
        assert(!proxy.include?('trycloudflare'))
        true
      end
    end


    test('normal Tailscale commands select the active daemon socket') do
      userspace_err, userspace_status, userspace_log = run_tailscale_cli(userspace: true)
      system_err, system_status, system_log = run_tailscale_cli(userspace: false)
      assert(userspace_status.success?, userspace_err)
      assert(system_status.success?, system_err)
      assert_includes(userspace_log, '--socket=')
      assert_includes(userspace_log, 'tailscaled.sock status')
      assert(system_log.strip == 'status', system_log)
      true
    end
  end

  test_category('return connection') do
    test('installs a dedicated non-forwarded Mini-to-Air identity') do
      Dir.mktmpdir('air-return-installer') do |home|
        bin = File.join(home, 'bin')
        FileUtils.mkdir_p(bin)
        fake_ssh = File.join(bin, 'ssh')
        ssh_log = File.join(home, 'ssh.log')
        air_keys = File.join(home, 'air-authorized-keys')
        write_executable(fake_ssh, <<~SH)
          #!/bin/sh
          echo "$*" >> "$SANE_SSH_LOG"
          if [ ! -t 0 ]; then
            key="$(cat)"
            [ -z "$key" ] || printf '%s\n' "$key" >> "$SANE_AIR_AUTHORIZED_KEYS"
          fi
          exit 0
        SH
        env = {
          'HOME' => home,
          'SANE_AIR_HOST' => '100.64.240.115',
          'SANE_AIR_KEY_FILE' => File.join(home, '.ssh', 'saneapps-mini-to-air'),
          'SANE_SSH_BIN' => fake_ssh,
          'SANE_SSH_LOG' => ssh_log,
          'SANE_AIR_AUTHORIZED_KEYS' => air_keys
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', AIR_RETURN_INSTALLER)
        assert(status.success?, err)
        config = File.read(File.join(home, '.ssh', 'config.d', 'saneapps-air.conf'))
        private_key = File.join(home, '.ssh', 'saneapps-mini-to-air')
        assert(File.exist?(private_key), 'dedicated private key must exist')
        assert(File.executable?(AIR_RETURN_INSTALLER), 'installer must be executable')
        assert_includes(config, 'Host air air-remote 100.64.240.115')
        assert_includes(config, "IdentityFile #{private_key}")
        assert_includes(config, 'IdentitiesOnly yes')
        assert_includes(config, 'ForwardAgent no')
        assert_includes(File.read(ssh_log), '-F /dev/null')
        assert_includes(File.read(ssh_log), '-o BatchMode=yes air')
        assert_includes(File.read(air_keys), 'saneapps-mini-to-air')
        true
      end
    end
  end
end)
