#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse action authorization boundary. Catastrophic actions are checked
# first and remain manual-only; consequential actions require an independently
# signed, exact, short-lived, one-time receipt.

require 'open3'
require 'rbconfig'
require_relative 'core/action_authorization'

ACTIVATION_PATH = '/Library/Application Support/SaneProcess/action-guard-enabled.json'
ACTIVATION_FILES = %w[
  sane_catastrophic_guard.rb
  sane_action_guard.rb
  sane_bash_guards.rb
  core/action_authorization.rb
].freeze

def action_guard_enforced?
  stat = File.lstat(ACTIVATION_PATH)
  raise 'invalid action guard activation file metadata' unless stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o777) == 0o444

  data = JSON.parse(File.read(ACTIVATION_PATH, encoding: Encoding::UTF_8))
  raise 'invalid action guard activation schema' unless data.keys.sort == %w[av_contain_required guard_sha256 mode schema_version].sort
  raise 'invalid action guard activation policy' unless data['schema_version'] == 1 && data['mode'] == 'enforce' && data['av_contain_required'] == true

  expected = ACTIVATION_FILES.to_h do |relative|
    path = File.expand_path(relative, __dir__)
    [relative, Digest::SHA256.file(path).hexdigest]
  end
  raise 'action guard source hash mismatch' unless data['guard_sha256'] == expected

  true
rescue Errno::ENOENT
  false
end

payload = $stdin.read.force_encoding(Encoding::UTF_8)
catastrophic = File.expand_path('sane_catastrophic_guard.rb', __dir__)
catastrophic_out, catastrophic_err, catastrophic_status = Open3.capture3(
  RbConfig.ruby,
  catastrophic,
  stdin_data: payload
)

unless catastrophic_status.success?
  $stdout.write(catastrophic_out)
  $stderr.write(catastrophic_err)
  exit catastrophic_status.exitstatus
end

# Audit-only until a separate reviewer/signing lane and av-contain client launch
# are independently cleared. There is intentionally no environment-variable or
# same-user activation bypass.
exit 0 unless action_guard_enforced?

result = SaneActionAuthorization::Authorizer.new.evaluate(payload)
exit 0 if result.allowed

warn <<~MESSAGE
  🔴 BLOCKED: #{result.classification}

  #{result.message}

  HARD_DENY actions remain manual user-only. USER_CONFIRM actions require the
  client's native action-time confirmation. REVIEW_REQUIRED actions require a
  constrained independent reviewer receipt at the canonical path shown above;
  the executing agent cannot mint that receipt.
MESSAGE
exit 2
