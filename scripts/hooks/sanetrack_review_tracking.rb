#!/usr/bin/env ruby
# frozen_string_literal: true

# Review-source binding and canonical runner command normalization extracted
# from sanetrack.rb so the hook entrypoint stays below the hard size limit.

require 'digest'
require 'json'
require 'open3'
require 'shellwords'
require 'time'
require_relative 'core/mandatory_workflows'
require_relative 'core/state_manager'

def track_skill_invocation(tool_name, tool_input)
  return unless tool_name == 'Skill'

  skill_name = tool_input['skill'] || tool_input[:skill]
  return unless skill_name

  StateManager.update(:skill) do |state|
    state[:invoked] = true
    state[:invoked_at] = Time.now.iso8601
    state[:invoked_skill] = skill_name
    state
  end
rescue StandardError => e
  warn "⚠️  Skill tracking error: #{e.message}" if ENV['DEBUG']
end

def bind_review_source!(state, source_fingerprint)
  return false unless source_fingerprint.to_s.match?(/\A[0-9a-f]{64}\z/)

  if !state[:review_source_fingerprint].to_s.empty? && state[:review_source_fingerprint] != source_fingerprint
    clear_review_credits!(state)
  end
  state[:review_source_fingerprint] = source_fingerprint
  true
end

def clear_review_credits!(state)
  state[:subagents_spawned] = 0
  state[:native_review_fingerprints] = []
  state[:codex_review_lanes_completed] = 0
  state[:codex_review_lane_fingerprints] = []
  state[:codex_review_lanes] = []
end

def invalidate_review_credits_if_source_changed
  skill_state = StateManager.get(:skill)
  bound = skill_state[:review_source_fingerprint].to_s
  return if bound.empty?

  current = MandatoryWorkflows.repo_source_snapshot(Dir.pwd)
  return if current && current['sha256'] == bound

  StateManager.update(:skill) do |state|
    clear_review_credits!(state)
    state[:review_source_fingerprint] = nil
    state
  end
end

def track_subagent_spawn(tool_name, tool_input, tool_response)
  return unless tool_name == 'Task'

  skill_state = StateManager.get(:skill)
  return unless skill_state[:required]
  return unless skill_state[:invoked] && !skill_state[:invoked_at].to_s.empty?
  task_text = [tool_input['description'], tool_input[:description], tool_input['prompt'], tool_input[:prompt]].compact.join(' ')
  return unless task_text.match?(/\b(?:audit|review|reviewer|critic|critique|perspective)\b/i)
  return if task_text.match?(/\bimplement\b|\bapply\b.*\b(?:fix|patch)|\b(?:edit|modify)\b.*\b(?:code|files?)\b/i)
  return unless tool_response.is_a?(Hash)
  return unless (tool_response['error'] || tool_response[:error]).to_s.strip.empty?
  return if tool_response['interrupted'] == true || tool_response[:interrupted] == true

  status = (tool_response['status'] || tool_response[:status]).to_s.downcase
  return unless %w[completed complete passed success succeeded].include?(status)
  final_result = tool_response['result'] || tool_response[:result] ||
                 tool_response['output'] || tool_response[:output] ||
                 tool_response['content'] || tool_response[:content]
  return if final_result.nil? || (final_result.respond_to?(:empty?) && final_result.empty?)
  final_text = final_result.is_a?(String) ? final_result : JSON.generate(final_result)
  return if final_text.strip.empty? || final_text.strip == 'null'

  identity = tool_response['task_id'] || tool_response[:task_id] ||
             tool_response['agent_id'] || tool_response[:agent_id] ||
             tool_response['id'] || tool_response[:id]
  return if identity.to_s.strip.empty?
  source = MandatoryWorkflows.repo_source_snapshot(Dir.pwd)
  return unless source
  fingerprint = Digest::SHA256.hexdigest("native-task\0#{identity}")

  StateManager.update(:skill) do |state|
    next state unless bind_review_source!(state, source['sha256'])
    state[:native_review_fingerprints] ||= []
    next state if state[:native_review_fingerprints].include?(fingerprint)

    state[:native_review_fingerprints] << fingerprint
    state[:native_review_fingerprints] = state[:native_review_fingerprints].last(50)
    state[:subagents_spawned] = (state[:subagents_spawned] || 0) + 1
    state
  end
rescue StandardError => e
  warn "⚠️  Subagent tracking error: #{e.message}" if ENV['DEBUG']
end

def track_codex_review_lane(tool_name, tool_input, tool_response)
  return unless tool_name == 'Bash'

  skill_state = StateManager.get(:skill)
  return unless skill_state[:required]
  return unless skill_state[:invoked] && !skill_state[:invoked_at].to_s.empty?

  command = tool_input['command'] || tool_input[:command] || ''
  evidence = MandatoryWorkflows.codex_review_evidence(command, tool_response, since: skill_state[:invoked_at])
  return if evidence.empty?

  StateManager.update(:skill) do |state|
    source_fingerprint = evidence.first[:source_fingerprint]
    next state unless evidence.all? { |lane| lane[:source_fingerprint] == source_fingerprint }
    next state unless bind_review_source!(state, source_fingerprint)

    if state[:codex_review_invoked_at] != state[:invoked_at]
      state[:codex_review_lane_fingerprints] = []
      state[:codex_review_lanes_completed] = 0
      state[:codex_review_lanes] = []
      state[:codex_review_invoked_at] = state[:invoked_at]
    end
    state[:codex_review_lane_fingerprints] ||= []
    fresh = evidence.reject { |lane| state[:codex_review_lane_fingerprints].include?(lane[:fingerprint]) }
    next state if fresh.empty?

    state[:codex_review_lane_fingerprints].concat(fresh.map { |lane| lane[:fingerprint] })
    state[:codex_review_lane_fingerprints] = state[:codex_review_lane_fingerprints].last(50)
    state[:codex_review_lanes_completed] = (state[:codex_review_lanes_completed] || 0) + fresh.length
    state[:codex_review_lanes] ||= []
    fresh.each { |lane| state[:codex_review_lanes] << lane.merge(completed_at: Time.now.iso8601) }
    state[:codex_review_lanes] = state[:codex_review_lanes].last(20)
    state
  end
rescue StandardError => e
  warn "⚠️  Codex review lane tracking error: #{e.message}" if ENV['DEBUG']
end

def runner_command_sha256(command)
  normalized = MandatoryWorkflows.normalized_shell_command(command)
  return nil unless normalized

  tokens = Shellwords.shellsplit(normalized)
  canonical = File.expand_path('../SaneMaster.rb', __dir__)
  arguments = if tokens.length >= 3 && File.basename(tokens[0]).match?(/\Aruby(?:\d+(?:\.\d+)*)?\z/) &&
                 File.realpath(tokens[1]) == File.realpath(canonical)
                tokens[2..]
              elsif tokens.length >= 2 && safe_sanemaster_wrapper?(tokens[0])
                tokens[1..]
              end
  return nil unless arguments

  Digest::SHA256.hexdigest(['ruby', canonical, *arguments].join("\0"))
rescue ArgumentError, Errno::ENOENT, Errno::EACCES
  nil
end

def safe_sanemaster_wrapper?(invoked)
  root, root_status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
  return false unless root_status.success?

  root = File.realpath(root.strip)
  wrapper = File.realpath(invoked)
  return false unless wrapper == File.join(root, 'scripts', 'SaneMaster.rb')
  metadata = File.lstat(wrapper)
  return false unless metadata.file? && !metadata.symlink? && metadata.uid == Process.uid
  return false unless File.executable?(wrapper) && (metadata.mode & 0o022).zero?
  relative = 'scripts/SaneMaster.rb'
  return false unless system('git', '-C', root, 'ls-files', '--error-unmatch', '--', relative,
                             out: File::NULL, err: File::NULL)
  return false unless system('git', '-C', root, 'diff', '--quiet', '--', relative,
                             out: File::NULL, err: File::NULL)
  return false unless system('git', '-C', root, 'diff', '--cached', '--quiet', '--', relative,
                             out: File::NULL, err: File::NULL)

  source = File.read(wrapper, 32_768)
  bash_delegate = source.start_with?('#!/bin/bash', '#!/usr/bin/env bash') &&
                  source.scan(/^\s*exec "\$\{INFRA\}" "\$@"\s*$/).length == 1 &&
                  source.include?('find_saneprocess_infra')
  ruby_delegate = source.start_with?('#!/usr/bin/env ruby') &&
                  source.scan(/^exec\(['"]ruby['"], master, \*ARGV\)\s*$/).length == 1 &&
                  source.include?("infra', 'SaneProcess', 'scripts', 'SaneMaster.rb")
  bash_delegate || ruby_delegate
rescue ArgumentError, Errno::ENOENT, Errno::EACCES
  false
end
