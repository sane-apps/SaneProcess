#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require 'time'

module SaneAppsDependencyBaseline
  BREW = '/opt/homebrew/bin/brew'
  NODE_BIN = '/opt/homebrew/opt/node@24/bin'
  RUBY_BIN = '/opt/homebrew/opt/ruby/bin'
  MARKER_START = '# >>> SaneApps dependency baseline >>>'
  MARKER_END = '# <<< SaneApps dependency baseline <<<'
  LEGACY_LINES = [
    '# Ensure Homebrew and local CLI tools are available in non-login SSH sessions.',
    '# Keep non-interactive SSH shells compatible with Ruby and other UTF-8 tools.',
    'export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"',
    'export LANG="en_US.UTF-8"',
    'export LC_ALL="en_US.UTF-8"'
  ].freeze

  SHARED_FORMULAE = %w[
    node@24 ruby python@3.14 xcodegen swiftlint swiftformat lefthook fastlane
    tailscale gh jq create-dmg mockolo periphery ripgrep xcbeautify
  ].freeze
  SHARED_NPM = %w[
    @modelcontextprotocol/sdk
    @modelcontextprotocol/server-github
    @modelcontextprotocol/server-memory
    @mweinbach/apple-docs-mcp
    @steipete/macos-automator-mcp
  ].freeze
  ROLE_NPM = {
    air: %w[@upstash/context7-mcp firecrawl-cli @google/gemini-cli],
    mini: %w[@agentmemory/agentmemory playwright]
  }.freeze
  FORBIDDEN_GLOBAL_NPM = %w[wrangler].freeze

  module_function

  def role_for(hostname = `hostname`.strip)
    hostname.downcase.include?('mini') ? :mini : :air
  end

  def managed_path(home)
    [NODE_BIN, RUBY_BIN, '/opt/homebrew/bin', '/usr/local/bin',
     File.join(home, '.npm-global', 'bin'), File.join(home, '.local', 'bin'),
     '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':')
  end

  def shell_block(home)
    <<~ZSH.chomp
      #{MARKER_START}
      export PATH="#{managed_path(home)}"
      export LANG="en_US.UTF-8"
      export LC_ALL="en_US.UTF-8"
      #{MARKER_END}
    ZSH
  end

  def normalized_zshenv(source, home)
    inside_managed_block = false
    retained = source.lines.reject do |line|
      stripped = line.chomp
      if stripped == MARKER_START
        inside_managed_block = true
        true
      elsif stripped == MARKER_END
        inside_managed_block = false
        true
      elsif inside_managed_block
        true
      else
        LEGACY_LINES.include?(stripped)
      end
    end
    remainder = retained.join.sub(/\A\s+/, '')
    [shell_block(home), remainder].reject(&:empty?).join("\n\n").rstrip + "\n"
  end

  def install_shell_baseline(home:, apply:)
    path = File.join(home, '.zshenv')
    current = File.exist?(path) ? File.read(path, encoding: 'UTF-8') : ''
    desired = normalized_zshenv(current, home)
    return [true, 'shell baseline current'] if current == desired
    return [false, "shell baseline drift: #{path}"] unless apply

    FileUtils.mkdir_p(File.dirname(path))
    if File.exist?(path)
      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      backup = "#{path}.sane-backup-#{stamp}"
      FileUtils.cp(path, backup, preserve: true)
      FileUtils.chmod(0o600, backup)
    end
    Tempfile.create(['zshenv', '.tmp'], File.dirname(path)) do |tmp|
      tmp.write(desired)
      tmp.flush
      FileUtils.chmod(0o600, tmp.path)
      FileUtils.mv(tmp.path, path)
    end
    [true, "installed shell baseline: #{path}"]
  end

  def capture(*command, env: {})
    Open3.capture3(env, *command)
  end

  def run!(*command, env: {})
    stdout, stderr, status = capture(*command, env: env)
    return stdout if status.success?

    raise "command failed (#{command.join(' ')}):\n#{stdout}#{stderr}"
  end

  def formula_state
    stdout = run!(BREW, 'info', '--json=v2', *SHARED_FORMULAE,
                  env: { 'HOMEBREW_NO_AUTO_UPDATE' => '1' })
    JSON.parse(stdout).fetch('formulae').map do |formula|
      installed = formula.fetch('installed').map { |entry| entry.fetch('version') }
      {
        name: formula.fetch('name'),
        installed: installed,
        stable: formula.dig('versions', 'stable'),
        outdated: formula.fetch('outdated')
      }
    end
  end

  def npm_env(home)
    { 'HOME' => home, 'PATH' => managed_path(home) }
  end

  def npm_packages(role)
    (SHARED_NPM + ROLE_NPM.fetch(role)).uniq
  end

  def npm_state(home)
    stdout = run!(File.join(NODE_BIN, 'npm'), 'ls', '-g', '--depth=0', '--json',
                  env: npm_env(home))
    JSON.parse(stdout).fetch('dependencies', {}).transform_values { |entry| entry['version'] }
  end

  def apply_formulae
    installed = formula_state.to_h { |entry| [entry[:name], entry[:installed].any?] }
    missing = SHARED_FORMULAE.reject { |name| installed[name] }
    present = SHARED_FORMULAE.select { |name| installed[name] }
    run!(BREW, 'install', *missing) if missing.any?
    run!(BREW, 'upgrade', *present) if present.any?
  end

  def apply_npm(role, home)
    npm = File.join(NODE_BIN, 'npm')
    packages = npm_packages(role).map { |name| "#{name}@latest" }
    run!(npm, 'install', '-g', 'npm@latest', *packages, env: npm_env(home))
    FORBIDDEN_GLOBAL_NPM.each do |name|
      current = npm_state(home)
      run!(npm, 'uninstall', '-g', name, env: npm_env(home)) if current.key?(name)
    end
  end

  def check(role:, home:)
    problems = []
    shell_ok, shell_message = install_shell_baseline(home: home, apply: false)
    problems << shell_message unless shell_ok

    formula_state.each do |entry|
      problems << "missing formula: #{entry[:name]}" if entry[:installed].empty?
      problems << "outdated formula: #{entry[:name]} -> #{entry[:stable]}" if entry[:outdated]
    end

    node = File.join(NODE_BIN, 'node')
    npm = File.join(NODE_BIN, 'npm')
    if File.executable?(node) && File.executable?(npm)
      packages = npm_state(home)
      npm_packages(role).each do |name|
        problems << "missing npm package: #{name}" unless packages.key?(name)
      end
      FORBIDDEN_GLOBAL_NPM.each do |name|
        problems << "forbidden global npm package: #{name}" if packages.key?(name)
      end
      node_version = run!(node, '--version').strip
      problems << "Node LTS baseline not active: #{node_version}" unless node_version.start_with?('v24.')
    else
      problems << 'Node 24 LTS runtime is not installed'
    end
    [problems.empty?, problems]
  end

  def main(argv)
    options = { apply: false, role: nil, refresh: false }
    OptionParser.new do |parser|
      parser.banner = 'Usage: dependency_baseline.rb [--check|--apply] [--role air|mini] [--refresh]'
      parser.on('--check') { options[:apply] = false }
      parser.on('--apply') { options[:apply] = true }
      parser.on('--role ROLE', %w[air mini]) { |value| options[:role] = value.to_sym }
      parser.on('--refresh') { options[:refresh] = true }
    end.parse!(argv)

    home = Dir.home
    role = options[:role] || role_for
    ENV['PATH'] = managed_path(home)
    puts "SaneApps dependency baseline role=#{role} mode=#{options[:apply] ? 'apply' : 'check'}"

    run!(BREW, 'update') if options[:apply] && options[:refresh]
    if options[:apply]
      apply_formulae
      ok, message = install_shell_baseline(home: home, apply: true)
      raise message unless ok
      puts message
      apply_npm(role, home)
    end

    ok, problems = check(role: role, home: home)
    if ok
      puts 'PASS dependency baseline current'
      return 0
    end

    problems.each { |problem| warn "- #{problem}" }
    warn 'FAIL dependency baseline drift detected'
    1
  rescue StandardError => e
    warn "ERROR #{e.message}"
    2
  end
end

exit SaneAppsDependencyBaseline.main(ARGV) if $PROGRAM_NAME == __FILE__
