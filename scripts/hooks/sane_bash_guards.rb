#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_bash_guards.rb — ungated PreToolUse Bash guard dispatcher
#
# Runs the high-risk Bash guards in-process so Claude invokes one hook instead
# of four subprocesses on every Bash call. Order matters: first block wins and
# each guard's existing stderr/exit behavior is preserved.

require 'stringio'

GUARDS = %w[
  sane_launch_guard.rb
  sane_release_guard.rb
  sane_ship_guard.rb
  sane_email_guard.rb
].map { |name| File.expand_path(name, __dir__) }.freeze

payload = $stdin.read.force_encoding(Encoding::UTF_8)
original_stdin = $stdin

GUARDS.each do |guard|
  $stdin = StringIO.new(payload)
  begin
    load guard, true
  rescue SystemExit => e
    status = e.status.is_a?(Integer) ? e.status : (e.success? ? 0 : 1)
    exit status unless status.zero?
  ensure
    $stdin = original_stdin
  end
end

exit 0
