#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'digest'
require 'fileutils'
require 'open3'
require 'socket'
require 'tmpdir'

include TestFramework

SCRIPT = File.expand_path('sync-memory-mini.sh', __dir__)
INSTALLER = File.expand_path('install-memory-sync-agent.sh', __dir__)
AGENTMEMORY_SHIM = File.expand_path('agentmemory-mcp-air.sh', __dir__)
INSTRUCTION_LINT = File.expand_path('../instruction_lint.rb', __dir__)

def memory_paths(home)
  slug = File.join(home, 'SaneApps').tr('/', '-')
  [
    File.join(home, '.claude', 'projects', slug, 'memory'),
    File.join(home, 'SaneApps', '.serena', 'memories'),
    File.join(home, '.codex', 'memories')
  ]
end

def run_sync(air, mini, strict: true, path: '/usr/bin:/bin:/usr/sbin:/sbin')
  args = ['/bin/bash', SCRIPT, '--local-peer-home', mini]
  args << '--strict' if strict
  Open3.capture3({ 'HOME' => air, 'PATH' => path }, *args)
end

def conflict_archive_root(home)
  File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'memory-conflicts')
end

def active_conflicts(home)
  memory_paths(home).flat_map { |path| Dir.glob(File.join(path, '**', '*.sane-conflict-*')) }
end

def archived_payloads(home)
  Dir.glob(File.join(conflict_archive_root(home), '**', '*')).select do |path|
    File.file?(path) && File.basename(path) != 'manifest.tsv'
  end
end

def run_instruction_lint(home)
  Open3.capture3({ 'HOME' => home }, '/usr/bin/ruby', INSTRUCTION_LINT)
end

exit(run_tests('Memory Sync Tests') do
  test_category('two-way no-delete parity') do
    test('unions one-sided files in both directions') do
      Dir.mktmpdir('memory-sync') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        air_paths = memory_paths(air)
        mini_paths = memory_paths(mini)
        (air_paths + mini_paths).each { |path| FileUtils.mkdir_p(path) }
        File.write(File.join(air_paths[0], 'air.md'), 'air')
        File.write(File.join(mini_paths[0], 'mini.md'), 'mini')

        _out, err, status = run_sync(air, mini)
        assert(status.success?, err)
        assert(File.read(File.join(air_paths[0], 'mini.md')) == 'mini')
        assert(File.read(File.join(mini_paths[0], 'air.md')) == 'air')
        true
      end
    end

    test('discovers one-sided project Serena memory and keeps repeated sync parity-safe') do
      Dir.mktmpdir('project-serena-sync') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        (memory_paths(air) + memory_paths(mini)).each { |path| FileUtils.mkdir_p(path) }

        relative = File.join('infra', 'SaneProcess', '.serena', 'memories')
        air_project = File.join(air, 'SaneApps', relative)
        mini_project = File.join(mini, 'SaneApps', relative)
        FileUtils.mkdir_p(mini_project)
        source = File.join(mini_project, 'air-mini-memory-parity-apr25-2026.md')
        File.write(source, "project-local Serena memory\n")

        archived_memory = File.join(
          air, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'dirty-work-snapshots',
          'fixture', '.serena', 'memories'
        )
        FileUtils.mkdir_p(archived_memory)
        File.write(File.join(archived_memory, 'must-not-sync.md'), "archive only\n")
        preserved_memory = File.join(
          air, 'SaneApps', 'archive', 'SaneProcess-preserved', '.serena', 'memories'
        )
        FileUtils.mkdir_p(preserved_memory)
        File.write(File.join(preserved_memory, 'must-not-sync.md'), "preserved archive only\n")

        external = File.join(root, 'external-serena')
        FileUtils.mkdir_p(File.join(external, 'memories'))
        File.write(File.join(external, 'memories', 'must-not-follow.md'), "external\n")
        symlink_project = File.join(air, 'SaneApps', 'apps', 'Symlinked')
        FileUtils.mkdir_p(symlink_project)
        FileUtils.ln_s(external, File.join(symlink_project, '.serena'))

        first_out, first_err, first_status = run_sync(air, mini)
        assert(first_status.success?, first_out + first_err)
        peer_file = File.join(air_project, File.basename(source))
        assert(File.read(peer_file) == "project-local Serena memory\n")
        first_hashes = [source, peer_file].map { |path| Digest::SHA256.file(path).hexdigest }
        assert(first_hashes.uniq.length == 1, first_hashes.inspect)
        assert(!File.exist?(File.join(mini, 'SaneApps', 'infra', 'SaneProcess', 'outputs',
                                      'dirty-work-snapshots', 'fixture', '.serena', 'memories', 'must-not-sync.md')))
        assert(!File.exist?(File.join(mini, 'SaneApps', 'archive', 'SaneProcess-preserved',
                                      '.serena', 'memories', 'must-not-sync.md')))
        assert(!File.exist?(File.join(mini, 'SaneApps', 'apps', 'Symlinked', '.serena',
                                      'memories', 'must-not-follow.md')))

        second_out, second_err, second_status = run_sync(air, mini)
        assert(second_status.success?, second_out + second_err)
        second_hashes = [source, peer_file].map { |path| Digest::SHA256.file(path).hexdigest }
        assert(second_hashes == first_hashes, "repeated sync changed project memory: #{second_hashes.inspect}")
        assert_includes(second_out, 'already in parity')
        true
      end
    end

    test('archives the losing version privately while the canonical file wins') do
      Dir.mktmpdir('memory-conflict') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        air_paths = memory_paths(air)
        mini_paths = memory_paths(mini)
        (air_paths + mini_paths).each { |path| FileUtils.mkdir_p(path) }
        air_file = File.join(air_paths[2], 'shared.md')
        mini_file = File.join(mini_paths[2], 'shared.md')
        File.write(air_file, 'air-version')
        File.write(mini_file, 'mini-version')
        old = Time.now - 120
        File.utime(old, old, air_file)
        File.utime(Time.now, Time.now, mini_file)

        _out, err, status = run_sync(air, mini)
        assert(status.success?, err)
        assert(File.read(air_file) == 'mini-version')
        assert(File.read(mini_file) == 'mini-version')
        assert(active_conflicts(air).empty?, active_conflicts(air).inspect)
        assert(active_conflicts(mini).empty?, active_conflicts(mini).inspect)

        air_archive = conflict_archive_root(air)
        payloads = archived_payloads(air)
        assert(payloads.any? { |path| File.binread(path) == 'air-version' }, payloads.inspect)
        manifest = Dir.glob(File.join(air_archive, '**', 'manifest.tsv')).first
        assert(manifest, 'missing local conflict archive manifest')
        receipt = File.read(manifest)
        assert_includes(receipt, 'sane-memory-conflict-archive-v1')
        assert_includes(receipt, 'shared.md')
        assert_includes(receipt, Digest::SHA256.hexdigest('air-version'))
        assert_includes(receipt, "file\trsync\t")
        assert((File.stat(air_archive).mode & 0o777) == 0o700, 'archive root is not private')
        Dir.glob(File.join(air_archive, '**', '*')).each do |path|
          expected = File.directory?(path) ? 0o700 : 0o600
          assert((File.stat(path).mode & 0o777) == expected, "unsafe archive mode for #{path}")
        end

        lint_out, lint_err, lint_status = run_instruction_lint(air)
        assert(lint_status.success?, lint_out + lint_err)
        assert_includes(lint_out, 'CLEAN')
        true
      end
    end

    test('moves legacy conflict artifacts to hashed private archives') do
      Dir.mktmpdir('memory-legacy-conflict') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        air_paths = memory_paths(air)
        mini_paths = memory_paths(mini)
        (air_paths + mini_paths).each { |path| FileUtils.mkdir_p(path) }
        air_file = File.join(air_paths[0], 'canonical.md')
        mini_file = File.join(mini_paths[0], 'canonical.md')
        File.write(air_file, 'canonical')
        File.write(mini_file, 'canonical')
        air_legacy = File.join(air_paths[0], 'canonical.md.sane-conflict-local-old')
        mini_legacy = File.join(mini_paths[0], 'canonical.md.sane-conflict-peer-old')
        File.write(air_legacy, 'losing-local')
        File.write(mini_legacy, 'losing-peer')

        _out, err, status = run_sync(air, mini)
        assert(status.success?, err)
        assert(File.read(air_file) == 'canonical')
        assert(File.read(mini_file) == 'canonical')
        assert(active_conflicts(air).empty?, active_conflicts(air).inspect)
        assert(active_conflicts(mini).empty?, active_conflicts(mini).inspect)
        assert(archived_payloads(air).any? { |path| File.binread(path) == 'losing-local' })
        assert(archived_payloads(mini).any? { |path| File.binread(path) == 'losing-peer' })

        air_receipts = Dir.glob(File.join(conflict_archive_root(air), '**', 'manifest.tsv')).map { |path| File.read(path) }
        mini_receipts = Dir.glob(File.join(conflict_archive_root(mini), '**', 'manifest.tsv')).map { |path| File.read(path) }
        assert(air_receipts.any? { |receipt| receipt.include?(Digest::SHA256.hexdigest('losing-local')) })
        assert(mini_receipts.any? { |receipt| receipt.include?(Digest::SHA256.hexdigest('losing-peer')) })
        assert(air_receipts.any? { |receipt| receipt.include?("file\tlegacy\tcanonical.md.sane-conflict-local-old") })
        assert(mini_receipts.any? { |receipt| receipt.include?("file\tlegacy\tcanonical.md.sane-conflict-peer-old") })

        [air, mini].each do |home|
          archive = conflict_archive_root(home)
          assert((File.stat(archive).mode & 0o777) == 0o700, "archive root is not private for #{home}")
          Dir.glob(File.join(archive, '**', '*')).each do |path|
            expected = File.directory?(path) ? 0o700 : 0o600
            assert((File.stat(path).mode & 0o777) == expected, "unsafe archive mode for #{path}")
          end
          lint_out, lint_err, lint_status = run_instruction_lint(home)
          assert(lint_status.success?, lint_out + lint_err)
          assert_includes(lint_out, 'CLEAN')
        end
        true
      end
    end

    test('held Mini lock serializes overlapping syncs without mutation') do
      Dir.mktmpdir('memory-lock') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        air_paths = memory_paths(air)
        mini_paths = memory_paths(mini)
        (air_paths + mini_paths).each { |path| FileUtils.mkdir_p(path) }
        FileUtils.mkdir_p(File.join(mini, '.cache', 'saneapps-memory-sync.lock'))
        File.write(File.join(air_paths[0], 'blocked.md'), 'blocked')

        out, err, status = run_sync(air, mini, strict: false)
        assert(status.success?, out + err)
        assert_includes(err, 'another sync owns the Mini lock')
        assert(!File.exist?(File.join(mini_paths[0], 'blocked.md')))
        true
      end
    end

    test('an old lock owned by a live controller process is never stolen') do
      Dir.mktmpdir('memory-live-lock') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        (memory_paths(air) + memory_paths(mini)).each { |path| FileUtils.mkdir_p(path) }
        lock = File.join(mini, '.cache', 'saneapps-memory-sync.lock')
        FileUtils.mkdir_p(lock)
        owner = File.join(lock, 'owner')
        File.write(owner, "#{Socket.gethostname.split('.').first}:#{Process.pid}:old\n")
        old = Time.now - 7200
        File.utime(old, old, lock)
        File.utime(old, old, owner)

        out, err, status = run_sync(air, mini, strict: false)
        assert(status.success?, out + err)
        assert_includes(err, 'another sync owns the Mini lock')
        assert(File.read(owner).include?(Process.pid.to_s), 'live owner lock was replaced')
        true
      end
    end

    test('strict mode fails closed when a parity rsync probe fails') do
      Dir.mktmpdir('memory-rsync-failure') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        (memory_paths(air) + memory_paths(mini)).each { |path| FileUtils.mkdir_p(path) }
        bin = File.join(root, 'bin')
        FileUtils.mkdir_p(bin)
        fake_rsync = File.join(bin, 'rsync')
        File.write(fake_rsync, "#!/bin/sh\necho injected-rsync-failure >&2\nexit 23\n")
        FileUtils.chmod(0o755, fake_rsync)

        _out, err, status = run_sync(air, mini, path: "#{bin}:/usr/bin:/bin:/usr/sbin:/sbin")
        assert(!status.success?, 'failed parity probe was reported as success')
        assert_includes(err, 'parity probe failed')
        true
      end
    end

    test('backup failure aborts before either memory store is mutated') do
      Dir.mktmpdir('memory-backup-failure') do |root|
        air = File.join(root, 'air')
        mini = File.join(root, 'mini')
        air_paths = memory_paths(air)
        mini_paths = memory_paths(mini)
        (air_paths + mini_paths).each { |path| FileUtils.mkdir_p(path) }
        File.write(File.join(air_paths[0], 'air-only.md'), "do not copy\n")
        bin = File.join(root, 'bin')
        FileUtils.mkdir_p(bin)
        fake_cp = File.join(bin, 'cp')
        File.write(fake_cp, "#!/bin/sh\necho injected-backup-failure >&2\nexit 1\n")
        FileUtils.chmod(0o755, fake_cp)

        _out, err, status = run_sync(air, mini, path: "#{bin}:/usr/bin:/bin:/usr/sbin:/sbin")
        assert(!status.success?, 'backup failure was reported as success')
        assert_includes(err, 'baseline backup failed')
        assert(!File.exist?(File.join(mini_paths[0], 'air-only.md')), 'sync mutated peer after backup failure')
        true
      end
    end
  end

  test_category('Air recurrence') do
    test('installs recurrence plus one persistent AgentMemory tunnel LaunchAgent') do
      Dir.mktmpdir('memory-agent') do |dir|
        fixture_dir = File.join(dir, 'scripts', 'automation')
        FileUtils.mkdir_p(fixture_dir)
        FileUtils.cp(SCRIPT, File.join(fixture_dir, 'sync-memory-mini.sh'))
        FileUtils.cp(INSTALLER, File.join(fixture_dir, 'install-memory-sync-agent.sh'))
        FileUtils.cp(AGENTMEMORY_SHIM, File.join(fixture_dir, 'agentmemory-mcp-air.sh'))
        FileUtils.chmod(0o755, File.join(fixture_dir, 'sync-memory-mini.sh'))
        FileUtils.chmod(0o755, File.join(fixture_dir, 'agentmemory-mcp-air.sh'))
        plist = File.join(dir, 'memory-sync.plist')
        tunnel_plist = File.join(dir, 'agentmemory-tunnel.plist')
        env = {
          'HOME' => dir,
          'SANE_MEMORY_SYNC_PLIST' => plist,
          'SANE_AGENTMEMORY_TUNNEL_PLIST' => tunnel_plist,
          'SANE_MEMORY_SYNC_LOG_DIR' => File.join(dir, 'logs')
        }
        out, err, status = Open3.capture3(env, '/bin/bash', File.join(fixture_dir, 'install-memory-sync-agent.sh'), '--dry-run')
        assert(status.success?, err)
        assert_includes(out, 'Validated Air memory-sync LaunchAgent')
        assert(!File.exist?(plist), 'dry-run wrote the memory sync plist')
        assert(!File.exist?(tunnel_plist), 'dry-run wrote the tunnel plist')
        assert(!Dir.exist?(File.join(dir, 'logs')), 'dry-run created the log directory')

        launchctl = File.join(dir, 'launchctl')
        launchctl_log = File.join(dir, 'launchctl.log')
        File.write(launchctl, "#!/bin/sh\necho \"$*\" >> \"$LAUNCHCTL_LOG\"\nexit 0\n")
        FileUtils.chmod(0o755, launchctl)
        install_env = env.merge(
          'SANE_MEMORY_SYNC_HOST_OVERRIDE' => 'fixture-macbook-air',
          'SANE_LAUNCHCTL_BIN' => launchctl,
          'LAUNCHCTL_LOG' => launchctl_log
        )
        _install_out, install_err, install_status = Open3.capture3(
          install_env, '/bin/bash', File.join(fixture_dir, 'install-memory-sync-agent.sh')
        )
        assert(install_status.success?, install_err)
        source = File.read(plist)
        assert_includes(source, '<string>com.saneapps.memory-sync</string>')
        assert_includes(source, '<key>RunAtLoad</key>')
        assert_includes(source, '<key>StartInterval</key>')
        assert_includes(source, '<integer>900</integer>')
        tunnel_source = File.read(tunnel_plist)
        assert_includes(tunnel_source, '<string>com.saneapps.agentmemory-tunnel</string>')
        assert_includes(tunnel_source, '<string>--tunnel</string>')
        assert_includes(tunnel_source, '<key>RunAtLoad</key>')
        assert_includes(tunnel_source, '<key>KeepAlive</key>')
        assert_includes(tunnel_source, '<key>ThrottleInterval</key>')
        assert_includes(tunnel_source, 'agentmemory_tunnel.stderr.log')
        assert_includes(File.read(launchctl_log), 'bootstrap gui/')
        _bad_out, bad_err, bad_status = Open3.capture3(env, '/bin/bash', File.join(fixture_dir, 'install-memory-sync-agent.sh'), 'mini')
        assert(!bad_status.success?, 'installer silently accepted an unknown host argument')
        assert_includes(bad_err, 'Usage:')
        true
      end
    end

    test('Air MCP shim uses one kickstarted owner and fails closed without health') do
      source = File.read(AGENTMEMORY_SHIM)
      assert_includes(source, 'kickstart "gui/')
      assert_includes(source, 'AGENTMEMORY_FORCE_PROXY=1')
      assert_includes(source, 'ServerAliveInterval=15')
      assert_includes(source, 'ServerAliveCountMax=3')
      assert_includes(source, 'ExitOnForwardFailure=yes')
      assert(!source.include?('kickstart -k'), 'MCP clients must not kill a shared tunnel owned by another client')
      assert(!source.include?('ssh -f'), 'shim must not create a detached per-client tunnel')
      true
    end

    test('Air MCP shim kickstarts the owner before executing the forced-proxy MCP') do
      Dir.mktmpdir('agentmemory-air-shim') do |dir|
        health_count = File.join(dir, 'health-count')
        launchctl_log = File.join(dir, 'launchctl.log')
        npx_log = File.join(dir, 'npx.log')
        fake_launchctl = File.join(dir, 'launchctl')
        fake_curl = File.join(dir, 'curl')
        fake_npx = File.join(dir, 'npx')
        File.write(fake_launchctl, "#!/bin/sh\necho \"$*\" > \"$LAUNCHCTL_LOG\"\n")
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          count=0
          [ ! -f "$HEALTH_COUNT" ] || count="$(cat "$HEALTH_COUNT")"
          count=$((count + 1))
          echo "$count" > "$HEALTH_COUNT"
          [ "$count" -ge 2 ]
        SH
        File.write(fake_npx, <<~SH)
          #!/bin/sh
          printf 'args=%s\nurl=%s\nforce=%s\n' "$*" "$AGENTMEMORY_URL" "$AGENTMEMORY_FORCE_PROXY" > "$NPX_LOG"
        SH
        FileUtils.chmod(0o755, [fake_launchctl, fake_curl, fake_npx])
        env = {
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_NPX_BIN' => fake_npx,
          'SANE_AGENTMEMORY_WAIT_INTERVAL' => '0',
          'HEALTH_COUNT' => health_count,
          'LAUNCHCTL_LOG' => launchctl_log,
          'NPX_LOG' => npx_log
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', AGENTMEMORY_SHIM)
        assert(status.success?, err)
        assert_includes(File.read(launchctl_log), 'kickstart gui/')
        mcp = File.read(npx_log)
        assert_includes(mcp, 'args=-y @agentmemory/mcp')
        assert_includes(mcp, 'url=http://127.0.0.1:3111')
        assert_includes(mcp, 'force=1')
        true
      end
    end

    test('foreground tunnel mode execs bounded SSH without launchctl') do
      Dir.mktmpdir('agentmemory-air-tunnel') do |dir|
        ssh_log = File.join(dir, 'ssh.log')
        fake_ssh = File.join(dir, 'ssh')
        File.write(fake_ssh, "#!/bin/sh\necho \"$*\" > \"$SSH_LOG\"\n")
        FileUtils.chmod(0o755, fake_ssh)
        env = { 'SANE_SSH_BIN' => fake_ssh, 'SSH_LOG' => ssh_log }
        _out, err, status = Open3.capture3(env, '/bin/bash', AGENTMEMORY_SHIM, '--tunnel')
        assert(status.success?, err)
        ssh = File.read(ssh_log)
        assert_includes(ssh, '-N')
        assert_includes(ssh, 'ExitOnForwardFailure=yes')
        assert_includes(ssh, 'ServerAliveInterval=15')
        assert_includes(ssh, 'ServerAliveCountMax=3')
        assert_includes(ssh, '-L 3111:127.0.0.1:3111 mini')
        true
      end
    end
  end
end)
