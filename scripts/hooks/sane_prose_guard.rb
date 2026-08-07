#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_prose_guard.rb — PreToolUse Write/Edit guard enforcing Orwell's rules on
# customer-facing copy.
#
# WHY (owner, 2026-07-24): "make the orwell rules SOP and require exceptions to
# be self explanatory and justified". Read-only style docs get forgotten, so the
# rules live here, where copy is actually written.
#
# From "Politics and the English Language":
#   1. Never use a metaphor/simile you are used to seeing in print.
#   2. Never use a long word where a short one will do.
#   3. If it is possible to cut a word out, cut it out.
#   4. Never use the passive where you can use the active.
#   5. Never use jargon/a foreign phrase if there is an everyday equivalent.
#   6. Break any of these rules sooner than say anything outright barbarous.
#
# Rules 1, 2 and 5 are mechanically checkable and are ENFORCED. Rules 3 and 4
# need judgement, so they are reported as advisory counts rather than blocking —
# a guard that cries wolf gets disabled, and a disabled guard enforces nothing.
#
# Rule 6 is the escape hatch, and it is deliberately self-documenting. Put a
# marker IN THE FILE, not in an env var, so the justification survives next to
# the copy it excuses and explains itself to whoever reads it next:
#
#   HTML: <!-- prose-exception: "quote-only" is the buyer's own term, keeps competitive bite -->
#   text/md: [prose-exception: "quote-only" is the buyer's own term]
#
# The reason must stand alone (>=25 chars, no filler).

require 'json'

REASON_MIN_LENGTH = 25
FILLER = /\A(?:ok(?:ay)?|yes|fine|needed|because|just|temp|test|trust me|it.s fine|style)\b/i.freeze

# Only customer-facing copy. Source files are none of this guard's business.
# BOTH an extension check AND a context check are required. The first version
# matched any path merely CONTAINING "outreach", so it blocked an edit to
# pull_leads.py over the word "purchase" in a code comment (2026-07-25). A guard
# that fires on source code gets switched off, and then it protects nothing.
COPY_EXT = /\.(?:txt|html?|md|markdown)\z/i.freeze
COPY_CONTEXT = %r{(?:outreach|/copy/|marketing|campaign|websites/)}i.freeze
# Internal docs that happen to live beside copy are not customer-facing either.
INTERNAL_DOC = /\/(?:README|AGENTS|CLAUDE|CHANGELOG|NOTES|TODO|BATCH_PLAN)\.[^\/]+\z/i.freeze
WEBSITE_PAGE = %r{websites/[^/]+/(?:index|pricing|about|compare/[^/]+)\.html\z}i.freeze
EMAIL_FILE = %r{/email-[^/]*\.(?:txt|html|md)\z}i.freeze

def copy_file?(path)
  return false if path.match?(INTERNAL_DOC)
  return true if path.match?(EMAIL_FILE) || path.match?(WEBSITE_PAGE)

  path.match?(COPY_EXT) && path.match?(COPY_CONTEXT)
end

# Rule 2 — long word where a short one will do.
LONG_WORDS = {
  /\butiliz(?:e|es|ed|ing)\b/i => 'use',
  /\bleverag(?:e|es|ed|ing)\b/i => 'use',
  /\bfacilitat(?:e|es|ed|ing)\b/i => 'help',
  /\bcommenc(?:e|es|ed|ing)\b/i => 'start',
  /\bendeavou?r\b/i => 'try',
  /\bendeavou?rs\b/i => 'tries',
  /\bprior to\b/i => 'before',
  /\bsubsequent to\b/i => 'after',
  /\bin order to\b/i => 'to',
  /\bat this point in time\b/i => 'now',
  /\bin the event that\b/i => 'if',
  /\ba majority of\b/i => 'most',
  /\bis able to\b/i => 'can',
  /\badditional\b/i => 'more',
  /\bapproximately\b/i => 'about',
  /\bsufficient\b/i => 'enough',
  /\bpurchase\b/i => 'buy',
  /\bassist(?:ance)?\b/i => 'help'
}.freeze

# Rule 5 — jargon with an everyday equivalent.
JARGON = {
  /\bsynerg(?:y|ies|istic)\b/i => 'say what actually combines',
  /\bbest[- ]in[- ]class\b/i => 'say what it does better',
  /\bcutting[- ]edge\b/i => 'say what is new about it',
  /\bstate[- ]of[- ]the[- ]art\b/i => 'say what it does',
  /\bseamless(?:ly)?\b/i => 'say what does not break',
  /\brobust\b/i => 'say what it survives',
  /\bgame[- ]chang(?:er|ing)\b/i => 'say what changes',
  /\brevolutionar(?:y|ise|ize)\b/i => 'say what is different',
  /\bturnkey\b/i => 'say what is already set up',
  /\bfrictionless\b/i => 'say what step is gone',
  /\bempower(?:s|ing|ed)?\b/i => 'say what it lets them do',
  /\bunlock(?:s|ing)? (?:the )?(?:value|potential|power)\b/i => 'say what they get',
  /\bmission[- ]critical\b/i => 'say what breaks without it',
  /\bholistic\b/i => 'say what it covers'
}.freeze

# Rule 1 — metaphors you are used to seeing in print.
DYING_METAPHORS = [
  /\bat the end of the day\b/i,
  /\bmove the needle\b/i,
  /\blow[- ]hanging fruit\b/i,
  /\bthink outside the box\b/i,
  /\btake it to the next level\b/i,
  /\bdeep dive\b/i,
  /\bcircle back\b/i,
  /\blevel playing field\b/i,
  /\bneedle in a haystack\b/i,
  /\bboil the ocean\b/i,
  /\bsecret sauce\b/i,
  /\bheavy lifting\b/i
].freeze

# Rule 6 territory, learned the hard way 2026-07-24: SaneCite is an AI product,
# and its cold email opened by scare-quoting "AI" as the thing to fear. Do not
# sneer at the category you sell.
# Punctuation commonly sits INSIDE the closing quote (`"AI."`), which is exactly
# how it appeared in the email that shipped, so allow for it.
SELF_SNEER = /["“”']\s*AI\s*[.,;:!?]?["“”']/.freeze

PASSIVE = /\b(?:is|are|was|were|be|been|being)\s+(?:\w+ly\s+)?\w+(?:ed|own|orn|uilt|old)\b/i.freeze

def payload(data_raw)
  JSON.parse(data_raw)
rescue JSON::ParserError
  nil
end

def target_text(data)
  input = data['tool_input'] || {}
  input['content'] || input['new_string'] || ''
end

def target_path(data)
  (data['tool_input'] || {})['file_path'].to_s
end

def visible_prose(text, path)
  body = text.dup
  if path.end_with?('.html')
    body = body.gsub(/<(script|style)[^>]*>.*?<\/\1>/mi, ' ')
    body = body.gsub(/<[^>]+>/, ' ')
  end
  body.gsub(/https?:\/\/\S+/, ' ').gsub(/\s+/, ' ')
end

def justified?(text)
  m = text.match(/prose-exception:\s*([^\n\->\]]+)/i)
  return false unless m

  reason = m[1].strip
  reason.length >= REASON_MIN_LENGTH && !reason.match?(FILLER)
end

data = payload($stdin.read.force_encoding(Encoding::UTF_8))
exit 0 if data.nil?
exit 0 unless %w[Write Edit].include?(data['tool_name'])

path = target_path(data)
exit 0 unless copy_file?(path)

raw = target_text(data)
exit 0 if raw.strip.empty?
exit 0 if justified?(raw)

prose = visible_prose(raw, path)
findings = []

LONG_WORDS.each do |re, better|
  next unless prose.match?(re)

  findings << "rule 2 (long word): #{prose[re].strip.downcase.inspect} → #{better.inspect}"
end
JARGON.each do |re, better|
  next unless prose.match?(re)

  findings << "rule 5 (jargon): #{prose[re].strip.downcase.inspect} → #{better}"
end
DYING_METAPHORS.each do |re|
  next unless prose.match?(re)

  findings << "rule 1 (stale metaphor): #{prose[re].strip.downcase.inspect}"
end
findings << 'rule 6: scare-quoted "AI" — do not sneer at the category you sell' if prose.match?(SELF_SNEER)

exit 0 if findings.empty?

passives = prose.scan(PASSIVE).size
warn '🔴 BLOCKED: customer-facing copy breaks Orwell rules'
warn "   #{File.basename(path)}"
warn ''
findings.first(12).each { |f| warn "   • #{f}" }
warn "   • …and #{findings.size - 12} more" if findings.size > 12
warn ''
warn "   Advisory (judgement, not blocked): #{passives} possible passive construction(s)." if passives.positive?
warn '   Also ask: could I put it more shortly? Anything avoidably ugly?'
warn ''
warn '   ✅ Fix the wording, or justify it IN THE FILE so the reason lives with the copy:'
warn '        HTML     <!-- prose-exception: <specific reason> -->'
warn '        txt/md   [prose-exception: <specific reason>]'
warn "   The reason must stand on its own (#{REASON_MIN_LENGTH}+ chars, no filler)."
warn '   Orwell rule 6 is real: break a rule sooner than say anything barbarous —'
warn '   but say WHY, so the next person does not "fix" your deliberate choice.'
exit 2
