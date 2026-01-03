# Script File Rules

> Pattern: `**/Scripts/**/*.rb`, `**/*.rb`, `**/hooks/**/*.rb`

---

## Requirements

1. **frozen_string_literal** - Always add pragma at top
2. **Exit codes matter** - 0 = success, 1 = blocked/error
3. **Warn, don't puts** - Use `warn` for messages (goes to stderr)
4. **Handle missing input** - Check ENV vars exist before using

## Right

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# Check required input exists
tool_input = ENV.fetch('CLAUDE_TOOL_INPUT', nil)
exit 0 if tool_input.nil? || tool_input.empty?

# Parse and validate
begin
  data = JSON.parse(tool_input)
  # ... process
rescue JSON::ParserError
  warn '⚠️  Invalid JSON input'
  exit 0  # Don't block on parse errors
end
```

## Wrong

```ruby
# Missing frozen_string_literal pragma
require 'json'

# Using puts instead of warn
puts "Processing..."  # Goes to stdout, may interfere with hook output

# Not checking if ENV exists
data = JSON.parse(ENV['CLAUDE_TOOL_INPUT'])  # Will crash if nil
```
