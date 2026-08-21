#!/opt/homebrew/opt/ruby/bin/ruby
# frozen_string_literal: true

require 'tmpdir'

$assertion_count = 0

def assert(condition, message)
  $assertion_count += 1
  raise message unless condition
end

root = File.expand_path('..', __dir__)
heartbeat = File.read(File.join(root, 'automation', 'agent-heartbeat.sh'))
xscout = File.read(File.join(root, 'automation', 'run-x-opportunity-scout.sh'))
watch = File.read(File.join(root, 'automation', 'run-app-review-watch.sh'))
install = File.read(File.join(root, 'automation', 'install-recurring-agents.sh'))

assert(heartbeat.include?('Timeout.timeout'), 'heartbeat must bound Grok without GNU timeout')
assert(!heartbeat.match?(/^\s*timeout "/), 'heartbeat must not call GNU timeout(1)')
assert(heartbeat.include?('--prompt-file'), 'heartbeat must use grok --prompt-file')
assert(heartbeat.include?('--always-approve'), 'heartbeat must be noninteractive')
assert(!xscout.include?('--product'), 'x-scout wrapper must match current argparse')
assert(xscout.include?('--all-live'), 'x-scout wrapper must stay report-only all-live')
assert(watch.include?('en_US.UTF-8'), 'app-review watch must force UTF-8')
assert(install.include?('LC_ALL'), 'LaunchAgents must set LC_ALL')
assert(File.file?(File.join(root, 'automation', 'heartbeats', 'saneapps-launch-ops.md')),
       'launch-ops prompt missing')
assert(File.file?(File.join(root, 'automation', 'heartbeats', 'grok-stack-smoke.md')),
       'grok smoke prompt missing')
assert(File.file?(File.join(root, 'automation', 'heartbeats', 'sanelot-x-opportunity-scout.md')),
       'X scout must be a Grok heartbeat, not the paid X API')
assert(install.include?('sanelot-x-opportunity-scout'), 'installer must schedule the Grok X scout')
submit = File.read(File.join(root, 'appstore_submit.rb'))
assert(submit.include?("mode: 'r:UTF-8'"), 'ASC env loader must not inherit US-ASCII from launchd')

puts "PASS #{$assertion_count}/#{$assertion_count}"
