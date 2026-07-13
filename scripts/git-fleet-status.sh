#!/usr/bin/env bash
# READ-ONLY cross-machine git fleet status. For every repo under ~/SaneApps on THIS machine AND the Mini,
# reports branch, dirty count, ahead/behind upstream, and DANGER flags so cross-machine drift is visible at a
# glance BEFORE it piles up. Never modifies anything (no add/commit/checkout/push/pull).
#   Usage: git-fleet-status.sh [mini-host]     (default host: mini; run before any reconcile)
set -uo pipefail

# Absolute path to THIS script, resolved before any `cd` (survey() changes cwd), so the ssh stdin redirect works.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

survey() {
  local label="$1" clean=0 attention=0
  printf '════════ %s ════════\n' "$label"
  printf '%-40s %-26s %5s %9s  %s\n' 'REPO' 'BRANCH' 'DIRTY' 'BHD/AHD' 'FLAGS'
  local g
  for g in $(find "$HOME/SaneApps" -maxdepth 3 -name .git -type d 2>/dev/null | sed 's#/.git##' | sort); do
    cd "$g" 2>/dev/null || continue
    local br dirty dels ab behind ahead flags
    br="$(git branch --show-current 2>/dev/null)"; br="${br:-DETACHED}"
    dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    dels="$(git status --porcelain 2>/dev/null | grep -cE '^( D|D )' || true)"
    if ab="$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"; then
      behind="$(printf '%s' "$ab" | awk '{print $1}')"; ahead="$(printf '%s' "$ab" | awk '{print $2}')"
    else behind='-'; ahead='-'; fi
    flags=''
    [ "$dirty" != 0 ] && [ "$dels" -gt "$(( dirty / 2 ))" ] && [ "$dels" -gt 5 ] && flags+=" ⚠DELETIONS($dels)"
    [ "$br" != main ] && [ "$br" != master ] && flags+=" ⚠off-main"
    [ "$behind" != '-' ] && [ "$behind" -gt 10 ] && flags+=" ⚠behind$behind"
    [ "$ahead" != '-' ] && [ "$ahead" != 0 ] && flags+=" ↑${ahead}unpushed"
    [ "$ahead" = '-' ] && flags+=' no-upstream'
    if [ "$dirty" = 0 ] && [ -z "$flags" ]; then clean=$((clean+1)); continue; fi
    attention=$((attention+1))
    printf '%-40s %-26s %5s %9s  %s\n' "${g/#$HOME/\~}" "$br" "$dirty" "${behind}/${ahead}" "$flags"
  done
  printf '  — %s clean+synced, %s need attention —\n\n' "$clean" "$attention"
}

if [ "${1:-}" = '--survey' ]; then survey "$(hostname -s)"; exit 0; fi

MINI="${1:-mini}"
survey "$(hostname -s) — LOCAL"
if ssh -o ConnectTimeout=8 "$MINI" true 2>/dev/null; then
  ssh "$MINI" 'bash -s -- --survey' < "$SELF" 2>/dev/null || echo "(survey on $MINI failed)"
else
  echo "(could not reach $MINI over ssh)"
fi
echo 'Flags: ⚠DELETIONS = working tree is mostly deletions (verify intent before committing); ⚠off-main;'
echo '       ⚠behindN = N commits behind upstream; ↑Nunpushed = N local commits not pushed. READ-ONLY report.'
