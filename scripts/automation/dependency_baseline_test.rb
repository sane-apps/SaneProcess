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
assert(SaneAppsDependencyBaseline.npm_packages(:air).include?('@upstash/context7-mcp'),
       'Air research dependency missing')
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
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['@steipete/macos-automator-mcp'] == '0.4.5',
       'macOS Automator MCP pin drifted')
assert(SaneAppsDependencyBaseline::NPM_VERSIONS['@upstash/context7-mcp'] == '3.2.3',
       'Context7 MCP pin drifted')
assert(SaneAppsDependencyBaseline.npm_specs(:mini).include?('@agentmemory/agentmemory@0.9.27'),
       'Mini AgentMemory install is not version-pinned')
assert(SaneAppsDependencyBaseline.npm_specs(:air).none? { |spec| spec.end_with?('@latest') },
       'dependency apply must not float managed packages to latest')

mini_installed = SaneAppsDependencyBaseline.npm_packages(:mini).to_h do |name|
  [name, SaneAppsDependencyBaseline::NPM_VERSIONS.fetch(name)]
end
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, mini_installed).empty?,
       'exact Mini package pins should pass')

drifted = mini_installed.merge('@steipete/macos-automator-mcp' => '0.4.1')
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, drifted).any? { |problem| problem.include?('0.4.1 != 0.4.5') },
       'version drift must fail the dependency check')

forbidden = mini_installed.merge('npm' => '99.0.0')
assert(SaneAppsDependencyBaseline.npm_version_problems(:mini, forbidden).include?('forbidden global npm package: npm'),
       'forbidden global packages must fail the dependency check')

puts "PASS #{$assertion_count}/#{$assertion_count}"
