#!/usr/bin/env ruby
# frozen_string_literal: true

# instruction_lint.rb — repeatable conflict check across every SaneApps
# instruction surface. Each rule bans a pattern that a past defect proved
# dangerous or stale. A hit is a violation UNLESS the line itself carries a
# retirement/correction marker (dated notes that mention the old thing to
# kill it are the one sanctioned context).
#
# Exit 0 = clean, 1 = violations found. Run: ruby instruction_lint.rb [--json]

require 'json'

HOME = Dir.home

SURFACES = [
  "#{HOME}/AGENTS.md",
  "#{HOME}/.claude/CLAUDE.md",
  "#{HOME}/SaneApps/meta/CLAUDE.md",
  "#{HOME}/SaneApps/meta/Brand/SaneApps-Brand-Guidelines.md",
  "#{HOME}/SaneApps/meta/Brand/NORTH_STAR.md",
  "#{HOME}/SaneApps/infra/SaneProcess/AGENTS.md",
  "#{HOME}/SaneApps/infra/SaneProcess/DEVELOPMENT.md",
  "#{HOME}/SaneApps/infra/SaneProcess/DEVELOPER_SETUP.md",
  "#{HOME}/SaneApps/infra/SaneProcess/ARCHITECTURE.md",
  "#{HOME}/SaneApps/infra/SaneProcess/templates/RELEASE_SOP.md",
  "#{HOME}/SaneApps/infra/SaneUI/AGENTS.md",
  "#{HOME}/SaneApps/infra/SaneUI/CLAUDE.md",
  "#{HOME}/.claude/projects/-Users-sj-SaneApps/memory/MEMORY.md",
  *Dir.glob("#{HOME}/SaneApps/apps/*/AGENTS.md"),
  *Dir.glob("#{HOME}/SaneApps/apps/*/CLAUDE.md"),
  *%w[.codex .agents .claude].flat_map { |client| Dir.glob("#{HOME}/#{client}/skills/**/*.md") }.reject { |path| path.include?("/.system/") },
  *Dir.glob("#{HOME}/SaneApps/meta/skills/**/*.md"),
].select { |p| File.file?(p) }

# A line may mention a banned term only while retiring it. Checked against the
# hit line plus its two predecessors, because dated correction notes wrap.
ALLOW = /retired|corrected|superseded|legacy|previously listed|never|do(?:es)? not exist|don't exist|no longer|deleted|removed|frozen snapshot|drift|must not|\bnot\b|era is over/i

RULES = [
  # [name, pattern, why]
  ['missing-screen-request-api', /no direct API to request screen recording permission/i, 'CGRequestScreenCaptureAccess exists; distinguish passive check from request'],
  ['cached-permission-bypass', /UserDefaults.*bool\(forKey:\s*"screenCaptureGranted"/, 'persisted app state is not current OS authorization'],
  ['phantom-runtime-entitlement', /^\s*<key>com\.apple\.security\.hardened-runtime<\/key>/, 'enable the runtime signing capability; this entitlement does not exist'],
  ['permission-reset-recipe', /^\s*tccutil\s+reset\b/, 'routine permission skill must preserve existing grants'],
  ['global-npm-audit',    /npm audit --global|npm audit -g\b/,            'npm audit requires a project dependency tree; use the maintenance owner for installed packages'],
  ['retired-mcp-fork',    %r{~/Dev/(?:xcodebuild|apple-docs)-mcp-local},    'resolve current configured executables; retired fork paths are not required'],
  ['nv-first-directive',  /NV-FIRST/,                                    'NV cost directive retired; GPT swarms are the delegation path'],
  ['raw-resend-curl',     %r{api\.resend\.com/emails},                   'email only via check-inbox.sh gated flow'],
  ['no-homebrew-claim',   /NO Homebrew|No Homebrew mentions|NEVER create Homebrew|[Dd]elete any `?homebrew/,
                                                                          'the tap is a live release channel maintained by release.sh'],
  ['per-app-accents',     /a855f7|Video Purple|Menu Blue|Sync Green|Shield Teal|Clip Blue/i,
                                                                          'per-app accents retired 2026-07-15; SaneUI Colors.swift is the source'],
  ['old-sig-title',       /SaneCite Founder/,                             'canonical B2B title is "Founder, SaneApps / [Product]"'],
  ['old-sig-phone',       /\(727\) 758-9785|7277589785/,                  'canonical phone format is 727-758-9785'],
  ['phantom-compose-fmt', /sanecite-prospect/,                            '--format sanecite-prospect does not exist in check-inbox.sh'],
  ['old-release-recipe',  /SaneMaster\.rb release(?![_a-z])/,             'releases go through release.sh --full'],
  ['dangerous-pkill',     /pkill -f ['"]?claude/,                         'kills live Claude sessions; RAM-discipline SOP owns cleanup'],
  ['serena-memory-advice',/Serena memor(?:y|ies)(?!.*code)|read_memory/,  'Serena is code-navigation only; memories live in agentmemory + file memory'],
  ['phantom-skill',       /docs-audit(?!s)/,                              'no such skill; use /audit'],
  ['phantom-script',      /clean_system|morning_report|nv-audit\.sh|nv-relnotes\.sh|nv-tests\.sh|nv-buildlog\.sh/,
                                                                          'these commands/scripts do not exist'],
  ['dead-pointer',        %r{SaneProcess/CLAUDE\.md},                     'file does not exist'],
  ['safari-asc-lane',     /mini-safari/,                                  'ASC Safari exception retired 2026-07-15; Brave-CDP is the lane'],
  ['hardcoded-price',     /\$5\b(?!.*(?:loaded|budget|credits))/,         'never hardcode public prices; live source = Lemon Squeezy'],
  ['sub-13px-text',       /\b1[0-2]px\b(?!.*(?:spacing|padding|margin|gap|between))/,
                                                                          '13px text floor on all customer surfaces'],
  ['context7-off-claim',  /context7.*toggled off|context7@claude-plugins-official: false/,
                                                                          'context7 is available (plugin:context7:context7)'],
]

# An installed repo disproves a blanket nonexistence claim. Do not keep a
# second hardcoded product roster in the lint.
def instruction_violations(path, source, repo_names:)
  violations = []
  lines = source.lines
  lines.each_with_index do |line, i|
    if line.match?(/\b(?:do|does) not exist\b/i) &&
       repo_names.any? { |name| line.match?(/\b#{Regexp.escape(name)}\b/) } &&
       !line.match?(/false|incorrect|do not (?:claim|declare)|example|quote/i)
      violations << { rule: 'existing-product-denied', file: path, line: i + 1,
                      text: line.strip[0, 160], why: 'a current repository exists; distinguish product, runtime and distribution evidence' }
    end
    RULES.each do |name, pattern, why|
      next unless line.match?(pattern)
      next if name == 'permission-reset-recipe' && !path.end_with?('macos-permissions/SKILL.md')
      next if name == 'sub-13px-text' && !line.match?(/font|text|typograph|caption|label/i)
      window = lines[[i - 3, 0].max..i].join.gsub(/\n>?\s*/, ' ')
      next if window.match?(ALLOW)
      violations << { rule: name, file: path, line: i + 1,
                      text: line.strip[0, 160], why: why }
    end
  end
  violations
end

if ARGV.include?('--self-test')
  checks = {
    'screen request API exists' => ["There's no direct API to request screen recording permission.", ['missing-screen-request-api']],
    'screen API correction is allowed' => ['Do not claim there is no direct API to request screen recording permission.', []],
    'persisted grant cannot bypass OS check' => ['if UserDefaults.standard.bool(forKey: "screenCaptureGranted") { return true }', ['cached-permission-bypass']],
    'real preflight is allowed' => ['return CGPreflightScreenCaptureAccess()', []],
    'invented runtime entitlement is rejected' => ['<key>com.apple.security.hardened-runtime</key>', ['phantom-runtime-entitlement']],
    'actual runtime build setting is allowed' => ['ENABLE_HARDENED_RUNTIME = YES', []],
    'routine skill reset is rejected' => ['tccutil reset Camera com.example.app', ['permission-reset-recipe']],
    'reset prohibition is allowed' => ['Do not run tccutil reset for routine verification.', []],
    'layout height is not text size' => ['frame.resize(300, 10) // Height stays at 10px.', []],
    'small text remains prohibited' => ['Use 10px font for helper text.', ['sub-13px-text']],
    'real product reference' => ['SaneSync has a supported archive.', []],
    'false product denial' => ['SaneSync, SaneAI and SaneScript do not exist.', ['existing-product-denied']],
    'runtime retirement is distinct' => ['SaneSync training runtime is retired.', []],
    'unknown product is not invented' => ['UnlistedApp does not exist.', []],
    'invalid global audit' => ['npm audit --global', ['global-npm-audit']],
    'retired advice can be discussed' => ['Do not use npm audit --global; audit the project lockfile.', []],
    'stale configured path' => ['apple-docs -> ~/Dev/apple-docs-mcp-local', ['retired-mcp-fork']],
    'retired path correction' => ['The ~/Dev/apple-docs-mcp-local path is retired.', []]
  }
  checks.each do |label, (source, expected)|
    actual = instruction_violations('fixture/macos-permissions/SKILL.md', source, repo_names: ['SaneSync']).map { |v| v[:rule] }
    abort "FAIL: #{label}: #{actual.inspect}" unless actual == expected
  end
  abort 'FAIL: installed mirror surface missing' if Dir.exist?("#{HOME}/.agents/skills") && !SURFACES.any? { |path| path.start_with?("#{HOME}/.agents/skills/") }
  puts "instruction_lint self-test: #{checks.length + 1} checks passed"
  exit 0
end

repo_names = Dir.glob("#{HOME}/SaneApps/apps/*").select { |path| File.exist?(File.join(path, '.git')) }.map { |path| File.basename(path) }
violations = SURFACES.flat_map do |path|
  instruction_violations(path.sub(HOME, '~'), File.read(path), repo_names: repo_names)
end

# Conflict artifacts in the memory dir are themselves violations.
Dir.glob("#{HOME}/.claude/projects/-Users-sj-SaneApps/memory/*{.sane-conflict-*,.tmp}").each do |f|
  violations << { rule: 'memory-conflict-artifact', file: f.sub(HOME, '~'), line: 0,
                  text: File.basename(f), why: 'stale sync artifact shadows a corrected canonical file' }
end

if ARGV.include?('--json')
  puts JSON.pretty_generate({ surfaces: SURFACES.length, violations: violations })
else
  puts "instruction_lint: #{SURFACES.length} surfaces scanned"
  if violations.empty?
    puts 'CLEAN: no conflicting instructions found'
  else
    violations.group_by { |v| v[:rule] }.each do |rule, vs|
      puts "\n[#{rule}] #{vs.first[:why]}"
      vs.each { |v| puts "  #{v[:file]}:#{v[:line]}  #{v[:text]}" }
    end
    puts "\n#{violations.length} violation(s)"
  end
end
exit(violations.empty? ? 0 : 1)
