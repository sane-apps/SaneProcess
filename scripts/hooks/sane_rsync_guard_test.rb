#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'tmpdir'

require_relative 'test/test_framework'

include TestFramework

SCRIPT = File.expand_path('sane_rsync_guard.sh', __dir__)

def guard_status(*args)
  env = {
    'SANE_RSYNC_GUARD_DRY_RUN' => '1',
    'SANE_REAL_RSYNC' => '/usr/bin/true'
  }
  _stdout, stderr, status = Open3.capture3(env, SCRIPT, *args)
  [status.exitstatus, stderr]
end

exit(run_tests('Sane rsync guard') do
  test_category('SaneApps app-root flattening') do
    test('blocks multiple file sources into an app repo root') do
      Dir.mktmpdir do |dir|
        one = File.join(dir, 'CHANGELOG.md')
        two = File.join(dir, 'README.md')
        File.write(one, 'one')
        File.write(two, 'two')

        code, stderr = guard_status(
          '-av',
          one,
          two,
          'mini:/Users/stephansmac/SaneApps/apps/SaneClip'
        )

        assert_eq(code, 2)
        assert_includes(stderr, 'risky rsync into a SaneApps app repo root')
      end
      true
    end

    test('blocks multiple file sources into a tilde-based app repo root') do
      Dir.mktmpdir do |dir|
        one = File.join(dir, 'CHANGELOG.md')
        two = File.join(dir, 'README.md')
        File.write(one, 'one')
        File.write(two, 'two')

        code, stderr = guard_status(
          '-av',
          one,
          two,
          'mini:~/SaneApps/apps/SaneClip/'
        )

        assert_eq(code, 2)
        assert_includes(stderr, 'risky rsync into a SaneApps app repo root')
      end
      true
    end

    test('blocks nested file source into an app repo root') do
      Dir.mktmpdir do |dir|
        nested_dir = File.join(dir, 'docs')
        Dir.mkdir(nested_dir)
        nested = File.join(nested_dir, 'index.html')
        File.write(nested, 'index')

        code, stderr = guard_status(
          '-av',
          nested,
          'mini:/Users/stephansmac/SaneApps/apps/SaneClip'
        )

        assert_eq(code, 2)
        assert_includes(stderr, 'docs/index.html become ./index.html')
      end
      true
    end

    test('blocks nested file source into a tilde-based app repo root') do
      Dir.mktmpdir do |dir|
        nested_dir = File.join(dir, 'Tests')
        Dir.mkdir(nested_dir)
        nested = File.join(nested_dir, 'CustomerUIActions.yml')
        File.write(nested, 'actions')

        code, stderr = guard_status(
          '-av',
          nested,
          'mini:~/SaneApps/apps/SaneClip/'
        )

        assert_eq(code, 2)
        assert_includes(stderr, 'docs/index.html become ./index.html')
      end
      true
    end

    test('allows exact remote file destination') do
      Dir.mktmpdir do |dir|
        nested_dir = File.join(dir, 'docs')
        Dir.mkdir(nested_dir)
        nested = File.join(nested_dir, 'index.html')
        File.write(nested, 'index')

        code, stderr = guard_status(
          '-av',
          nested,
          'mini:/Users/stephansmac/SaneApps/apps/SaneClip/docs/index.html'
        )

        assert_eq(code, 0)
        assert_eq(stderr, '')
      end
      true
    end

    test('allows full directory sync with trailing slash') do
      Dir.mktmpdir do |dir|
        code, stderr = guard_status(
          '-av',
          "#{dir}/",
          'mini:/Users/stephansmac/SaneApps/apps/SaneClip/'
        )

        assert_eq(code, 0)
        assert_eq(stderr, '')
      end
      true
    end
  end
end)
