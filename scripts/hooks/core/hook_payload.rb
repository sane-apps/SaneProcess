# frozen_string_literal: true

require 'json'

# Shared hook-payload parser for cross-client guard dispatch.
#
# Hook payloads arrive as JSON with string keys. Client tool names differ, so
# guards must not assume a single shape: parse never raises and never returns
# nil. Unparseable or unexpected payloads yield a blank record, which every
# guard treats as "no command" and allows (same fail-open as an empty command).
module SaneHookPayload
  SHELL_TOOLS = %w[bash].freeze
  EDIT_TOOLS = %w[write edit notebookedit strreplace writefile search_replace].freeze

  module_function

  def parse(payload)
    data = JSON.parse(payload.to_s)
    data = {} unless data.is_a?(Hash)
    tool_input = data['tool_input']
    tool_input = {} unless tool_input.is_a?(Hash)
    {
      'tool_name' => data['tool_name'].to_s,
      'tool_input' => tool_input,
      'command' => tool_input['command'].to_s,
      'path' => tool_input['file_path'] || tool_input['path']
    }
  rescue JSON::ParserError
    blank
  end

  def blank
    { 'tool_name' => '', 'tool_input' => {}, 'command' => '', 'path' => nil }
  end

  def shell?(tool_name)
    SHELL_TOOLS.include?(tool_name.to_s.downcase)
  end

  def edit?(tool_name)
    EDIT_TOOLS.include?(tool_name.to_s.downcase)
  end
end
