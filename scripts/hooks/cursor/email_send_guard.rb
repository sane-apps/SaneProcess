#!/usr/bin/env ruby
# frozen_string_literal: true

# Compatibility adapter retained for existing Cursor installations. New
# manifests use before_shell_guard.rb, which includes the same email guard.

require 'json'
require 'open3'
require 'rbconfig'
require_relative 'runtime_paths'

GUARD = SaneCursorRuntimePaths.hook('sane_email_guard.rb')

def respond(permission, message = nil)
  payload = { permission: permission }
  payload[:user_message] = message if message
  payload[:agent_message] = message if message
  puts JSON.generate(payload)
  exit 0
end

begin
  input = JSON.parse($stdin.read.to_s)
  command = input['command'] || input.dig('input', 'command') || ''
  respond('allow') if command.to_s.strip.empty?
  respond('deny', 'Email send blocked: SaneProcess email guard is missing.') unless GUARD && File.file?(GUARD)

  payload = JSON.generate('tool_name' => 'Bash', 'tool_input' => { 'command' => command })
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, GUARD, stdin_data: payload)
  if status.exitstatus == 2
    detail = stderr.to_s.strip
    detail = stdout.to_s.strip if detail.empty?
    respond('deny', detail.empty? ? 'Email send blocked by SaneProcess.' : detail)
  end
  respond('deny', "Email send blocked: guard failed (exit #{status.exitstatus}).") unless status.success?
  respond('allow', stderr.to_s.strip.empty? ? nil : stderr.to_s.strip)
rescue JSON::ParserError => e
  respond('deny', "Email send blocked: invalid Cursor hook payload (#{e.class}).")
rescue StandardError => e
  respond('deny', "Email send blocked: SaneProcess guard error (#{e.class}).")
end
