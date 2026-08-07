#!/usr/bin/env bash
# Reap idle agent resources on this host (sensible, not aggressive).
# Default = dry-run. Pass --apply to act.
# Does NOT kill: Cursor, ChatGPT/Codex, user Brave sessions, active xcodebuild.
set -euo pipefail

APPLY=0
HOST_LABEL="$(hostname -s 2>/dev/null || hostname)"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--apply]"
      echo "Dry-run by default. Reaps: booted simulators (when no xcodebuild), /tmp brave-* automation profiles, orphaned esbuild for SaneApps, Playwright Chromium leftovers."
      exit 0
      ;;
  esac
done

act() {
  if [[ "$APPLY" -eq 1 ]]; then
    eval "$1"
  else
    echo "DRY: $1"
  fi
}

echo "host=$HOST_LABEL apply=$APPLY"

# 1) Simulators — only if no active xcodebuild
if pgrep -x xcodebuild >/dev/null 2>&1; then
  echo "keep_sims: xcodebuild running"
else
  BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted || true)
  echo "booted_sims=$BOOTED"
  if [[ "${BOOTED:-0}" -gt 0 ]]; then
    act "xcrun simctl shutdown all"
    act "osascript -e 'tell application \"Simulator\" to quit' 2>/dev/null || killall Simulator 2>/dev/null || true"
  fi
fi

# 2) Temp Brave/Playwright automation profiles (never the real Brave profile)
for d in /tmp/brave-access-* /tmp/brave-gmail-* /tmp/brave-pl-* /tmp/brave-slap-* /tmp/playwright* ; do
  [[ -e "$d" ]] || continue
  echo "tmp_profile=$d"
  act "rm -rf \"$d\""
done

# 3) Orphaned esbuild tied to SaneApps websites (not general node)
if pgrep -f "SaneApps/.*/node_modules/@esbuild" >/dev/null 2>&1; then
  echo "orphaned_esbuild=yes"
  act "pkill -f 'SaneApps/.*/node_modules/@esbuild' || true"
else
  echo "orphaned_esbuild=no"
fi

# 4) memory snapshot
if command -v memory_pressure >/dev/null 2>&1; then
  memory_pressure 2>/dev/null | head -5 || true
fi

echo "done. Use --apply to execute. Prefer: ruby scripts/SaneMaster.rb machine_cleanup --host mini|--local --apply --preserve-apps ..."
