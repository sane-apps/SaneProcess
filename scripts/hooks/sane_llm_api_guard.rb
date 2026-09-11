#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_llm_api_guard.rb — PreToolUse Bash guard
# Blocks winging Cloudflare Workers AI / NVIDIA NIM inference without research.
#
# Owner 2026-09-11: agents repeatedly called CF/NVIDIA without reading schemas,
# then blamed the vendor. SOP: infra/SaneProcess/docs/LLM_VENDOR_API_SOP.md
#
# BLOCKS: POST/body inference to NIM chat or Workers AI run/chat/responses
# ALLOWS: llm_bakeoff.py, llm_api_research_gate.rb, schema/docs GETs,
#         fresh SANE_LLM_API_RECEIPT / --llm-api-receipt, owner override string

require 'json'
require 'time'
require_relative 'core/hook_payload'

LLM_API_APPROVAL = 'MR. SANE APPROVES LLM VENDOR API CALL'
RECEIPT_ENV = 'SANE_LLM_API_RECEIPT'
RECEIPT_FLAG = /--llm-api-receipt\s+(\S+)/
RECEIPT_TTL_SECONDS = 4 * 3600

INFERENCE_ENDPOINT = Regexp.union(
  %r{integrate\.api\.nvidia\.com}i,
  %r{api\.nvidia\.com/.*/chat/completions}i,
  %r{api\.cloudflare\.com/client/v4/accounts/[^/\s]+/ai/run/}i,
  %r{api\.cloudflare\.com/client/v4/accounts/[^/\s]+/ai/v1/chat/completions}i,
  %r{api\.cloudflare\.com/client/v4/accounts/[^/\s]+/ai/v1/responses}i
).freeze

READ_ONLY_SCHEMA = Regexp.union(
  %r{ai/models/schema}i,
  %r{docs\.api\.nvidia\.com/nim/reference}i,
  %r{developers\.cloudflare\.com/workers-ai}i,
  %r{llm_api_research_gate\.rb},
  %r{LLM_VENDOR_API_SOP\.md},
  %r{LLM_API_SETUP\.md}
).freeze

CANONICAL_HARNESS = %r{(?:scripts/)?(?:llm_bakeoff|ai_promote)\.py}.freeze

MUTATING_HINT = Regexp.union(
  /\b-X\s*POST\b/i,
  /\b--request\s+POST\b/i,
  /\b-d\s/,
  /\b--data\b/,
  /\b--json\b/,
  /\bjson\.dumps\b/,
  /\burllib\.request\b/,
  /\brequests\.(?:post|put)\b/i,
  /\bNet::HTTP(?:::Post|::Put)\b/,
  %r{\bchat/completions\b}i,
  %r{\bai/run/}i,
  %r{\bai/v1/responses\b}i,
  /\b"messages"\s*:/,
  /\b'messages'\s*:/
).freeze

def shell_command
  data = SaneHookPayload.parse($stdin.read.force_encoding(Encoding::UTF_8))
  return nil unless SaneHookPayload.shell?(data['tool_name']) || data['tool_name'].empty?

  cmd = data['command']
  cmd.empty? ? nil : cmd
end

def approval_present?(command)
  command.include?("SANE_LLM_API_RESEARCH_OK=#{LLM_API_APPROVAL}") ||
    command.include?("SANE_LLM_API_RESEARCH_OK='#{LLM_API_APPROVAL}'") ||
    command.include?("SANE_LLM_API_RESEARCH_OK=\"#{LLM_API_APPROVAL}\"")
end

def receipt_path_from_command(command)
  if command =~ /\b#{RECEIPT_ENV}=(\S+)/
    return Regexp.last_match(1).to_s.gsub(/\A["']|["']\z/, '')
  end
  if command =~ RECEIPT_FLAG
    return Regexp.last_match(1).to_s.gsub(/\A["']|["']\z/, '')
  end

  nil
end

def model_ids_in_command(command)
  ids = []
  command.scan(%r{@(?:cf|hf)/[A-Za-z0-9._/-]+}) { |m| ids << m }
  command.scan(%r{(?:nvidia|deepseek-ai|mistralai|meta)/[A-Za-z0-9._-]+}) { |m| ids << m }
  ids.uniq
end

def receipt_ok?(path, command)
  return false if path.nil? || path.empty? || !File.file?(path)

  begin
    data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
  rescue JSON::ParserError, Errno::ENOENT
    return false
  end

  researched = begin
    Time.parse(data['researched_at'].to_s)
  rescue ArgumentError, TypeError
    return false
  end
  age = Time.now.utc - researched.utc
  return false if age.negative? || age > RECEIPT_TTL_SECONDS

  if data['expires_at']
    begin
      return false if Time.now.utc > Time.parse(data['expires_at'].to_s).utc
    rescue ArgumentError, TypeError
      return false
    end
  end

  models = Array(data['models']).map(&:to_s)
  return false if models.empty?

  mentioned = model_ids_in_command(command)
  return true if mentioned.empty?

  mentioned.all? { |id| models.any? { |m| m == id || id.include?(m) || m.include?(id) } }
end

def inference_attempt?(command)
  return false unless command.match?(INFERENCE_ENDPOINT)
  return false if command.match?(READ_ONLY_SCHEMA) && !command.match?(MUTATING_HINT)
  return true if command.match?(MUTATING_HINT)

  # Host present without explicit GET-only markers → treat as inference risk
  !command.match?(/\b(-G|--get|method['\"]?\s*:\s*['\"]GET)\b/i)
end

def allowed?(command)
  return true if approval_present?(command)
  return true if command.match?(CANONICAL_HARNESS)
  return true if command.include?('llm_api_research_gate.rb')
  return true if receipt_ok?(receipt_path_from_command(command), command)

  false
end

command = shell_command
exit 0 if command.nil? || command.strip.empty?
exit 0 unless inference_attempt?(command)
exit 0 if allowed?(command)

warn <<~MSG
  BLOCKED: Cloudflare Workers AI / NVIDIA NIM inference without research receipt.

  Rule: read infra/SaneProcess/docs/LLM_VENDOR_API_SOP.md and the live model
  schema BEFORE calling. Empty/null/hang is usually wrong call shape, not a dead API.

  Fix (pick one):
  1. Use the profiled harness: python3 …/scripts/llm_bakeoff.py …
  2. Research first:
       ruby ~/SaneApps/infra/SaneProcess/scripts/llm_api_research_gate.rb \\
         --provider cf|nvidia --model '<exact-id>' --notes 'kwargs…'
     then:
       SANE_LLM_API_RECEIPT=/path/to/receipt.json <your command>
  3. Owner override in THIS command only:
       SANE_LLM_API_RESEARCH_OK='#{LLM_API_APPROVAL}' …

  Do not invent temperature/thinking defaults. Smoke {"ok":true} before bake.
MSG
exit 2
