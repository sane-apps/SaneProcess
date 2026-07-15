#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Research EVIDENCE gate tests
# ==============================================================================
# The verify research gate used to clear on research.md mtime alone, so a bare
# hand-edit (zero fresh research) satisfied it. These tests lock the fix: the
# gate now also requires the tool-call-tracked research categories (StateManager
# :research, with completed_at timestamps) to be FRESH since the lock fired.
# ==============================================================================

require 'json'
require 'time'

require_relative '../hooks/test/test_framework'
require_relative 'sop_loop'

class ResearchEvidenceGateHarness
  include SaneMasterModules::SOPLoop
end

include TestFramework

T0 = Time.parse('2026-06-29T04:00:00-04:00')
FRESH = (T0 + 3600).iso8601   # research done AFTER the lock fired
STALE = (T0 - 3600).iso8601   # research done BEFORE the lock fired

def fresh_research
  { web: { completed_at: FRESH }, local: { completed_at: FRESH }, docs: { completed_at: FRESH } }
end

exit(run_tests('Research Evidence Gate') do
  subject = ResearchEvidenceGateHarness.new

  test_category('missing_research_evidence (pure)') do
    test('all categories fresh since trigger → nothing missing') do
      missing = subject.send(:missing_research_evidence, fresh_research, %i[web local], T0)
      assert_eq(missing, [])
      true
    end

    test('a category completed BEFORE the trigger is still missing') do
      research = { web: { completed_at: STALE }, local: { completed_at: FRESH } }
      missing = subject.send(:missing_research_evidence, research, %i[web local], T0)
      assert_eq(missing, [:web])
      true
    end

    test('a never-run category (nil) is missing') do
      research = { web: { completed_at: FRESH } } # local absent
      missing = subject.send(:missing_research_evidence, research, %i[web local], T0)
      assert_eq(missing, [:local])
      true
    end

    test('the bare-hand-edit bypass: no fresh research → every category missing') do
      research = { web: { completed_at: STALE }, local: { completed_at: STALE }, docs: { completed_at: STALE } }
      missing = subject.send(:missing_research_evidence, research, %i[web local docs], T0)
      assert_eq(missing, %i[web local docs])
      true
    end

    test('nil trigger never enforces (cannot fail-closed without a trigger)') do
      assert_eq(subject.send(:missing_research_evidence, {}, %i[web local], nil), [])
      true
    end

    test('string completed_at keys are honored') do
      research = { web: { 'completed_at' => FRESH }, local: { 'completed_at' => FRESH } }
      assert_eq(subject.send(:missing_research_evidence, research, %i[web local], T0), [])
      true
    end
  end

  test_category('effective_research_evidence_categories') do
    test('web + local always required; docs added only when apple-docs is configured') do
      subject.define_singleton_method(:apple_docs_research_configured?) { true }
      assert_eq(subject.send(:effective_research_evidence_categories), %i[web local docs])
      subject.define_singleton_method(:apple_docs_research_configured?) { false }
      assert_eq(subject.send(:effective_research_evidence_categories), %i[web local])
      true
    end
  end

  test_category('current memory guidance') do
    test('research steps use AgentMemory instead of the retired graph MCP') do
      steps = subject.send(:default_research_steps).join(' ')
      assert_includes(steps, 'mcp__agentmemory__memory_smart_search')
      assert_includes(steps, 'mcp__agentmemory__memory_recall')
      assert(!steps.include?('mcp__memory__'), 'research guidance still names the retired graph MCP')
      true
    end
  end

  test_category('active_research_locks wired to evidence') do
    lock = { source_updated_at: T0.iso8601 }

    test('fresh research.md AND fresh tool-call evidence → lock clears') do
      probe = ResearchEvidenceGateHarness.new
      probe.define_singleton_method(:apple_docs_research_configured?) { false }
      probe.define_singleton_method(:research_state_section) { fresh_research }
      result = probe.send(:active_research_locks, locks: [lock], research_time: T0 + 7200)
      assert_eq(result, [])
      true
    end

    test('fresh research.md but NO fresh evidence (the old bypass) → lock STAYS active') do
      probe = ResearchEvidenceGateHarness.new
      probe.define_singleton_method(:apple_docs_research_configured?) { false }
      probe.define_singleton_method(:research_state_section) do
        { web: { completed_at: STALE }, local: { completed_at: STALE } }
      end
      result = probe.send(:active_research_locks, locks: [lock], research_time: T0 + 7200)
      assert_eq(result, [lock])
      true
    end

    test('stale research.md still blocks (unchanged mtime behavior)') do
      probe = ResearchEvidenceGateHarness.new
      probe.define_singleton_method(:apple_docs_research_configured?) { false }
      probe.define_singleton_method(:research_state_section) { fresh_research }
      result = probe.send(:active_research_locks, locks: [lock], research_time: T0 - 7200)
      assert_eq(result, [lock])
      true
    end

    test('unreadable hook state fails OPEN (never bricks verify)') do
      probe = ResearchEvidenceGateHarness.new
      probe.define_singleton_method(:apple_docs_research_configured?) { false }
      probe.define_singleton_method(:research_state_section) { nil }
      result = probe.send(:active_research_locks, locks: [lock], research_time: T0 + 7200)
      assert_eq(result, [])
      true
    end
  end
end)
