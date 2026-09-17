#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'test/test_framework'
require_relative 'sanetools_checks'

include TestFramework

KEYWORDS = %w[edit write create modify change update add remove delete fix patch].freeze

GOOD_BRIEF = 'Work on the Mac Mini via ssh mini (never /Users/sj/SaneApps on the Air). ' \
  'Repo ~/SaneApps/clients/translations. Scope files: books/photius-bibliotheca/translations/bibl_codex_16_*. ' \
  'Acceptance: scripts/assert_tip_ready.py exits 0 with "tip-ready: ok". ' \
  'Stop if any gate fails. Commit nothing.'.freeze

exit(run_tests('BriefLinter') do
  test('read-only lookup passes untouched') do
    assert_eq(SaneToolsChecks.brief_gaps('Find the file that defines check_subagent_bypass', KEYWORDS), [])
  end

  test('edit brief without host, done, or commit flags three gaps') do
    gaps = SaneToolsChecks.brief_gaps('Fix the failing gate in pipeline/check_pass_ab.py and run the tests', KEYWORDS)
    assert_eq(gaps.length, 3)
    assert(gaps.any? { |g| g.start_with?('HOST:') }, 'expected HOST gap')
    assert(gaps.any? { |g| g.start_with?('DONE:') }, 'expected DONE gap')
    assert(gaps.any? { |g| g.start_with?('NO-COMMIT:') }, 'expected NO-COMMIT gap')
  end

  test('complete brief passes') do
    assert_eq(SaneToolsChecks.brief_gaps(GOOD_BRIEF, KEYWORDS), [])
  end

  test('bypass/repair wording does not fake the checks') do
    gaps = SaneToolsChecks.brief_gaps('Fix the failing build without bypassing the gate, then repair what broke', KEYWORDS)
    assert_eq(gaps.length, 4)
  end

  test('wrapper ignores non-Task tools') do
    assert_eq(SaneToolsChecks.check_brief_completeness('Bash', { 'command' => 'fix tests' }, KEYWORDS), nil)
  end

  test('wrapper passes a complete Task brief outside self-development') do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        assert_eq(SaneToolsChecks.check_brief_completeness('Task', { 'prompt' => GOOD_BRIEF }, KEYWORDS), nil)
      end
    end
  end

  test('wrapper blocks an incomplete Task brief with actionable message') do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        reason = SaneToolsChecks.check_brief_completeness('Task',
                                                          { 'prompt' => 'Fix the failing gate and update the docs' },
                                                          KEYWORDS)
        assert_match(reason.to_s, /BRIEF INCOMPLETE/)
        assert_match(reason.to_s, /HOST:/)
      end
    end
  end
end)
