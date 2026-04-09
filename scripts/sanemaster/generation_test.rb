#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'generation'

class GenerationHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Generation

  def initialize(root)
    @root = root
  end

  def saneprocess_repo_root
    @root
  end
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

def write_fake_saneprocess_root(root)
  FileUtils.mkdir_p(File.join(root, 'scripts', 'mini'))
  FileUtils.mkdir_p(File.join(root, 'scripts', 'automation'))

  File.write(
    File.join(root, 'DEVELOPMENT.md'),
    <<~MD
      verify --ui
      verify_api
      verify_mocks
      check_docs
    MD
  )
  File.write(File.join(root, 'README.md'), "## Operator Docs Map\n")
  File.write(
    File.join(root, 'scripts', 'mini', 'README.md'),
    "| `bootstrap-build-server.sh` | On demand |\n"
  )
  File.write(
    File.join(root, 'scripts', 'automation', 'README.md'),
    "repo-root-safe\n"
  )
  File.write(
    File.join(root, 'scripts', 'SaneMaster.rb'),
    <<~SH
      #!/bin/bash
      cat <<'EOF'
        check_docs
      EOF
    SH
  )
  FileUtils.chmod('+x', File.join(root, 'scripts', 'SaneMaster.rb'))
end

exit(run_tests('SaneMaster Generation Tests') do
  test_category('Documentation sync') do
    test('reads shared SaneProcess docs from saneprocess_repo_root instead of cwd') do
      Dir.mktmpdir('generation-root-') do |root|
        write_fake_saneprocess_root(root)
        harness = GenerationHarness.new(root)

        Dir.mktmpdir('generation-cwd-') do |cwd|
          output = nil
          result = nil

          Dir.chdir(cwd) do
            output = capture_stdout { result = harness.send(:verify_documentation_sync) }
          end

          assert_eq(result, false)
          assert_includes(output, '✅ Documentation is in sync with tools')
        end
      end
      true
    end
  end
end)
