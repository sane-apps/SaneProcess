#!/bin/bash
# session-guardian.sh — periodic orphan reaper plus sustained unexpected-CPU watch.
#
# WHY: macOS jetsam OOM-kills a Claude session on a transient RAM spike. The dead
# session's disposable children (node/uvx/python MCP servers, crashpad handlers,
# claude-code helpers) get reparented to launchd (ppid==1) and linger, eating RAM
# so the NEXT session starts closer to the OOM ceiling -> death spiral. The
# mcp-watchdog only reaps the MCP subset; this guardian reaps the rest.
#
# CPU: AgentMemory watch does not catch a hot box. This job samples 5-minute load
# against core count, names unexpected offenders, and pages the Air after two
# consecutive 10-minute hits. Expected work (builds, signed SaneApps, coding
# apps, Mini Brave, work-session caffeinate) is logged, never an alarm. Mini
# never pops a local banner; Air pages Mini heat from Mini's last sample.
#
# SAFETY MODEL (intentionally conservative — never kill live work):
#   A process is reaped ONLY if ALL hold:
#     1. ppid == 1            (its real parent is DEAD; a live session has ppid != 1)
#     2. command matches the disposable family regex below
#     3. its pid is NOT a launchd-managed job (excludes the mcp-singleton bridges)
#   Live Claude sessions, Claude.app, the MCP singleton bridge, and the user's
#   own apps are therefore never touched.
#
# Memory hogs and unexpected CPU that are NOT orphans are LOGGED / notified,
# never auto-killed (could be the user's active session).
#
# Usage:
#   session-guardian.sh              # reap + memory forensics + CPU watch
#   session-guardian.sh --cpu-only   # sample CPU, no reap, no Mini SSH
#   session-guardian.sh --cpu-only --json
#   session-guardian.sh --install    # LaunchAgent on this host (Air and Mini)

set -u

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
LOG="${SANE_GUARDIAN_LOG:-$HOME/Library/Logs/SaneApps/session-guardian.log}"
STATE_DIR="${SANE_GUARDIAN_STATE_DIR:-$HOME/Library/Logs/SaneApps}"
CPU_JSON="${SANE_GUARDIAN_CPU_JSON:-$STATE_DIR/session-guardian-cpu.json}"
mkdir -p "$(dirname "$LOG")" "$STATE_DIR"

CPU_ONLY=0
PRINT_JSON=0
DO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --cpu-only) CPU_ONLY=1 ;;
    --json) PRINT_JSON=1 ;;
    --install) DO_INSTALL=1 ;;
    --help|-h)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

host_s="$(hostname -s 2>/dev/null || hostname)"
if [[ -n "${SANE_GUARDIAN_ROLE:-}" ]]; then
  ROLE="$SANE_GUARDIAN_ROLE"
elif [[ "$host_s" == *[Mm]ini* ]]; then
  ROLE="mini"
else
  ROLE="air"
fi

install_agent() {
  local label="com.saneapps.session-guardian"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  local out_log="${SANE_GUARDIAN_OUT_LOG:-$HOME/Library/Logs/SaneApps/session-guardian.out.log}"
  local err_log="${SANE_GUARDIAN_ERR_LOG:-$HOME/Library/Logs/SaneApps/session-guardian.err.log}"
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$out_log")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>Nice</key>
  <integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${out_log}</string>
  <key>StandardErrorPath</key>
  <string>${err_log}</string>
</dict>
</plist>
EOF
  if [[ "${SANE_GUARDIAN_SKIP_LAUNCHCTL:-}" == "1" ]]; then
    echo "Wrote $plist (launchctl skipped)"
    return 0
  fi
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/${label}" 2>/dev/null || true
  echo "Installed ${label} on ${host_s}"
}

if [[ "$DO_INSTALL" -eq 1 ]]; then
  install_agent
  exit 0
fi

# Disposable family: orphaned MCP servers + claude-code leftovers safe to reap when
# parentless. Deliberately specific — generic node/python match ONLY via MCP/uv paths.
# NOTE: chrome_crashpad_handler and "Claude Helper" are EXCLUDED on purpose: crashpad
# handlers detach to ppid==1 by design (so they outlive the app to record its crash),
# so a ppid==1 crashpad belongs to a LIVE app, not a dead session.
FAMILY='server-memory|mcp-memory-enhanced|mcp-central-memory|@modelcontextprotocol|/serena|start-mcp-server|\.cache/uv/|claude-code/[0-9].*/claude\.app'

reap_orphans() {
  local managed_pids reaped pid ppid rss command mb
  managed_pids=" $(launchctl list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ') "
  reaped=0
  while read -r pid ppid rss command; do
    [ "$ppid" = "1" ] || continue
    case "$command" in *Claude.app/Contents/MacOS/Claude*) continue;; esac
    echo "$command" | grep -Eq "$FAMILY" || continue
    case "$managed_pids" in *" $pid "*) continue;; esac
    mb=$((rss/1024))
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    log "REAPED orphan pid=$pid rss=${mb}MB cmd=$(echo "$command" | cut -c1-90)"
    reaped=$((reaped+1))
  done < <(ps -A -o pid=,ppid=,rss=,command=)
  echo "$reaped"
}

memory_forensics() {
  local reaped="$1"
  local free_pct
  free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2}')
  free_pct=${free_pct:-unknown}
  if [ "$reaped" -gt 0 ]; then
    log "run complete: reaped=$reaped free=${free_pct}%"
  fi
  if [ "$free_pct" != "unknown" ] && [ "$free_pct" -lt 15 ] 2>/dev/null; then
    log "LOW MEMORY: free=${free_pct}% — top RSS:"
    ps -A -o rss=,pid=,comm= -m | head -6 | while read -r r p c; do
      log "   $((r/1024))MB pid=$p $c"
    done
  fi
}

notify_cpu() {
  local title="$1"
  local body="$2"
  if [[ -n "${SANE_GUARDIAN_NOTIFY_SINK:-}" ]]; then
    printf '%s\t%s\n' "$title" "$body" >> "$SANE_GUARDIAN_NOTIFY_SINK"
    return 0
  fi
  [[ "${SANE_GUARDIAN_NOTIFY:-1}" == "1" ]] || return 0
  /usr/bin/osascript -e "display notification $(printf '%s' "$body" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') with title $(printf '%s' "$title" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') sound name \"Basso\"" 2>/dev/null || true
}

fetch_mini_cpu_json() {
  local ssh_bin remote_out
  ssh_bin="${SANE_GUARDIAN_SSH:-ssh}"
  remote_out="$STATE_DIR/session-guardian-mini.json"
  if "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 mini "cat ~/Library/Logs/SaneApps/session-guardian-cpu.json" >"$remote_out" 2>/dev/null; then
    if [[ -s "$remote_out" ]]; then
      printf '%s\n' "$remote_out"
      return 0
    fi
  fi
  if "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=8 mini "SANE_GUARDIAN_CPU_ONLY=1 /bin/bash ~/SaneApps/infra/SaneProcess/scripts/hooks/session-guardian.sh --cpu-only --json" >"$remote_out" 2>/dev/null; then
    if [[ -s "$remote_out" ]]; then
      printf '%s\n' "$remote_out"
      return 0
    fi
  fi
  return 1
}

cpu_watch() {
  local mini_json report
  mini_json="${SANE_GUARDIAN_MINI_JSON:-}"
  if [[ "$ROLE" == "air" && "$CPU_ONLY" -eq 0 && "${SANE_GUARDIAN_SKIP_REMOTE:-}" != "1" && -z "$mini_json" ]]; then
    mini_json="$(fetch_mini_cpu_json || true)"
  fi

  report="$(
    SANE_GUARDIAN_ROLE="$ROLE" \
    SANE_GUARDIAN_CPU_JSON="$CPU_JSON" \
    SANE_GUARDIAN_MINI_JSON="${mini_json:-}" \
    /usr/bin/python3 - "$CPU_JSON" <<'PY'
import json, os, re, time, subprocess, sys

EXPECTED = [
    r'caffeinate',
    r'xcodebuild',
    r'\bxcbuild\b',
    r'swift-frontend',
    r'swift-plugin-server',
    r'sourcekit-lsp',
    r'com\.apple\.dt',
    r'CoreSimulator',
    r'Simulator\.app',
    r'\bsimctl\b',
    r'\bcodesign\b',
    r'ANECompilerService',
    r'MTLCompilerService',
    r'\bWindowServer\b',
    r'\bkernel_task\b',
    r'/usr/libexec/',
    r'/System/Library/',
    r'Sane(Clip|Click|Hosts|Video|Sales|Scan|Lot|UI|Sync|Cite|Bar)(?:\.app|/)',
    r'/Applications/Sane',
    r'DerivedData/.*/Sane',
    r'Cursor\.app',
    r'Cursor Helper',
    r'Grok\.app',
    r'ChatGPT\.app',
    r'Codex(?: Computer Use)?\.app',
    r'Brave Browser',
    r'SaneMaster',
    r'session-guardian',
    r'agentmemory',
    r'mcp-watchdog',
    r'mini-gui-run',
]


def env(name, default=''):
    return os.environ.get(name, default)


def env_float(name, default):
    raw = env(name, '')
    return default if raw == '' else float(raw)


def env_int(name, default):
    raw = env(name, '')
    return default if raw == '' else int(float(raw))


def run_cmd(args):
    try:
        return subprocess.check_output(args, stderr=subprocess.DEVNULL, text=True, timeout=5).strip()
    except Exception:
        return ''


def expected_command(command):
    return any(re.search(pat, command, re.I) for pat in EXPECTED)


def offender_lines(items):
    lines = []
    for row in (items or [])[:4]:
        cmd = re.sub(r'\s+', ' ', str(row.get('command', '')))[:90]
        lines.append(f"{float(row.get('cpu') or 0):.0f}% pid={row.get('pid')} {cmd}")
    return lines


role = env('SANE_GUARDIAN_ROLE', 'air')
now = env_int('SANE_GUARDIAN_NOW', int(time.time()))
ncpu = env_int('SANE_GUARDIAN_NCPU', 0)
if ncpu <= 0:
    raw = run_cmd(['/usr/sbin/sysctl', '-n', 'hw.logicalcpu']) or run_cmd(['sysctl', '-n', 'hw.logicalcpu'])
    try:
        ncpu = int(raw)
    except Exception:
        ncpu = 1

load5 = env('SANE_GUARDIAN_LOAD5', '')
if load5 == '':
    raw = run_cmd(['/usr/sbin/sysctl', '-n', 'vm.loadavg']) or run_cmd(['sysctl', '-n', 'vm.loadavg'])
    parts = re.findall(r'[0-9]+\.[0-9]+', raw)
    load5 = parts[1] if len(parts) >= 2 else (parts[0] if parts else '0')
load5 = float(load5)

ratio = env_float('SANE_GUARDIAN_LOAD_RATIO', 0.85)
threshold = ncpu * ratio
min_cpu = env_float('SANE_GUARDIAN_MIN_OFFENDER_CPU', 20.0)
needed = env_int('SANE_GUARDIAN_CONSECUTIVE', 2)
silence = env_int('SANE_GUARDIAN_SILENCE_SECONDS', 1800)
stale_after = env_int('SANE_GUARDIAN_STALE_SECONDS', 1200)
state_path = env('SANE_GUARDIAN_CPU_JSON', '') or (sys.argv[1] if len(sys.argv) > 1 else '')

ps_file = env('SANE_GUARDIAN_PS_FILE', '')
if ps_file:
    try:
        ps_text = open(ps_file, encoding='utf-8').read()
    except OSError:
        ps_text = ''
else:
    ps_text = run_cmd(['ps', '-A', '-o', '%cpu=,pid=,command='])

rows = []
for line in ps_text.splitlines():
    line = line.strip()
    if not line:
        continue
    match = re.match(r'^\s*([0-9]+(?:\.[0-9]+)?)\s+(\d+)\s+(.*)$', line)
    if not match:
        continue
    rows.append({'cpu': float(match.group(1)), 'pid': int(match.group(2)), 'command': match.group(3)})
rows.sort(key=lambda row: row['cpu'], reverse=True)
top = rows[:8]
offenders = [row for row in top if row['cpu'] >= min_cpu and not expected_command(row['command'])]
expected_top = [row for row in top if row['cpu'] >= min_cpu and expected_command(row['command'])]

if load5 < threshold:
    status = 'ok'
elif offenders:
    status = 'unexpected'
else:
    status = 'expected_busy'

signature = '|'.join(re.sub(r'\s+', ' ', row['command'])[:80] for row in offenders[:3]) if offenders else ''

prev = {}
if state_path:
    try:
        prev = json.load(open(state_path, encoding='utf-8'))
    except Exception:
        prev = {}

if status == 'unexpected':
    consecutive = int(prev.get('consecutive_unexpected') or 0) + 1 if signature and signature == prev.get('signature') else 1
else:
    consecutive = 0

last_notify_at = int(prev.get('last_notify_at') or 0)
last_notify_signature = prev.get('last_notify_signature') or ''
mini_last_notify_at = int(prev.get('mini_last_notify_at') or 0)
mini_last_notify_signature = prev.get('mini_last_notify_signature') or ''
should_alert = status == 'unexpected' and consecutive >= needed
notify = False
notify_title = ''
notify_body = ''

if should_alert and role == 'air':
    silent = signature == last_notify_signature and last_notify_at and (now - last_notify_at) < silence
    if not silent:
        notify = True
        notify_title = 'Air CPU watch'
        notify_body = f"load5 {load5:.2f} on {ncpu} cores for {consecutive} samples. " + '; '.join(offender_lines(offenders))
        last_notify_at = now
        last_notify_signature = signature

mini = None
mini_path = env('SANE_GUARDIAN_MINI_JSON', '')
if role == 'air' and mini_path:
    try:
        mini = json.load(open(mini_path, encoding='utf-8'))
    except Exception:
        mini = None
    if mini and mini.get('status') == 'unexpected' and int(mini.get('consecutive_unexpected') or 0) >= needed:
        mini_sig = mini.get('signature') or ''
        sampled_at = int(mini.get('sampled_at') or 0)
        stale = sampled_at and (now - sampled_at) > stale_after
        if mini_sig and not stale:
            silent = mini_sig == mini_last_notify_signature and mini_last_notify_at and (now - mini_last_notify_at) < silence
            if not silent:
                extra_title = 'Mini CPU watch'
                extra_body = (
                    f"load5 {float(mini.get('load5') or 0):.2f} on {mini.get('ncpu')} cores "
                    f"for {mini.get('consecutive_unexpected')} samples. "
                    + '; '.join(offender_lines(mini.get('offenders')))
                )
                if notify:
                    notify_title = 'Air/Mini CPU watch'
                    notify_body = notify_body + ' | ' + extra_body
                else:
                    notify = True
                    notify_title = extra_title
                    notify_body = extra_body
                mini_last_notify_at = now
                mini_last_notify_signature = mini_sig

report = {
    'schema': 1,
    'host_role': role,
    'sampled_at': now,
    'load5': load5,
    'ncpu': ncpu,
    'threshold': round(threshold, 3),
    'status': status,
    'consecutive_unexpected': consecutive,
    'signature': signature,
    'offenders': offenders,
    'expected_top': expected_top,
    'last_notify_at': last_notify_at,
    'last_notify_signature': last_notify_signature,
    'mini_last_notify_at': mini_last_notify_at,
    'mini_last_notify_signature': mini_last_notify_signature,
    'should_alert': should_alert,
    'notify': notify,
    'notify_title': notify_title,
    'notify_body': notify_body,
}
if mini is not None:
    report['mini_status'] = mini.get('status')
    report['mini_signature'] = mini.get('signature')

if state_path:
    tmp = state_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    os.replace(tmp, state_path)

print(json.dumps(report))
PY
  )"

  if [[ -z "${report}" ]]; then
    log "CPU ${ROLE}: classifier produced no report"
    return 0
  fi
  printf '%s\n' "$report" > "$CPU_JSON"
  eval "$(/usr/bin/python3 -c 'import json,sys,shlex
d=json.load(sys.stdin)
keys=("status","consecutive_unexpected","load5","ncpu","notify","notify_title","notify_body","signature")
print("status=%s" % shlex.quote(str(d.get("status",""))))
print("consecutive=%s" % shlex.quote(str(d.get("consecutive_unexpected",0))))
print("load5=%s" % shlex.quote(str(d.get("load5",0))))
print("ncpu=%s" % shlex.quote(str(d.get("ncpu",0))))
print("do_notify=%s" % shlex.quote("yes" if d.get("notify") else "no"))
print("title=%s" % shlex.quote(str(d.get("notify_title",""))))
print("body=%s" % shlex.quote(str(d.get("notify_body",""))))
print("signature=%s" % shlex.quote(str(d.get("signature",""))))
' <<<"$report")"
  log "CPU ${ROLE}: status=$status load5=$load5 ncpu=$ncpu consecutive=$consecutive"
  if [[ "$status" == "unexpected" ]]; then
    log "CPU unexpected: $signature"
  fi
  if [[ "$do_notify" == "yes" && "$ROLE" == "air" ]]; then
    notify_cpu "$title" "$body"
    log "CPU notify: $title $body"
  fi
  if [[ "$PRINT_JSON" -eq 1 ]]; then
    printf '%s\n' "$report"
  fi
}

if [[ "$CPU_ONLY" -eq 0 && "${SANE_GUARDIAN_SKIP_REAP:-}" != "1" ]]; then
  reaped="$(reap_orphans)"
else
  reaped=0
fi

if [[ "$CPU_ONLY" -eq 0 && "${SANE_GUARDIAN_SKIP_MEMORY:-}" != "1" ]]; then
  memory_forensics "$reaped"
fi

if [[ "${SANE_GUARDIAN_SKIP_CPU:-}" != "1" ]]; then
  cpu_watch
fi

exit 0
