# frozen_string_literal: true

# ==============================================================================
# SaneTrack - Blind (source-fingerprint) Test Detection (Rule #7)
# ==============================================================================
# Sibling of the tautology/mock-passthrough checks in sanetrack.rb.
#
# Context: SaneBar's RuntimeGuard*XCTests.swift suite shipped ~2,000+
# `source.contains("…")` / `String(contentsOf:)` assertions that check code
# STRUCTURE, not runtime behavior. A real regression PASSES them, so broken
# builds shipped "tests green." This module red-flags that blindness at write
# time so it can never silently return.
#
# It is a WARNING, not a block (matches check_tautologies). PostToolUse never
# blocks; warnings go to stderr via `warn`.
# ==============================================================================

module SaneTrackBlindTests
  module_function

  # --- Source-loading signals: the test reads a source file into a string ---
  SOURCE_LOAD_PATTERNS = [
    /String\s*\(\s*contentsOf\s*:/i,        # try String(contentsOf: url, ...)
    /String\s*\(\s*contentsOfFile\s*:/i,    # String(contentsOfFile: path, ...)
    /\.appendingPathComponent\([^)]*\.swift/i, # building a path to a .swift file
    /projectRootURL\(\)/i,                  # SaneBar's source-root helper
    /Data\s*\(\s*contentsOf\s*:[^)]*\.swift/i
  ].freeze

  # --- Blind assertion signals: asserting a substring lives in loaded source ---
  # These are the assertions that pass regardless of runtime behavior.
  BLIND_ASSERTION_PATTERNS = [
    /\b\w*[Ss]ource\w*\.contains\s*\(/,        # source.contains( / managerSource.contains(
    /\b\w*[Ss]ource\w*\.range\s*\(\s*of\s*:/,  # source.range(of:)
    /\b\w*[Ss]ource\w*\.hasPrefix\s*\(/,
    /\b\w*[Ss]ource\w*\.hasSuffix\s*\(/,
    /XCTAssert(?:True|False)?\s*\([^,)]*\.contains\s*\([^)]*"\)/ # XCTAssertTrue(x.contains("..."))
  ].freeze

  # --- Behavioral signals: the test actually drives code / observes runtime ---
  # If a test does any of these, it is doing real work — do not flag.
  BEHAVIORAL_PATTERNS = [
    /\bawait\b/,                                # driving async behavior
    /\.shared\b(?!\.geometryResolver)/,         # touching a live singleton (weak signal, see scoring)
    /\b(?:try\s+)?await\s+\w+\.\w+\(/,          # awaiting a real method
    /=\s*\w+\([^)]*\)\s*$/,                      # instantiating an object: let x = Foo(...)
    /\.init\s*\(/,
    /XCTAssertEqual\s*\([^,]+,\s*\w+\.[a-z]\w*\(/, # asserting on a method's return value
    /XCTAssertThrowsError|XCTAssertNoThrow/,
    /#expect\s*\(\s*try\b/,
    /measure\s*\{/,                             # performance test
    /expectation\(description:/                 # async XCTest expectation
  ].freeze

  # A test that merely mentions a string literal somewhere is NOT blind. We only
  # flag when blind assertions DOMINATE and behavior is essentially absent.
  #
  # Returns a warning String, or nil if the content is not blind.
  def check(code)
    return nil if code.nil? || code.strip.empty?

    loads_source = SOURCE_LOAD_PATTERNS.any? { |p| code.match?(p) }
    blind_count = BLIND_ASSERTION_PATTERNS.sum { |p| code.scan(p).length }

    # Behavioral signals must be detected on CODE, not on the source snippets
    # being asserted. Blind tests pass string literals like
    #   source.contains("await manager.warmCache(...)")
    # which would otherwise trip the `\bawait\b` / instantiation signals. Mask
    # double-quoted string literal CONTENTS before scanning for behavior.
    code_no_strings = mask_string_literals(code)

    # Total assertions in the chunk (XCTest + Swift Testing).
    total_assertions = code.scan(/XCTAssert\w*\s*\(|#expect\s*\(/).length

    # No blind assertions => not this failure mode.
    return nil if blind_count.zero?

    # The fingerprint is established by EITHER an explicit source-load idiom
    # (String(contentsOf:), projectRootURL(), …) OR a clear cluster of
    # substring assertions against a *source*-named variable — which covers the
    # common helper idiom `let source = try appleScriptCommandSource()`.
    return nil unless loads_source || blind_count >= 3

    # Behavioral evidence. We exclude the source-root helper from the
    # ".shared" weak signal because SaneBar's blind tests reference
    # MenuBarManager.shared.geometryResolver INSIDE the asserted string literal,
    # not as a live call.
    behavioral_hits = BEHAVIORAL_PATTERNS.count { |p| code_no_strings.match?(p) }

    # Real instantiation outside of URL/path building is the strongest "this is
    # behavioral" signal. URL(...) / appendingPathComponent(...) don't count.
    real_instantiation = code_no_strings.match?(/=\s*(?!URL\b|String\b|Data\b|try\s+String\b)[A-Z]\w+\s*\(/) &&
                         !code_no_strings.match?(/=\s*\w*URL\b/)

    behavioral = behavioral_hits.positive? || real_instantiation

    # Dominance: at least 3 blind assertions and they are the overwhelming
    # majority of assertions (>= 80%), with no behavioral evidence.
    return nil if blind_count < 3
    blind_ratio = total_assertions.zero? ? 1.0 : (blind_count.to_f / total_assertions)
    return nil if blind_ratio < 0.8
    return nil if behavioral

    warning_text(blind_count, total_assertions)
  end

  # Replace the CONTENTS of double-quoted Swift string literals with a marker so
  # behavioral-signal scanning ignores code that only appears inside asserted
  # source snippets. Handles escaped quotes (\"). Conservative: leaves the
  # surrounding quotes so assertion-shape patterns still match.
  def mask_string_literals(code)
    code.gsub(/"(?:\\.|[^"\\])*"/, '"_"')
  end

  def warning_text(blind_count, total_assertions)
    <<~WARN.chomp
      🚩 BLIND TEST WARNING: this test asserts source structure (#{blind_count} of #{total_assertions} assertions use source.contains/String(contentsOf:)), not runtime behavior — a real regression will pass it.
         Pair it with a runtime gate that reproduces the failure AND the success by driving the app, and assert the customer-observable end-state.
         Source-fingerprint guards are not behavioral coverage. See DEVELOPMENT.md.
    WARN
  end
end
