#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for Verify#extract_ui_identifiers / #extract_test_references — the
# UI-test identifier consistency check that gates pre-push verify.
#
# Regression (2026-07-15, SaneVideo): identifiers passed as labeled component
# arguments (SheetHeader(accessibilityID: "voiceover.sheet.close")) were not
# recognized as declared, so a healthy tree failed the gate with
# "Tests reference non-existent identifiers".
#
# Run: ruby scripts/sanemaster/verify_doctor_identifier_test.rb

require 'tmpdir'
require 'fileutils'
require 'set'
require_relative 'verify_doctor'

@passed = 0
@failed = 0

def check(desc)
  ok = yield
  if ok
    @passed += 1
    puts "  PASS: #{desc}"
  else
    @failed += 1
    puts "  FAIL: #{desc}"
  end
rescue StandardError => e
  @failed += 1
  puts "  FAIL: #{desc} (#{e.class}: #{e.message})"
end

class VerifyDoctorHarness
  include SaneMasterModules::Verify
  # The module reads these from the including class in real use.
  def project_ui_tests_dir = File.join(Dir.pwd, 'AppUITests')
  def project_app_dir = File.join(Dir.pwd, 'App')
  def ui_tests_present? = Dir.exist?(project_ui_tests_dir)
  # The module marks its helpers private; expose the two under test.
  public :extract_ui_identifiers, :extract_test_references
end

def with_fixture
  Dir.mktmpdir('vd_fixture') do |dir|
    FileUtils.mkdir_p(File.join(dir, 'App/Views'))
    FileUtils.mkdir_p(File.join(dir, 'AppUITests'))
    Dir.chdir(dir) { yield dir }
  end
end

harness = VerifyDoctorHarness.new

puts 'Declared-identifier extraction:'

check('direct .accessibilityIdentifier("...") is declared') do
  with_fixture do
    File.write('App/Views/A.swift', %(Text("x").accessibilityIdentifier("direct.id.here")\n))
    harness.extract_ui_identifiers.include?('direct.id.here')
  end
end

check('labeled component argument accessibilityID: "..." is declared (SaneVideo regression)') do
  with_fixture do
    File.write('App/Views/Sheet.swift', <<~SWIFT)
      SheetHeader(
          title: "Generate Voiceover",
          dismissAction: { dismiss() },
          accessibilityID: "voiceover.sheet.close"
      )
    SWIFT
    harness.extract_ui_identifiers.include?('voiceover.sheet.close')
  end
end

check('labeled accessibilityIdentifier: "..." init argument is declared') do
  with_fixture do
    File.write('App/Views/B.swift', %(MyControl(accessibilityIdentifier: "init.arg.id")\n))
    harness.extract_ui_identifiers.include?('init.arg.id')
  end
end

check('suffixed ...ID: labels are declarations (SaneVideo cancelID/actionID)') do
  with_fixture do
    File.write('App/Views/C.swift', <<~SWIFT)
      SheetFooter(
          cancelID: "demo_studio.cancel",
          actionID: "demo_studio.save"
      )
    SWIFT
    ids = harness.extract_ui_identifiers
    ids.include?('demo_studio.cancel') && ids.include?('demo_studio.save')
  end
end

check('bare id: label with dotted identifier is a declaration (SaneVideo audio action)') do
  with_fixture do
    File.write('App/Views/D.swift', %(ActionRow(\n    id: "audio.action.repair_sync"\n)\n))
    harness.extract_ui_identifiers.include?('audio.action.repair_sync')
  end
end

check('id: labels with non-identifier-shaped values are NOT declarations') do
  with_fixture do
    File.write('App/Views/E.swift', %(Model(id: "UUID-1234"): id: "plainword"\n))
    ids = harness.extract_ui_identifiers
    !ids.include?('UUID-1234') && !ids.include?('plainword')
  end
end

check('identifiers inside UITests are NOT treated as declarations') do
  with_fixture do
    File.write('AppUITests/T.swift', %(app.buttons["only.in.tests"].tap()\n))
    !harness.extract_ui_identifiers.include?('only.in.tests')
  end
end

puts ''
puts 'Test-reference extraction:'

check('app.buttons["..."] subscript reference is detected') do
  with_fixture do
    File.write('AppUITests/T.swift', %(let b = app.buttons["voiceover.sheet.close"].waitForExistence(timeout: 5)\n))
    harness.extract_test_references.include?('voiceover.sheet.close')
  end
end

check('end-to-end: labeled-argument declaration satisfies a test reference') do
  with_fixture do
    File.write('App/Views/Sheet.swift', %(SheetHeader(accessibilityID: "voiceover.sheet.close")\n))
    File.write('AppUITests/T.swift', %(app.buttons["voiceover.sheet.close"].tap()\n))
    missing = harness.extract_test_references - harness.extract_ui_identifiers
    missing.empty?
  end
end

puts ''
puts "#{@passed}/#{@passed + @failed} tests passed"
if @failed.zero?
  puts 'ALL TESTS PASSED'
  exit 0
else
  puts "#{@failed} FAILED"
  exit 1
end
