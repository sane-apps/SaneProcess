# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'

# Post-release Stop-hook step: keep the Mini's ~/Desktop/LemonSqueezy-Uploads
# folder staged to ONLY the latest release ZIP per app.
#
# Lemon Squeezy's hosted file is the one release channel release.sh cannot
# auto-deploy — the owner replaces it by hand in the LS dashboard, and that
# folder is the staging area. Codex can drive the browser upload; Claude cannot,
# so after a release Claude's post-flight runs this so the owner always finds
# exactly the right file with no stale versions beside it.
#
# Non-blocking: auto-stages on success (once per session), warns on failure with
# the manual command. The heavy lifting lives in stage_lemonsqueezy_uploads.rb.
module LemonSqueezyUploads
  STAGE_SCRIPT = File.expand_path('../stage_lemonsqueezy_uploads.rb', __dir__)
  REMOTE_STAGE_SCRIPT = '~/SaneApps/infra/SaneProcess/scripts/stage_lemonsqueezy_uploads.rb'
  UPLOADS_FOLDER = File.expand_path('~/Desktop/LemonSqueezy-Uploads')

  module_function

  # Entry point called from process_stop. Never raises, never blocks.
  def stage_after_release(transcript_path)
    state = StateManager.get(:lemonsqueezy_uploads) || {}
    return if state[:done] || state['done']

    project = detect_release_deploy_project(transcript_path)
    return unless project

    res = run_staging(project)
    app = File.basename(project.to_s)
    if res[:ok]
      StateManager.update(:lemonsqueezy_uploads) { |v| (v || {}).merge('done' => true) }
      if res[:status] == 'staged'
        warn '---'
        warn "📦 LemonSqueezy-Uploads auto-staged for #{app} (post-release): #{res[:message]}"
        warn '---'
      end
    else
      warn '---'
      warn "📦 LemonSqueezy-Uploads NOT staged for #{app} after release: #{res[:message]}"
      warn '   The owner uploads the LS hosted file from ~/Desktop/LemonSqueezy-Uploads on the mini.'
      warn "   Stage it: ruby #{REMOTE_STAGE_SCRIPT} --project #{project}"
      warn '---'
    end
    nil
  rescue StandardError
    nil
  end

  # Most recent `release.sh ... --deploy/--full` command's --project, or nil.
  # Extracts each Bash command string from the transcript JSON (escape-aware) so
  # a quoted --notes value cannot truncate the match.
  def detect_release_deploy_project(transcript_path)
    return nil unless transcript_path && File.exist?(transcript_path)

    content = File.read(transcript_path, encoding: Encoding::UTF_8)
    project = nil
    content.scan(/"command"\s*:\s*"((?:[^"\\]|\\.)*)"/).each do |match|
      cmd = match[0].gsub('\\n', "\n").gsub('\\t', "\t").gsub('\\/', '/').gsub('\\"', '"').gsub('\\\\', '\\')
      next unless cmd.include?('release.sh')
      next unless cmd.include?('--deploy') || cmd.include?('--full')

      pm = cmd.match(/--project\s+(\S+)/)
      project = pm[1].gsub(/["']/, '') if pm # last release this session wins (strip stray quotes)
    end
    project
  rescue StandardError
    nil
  end

  # Run the staging script where the folder lives (locally on the mini, else via
  # ssh mini). Returns { ok:, status:, message: }; never raises.
  def run_staging(project)
    out =
      if File.directory?(UPLOADS_FOLDER)
        capture(['ruby', STAGE_SCRIPT, '--project', File.expand_path(project), '--json'])
      else
        escaped = "'#{project.to_s.gsub("'", "'\\''")}'"
        capture(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
                 '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', 'mini',
                 "ruby #{REMOTE_STAGE_SCRIPT} --project #{escaped} --json"])
      end
    json_line = out.to_s.lines.map(&:strip).reverse.find { |l| l.start_with?('{') }
    res = json_line ? (JSON.parse(json_line) rescue {}) : {}
    status = res['status']
    { ok: %w[staged current noop].include?(status), status: status, message: res['message'] || out.to_s.strip[0, 200] }
  rescue StandardError => e
    { ok: false, status: 'unreachable', message: "could not run staging: #{e.message}" }
  end

  def capture(cmd)
    # Hard ceiling so a stalled remote process can never hang session teardown;
    # Timeout::Error is a StandardError, caught by run_staging -> 'unreachable'.
    out = Timeout.timeout(30) { Open3.capture2e(*cmd).first }
    # Force UTF-8 + scrub: capture output is ASCII-8BIT and a non-UTF-8 locale
    # would otherwise raise Encoding::CompatibilityError on .lines/.start_with?
    # (see memory saneprocess-state-encoding-wipe).
    out = out.to_s.dup.force_encoding('UTF-8')
    out.valid_encoding? ? out : out.scrub('?')
  end
end
