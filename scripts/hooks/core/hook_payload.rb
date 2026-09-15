# frozen_string_literal: true

# Normalize Claude, Grok, Cursor, and Codex hook stdin into one shape.
# Claude: tool_name / tool_input (Bash, Write, Edit)
# Grok:   toolName / toolInput  (run_terminal_command, search_replace)
# Cursor: command, or tool_name + input/arguments
module SaneHookPayload
  SHELL_NAMES = %w[Bash run_terminal_command Shell].freeze
  EDIT_NAMES = %w[
    Write Edit MultiEdit NotebookEdit StrReplace WriteFile search_replace
  ].freeze

  module_function

  def parse(source)
    data = source.is_a?(Hash) ? source : JSON.parse(source.to_s)
    data = {} unless data.is_a?(Hash)
    input = nested_input(data)
    name = data['tool_name'] || data['toolName'] || data.dig('tool', 'name') || ''
    command = input['command'] || data['command']
    path = input['file_path'] || input['path'] || input['filePath'] ||
           input['target_file'] || input['target_notebook']
    {
      'raw' => data,
      'tool_name' => name.to_s,
      'tool_input' => input,
      'command' => command.to_s,
      'path' => path.to_s,
      'cwd' => input['cwd'] || data['cwd']
    }
  rescue JSON::ParserError
    empty
  end

  def shell?(name)
    SHELL_NAMES.include?(name.to_s)
  end

  def edit?(name)
    EDIT_NAMES.include?(name.to_s)
  end

  def empty
    {
      'raw' => {},
      'tool_name' => '',
      'tool_input' => {},
      'command' => '',
      'path' => '',
      'cwd' => nil
    }
  end

  def nested_input(data)
    input = data['tool_input'] || data['toolInput'] || data['input'] ||
            data['arguments']
    input.is_a?(Hash) ? input : {}
  end
end
