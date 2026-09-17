#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../test/test_framework'
require_relative 'hook_payload'

include TestFramework

exit(run_tests('Hook Payload Parser Tests') do
  test_category('parse') do
    test('parses Bash payload command and path') do
      data = SaneHookPayload.parse(JSON.generate(
                                     'tool_name' => 'Bash',
                                     'tool_input' => {
                                       'command' => 'ls ~/SaneApps',
                                       'file_path' => '/tmp/x'
                                     }
                                   ))
      assert_eq(data['tool_name'], 'Bash')
      assert_eq(data['command'], 'ls ~/SaneApps')
      assert_eq(data['path'], '/tmp/x')
      true
    end

    test('prefers file_path over path for edit payloads') do
      data = SaneHookPayload.parse(JSON.generate(
                                     'tool_name' => 'Write',
                                     'tool_input' => { 'file_path' => '/a', 'path' => '/b' }
                                   ))
      assert_eq(data['path'], '/a')
      assert_eq(data['command'], '')
      true
    end

    test('never raises and never returns nil for bad payloads') do
      ['', 'not json', '[1,2]', 'null', '42'].each do |raw|
        data = SaneHookPayload.parse(raw)
        assert(data.is_a?(Hash), "expected Hash for #{raw.inspect}")
        assert_eq(data['tool_name'], '')
        assert_eq(data['command'], '')
        assert(data['tool_input'].is_a?(Hash), "expected tool_input Hash for #{raw.inspect}")
      end
      true
    end
  end

  test_category('tool classification') do
    test('recognizes shell tools') do
      assert(SaneHookPayload.shell?('Bash'), 'Bash is a shell tool')
      assert(!SaneHookPayload.shell?('Write'), 'Write is not a shell tool')
      assert(!SaneHookPayload.shell?(''), 'blank is not a shell tool')
      true
    end

    test('recognizes edit tools across clients') do
      %w[Write Edit NotebookEdit StrReplace WriteFile search_replace].each do |name|
        assert(SaneHookPayload.edit?(name), "#{name} is an edit tool")
      end
      assert(!SaneHookPayload.edit?('Bash'), 'Bash is not an edit tool')
      true
    end
  end
end)
