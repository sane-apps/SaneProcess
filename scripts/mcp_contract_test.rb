#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'

include TestFramework

ROOT = File.expand_path('..', __dir__)

def server_source(relative_path)
  File.read(File.join(ROOT, relative_path))
end

exit(run_tests('SaneProcess MCP contract tests') do
  test_category('structured output') do
    test('central memory tools declare output schemas') do
      source = server_source('scripts/mcp-central-memory/server.mjs')

      %w[remember recall recent stats delete_by_external_id import_knowledge_graph].each do |tool_name|
        tool_index = source.index("name: '#{tool_name}'")
        assert(tool_index, "missing central-memory tool #{tool_name}")
        next_tool_index = source.index("\n  {\n    name:", tool_index + 1) || source.index("\n];", tool_index)
        tool_block = source[tool_index...next_tool_index]
        assert_includes(tool_block, 'outputSchema:')
      end
      true
    end

    test('central memory responses include structuredContent') do
      source = server_source('scripts/mcp-central-memory/server.mjs')

      assert_includes(source, 'structuredContent: payload')
      true
    end

    test('graph memory tools keep output schemas and structuredContent') do
      source = server_source('scripts/mcp-memory-enhanced/server.mjs')

      assert(source.scan('outputSchema:').length >= 8, 'expected graph-memory tools to declare output schemas')
      assert_includes(source, 'structuredContent:')
      true
    end
  end
end)
