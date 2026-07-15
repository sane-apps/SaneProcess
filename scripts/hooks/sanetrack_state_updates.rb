#!/usr/bin/env ruby
# frozen_string_literal: true

module SaneTrackStateUpdates
  SPARKLE_SIGN_DETECT = /sign_update(?:\.swift)?\s+["']?([^"'\s]+\.dmg)["']?/i.freeze
  STAPLER_DETECT = /xcrun\s+stapler\s+(?:validate|staple)\s+["']?([^"'\s]+\.dmg)["']?/i.freeze

  HANDOFF_FILE_PATTERNS = [
    /SESSION_HANDOFF\.md$/i,
    /MEMORY\.md$/i,
    %r{memory/.*\.md$}i,
    %r{\.serena/memories/}i,
    /sop_ratings\.csv$/i,
    /state\.json$/i,
    /sanetrack\.log$/i,
    /sanestop\.log$/i,
    /session_learnings/i
  ].freeze

  TRIVIAL_FILE_PATTERNS = [
    /\.log$/i,
    /\.csv$/i,
    /\.lock$/i,
    /\.json\.lock$/i
  ].freeze

  ALWAYS_PERSIST_FILE_PATTERNS = [
    %r{/scripts/hooks/}i,
    %r{/scripts/.*\.(rb|py|sh)$}i,
    %r{/templates/}i,
    /(?:^|\/)AGENTS\.md$/i,
    /(?:^|\/)CLAUDE(?:_PUBLIC)?\.md$/i,
    /(?:^|\/)(README|DEVELOPMENT|ARCHITECTURE)\.md$/i,
    /(?:^|\/)SKILL\.md$/i
  ].freeze

  def track_deployment_actions(tool_name, tool_input, tool_response)
    return unless tool_name == 'Bash'

    command = tool_input['command'] || tool_input[:command] || ''
    return if command.empty?

    sign_match = command.match(SPARKLE_SIGN_DETECT)
    if sign_match
      dmg_filename = File.basename(sign_match[1])
      StateManager.update(:deployment) do |deployment|
        deployment[:sparkle_signed_dmgs] ||= []
        deployment[:sparkle_signed_dmgs] << dmg_filename unless deployment[:sparkle_signed_dmgs].include?(dmg_filename)
        deployment
      end
      warn "✅ Sparkle signature recorded for #{dmg_filename}"
    end

    staple_match = command.match(STAPLER_DETECT)
    if staple_match
      dmg_filename = File.basename(staple_match[1])
      error_sig = detect_actual_failure(tool_name, tool_response)
      if error_sig.nil?
        StateManager.update(:deployment) do |deployment|
          deployment[:staple_verified_dmgs] ||= []
          deployment[:staple_verified_dmgs] << dmg_filename unless deployment[:staple_verified_dmgs].include?(dmg_filename)
          deployment
        end
        warn "✅ Staple verification recorded for #{dmg_filename}"
      end
    end
  rescue StandardError => e
    warn "⚠️  Deployment tracking error: #{e.message}" if ENV['DEBUG']
  end

  def track_handoff_status(tool_name, tool_input)
    if tool_name == 'mcp__serena__write_memory' ||
       tool_name.match?(/\Amcp__(?:plugin_[a-z0-9_-]+_)?agentmemory__(?:memory_save|memory_lesson_save)\z/i) ||
       tool_name.match?(/\Amcp__(?:memory|central-memory)__(?:add|create|delete|update|write)_/i)
      StateManager.update(:handoff_tracking) do |handoff|
        handoff[:memory_updated] = true
        handoff
      end
      return
    end

    return unless EDIT_TOOLS.include?(tool_name)

    file_path = tool_input['file_path'] || tool_input[:file_path]
    return unless file_path

    basename = File.basename(file_path)

    if file_path.match?(/SESSION_HANDOFF\.md$/i)
      StateManager.update(:handoff_tracking) do |handoff|
        handoff[:handoff_updated] = true
        handoff
      end
      return
    end

    if file_path.match?(/MEMORY\.md$/i) || file_path.match?(%r{memory/.*\.md$}i) || file_path.match?(%r{\.serena/memories/}i)
      StateManager.update(:handoff_tracking) do |handoff|
        handoff[:memory_updated] = true
        handoff
      end
      return
    end

    return if HANDOFF_FILE_PATTERNS.any? { |pattern| file_path.match?(pattern) }
    return if TRIVIAL_FILE_PATTERNS.any? { |pattern| file_path.match?(pattern) }

    if ALWAYS_PERSIST_FILE_PATTERNS.any? { |pattern| file_path.match?(pattern) }
      StateManager.update(:handoff_tracking) do |handoff|
        handoff[:always_persist_required] = true
        handoff[:always_persist_files] ||= []
        handoff[:always_persist_files] << basename unless handoff[:always_persist_files].include?(basename)
        handoff[:always_persist_files] = handoff[:always_persist_files].last(20)
        handoff[:significant_edits] = (handoff[:significant_edits] || 0) + 1
        handoff[:significant_files] ||= []
        handoff[:significant_files] << basename unless handoff[:significant_files].include?(basename)
        handoff[:significant_files] = handoff[:significant_files].last(20)
        handoff
      end
      return
    end

    StateManager.update(:handoff_tracking) do |handoff|
      handoff[:significant_edits] = (handoff[:significant_edits] || 0) + 1
      handoff[:significant_files] ||= []
      handoff[:significant_files] << basename unless handoff[:significant_files].include?(basename)
      handoff[:significant_files] = handoff[:significant_files].last(20)
      handoff
    end
  rescue StandardError => e
    warn "⚠️  Handoff tracking error: #{e.message}" if ENV['DEBUG']
  end
end
