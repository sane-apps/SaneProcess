#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Post-hoc audit of Muse subagent_spawn briefs. Muse Code fires no hook
# events, so this is detection, not prevention: it scans recent session logs,
# extracts spawn objectives, and runs the same brief_gaps check the PreToolUse
# gate enforces for other clients. Prints identifiers and gaps only.
#
# Usage: audit_spawn_briefs.rb [--days N]  (default 1)
# Exit 0 = all briefs complete, 1 = gaps found.

require 'json'
require 'date'
require_relative 'hooks/sanetools_checks'

KEYWORDS = %w[edit write create modify change update add remove delete fix patch generate produce implement build rebuild scaffold migrate translate].freeze

days = (ARGV[ARGV.index('--days') + 1].to_i if ARGV.include?('--days')) || 1
days = 1 if days < 1
sessions_root = File.expand_path('~/.local/share/muse/sessions')
cutoff = Time.now - (days * 86_400)

checked = 0
flagged = 0

Dir.glob(File.join(sessions_root, '*', '*', '*', '*', 'session.jsonl')).each do |log|
  next unless File.mtime(log) >= cutoff

  File.foreach(log) do |line|
    next unless line.include?('"name": "subagent_spawn"') || line.include?('"name":"subagent_spawn"')

    begin
      record = JSON.parse(line)
    rescue JSON::ParserError
      next
    end

    objectives = []
    scan = lambda do |node|
      case node
      when Hash
        if node['name'] == 'subagent_spawn' && node['args'].is_a?(String)
          begin
            objectives << JSON.parse(node['args'])
          rescue JSON::ParserError
            nil
          end
        end
        node.each_value { |v| scan.call(v) }
      when Array
        node.each { |v| scan.call(v) }
      end
    end
    scan.call(record)

    objectives.each do |args|
      brief = args['objective'].to_s
      next if brief.empty?

      checked += 1
      gaps = SaneToolsChecks.brief_gaps(brief, KEYWORDS)
      next if gaps.empty?

      flagged += 1
      puts "GAPS session=#{File.basename(File.dirname(log))} " \
           "task=#{args['task_name'] || args['command_id'] || '?'}"
      gaps.each { |g| puts "  - #{g.split(':').first}" }
    end
  end
end

puts "checked=#{checked} flagged=#{flagged}"
exit(flagged.zero? ? 0 : 1)
