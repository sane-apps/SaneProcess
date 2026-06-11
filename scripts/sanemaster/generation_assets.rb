# frozen_string_literal: true

require 'shellwords'

module SaneMasterModules
  # Test asset generation using FFmpeg
  module GenerationAssets
    include Base

    def generate_test_assets
      puts '🎬 --- [ SANEMASTER TEST ASSETS ] ---'
      puts 'Generating lightweight test media...'

      assets_dir = 'Tests/Assets'
      FileUtils.mkdir_p(assets_dir)

      unless system('which ffmpeg > /dev/null 2>&1')
        puts '❌ ffmpeg not found. Install: brew install ffmpeg'
        return
      end

      generate_test_video(assets_dir)
      generate_silence_audio(assets_dir)
      generate_mov_aliases(assets_dir)
      generate_stress_clip(assets_dir)
      generate_website_demo_clip(assets_dir)
      puts "\n✅ Test assets ready."
    end

    private

    def generate_test_video(assets_dir)
      video_path = "#{assets_dir}/test_video.mp4"
      if File.exist?(video_path)
        puts '  ⚠️  test_video.mp4 already exists, skipping'
        return
      end

      print '  Generating test_video.mp4 (5s, 640x480, audio)... '
      cmd = [
        'ffmpeg',
        '-f lavfi -i testsrc=duration=5:size=640x480:rate=30',
        '-f lavfi -i sine=frequency=440:duration=5',
        '-c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p',
        '-c:a aac -shortest -y',
        Shellwords.escape(video_path),
        '2>/dev/null'
      ].join(' ')
      puts system(cmd) ? '✅' : '❌ Failed'
    end

    def generate_silence_audio(assets_dir)
      silence_path = "#{assets_dir}/test_silence.mp4"
      if File.exist?(silence_path)
        puts '  ⚠️  test_silence.mp4 already exists, skipping'
        return
      end

      print '  Generating test_silence.mp4 (5s video with silent audio)... '
      cmd = [
        'ffmpeg',
        '-f lavfi -i testsrc=duration=5:size=640x480:rate=30',
        '-f lavfi -i anullsrc=r=44100:cl=stereo',
        '-t 5',
        '-c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p',
        '-c:a aac -shortest -y',
        Shellwords.escape(silence_path),
        '2>/dev/null'
      ].join(' ')
      puts system(cmd) ? '✅' : '❌ Failed'
    end

    def generate_mov_aliases(assets_dir)
      source = "#{assets_dir}/test_video.mp4"
      %w[test.mov file.mov IMG_7668.MOV German.MOV IMG_0422.MOV IMG_6091.MOV].each do |filename|
        path = "#{assets_dir}/#{filename}"
        if File.exist?(path)
          puts "  ⚠️  #{filename} already exists, skipping"
          next
        end

        print "  Generating #{filename}... "
        cmd = "ffmpeg -i #{Shellwords.escape(source)} -c copy -y #{Shellwords.escape(path)} 2>/dev/null"
        puts system(cmd) ? '✅' : '❌ Failed'
      end
    end

    def generate_stress_clip(assets_dir)
      path = "#{assets_dir}/stress_test_clip.mp4"
      if File.exist?(path)
        puts '  ⚠️  stress_test_clip.mp4 already exists, skipping'
        return
      end

      print '  Generating stress_test_clip.mp4... '
      source = "#{assets_dir}/test_video.mp4"
      cmd = "cp #{Shellwords.escape(source)} #{Shellwords.escape(path)}"
      puts system(cmd) ? '✅' : '❌ Failed'
    end

    def generate_website_demo_clip(assets_dir)
      path = "#{assets_dir}/website-demo-video-call.mp4"
      if File.exist?(path)
        puts '  ⚠️  website-demo-video-call.mp4 already exists, skipping'
        return
      end

      print '  Generating website-demo-video-call.mp4 (6s, 1280x720, video-only)... '
      cmd = [
        'ffmpeg',
        '-f lavfi -i testsrc=duration=6:size=1280x720:rate=30',
        '-c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p',
        '-an -y',
        Shellwords.escape(path),
        '2>/dev/null'
      ].join(' ')
      puts system(cmd) ? '✅' : '❌ Failed'
    end
  end
end
