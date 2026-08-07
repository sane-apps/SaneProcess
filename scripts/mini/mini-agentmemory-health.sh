#!/bin/bash
# Shared by the Mini supervisor and installer. Callers provide CURL, RUBY,
# MKTEMP, AGENTMEMORY, AGENTMEMORY_URL, CORPUS_MIN, and log-size settings.

agentmemory_secret() {
  local file mode line value
  if [[ -n "${AGENTMEMORY_SECRET:-}" ]]; then
    [[ "$AGENTMEMORY_SECRET" != *[[:space:]]* ]] || return 1
    printf '%s' "$AGENTMEMORY_SECRET"
    return 0
  fi
  file="${SANE_AGENTMEMORY_ENV_FILE:-$HOME/.agentmemory/.env}"
  [[ -r "$file" ]] || return 1
  mode="$(/usr/bin/stat -f '%Lp' "$file" 2>/dev/null)" || return 1
  [[ "$mode" == "600" || "$mode" == "400" ]] || return 1
  line="$(/usr/bin/grep -E '^AGENTMEMORY_SECRET=' "$file" 2>/dev/null | /usr/bin/tail -1)"
  [[ -n "$line" ]] || return 1
  value="${line#AGENTMEMORY_SECRET=}"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  [[ -n "$value" && "$value" != *[[:space:]]* ]] || return 1
  printf '%s' "$value"
}

agentmemory_curl() {
  local secret
  secret="$(agentmemory_secret 2>/dev/null || true)"
  if [[ -z "$secret" ]]; then
    "$CURL" "$@"
    return $?
  fi
  # curl reads the header from stdin: the bearer is never in argv or on disk.
  printf 'Authorization: Bearer %s\n' "$secret" | "$CURL" -H @- "$@"
}

compact_log() {
  local path size temp
  path="$1"
  [[ -f "$path" ]] || return 0
  size="$(/usr/bin/wc -c < "$path" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt "$LOG_MAX_BYTES" ]] || return 0
  temp="$("$MKTEMP" "${path}.compact.XXXXXX")" || return 1
  if /usr/bin/tail -c "$LOG_KEEP_BYTES" "$path" > "$temp" 2>/dev/null; then
    /bin/cat "$temp" > "$path"
  fi
  /bin/rm -f "$temp"
}

healthy() {
  local status_output count
  agentmemory_curl --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/livez" >/dev/null || return 1
  agentmemory_curl --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/health" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["service"] == "agentmemory" && value["status"] == "healthy" ? 0 : 1)' || return 1
  status_output="$($AGENTMEMORY status 2>&1 || true)"
  printf '%s\n' "$status_output" | /usr/bin/grep -Eq 'Health:[[:space:]].*healthy' || return 1
  count="$(printf '%s\n' "$status_output" | /usr/bin/sed -nE 's/.*Memories:[[:space:]]*([0-9][0-9,]*).*/\1/p' | /usr/bin/head -1 | /usr/bin/tr -d ',')"
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge "$CORPUS_MIN" ]] || return 1
  agentmemory_curl --silent --show-error --fail --max-time 4 \
    -H 'Content-Type: application/json' --data '{"query":"SaneApps","limit":1,"format":"compact"}' \
    "$AGENTMEMORY_URL/agentmemory/search" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["results"].is_a?(Array) ? 0 : 1)'
}
