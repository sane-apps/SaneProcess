#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require 'time'
require_relative 'test/test_framework'

include TestFramework

HOOK_DIR = File.expand_path(__dir__)
GUARD = File.join(HOOK_DIR, 'sane_llm_api_guard.rb')
DISPATCHER = File.join(HOOK_DIR, 'sane_bash_guards.rb')

def run_guard(script, command)
  payload = {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => command }
  }
  Open3.capture3('ruby', script, stdin_data: JSON.generate(payload), chdir: File.expand_path('../..', __dir__))
end

exit(run_tests('Sane LLM API Guard Tests') do
  test('blocks raw curl POST to NVIDIA chat completions') do
    _out, err, status = run_guard(
      GUARD,
      "curl -X POST https://integrate.api.nvidia.com/v1/chat/completions -d '{\"model\":\"x\"}'"
    )
    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'without research receipt')
    true
  end

  test('blocks Workers AI /ai/run POST') do
    _out, err, status = run_guard(
      GUARD,
      "curl -X POST 'https://api.cloudflare.com/client/v4/accounts/abc/ai/run/@cf/meta/llama-3.1-8b-instruct' -d '{}'"
    )
    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'LLM_VENDOR_API_SOP')
    true
  end

  test('allows ai_promote.py harness') do
    _out, err, status = run_guard(
      GUARD,
      "python3 clients/translations/scripts/ai_promote.py --claim jer-h6 --agent overnight"
    )
    assert_eq(status.exitstatus, 0)
    assert_eq(err.strip, '')
    true
  end

  test('allows llm_bakeoff.py harness') do
    _out, err, status = run_guard(
      GUARD,
      "python3 clients/translations/scripts/llm_bakeoff.py --nvidia deepseek-ai/deepseek-v4-flash-0731"
    )
    assert_eq(status.exitstatus, 0)
    assert_eq(err.strip, '')
    true
  end

  test('allows research gate script') do
    _out, _err, status = run_guard(
      GUARD,
      "ruby ~/SaneApps/infra/SaneProcess/scripts/llm_api_research_gate.rb --provider cf --model '@cf/zai-org/glm-4.7-flash'"
    )
    assert_eq(status.exitstatus, 0)
    true
  end

  test('allows schema GET') do
    _out, _err, status = run_guard(
      GUARD,
      "curl -H 'Authorization: Bearer x' 'https://api.cloudflare.com/client/v4/accounts/abc/ai/models/schema?model=@cf/google/gemma-4-26b-a4b-it'"
    )
    assert_eq(status.exitstatus, 0)
    true
  end

  test('allows fresh research receipt matching model') do
    Tempfile.create(['llm-api-receipt', '.json']) do |f|
      receipt = {
        'models' => ['deepseek-ai/deepseek-v4-flash-0731'],
        'researched_at' => Time.now.utc.iso8601,
        'expires_at' => (Time.now.utc + 3600).iso8601
      }
      f.write(JSON.generate(receipt))
      f.flush
      cmd = "SANE_LLM_API_RECEIPT=#{f.path} curl -X POST https://integrate.api.nvidia.com/v1/chat/completions -d '{\"model\":\"deepseek-ai/deepseek-v4-flash-0731\"}'"
      _out, _err, status = run_guard(GUARD, cmd)
      assert_eq(status.exitstatus, 0)
    end
    true
  end

  test('owner override string allows call') do
    _out, _err, status = run_guard(
      GUARD,
      "SANE_LLM_API_RESEARCH_OK='MR. SANE APPROVES LLM VENDOR API CALL' curl -X POST https://integrate.api.nvidia.com/v1/chat/completions -d '{}'"
    )
    assert_eq(status.exitstatus, 0)
    true
  end

  test('dispatcher includes llm api guard block') do
    _out, err, status = run_guard(
      DISPATCHER,
      "curl -X POST https://integrate.api.nvidia.com/v1/chat/completions -d '{}'"
    )
    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'research receipt')
    true
  end
end)
