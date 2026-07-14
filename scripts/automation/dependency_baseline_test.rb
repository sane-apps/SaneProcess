#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'dependency_baseline'

def assert(condition, message)
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

puts 'PASS 12/12'
