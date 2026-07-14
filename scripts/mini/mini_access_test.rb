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
      assert_includes(log, 'tailscale ping -c 1 --timeout=3s stephans-mac-mini')
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
        write_executable(File.join(bin, 'tailscale'), "#!/bin/sh\n[ \"${1:-}\" = status ]\n")
        env = { 'HOME' => home, 'PATH' => "#{bin}:/usr/bin:/bin" }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(status.success?, err)
        config = File.read(File.join(home, '.ssh', 'config.d', 'saneapps-mini.conf'))
        proxy = File.read(File.join(home, '.local', 'bin', 'saneapps-mini-proxy'))
        tailscale_cli = File.read(File.join(home, '.local', 'bin', 'tailscale'))
        assert_includes(config, 'Host mini mini-remote')
        assert_includes(config, 'ProxyCommand ~/.local/bin/saneapps-mini-proxy')
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
end)
