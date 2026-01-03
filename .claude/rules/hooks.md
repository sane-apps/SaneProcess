# Hook File Rules

> Pattern: `**/hooks/**/*.rb`, `**/*_hook.rb`, `**/*_validator.rb`

---

## Requirements

1. **Exit 0 to allow** - Tool call proceeds
2. **Exit 1 to block** - Tool call is prevented
3. **Warn for messages** - User sees stderr output
4. **Handle errors gracefully** - Don't block on unexpected errors

## Right

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# Get tool context from environment
tool_name = ENV.fetch('CLAUDE_TOOL_NAME', nil)
tool_input = ENV.fetch('CLAUDE_TOOL_INPUT', nil)

# Skip if no input
exit 0 if tool_name.nil? || tool_input.nil?

begin
  # Validation logic here
  data = JSON.parse(tool_input)

  if should_block?(data)
    warn '🔴 BLOCKED: [Rule Name]'
    warn '   Reason: [explanation]'
    exit 1
  end

  # Allow the call
  exit 0
rescue StandardError => e
  # Don't block on unexpected errors
  warn "⚠️  Hook error: #{e.message}"
  exit 0
end
```

## Hook Types

| Type | Runs | Purpose |
|------|------|---------|
| PreToolUse | Before tool executes | Block dangerous operations |
| PostToolUse | After tool completes | Track failures, log decisions |
| SessionStart | When session begins | Bootstrap environment |
| SessionEnd | When session ends | Capture learnings |

## Wrong

```ruby
# Missing error handling - will crash and block unexpectedly
data = JSON.parse(ENV['CLAUDE_TOOL_INPUT'])

# Using exit 1 for warnings - will block the tool
if file_too_large?(data)
  puts "Warning: file is large"
  exit 1  # Should warn and exit 0 for warnings
end
```
