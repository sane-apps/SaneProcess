#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'dependency_baseline'

$assertion_count = 0

def assert(condition, message)
  $assertion_count += 1
  raise message unless condition
end

Dir.mktmpdir('dependency-baseline') do |home|
  legacy = <<~ZSH
    # Ensure Homebrew and local CLI tools are available in non-login SSH sessions.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
    export LANG="en_US.UTF-8"
    export LC_ALL="en_US.UTF-8"

    export KEEP_ME="yes"
  ZSH
  desired = SaneAppsDependencyBaseline.normalized_zshenv(legacy, home)
  assert(desired.scan(SaneAppsDependencyBaseline::MARKER_START).length == 1,
         'managed shell block duplicated')
  assert(desired.include?('/opt/homebrew/opt/node@24/bin'), 'Node 24 path missing')
  assert(desired.include?('/opt/homebrew/opt/ruby/bin'), 'Homebrew Ruby path missing')
  managed_path = SaneAppsDependencyBaseline.managed_path(home)
  assert(managed_path.index(File.join(home, '.local', 'bin')) < managed_path.index('/opt/homebrew/bin'),
         'managed command wrappers must precede Homebrew shims')
  assert(desired.include?('export KEEP_ME="yes"'), 'unmanaged shell content was lost')
  assert(!desired.include?('$HOME/.local/bin:$PATH'), 'legacy path survived migration')
  assert(SaneAppsDependencyBaseline.normalized_zshenv(desired, home) == desired,
         'shell migration is not idempotent')
end

assert(SaneAppsDependencyBaseline::SHARED_FORMULAE.include?('node@24'),
       'Node LTS formula missing')
assert(!SaneAppsDependencyBaseline::SHARED_FORMULAE.include?('bash'),
       'Homebrew Bash must not replace Apple Bash compatibility')
assert(!SaneAppsDependencyBaseline::SHARED_NPM.include?('wrangler'),
       'release-pinned Wrangler must not become a global baseline')
assert(SaneAppsDependencyBaseline::FORBIDDEN_GLOBAL_NPM.include?('npm'),
       'Node LTS must use its bundled npm to prevent CLI drift')
assert(SaneAppsDependencyBaseline.npm_packages(:mini).include?('playwright'),
       'Mini browser dependency missing')
assert(SaneAppsDependencyBaseline.npm_packages(:mini).include?('firecrawl-cli'),
       'Mini Grok research CLI missing')
assert(SaneAppsDependencyBaseline.npm_packages(:air).include?('firecrawl-cli'),
       'Air Firecrawl CLI missing after shared move')
assert(SaneAppsDependencyBaseline.npm_packages(:air).include?('@upstash/context7-mcp'),
       'Air research dependency missing')
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['firecrawl-cli'] == '1.23.3',
       'Firecrawl CLI pin drifted')
assert(SaneAppsDependencyBaseline::NODE_BIN.end_with?('/node@24/bin'),
       'Node LTS executable path drifted')
assert(SaneAppsDependencyBaseline.formulae(:mini).include?('pango'),
       'Mini PDF renderer dependency missing')
assert(!SaneAppsDependencyBaseline.formulae(:air).include?('pango'),
       'Air should not inherit the Mini-only PDF renderer stack')

all_packages = (
  SaneAppsDependencyBaseline.npm_packages(:air) +
  SaneAppsDependencyBaseline.npm_packages(:mini)
).uniq.sort
assert(SaneAppsDependencyBaseline::NPM_VERSIONS.keys.sort == all_packages,
       'every managed npm package must have exactly one version pin')
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['@steipete/macos-automator-mcp'] == '0.4.7',
       'macOS Automator MCP pin drifted')
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['firecrawl-cli'] == '1.23.3',
       'Firecrawl CLI pin drifted')
assert(SaneAppsDependencyBaseline::SAFE_AUTO_BUMP == %w[firecrawl-cli],
       'keep-current auto-bump allowlist drifted')
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['@upstash/context7-mcp'] == '4.0.5',
       'Context7 MCP pin drifted')
assert(SaneAppsDependencyBaseline.npm_specs(:mini).include?('@agentmemory/agentmemory@0.9.29'),
       'Mini AgentMemory install is not version-pinned')
assert(SaneAppsDependencyBaseline.npm_specs(:air).none? { |spec| spec.end_with?('@latest') },
       'dependency apply must not float managed packages to latest')

mini_installed = SaneAppsDependencyBaseline.npm_packages(:mini).to_h do |name|
  [name, SaneAppsDependencyBaseline::NPM_VERSIONS.fetch(name)]
end
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, mini_installed).empty?,
       'exact Mini package pins should pass')

drifted = mini_installed.merge('@steipete/macos-automator-mcp' => '0.4.1')
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, drifted).any? { |problem| problem.include?('0.4.1 != 0.4.7') },
       'version drift must fail the dependency check')
assert(SaneAppsDependencyBaseline.same_major?('1.19.26', '1.23.1'),
       'Firecrawl minor bumps stay auto-eligible')
assert(!SaneAppsDependencyBaseline.same_major?('1.23.1', '2.0.0'),
       'Firecrawl major bumps must not auto-apply')
grok_bin = File.expand_path('../grok-bin', __dir__)
%w[cloudflare-mcp-remote.sh agentmemory-mcp-remote.sh xcode-mcp.sh xcode-mcp-frame.py].each do |name|
  path = File.join(grok_bin, name)
  assert(File.executable?(path), "git-owned grok helper missing: #{path}")
end
self_test = `#{File.join(grok_bin, 'agentmemory-mcp-remote.sh')} --self-test 2>&1`
assert($?.success? && self_test.include?('self-test: pass'),
       "agentmemory-mcp-remote --self-test failed: #{self_test}")
sync = File.read(File.expand_path('sync-grok-mini.sh', __dir__))
assert(!sync.include?('rsync -az --delete "$REPO_GROK_BIN_DIR/"'),
       'sync_grok must not --delete ~/.grok/bin')
assert(SaneAppsDependencyBaseline::SAFE_AUTO_BUMP.none? { |name| name.include?('macos-automator') },
       'macos-automator pin is shared across singleton files; do not auto-rewrite it')

forbidden = mini_installed.merge('npm' => '99.0.0')
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, forbidden).include?('forbidden global npm package: npm'),
       'forbidden global packages must fail the dependency check')

# Intercept the first check/mutation, but use a real child process to prove
# inherited policy. No package manager or credential lookup runs.
require 'rbconfig'
require 'stringio'
baseline = SaneAppsDependencyBaseline
[
  [%w[--check --role mini], :check],
  [%w[--apply --role mini], :apply_formulae],
  [%w[--apply --npm-only --role air], :apply_npm]
].each do |args, first_call|
  saved_env, saved_stdout = ENV.to_h, $stdout
  original = baseline.method(first_call)
  output = StringIO.new
  begin
    ENV.update('SANE_NO_KEYCHAIN' => '0', 'SANE_KEYCHAIN_FALLBACK' => '1',
               'SANE_ALLOW_KEYCHAIN_PROMPTS' => '1')
    $stdout = output
    baseline.define_singleton_method(first_call) do |*_, **_keywords|
      stdout, _, status = capture(RbConfig.ruby, '-rjson', '-e',
                                 'puts JSON.generate(ENV.to_h.select { |k,_| k.start_with?("SANE_") })')
      throw :observed_policy, [JSON.parse(stdout), status.success?]
    end
    inherited, success = catch(:observed_policy) { baseline.main(args) }
    assert(success && inherited.values_at('SANE_NO_KEYCHAIN', 'SANE_KEYCHAIN_FALLBACK',
                                         'SANE_ALLOW_KEYCHAIN_PROMPTS') == %w[1 0 0],
           "#{first_call} ran before no-prompt policy reached child processes")
    next unless args.include?('--apply')

    role = args.last.to_sym
    targets = args.include?('--npm-only') ? '(none)' : baseline.formulae(role).join(', ')
    assert(output.string.include?("Formula targets: #{targets}"), 'formula plan missing before mutation')
    assert(output.string.include?("npm targets: #{baseline.npm_specs(role).join(', ')}"),
           'exact npm plan missing before mutation')
    assert(output.string.include?('require separate preflight'), 'manual permission boundary missing')
  ensure
    baseline.define_singleton_method(first_call, original)
    ENV.replace(saved_env)
    $stdout = saved_stdout
  end
end

Dir.mktmpdir('no-client-bootstrap') do |dir|
  saved_path = ENV['PATH']
  log = File.join(dir, 'client-started')
  %w[claude codex].each do |name|
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\necho started >> '#{log}'\necho 1.0\n")
    File.chmod(0o755, path)
  end
  begin
    ENV['PATH'] = "#{dir}:#{saved_path}"
    baseline.client_version_rows
    assert(!File.exist?(log), 'version reporting executed a native client launcher')
  ensure
    ENV['PATH'] = saved_path
  end
end


# A moved tap must retain its qualified name or the next updater targets the old formula.
baseline = SaneAppsDependencyBaseline
original_run = baseline.method(:run!)
begin
  baseline.define_singleton_method(:run!) do |*_, **_kwargs|
    JSON.generate('formulae' => [
      { 'name' => 'peekaboo', 'full_name' => 'openclaw/tap/peekaboo',
        'installed' => [{ 'version' => '4.3.1' }], 'versions' => { 'stable' => '4.3.1' }, 'outdated' => false },
      { 'name' => 'ruby', 'installed' => [{ 'version' => '4.0.1' }],
        'versions' => { 'stable' => '4.0.1' }, 'outdated' => false }
    ])
  end
  rows = baseline.formula_state(:mini)
  assert(rows.first[:name] == 'openclaw/tap/peekaboo', 'migrated tap identity was lost')
  assert(rows.last[:name] == 'ruby', 'plain formula fallback changed')
  assert(baseline.formulae(:mini).include?(rows.first[:name]), 'Peekaboo missing from maintenance targets')
ensure
  baseline.define_singleton_method(:run!, original_run)
end

puts "PASS #{$assertion_count}/#{$assertion_count}"
