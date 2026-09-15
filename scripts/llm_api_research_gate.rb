#!/usr/bin/env ruby
# frozen_string_literal: true

# llm_api_research_gate.rb — research receipt before Cloudflare Workers AI / NVIDIA NIM inference
#
# Usage:
#   ruby scripts/llm_api_research_gate.rb --provider cf --model '@cf/google/gemma-4-26b-a4b-it'
#   ruby scripts/llm_api_research_gate.rb --provider nvidia --model 'deepseek-ai/deepseek-v4-flash-0731'
#
# Then run inference with:
#   SANE_LLM_API_RECEIPT=/path/to/receipt.json curl ...
#
# Enforced by scripts/hooks/sane_llm_api_guard.rb

require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require 'fileutils'
require 'time'

ROOT = File.expand_path('..', __dir__)
OUT = File.join(ROOT, 'outputs', 'llm-api-research')
DEFAULT_CF_ACCOUNT = '2c267ab06352ba2522114c3081a8c5fa'
TTL_HOURS = 4

options = {
  provider: nil,
  model: nil,
  notes: '',
  sources: []
}

OptionParser.new do |opts|
  opts.banner = 'Usage: llm_api_research_gate.rb --provider cf|nvidia --model ID [--source URL] [--notes TEXT]'
  opts.on('--provider NAME', 'cf or nvidia') { |v| options[:provider] = v.to_s.downcase }
  opts.on('--model ID', 'Exact model id') { |v| options[:model] = v }
  opts.on('--source URL', 'Doc/schema URL (repeatable)') { |v| options[:sources] << v }
  opts.on('--notes TEXT', 'What kwargs you will send') { |v| options[:notes] = v }
end.parse!

abort('Need --provider cf|nvidia') unless %w[cf cloudflare nvidia nv].include?(options[:provider])
abort('Need --model') if options[:model].to_s.strip.empty?

provider = options[:provider].start_with?('n') ? 'nvidia' : 'cf'
model = options[:model].strip
sources = options[:sources].dup
schema_excerpt = nil
checks = []

def load_env_token(*keys)
  keys.each do |key|
    val = ENV[key].to_s.strip
    return val unless val.empty?
  end
  env_path = File.expand_path('~/.config/nv/env')
  if File.readable?(env_path)
    File.readlines(env_path, encoding: Encoding::UTF_8).each do |line|
      next unless line =~ /\A\s*([A-Z0-9_]+)=(.*)\s*\z/

      k = Regexp.last_match(1)
      v = Regexp.last_match(2).to_s.gsub(/\A["']|["']\z/, '')
      ENV[k] ||= v
    end
  end
  keys.each do |key|
    val = ENV[key].to_s.strip
    return val unless val.empty?
  end
  nil
end

def http_get(url, headers = {})
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  headers.each { |k, v| req[k] = v }
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 20, read_timeout: 45) do |http|
    http.request(req)
  end
end

case provider
when 'cf'
  token = load_env_token('CLOUDFLARE_API_TOKEN', 'CF_TOKEN')
  abort('Need CLOUDFLARE_API_TOKEN for CF schema fetch') if token.nil? || token.empty?
  account = ENV['CLOUDFLARE_ACCOUNT_ID'].to_s.strip
  account = DEFAULT_CF_ACCOUNT if account.empty?
  schema_url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/models/schema?model=#{URI.encode_www_form_component(model)}"
  sources << schema_url
  sources << "https://developers.cloudflare.com/workers-ai/models/#{model.split('/').last}/"
  resp = http_get(schema_url, 'Authorization' => "Bearer #{token}")
  abort("CF schema HTTP #{resp.code}: #{resp.body[0, 240]}") unless resp.code.to_i == 200
  data = JSON.parse(resp.body)
  abort("CF schema success=false: #{resp.body[0, 240]}") unless data['success']
  schema_json = JSON.generate(data['result'])
  schema_excerpt = schema_json[0, 4000]
  checks << 'fetched_live_cf_schema'
  if schema_json.include?('enable_thinking')
    checks << 'schema_has_enable_thinking_default_true_likely'
  end
  if schema_json.include?('max_completion_tokens')
    checks << 'prefer_max_completion_tokens_if_max_tokens_deprecated'
  end
when 'nvidia'
  sources << "https://docs.api.nvidia.com/nim/reference/#{model.tr('/', '-')}-infer"
  sources << 'https://docs.api.nvidia.com/nim/reference/deepseek-ai-deepseek-v4-flash-0731-infer' if model.include?('deepseek')
  sources << 'https://docs.api.nvidia.com/nim/reference/nvidia-nemotron-3-super-120b-a12b-infer' if model.include?('nemotron-3-super')
  checks << 'must_read_official_infer_page_before_call'
  if model.downcase.include?('deepseek')
    checks << 'deepseek_requires_stream_true_and_reasoning_effort_none'
  end
  if model.downcase.include?('nemotron-3-super') || model.downcase.include?('deepseek')
    checks << 'reasoning_effort_none_for_json_drafts'
  end
  token = load_env_token('NV_API_KEY', 'NVIDIA_API_KEY', 'NGC_API_KEY')
  if token && !token.empty?
    resp = http_get(
      'https://integrate.api.nvidia.com/v1/models',
      'Authorization' => "Bearer #{token}",
      'Accept' => 'application/json'
    )
    if resp.code.to_i == 200
      catalog = JSON.parse(resp.body)
      ids = (catalog['data'] || []).map { |row| row['id'] }
      checks << (ids.include?(model) ? 'model_listed_on_v1_models' : 'model_NOT_in_v1_models_catalog')
    else
      checks << "models_list_http_#{resp.code}"
    end
  else
    checks << 'no_nv_key_skipped_catalog_probe'
  end
end

sources = sources.uniq
FileUtils.mkdir_p(OUT)
stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
safe = model.gsub(%r{[^A-Za-z0-9._-]+}, '_')
path = File.join(OUT, "#{stamp}-#{provider}-#{safe}.json")

receipt = {
  'version' => 1,
  'provider' => provider,
  'models' => [model],
  'researched_at' => Time.now.utc.iso8601,
  'expires_at' => (Time.now.utc + (TTL_HOURS * 3600)).iso8601,
  'sources' => sources,
  'checks' => checks,
  'notes' => options[:notes].to_s,
  'sop' => 'infra/SaneProcess/docs/LLM_VENDOR_API_SOP.md',
  'schema_excerpt' => schema_excerpt
}

File.write(path, JSON.pretty_generate(receipt))
puts "Research receipt: #{path}"
puts "Use: SANE_LLM_API_RECEIPT=#{path} <your inference command>"
puts "Checks: #{checks.join(', ')}"
puts 'Reminder: smoke {"ok":true} with hard timeout before fixture/bake.'
exit 0
