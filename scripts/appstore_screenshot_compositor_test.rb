#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'yaml'

Dir.mktmpdir('appstore-compositor-test') do |tmpdir|
  docs = File.join(tmpdir, 'docs')
  FileUtils.mkdir_p(docs)
  source = File.join(docs, 'source.png')
  File.binwrite(source, Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='))
  storyboard = {
    'brand' => 'SaneTest',
    'canvas' => {
      'width' => 600,
      'height' => 1300,
      'background_start' => '#08111F',
      'background_end' => '#12314A',
      'accent' => '#35D0BA'
    },
    'platforms' => {
      'ios' => [{
        'file' => 'docs/output.png',
        'source' => 'docs/source.png',
        'title' => 'Outcome first.',
        'subtitle' => 'Truthful product proof.',
        'purpose' => 'Exercise deterministic rendering',
        'must_show' => ['source screenshot']
      }]
    }
  }
  File.write(File.join(docs, 'appstore_screenshot_storyboard.yml'), storyboard.to_yaml)
  script = File.expand_path('appstore_screenshot_compositor.rb', __dir__)
  stdout, stderr, status = Open3.capture3('ruby', script, '--project', tmpdir)
  abort "Compositor failed:\n#{stdout}\n#{stderr}" unless status.success?
  output = File.join(docs, 'output.png')
  abort 'Compositor did not create its declared output' unless File.file?(output)
  dimensions = `sips -g pixelWidth -g pixelHeight #{output.shellescape} 2>/dev/null`
  abort "Wrong output width:\n#{dimensions}" unless dimensions.include?('pixelWidth: 600')
  abort "Wrong output height:\n#{dimensions}" unless dimensions.include?('pixelHeight: 1300')
end

puts 'App Store Screenshot Compositor Tests: PASS'
