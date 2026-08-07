#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor beforeShellExecution adapter for the shared SaneProcess Bash guards.
# Cursor expects a permission JSON response; high-risk guard errors fail closed.

require 'json'
require 'open3'
require 'rbconfig'
require_relative 'runtime_paths'

GUARD = SaneCursorRuntimePaths.hook('sane_bash_guards.rb')

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
  respond('deny', 'Shell action blocked: shared SaneProcess guard is missing.') unless GUARD && File.file?(GUARD)

  hook_payload = JSON.generate('tool_name' => 'Bash', 'tool_input' => { 'command' => command })
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, GUARD, stdin_data: hook_payload)

  if status.exitstatus == 2
    detail = stderr.to_s.strip
    detail = stdout.to_s.strip if detail.empty?
    respond('deny', detail.empty? ? 'Shell action blocked by SaneProcess.' : detail)
  end

  unless status.success?
    detail = stderr.to_s.strip
    detail = "Shell action blocked: SaneProcess guard failed (exit #{status.exitstatus})." if detail.empty?
    respond('deny', detail)
  end

  respond('allow', stderr.to_s.strip.empty? ? nil : stderr.to_s.strip)
rescue JSON::ParserError => e
  respond('deny', "Shell action blocked: invalid Cursor hook payload (#{e.class}).")
rescue StandardError => e
  respond('deny', "Shell action blocked: SaneProcess guard error (#{e.class}).")
end
