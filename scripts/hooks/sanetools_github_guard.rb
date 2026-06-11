#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

module SaneToolsGitHubGuard
  GITHUB_PUBLIC_POST_TOOLS = %w[
    mcp__github__add_issue_comment
    mcp__github__update_issue
    mcp__github__create_issue
    mcp__github__create_pull_request_review
    mcp__github__create_pull_request
  ].freeze

  GITHUB_APPROVAL_FLAG = '/tmp/.gh_post_approved.json'
  GITHUB_APPROVAL_TTL_SECONDS = 300
  SANE_OWNER_PATTERN = /\A(?:sane-apps|mrsaneapps)\z/i
  CORPORATE_WE_PATTERN = /\b(?:we|we['’]re|we['’]ll|we['’]ve|our|us)\b/i

  def check_github_post_guard(tool_name, tool_input)
    return nil unless GITHUB_PUBLIC_POST_TOOLS.include?(tool_name)
    return nil unless sane_owner?(tool_input)

    public_text = extract_public_text(tool_input)
    if public_text.match?(CORPORATE_WE_PATTERN)
      return "GITHUB POST BLOCKED\n" \
             'Use first-person singular language only for client/public replies.' \
             "\nReplace: we/us/our -> I/me/my."
    end

    status = consume_github_approval_flag
    return nil if status == :valid

    "GITHUB POST BLOCKED\n" \
    "This action posts publicly and requires explicit user approval first.\n" \
    "Show the final draft, get approval, then run:\n" \
    '  ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb github_post_approval --user-approval "<quote>"'
  end

  def sane_owner?(tool_input)
    owner = (tool_input['owner'] || tool_input[:owner]).to_s.strip
    return false if owner.empty?

    owner.match?(SANE_OWNER_PATTERN)
  end

  def extract_public_text(tool_input)
    pieces = []

    %w[title body comment].each do |key|
      value = tool_input[key] || tool_input[key.to_sym]
      pieces << value.to_s unless value.nil?
    end

    comments = tool_input['comments'] || tool_input[:comments]
    if comments.is_a?(Array)
      comments.each { |value| pieces << value.to_s }
    elsif !comments.nil?
      pieces << comments.to_s
    end

    pieces.join("\n")
  end

  def consume_github_approval_flag
    return :missing unless File.exist?(GITHUB_APPROVAL_FLAG)

    payload = JSON.parse(File.read(GITHUB_APPROVAL_FLAG, encoding: Encoding::UTF_8))
    File.delete(GITHUB_APPROVAL_FLAG)
    created_at = payload['created_at'].to_i
    approval = payload['user_approval'].to_s.strip
    age = Time.now.to_i - created_at
    return :valid if created_at.positive? && age >= 0 && age < GITHUB_APPROVAL_TTL_SECONDS && !approval.empty?

    :stale
  rescue StandardError
    :missing
  end
end
