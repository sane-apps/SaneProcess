#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

module SelfTestEnvironment
  TEST_HOOK_SECRET = 'saneprocess-self-test-secret'

  DOC_FIXTURES = {
    'CLAUDE.md' => "# Test Project\n",
    'README.md' => "# Test Project\n",
    'DEVELOPMENT.md' => "# Test Project\n",
    'ARCHITECTURE.md' => "# Test Project\n",
    'SESSION_HANDOFF.md' => "# Test Project\n"
  }.freeze

  class << self
    def run_isolated(hook_file, internal_flag: '--self-test-internal')
      hook_path = File.expand_path(hook_file)
      Dir.mktmpdir("saneprocess-self-test-#{File.basename(hook_file, '.rb')}-") do |project_dir|
        setup_project(project_dir)
        stdout, stderr, status = Open3.capture3(
          {
            'CLAUDE_PROJECT_DIR' => project_dir,
            'HOME' => project_dir,
            'CLAUDE_HOOK_SECRET' => TEST_HOOK_SECRET,
            'SANEMASTER_PROCESS_METRICS_PATH' => File.join(project_dir, '.sanemaster', 'process_metrics.jsonl'),
            'SANE_ENV_CACHE_WRITE' => '0'
          },
          'ruby', hook_path, internal_flag,
          chdir: project_dir
        )
        $stdout.write(stdout)
        $stderr.write(stderr)
        status.exitstatus
      end
    end

    def create_project(label)
      project_dir = Dir.mktmpdir("saneprocess-#{label}-")
      setup_project(project_dir)
      project_dir
    end

    def setup_project(project_dir)
      FileUtils.mkdir_p(File.join(project_dir, '.claude', 'rules'))
      File.write(File.join(project_dir, '.saneprocess'), "{\n}\n")

      DOC_FIXTURES.each do |file, contents|
        File.write(File.join(project_dir, file), contents)
      end
    end
  end
end
