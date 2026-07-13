#!/bin/bash
# mini-daytime-cleanup.sh - Remove GUI startup items and disable low-value resident agents.
# Usage:
#   mini-daytime-cleanup.sh
#   mini-daytime-cleanup.sh --dry-run

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

LOW_VALUE_AGENT_LIST="${LOW_VALUE_AGENT_LIST:-com.saneapps.codex-keepalive}"
PURGE_ALL_LOGIN_ITEMS="${PURGE_ALL_LOGIN_ITEMS:-true}"

run_cmd() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  "$@"
}

cleanup_login_items() {
  local duplicates_csv all_items_csv

  duplicates_csv=$(osascript <<'APPLESCRIPT'
tell application "System Events"
  set seenNames to {}
  set duplicateNames to {}
  repeat with li in login items
    set itemName to (name of li as text)
    if seenNames contains itemName then
      if duplicateNames does not contain itemName then set end of duplicateNames to itemName
    else
      set end of seenNames to itemName
    end if
  end repeat
  duplicateNames as text
end tell
APPLESCRIPT
)

  if [ "$PURGE_ALL_LOGIN_ITEMS" = "true" ]; then
    all_items_csv=$(osascript <<'APPLESCRIPT'
tell application "System Events"
  set outText to ""
  repeat with li in login items
    set outText to outText & (name of li as text) & linefeed
  end repeat
  return outText
end tell
APPLESCRIPT
)

    if [ -z "$all_items_csv" ]; then
      echo "No login items found."
      return 0
    fi

    printf '%s\n' "$all_items_csv" | while IFS= read -r item_name; do
      item_name=$(printf '%s' "$item_name" | sed 's/^ *//; s/ *$//')
      [ -n "$item_name" ] || continue
      echo "Removing login item: $item_name"
      if [ "$DRY_RUN" = "true" ]; then
        printf '[dry-run] delete login item named %s\n' "$item_name"
        continue
      fi
      ITEM_NAME="$item_name" osascript <<'APPLESCRIPT'
set targetName to system attribute "ITEM_NAME"
tell application "System Events"
  set matchingItems to every login item whose name is targetName
  repeat with li in matchingItems
    delete li
  end repeat
end tell
APPLESCRIPT
    done
    return 0
  fi

  if [ -z "$duplicates_csv" ]; then
    echo "No duplicate login items found."
    return 0
  fi

  printf '%s\n' "$duplicates_csv" | tr ',' '\n' | while IFS= read -r item_name; do
    item_name=$(printf '%s' "$item_name" | sed 's/^ *//; s/ *$//')
    [ -n "$item_name" ] || continue
    echo "Removing duplicate login item entries for: $item_name"
    if [ "$DRY_RUN" = "true" ]; then
      printf '[dry-run] delete duplicate login items named %s\n' "$item_name"
      continue
    fi
    ITEM_NAME="$item_name" osascript <<'APPLESCRIPT'
set targetName to system attribute "ITEM_NAME"
tell application "System Events"
  set matchingItems to every login item whose name is targetName
  set itemCount to count of matchingItems
  if itemCount > 1 then
    repeat with idx from itemCount to 2 by -1
      delete item idx of matchingItems
    end repeat
  end if
end tell
APPLESCRIPT
  done
}

disable_low_value_agents() {
  local label
  for label in $(printf '%s' "$LOW_VALUE_AGENT_LIST" | tr ',' ' '); do
    [ -n "$label" ] || continue
    echo "Disabling low-value agent: $label"
    run_cmd launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
    run_cmd launchctl disable "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
  done
}

report_state() {
  local disabled_snapshot

  echo "Login items:"
  osascript -e 'tell application "System Events" to get the name of every login item'
  echo
  echo "Agent status:"
  disabled_snapshot=$(launchctl print-disabled "gui/$(id -u)" 2>/dev/null || true)
  for label in $(printf '%s' "$LOW_VALUE_AGENT_LIST" | tr ',' ' '); do
    [ -n "$label" ] || continue
    printf '%s\t' "$label"
    printf '%s\n' "$disabled_snapshot" | grep -Fq "\"$label\"" && echo disabled && continue
    launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 && echo loaded || echo not-loaded
  done
}

cleanup_login_items
disable_low_value_agents
report_state
