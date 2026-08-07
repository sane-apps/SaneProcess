#!/bin/bash
# Sync the Codex control-plane profile from the local machine to the Mac Mini.
# Automation records are deliberately outside this sync boundary: production
# automation mutations must go through Codex automation_update.
set -euo pipefail
MINI_HOST="mini"
QUIET=0
RESTART_CODEX=0
DUMP_CONFIG=0
ALLOW_REVIEWED_DIRTY=0
DUMP_MANIFEST=0
VALIDATE_MANIFEST_ROOT=""
usage() {
  cat <<USAGE
Usage: $(basename "$0") [peer-host] [--quiet] [--restart] [--allow-reviewed-dirty]

The peer must be clean and at the same Git HEAD. By default the source must be
clean too. --allow-reviewed-dirty permits source changes only when every dirty
SaneProcess path is in the reviewed control-plane manifest.
USAGE
}
log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$@"
  fi
}
die() {
  echo "ERROR: $*" >&2
  exit 1
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --no-restart)
      RESTART_CODEX=0
      shift
      ;;
    --restart)
      RESTART_CODEX=1
      shift
      ;;
    --dump-config)
      DUMP_CONFIG=1
      shift
      ;;
    --dump-manifest)
      DUMP_MANIFEST=1
      shift
      ;;
    --allow-reviewed-dirty)
      ALLOW_REVIEWED_DIRTY=1
      shift
      ;;
    --validate-manifest-root)
      shift
      [[ $# -gt 0 ]] || die "--validate-manifest-root requires a path"
      VALIDATE_MANIFEST_ROOT="$1"
      shift
      ;;
    --*)
      die "Unknown option: $1"
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done
command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v scp >/dev/null 2>&1 || die "scp not found"
command -v rsync >/dev/null 2>&1 || die "rsync not found"

LOCAL_CODEX_DIR="$HOME/.codex"
LOCAL_CODEX_CONFIG="$LOCAL_CODEX_DIR/config.toml"
LOCAL_CODEX_BIN_DIR="$LOCAL_CODEX_DIR/bin"
LOCAL_CODEX_STANDALONE_BIN="$LOCAL_CODEX_DIR/packages/standalone/current/codex"
REPO_CODEX_BIN_DIR="$HOME/SaneApps/infra/SaneProcess/scripts/codex-bin"
LOCAL_SKILLS_REGISTRY="$LOCAL_CODEX_DIR/SKILLS_REGISTRY.md"
LOCAL_SKILLS_DIR="$LOCAL_CODEX_DIR/skills"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
LOCAL_REPO="$HOME/SaneApps/infra/SaneProcess"
CODEX_BIN_FILES=("check-mcps" "github-mcp-bridge.mjs" "xcode-mcpbridge-wrapper.sh")
CONTROL_PLANE_REL_FILES=(
  "SaneApps/infra/scripts/check-inbox.sh" "SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"
  "SaneApps/infra/SaneProcess/scripts/automation/control_plane_sync_test.rb" "SaneApps/infra/SaneProcess/scripts/automation/reconcile-air-mini.sh"
  "SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh" "SaneApps/infra/SaneProcess/scripts/hooks/core/local_ui_guard.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/core/process_metrics.rb" "SaneApps/infra/SaneProcess/scripts/hooks/core/project_root.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/core/state_manager.rb" "SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_build_tool_guard.sh" "SaneApps/infra/SaneProcess/scripts/hooks/sane_automation_guard.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_bash_guards.rb" "SaneApps/infra/SaneProcess/scripts/hooks/sane_catastrophic_guard.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_email_guard.rb" "SaneApps/infra/SaneProcess/scripts/hooks/sane_launch_guard.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_release_guard.rb" "SaneApps/infra/SaneProcess/scripts/hooks/sane_ship_guard.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_open_guard.sh" "SaneApps/infra/SaneProcess/scripts/hooks/sane_rsync_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_security_guard.sh" "SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/release_receipt_signer.rb" "SaneApps/infra/SaneProcess/scripts/hooks/session_briefing.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/session_start_cleanup.rb" "SaneApps/infra/SaneProcess/scripts/hooks/state_signer.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/swift" "SaneApps/infra/SaneProcess/scripts/hooks/xcodebuild"
  "SaneApps/infra/SaneProcess/scripts/mini/mini-reclaim-automation-windows.sh" "SaneApps/infra/SaneProcess/scripts/mini/mini-nightly.sh"
  "SaneApps/infra/SaneProcess/scripts/mini/mini-prepare-automation-root.sh" "SaneApps/infra/SaneProcess/scripts/validation_report.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb" "SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb" "SaneApps/infra/SaneProcess/scripts/sanemaster/verify_doctor.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/verify_permissions.rb" "SaneApps/infra/SaneProcess/scripts/sanemaster/verify_support.rb"
)
USER_CONTROL_PLANE_REL_FILES=(
  ".codex/SKILLS_REGISTRY.md" ".codex/packages/standalone/current/codex"
  ".codex/bin/check-mcps" ".codex/bin/github-mcp-bridge.mjs" ".codex/bin/xcode-mcpbridge-wrapper.sh"
  ".local/bin/curl" ".local/bin/open" ".local/bin/rsync" ".local/bin/security"
  ".local/bin/ssh" ".local/bin/swift" ".local/bin/xcodebuild"
)
if [[ "$DUMP_CONFIG" -eq 1 ]]; then
  printf 'MINI_HOST=%s\n' "$MINI_HOST"
  printf 'QUIET=%s\n' "$QUIET"
  printf 'RESTART_CODEX=%s\n' "$RESTART_CODEX"
  printf 'ALLOW_REVIEWED_DIRTY=%s\n' "$ALLOW_REVIEWED_DIRTY"
  exit 0
fi
if [[ "$DUMP_MANIFEST" -eq 1 ]]; then
  printf '%s\n' "${CONTROL_PLANE_REL_FILES[@]}"
  exit 0
fi
extract_semver() {
  python3 - "$1" <<'PY'
import re
import sys

match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1] or "")
if match:
    print(".".join(match.groups()))
PY
}
version_needs_update() {
  local version="$1"
  local minimum="$2"
  python3 - "$version" "$minimum" <<'PY'
import re
import sys

current = sys.argv[1]
minimum = sys.argv[2]
def parts(value):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())
current_parts = parts(current)
minimum_parts = parts(minimum)
if current_parts is None or minimum_parts is None or current_parts < minimum_parts:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

install_codex_standalone() {
  local installer
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX") || die "Could not create Codex installer temp file"
  if ! CODEX_NON_INTERACTIVE=1 curl --fail --show-error --silent --proto '=https' --tlsv1.2 --location --max-redirs 0 \
    --output "$installer" \
    https://chatgpt.com/codex/install.sh; then
    rm -f "$installer"
    return 1
  fi
  chmod 600 "$installer"
  if CODEX_NON_INTERACTIVE=1 sh "$installer"; then
    rm -f "$installer"
    return 0
  fi
  local status=$?
  rm -f "$installer"
  return "$status"
}
ensure_local_codex_standalone() {
  local current_version=""
  if [[ -x "$LOCAL_CODEX_STANDALONE_BIN" ]]; then
    current_version=$("$LOCAL_CODEX_STANDALONE_BIN" --version 2>/dev/null || true)
  fi

  if [[ -z "$(extract_semver "$current_version")" ]]; then
    log "Installing current local Codex standalone CLI for app-server daemon..."
    install_codex_standalone || die "Local Codex standalone installation failed"
    current_version=$("$LOCAL_CODEX_STANDALONE_BIN" --version 2>/dev/null || true)
  fi
  SUPPORTED_CODEX_CLI_VERSION=$(extract_semver "$current_version")
  [[ -n "$SUPPORTED_CODEX_CLI_VERSION" ]] || die "Could not determine local Codex CLI version"
}
ensure_remote_codex_standalone() {
  ssh "$MINI_HOST" "SUPPORTED_CODEX_CLI_VERSION='$SUPPORTED_CODEX_CLI_VERSION' bash -s" <<'REMOTE'
set -euo pipefail

codex_bin="$HOME/.codex/packages/standalone/current/codex"
current_version=""
if [ -x "$codex_bin" ]; then
  current_version=$("$codex_bin" --version 2>/dev/null || true)
fi

needs_update=$(python3 - "$current_version" "$SUPPORTED_CODEX_CLI_VERSION" <<'PY'
import re
import sys

current = sys.argv[1]
minimum = sys.argv[2]
def parts(value):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())
current_parts = parts(current)
minimum_parts = parts(minimum)
print("1" if current_parts is None or current_parts < minimum_parts else "0")
PY
)

install_codex_standalone() {
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX") || return 1
  if ! CODEX_NON_INTERACTIVE=1 curl --fail --show-error --silent --proto '=https' --tlsv1.2 --location --max-redirs 0 \
    --output "$installer" \
    https://chatgpt.com/codex/install.sh; then
    rm -f "$installer"
    return 1
  fi
  chmod 600 "$installer"
  if CODEX_NON_INTERACTIVE=1 sh "$installer"; then
    rm -f "$installer"
    return 0
  fi
  status=$?
  rm -f "$installer"
  return "$status"
}

if [ "$needs_update" = "1" ]; then
  install_codex_standalone
fi
REMOTE
}

validate_manifest_dependency_closure() {
  local root="${1:-$HOME}"
  python3 - "$root" "${CONTROL_PLANE_REL_FILES[@]}" <<'PY'
import pathlib
import re
import sys

home = pathlib.Path(sys.argv[1]).resolve()
manifest = set(sys.argv[2:])
missing = []
pattern = re.compile(r'^\s*require_relative\s+["\']([^"\']+)["\']')

for rel in sorted(manifest):
    source = home / rel
    if source.suffix != '.rb' or not source.is_file():
        continue
    for line in source.read_text(encoding='utf-8').splitlines():
        match = pattern.match(line)
        if not match:
            continue
        candidate = (source.parent / match.group(1))
        if candidate.suffix == '':
            candidate = candidate.with_suffix('.rb')
        candidate = candidate.resolve()
        if not candidate.is_file():
            continue
        try:
            dependency = str(candidate.relative_to(home))
        except ValueError:
            continue
        if dependency not in manifest:
            missing.append(f'{rel} -> {dependency}')

if missing:
    print('Manifest dependency closure is incomplete:', file=sys.stderr)
    for item in missing:
        print(f'  {item}', file=sys.stderr)
    raise SystemExit(1)
PY
}

if [[ -n "$VALIDATE_MANIFEST_ROOT" ]]; then
  validate_manifest_dependency_closure "$VALIDATE_MANIFEST_ROOT" || \
    die "Staged control-plane manifest dependency validation failed"
  exit 0
fi

[[ -f "$LOCAL_CODEX_CONFIG" ]] || die "Missing local Codex config: $LOCAL_CODEX_CONFIG"
[[ -f "$LOCAL_SKILLS_REGISTRY" ]] || die "Missing local Codex skills registry: $LOCAL_SKILLS_REGISTRY"
[[ -d "$LOCAL_SKILLS_DIR" ]] || die "Missing local Codex skills dir: $LOCAL_SKILLS_DIR"
[[ -d "$REPO_CODEX_BIN_DIR" ]] || die "Missing repo Codex bin dir: $REPO_CODEX_BIN_DIR"

for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  [[ -f "$HOME/$rel" ]] || die "Missing control-plane file: $HOME/$rel"
done

for bin_name in "${CODEX_BIN_FILES[@]}"; do
  [[ -f "$REPO_CODEX_BIN_DIR/$bin_name" ]] || die "Missing repo Codex bin helper: $REPO_CODEX_BIN_DIR/$bin_name"
done

validate_reviewed_local_dirty_paths() {
  local repo="$1"
  python3 - "$repo" "${CONTROL_PLANE_REL_FILES[@]}" <<'PY'
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
prefix = 'SaneApps/infra/SaneProcess/'
allowed = {item[len(prefix):] for item in sys.argv[2:] if item.startswith(prefix)}
raw = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain=v1', '-z'])
records = raw.decode('utf-8', errors='surrogateescape').split('\0')
dirty = []
i = 0
while i < len(records):
    record = records[i]
    i += 1
    if not record:
        continue
    status = record[:2]
    path = record[3:]
    dirty.append(path)
    if 'R' in status or 'C' in status:
        if i < len(records) and records[i]:
            dirty.append(records[i])
            i += 1

outside = sorted({path for path in dirty if path not in allowed})
if outside:
    print('Reviewed-dirty sync refused; paths outside the manifest:', file=sys.stderr)
    for path in outside:
        print(f'  {path}', file=sys.stderr)
    raise SystemExit(1)
PY
}

hash_path() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'SYMLINK %s' "$(readlink "$path")"
  elif [[ -f "$path" ]]; then
    shasum -a 256 "$path" | cut -d' ' -f1
  else
    printf 'MISSING'
  fi
}

capture_local_preimages() {
  local receipt="$1"
  local state="$2"
  mkdir -p "$receipt/files"
  chmod 700 "$receipt"
  printf '%s\n' "$state" > "$receipt/repo-state.txt"
  : > "$receipt/hashes.txt"
  local rel source destination
  for rel in "${CONTROL_PLANE_REL_FILES[@]}" "${USER_CONTROL_PLANE_REL_FILES[@]}"; do
    source="$HOME/$rel"
    destination="$receipt/files/$rel"
    printf '%s  %s\n' "$(hash_path "$source")" "$rel" >> "$receipt/hashes.txt"
    if [[ -f "$source" || -L "$source" ]]; then
      mkdir -p "$(dirname "$destination")"
      cp -Pp "$source" "$destination"
    fi
  done
  printf '%s  %s\n' "$(hash_path "$LOCAL_CODEX_CONFIG")" '.codex/config.toml (hash only)' >> "$receipt/hashes.txt"
  if [[ -d "$LOCAL_SKILLS_DIR" ]]; then
    find "$LOCAL_SKILLS_DIR" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort > "$receipt/codex-skills.sha256"
  fi
  if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
    find "$LOCAL_AGENTS_SKILLS_DIR" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort > "$receipt/agent-skills.sha256"
  fi
  chmod 600 "$receipt"/*.txt "$receipt"/*.sha256 2>/dev/null || true
}

capture_remote_preimages() {
  local receipt="$1"
  local state="$2"
  local manifest_file="$TMP_DIR/preimage-manifest.txt"
  local reviewed_manifest_file="$TMP_DIR/reviewed-manifest.txt"
  printf '%s\n' "${CONTROL_PLANE_REL_FILES[@]}" "${USER_CONTROL_PLANE_REL_FILES[@]}" > "$manifest_file"
  printf '%s\n' "${CONTROL_PLANE_REL_FILES[@]}" > "$reviewed_manifest_file"
  ssh "$MINI_HOST" "mkdir -p \"$receipt/files\" && chmod 700 \"$receipt\""
  scp -q "$manifest_file" "$MINI_HOST:$receipt/manifest.txt"
  scp -q "$reviewed_manifest_file" "$MINI_HOST:$receipt/reviewed-manifest.txt"
  ssh "$MINI_HOST" "RECEIPT='$receipt' REPO_STATE='$state' bash -s" <<'REMOTE'
set -euo pipefail
printf '%s\n' "$REPO_STATE" > "$RECEIPT/repo-state.txt"
: > "$RECEIPT/hashes.txt"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  source="$HOME/$rel"
  destination="$RECEIPT/files/$rel"
  if [ -L "$source" ]; then
    hash="SYMLINK $(readlink "$source")"
  elif [ -f "$source" ]; then
    hash=$(shasum -a 256 "$source" | cut -d' ' -f1)
  else
    hash="MISSING"
  fi
  printf '%s  %s\n' "$hash" "$rel" >> "$RECEIPT/hashes.txt"
  if [ -f "$source" ] || [ -L "$source" ]; then
    mkdir -p "$(dirname "$destination")"
    cp -Pp "$source" "$destination"
  fi
done < "$RECEIPT/manifest.txt"
: > "$RECEIPT/reviewed-preimage.sha256"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  source="$HOME/$rel"
  if [ -L "$source" ]; then
    hash="SYMLINK:$(readlink "$source")"
  elif [ -f "$source" ]; then
    hash=$(shasum -a 256 "$source" | cut -d' ' -f1)
  else
    hash="MISSING"
  fi
  printf '%s\t%s\n' "$hash" "$rel" >> "$RECEIPT/reviewed-preimage.sha256"
done < "$RECEIPT/reviewed-manifest.txt"
config="$HOME/.codex/config.toml"
if [ -f "$config" ]; then
  printf '%s  %s\n' "$(shasum -a 256 "$config" | cut -d' ' -f1)" '.codex/config.toml (hash only)' >> "$RECEIPT/hashes.txt"
else
  printf 'MISSING  %s\n' '.codex/config.toml (hash only)' >> "$RECEIPT/hashes.txt"
fi
if [ -d "$HOME/.codex/skills" ]; then
  find "$HOME/.codex/skills" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort > "$RECEIPT/codex-skills.sha256"
fi
if [ -d "$HOME/.agents/skills" ]; then
  find "$HOME/.agents/skills" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort > "$RECEIPT/agent-skills.sha256"
fi
chmod 600 "$RECEIPT"/*.txt "$RECEIPT"/*.sha256 2>/dev/null || true
REMOTE
}

snapshot_dirty_repos() {
  local local_dirty="$1"
  local remote_dirty="$2"
  local remote_git_sync="$REMOTE_REPO/scripts/automation/git-sync-safe.sh"
  if [[ "$local_dirty" -gt 0 ]]; then
    bash "$LOCAL_REPO/scripts/automation/git-sync-safe.sh" --snapshot-only >/dev/null || \
      die "Local dirty-work snapshot failed"
  fi
  if [[ "$remote_dirty" -gt 0 ]]; then
    ssh "$MINI_HOST" "bash \"$remote_git_sync\" --snapshot-only" >/dev/null || \
      die "Peer dirty-work snapshot failed"
  fi
}

read_local_repo_state() {
  git -C "$LOCAL_REPO" rev-parse HEAD 2>/dev/null || return 1
  git -C "$LOCAL_REPO" status --porcelain=v1 | wc -l | tr -d ' '
}

read_remote_repo_state() {
  ssh "$MINI_HOST" "git -C \"$REMOTE_REPO\" rev-parse HEAD && git -C \"$REMOTE_REPO\" status --porcelain=v1 | wc -l | tr -d ' '"
}

write_reviewed_hashes() {
  local output="$1"
  local root="$2"
  : > "$output"
  local rel
  for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
    printf '%s  %s\n' "$(shasum -a 256 "$root/$rel" | cut -d' ' -f1)" "$rel" >> "$output"
  done
}

acquire_control_plane_locks() {
  mkdir -p "$(dirname "$LOCAL_LOCK")"
  if ! mkdir "$LOCAL_LOCK" 2>/dev/null; then
    die "Local control-plane sync lock is held: $LOCAL_LOCK"
  fi
  LOCAL_LOCK_HELD=1
  printf 'pid=%s host=%s started=%s\n' "$$" "$LOCAL_HOST" "$RUN_TAG" > "$LOCAL_LOCK/owner"

  if ! ssh "$MINI_HOST" "mkdir -p \"$(dirname "$REMOTE_LOCK")\" && mkdir \"$REMOTE_LOCK\""; then
    die "Peer control-plane sync lock is held: $MINI_HOST:$REMOTE_LOCK"
  fi
  REMOTE_LOCK_HELD=1
  ssh "$MINI_HOST" "printf 'pid=%s host=%s started=%s\\n' '$$' '$LOCAL_HOST' '$RUN_TAG' > \"$REMOTE_LOCK/owner\""
}

cleanup_sync() {
  local status=$?
  set +e
  if [[ "${REMOTE_LOCK_HELD:-0}" -eq 1 ]]; then
    ssh "$MINI_HOST" "rm -f \"$REMOTE_LOCK/owner\"; rmdir \"$REMOTE_LOCK\"" >/dev/null 2>&1
  fi
  if [[ "${LOCAL_LOCK_HELD:-0}" -eq 1 ]]; then
    rm -f "$LOCAL_LOCK/owner"
    rmdir "$LOCAL_LOCK" 2>/dev/null
  fi
  [[ -z "${TMP_DIR:-}" ]] || rm -r "$TMP_DIR"
  exit "$status"
}

verify_locked_state_unchanged() {
  local local_now remote_now local_hashes_now
  local_now=$(read_local_repo_state) || die "Could not re-read local SaneProcess state under lock"
  remote_now=$(read_remote_repo_state) || die "Could not re-read peer SaneProcess state under lock"
  [[ "$local_now" == "$LOCKED_LOCAL_STATE" ]] || \
    die "Local SaneProcess changed after locked preflight; staged apply refused"
  [[ "$remote_now" == "$LOCKED_REMOTE_STATE" ]] || \
    die "Peer SaneProcess changed after locked preflight; staged apply refused"

  local_hashes_now="$TMP_DIR/reviewed-source-now.sha256"
  write_reviewed_hashes "$local_hashes_now" "$HOME"
  cmp -s "$SOURCE_MANIFEST_HASHES" "$local_hashes_now" || \
    die "Local reviewed manifest changed after locked preflight; staged apply refused"

  ssh "$MINI_HOST" "RECEIPT='$REMOTE_PREIMAGE_DIR' bash -s" <<'REMOTE' || \
    die "Peer reviewed manifest changed after locked preflight; staged apply refused"
set -euo pipefail
while IFS=$'\t' read -r expected rel; do
  [ -n "$rel" ] || continue
  path="$HOME/$rel"
  if [ -L "$path" ]; then
    actual="SYMLINK:$(readlink "$path")"
  elif [ -f "$path" ]; then
    actual=$(shasum -a 256 "$path" | cut -d' ' -f1)
  else
    actual="MISSING"
  fi
  [ "$actual" = "$expected" ] || {
    printf 'peer preimage mismatch: %s\n' "$rel" >&2
    exit 1
  }
done < "$RECEIPT/reviewed-preimage.sha256"
REMOTE
}

stage_reviewed_manifest() {
  local archive="$TMP_DIR/reviewed-manifest.tar"
  local manifest="$TMP_DIR/reviewed-manifest.txt"
  printf '%s\n' "${CONTROL_PLANE_REL_FILES[@]}" > "$manifest"
  tar -cf "$archive" -C "$HOME" "${CONTROL_PLANE_REL_FILES[@]}"

  ssh "$MINI_HOST" "mkdir -p \"$REMOTE_STAGE/files\""
  scp -q "$archive" "$MINI_HOST:$REMOTE_STAGE/reviewed-manifest.tar"
  scp -q "$manifest" "$MINI_HOST:$REMOTE_STAGE/reviewed-manifest.txt"
  scp -q "$SOURCE_MANIFEST_HASHES" "$MINI_HOST:$REMOTE_STAGE/reviewed-manifest.sha256"
  ssh "$MINI_HOST" "set -e; tar -xf \"$REMOTE_STAGE/reviewed-manifest.tar\" -C \"$REMOTE_STAGE/files\"; cd \"$REMOTE_STAGE/files\"; shasum -a 256 -c \"$REMOTE_STAGE/reviewed-manifest.sha256\" >/dev/null; bash \"$REMOTE_STAGE/files/SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh\" --validate-manifest-root \"$REMOTE_STAGE/files\""
}

promote_reviewed_manifest() {
  local fail_after="${SANE_CONTROL_PLANE_FAIL_AFTER_PROMOTIONS:-0}"
  [[ "$fail_after" =~ ^[0-9]+$ ]] || die "Invalid promotion failure-test value"
  ssh "$MINI_HOST" "STAGE='$REMOTE_STAGE' FAIL_AFTER='$fail_after' bash -s" <<'REMOTE'
set -euo pipefail
promoted="$STAGE/promoted.tsv"
backups="$STAGE/backups"
failed="$STAGE/rolled-back-new-files"
: > "$promoted"
mkdir -p "$backups" "$failed"

rollback() {
  local rel had destination backup evidence
  awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' "$promoted" |
    while IFS=$'\t' read -r rel had; do
      [ -n "$rel" ] || continue
      destination="$HOME/$rel"
      backup="$backups/$rel"
      evidence="$failed/$rel"
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        mkdir -p "$(dirname "$evidence")"
        mv "$destination" "$evidence" || return 1
      fi
      if [ "$had" = "1" ]; then
        mkdir -p "$(dirname "$destination")"
        mv "$backup" "$destination" || return 1
      fi
    done
}

promote_all() {
  local rel source destination backup temp had count
  count=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    source="$STAGE/files/$rel"
    destination="$HOME/$rel"
    backup="$backups/$rel"
    temp="$(dirname "$destination")/.sane-control-plane-$$-$(basename "$destination")"
    mkdir -p "$(dirname "$destination")" "$(dirname "$backup")" || return 1
    cp -p "$source" "$temp" || return 1
    had=0
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      cp -Pp "$destination" "$backup" || return 1
      had=1
    fi
    printf '%s\t%s\n' "$rel" "$had" >> "$promoted" || return 1
    mv "$temp" "$destination" || return 1
    count=$((count + 1))
    if [ "$FAIL_AFTER" -gt 0 ] && [ "$count" -ge "$FAIL_AFTER" ]; then
      echo "Injected control-plane promotion failure after $count file(s)" >&2
      return 1
    fi
  done < "$STAGE/reviewed-manifest.txt"
}

if ! promote_all; then
  rollback || echo "Control-plane rollback encountered an error" >&2
  exit 1
fi
printf 'success\n' > "$STAGE/promotion-status.txt"
REMOTE
}

REMOTE_HOME=$(ssh -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || die "Could not reach $MINI_HOST"
LOCAL_HOST="${SANE_LOCAL_HOST_OVERRIDE:-$(hostname -s 2>/dev/null || hostname)}"
REMOTE_HOST="${SANE_REMOTE_HOST_OVERRIDE:-$(ssh -o ConnectTimeout=8 "$MINI_HOST" 'hostname -s 2>/dev/null || hostname')}" || die "Could not resolve host identity on $MINI_HOST"
[[ -n "$REMOTE_HOST" && "$LOCAL_HOST" != "$REMOTE_HOST" ]] || die "Refusing Mini control-plane loopback on $LOCAL_HOST"
REMOTE_REPO="$REMOTE_HOME/SaneApps/infra/SaneProcess"
TMP_DIR=$(mktemp -d)
LOCAL_LOCK_HELD=0
REMOTE_LOCK_HELD=0
trap cleanup_sync EXIT

validate_manifest_dependency_closure || die "Control-plane manifest dependency validation failed"

PREFLIGHT_LOCAL_STATE=$(read_local_repo_state) || die "Local SaneProcess is not a Git checkout"
PREFLIGHT_REMOTE_STATE=$(read_remote_repo_state) || die "Could not read peer SaneProcess Git state"

RUN_TAG="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOCAL_LOCK="${SANE_CONTROL_PLANE_LOCAL_LOCK:-$LOCAL_REPO/outputs/locks/control-plane-sync.lock}"
REMOTE_LOCK="${SANE_CONTROL_PLANE_REMOTE_LOCK:-$REMOTE_REPO/outputs/locks/control-plane-sync.lock}"
REMOTE_STAGE="$REMOTE_REPO/outputs/control-plane-staging/$RUN_TAG"
SOURCE_MANIFEST_HASHES="$TMP_DIR/reviewed-source.sha256"
acquire_control_plane_locks

LOCKED_LOCAL_STATE=$(read_local_repo_state) || die "Could not read local SaneProcess state under lock"
LOCKED_REMOTE_STATE=$(read_remote_repo_state) || die "Could not read peer SaneProcess state under lock"
[[ "$PREFLIGHT_LOCAL_STATE" == "$LOCKED_LOCAL_STATE" ]] || \
  die "Local SaneProcess changed while acquiring control-plane locks"
[[ "$PREFLIGHT_REMOTE_STATE" == "$LOCKED_REMOTE_STATE" ]] || \
  die "Peer SaneProcess changed while acquiring control-plane locks"

LOCAL_HEAD=$(printf '%s\n' "$LOCKED_LOCAL_STATE" | sed -n '1p')
LOCAL_DIRTY=$(printf '%s\n' "$LOCKED_LOCAL_STATE" | sed -n '2p')
REMOTE_HEAD=$(printf '%s\n' "$LOCKED_REMOTE_STATE" | sed -n '1p')
REMOTE_DIRTY=$(printf '%s\n' "$LOCKED_REMOTE_STATE" | sed -n '2p')
[[ "$LOCAL_DIRTY" =~ ^[0-9]+$ ]] || die "Could not parse local dirty-work state"
[[ "$REMOTE_DIRTY" =~ ^[0-9]+$ ]] || die "Could not parse peer dirty-work state"

LOCAL_PREIMAGE_DIR="$LOCAL_REPO/outputs/control-plane-preimages/$RUN_TAG-$LOCAL_HOST"
REMOTE_PREIMAGE_DIR="$REMOTE_REPO/outputs/control-plane-preimages/$RUN_TAG-$REMOTE_HOST"
LOCAL_STATE="host=$LOCAL_HOST head=$LOCAL_HEAD dirty=$LOCAL_DIRTY"
REMOTE_STATE_RECEIPT="host=$REMOTE_HOST head=$REMOTE_HEAD dirty=$REMOTE_DIRTY"

write_reviewed_hashes "$SOURCE_MANIFEST_HASHES" "$HOME"
snapshot_dirty_repos "$LOCAL_DIRTY" "$REMOTE_DIRTY"
capture_local_preimages "$LOCAL_PREIMAGE_DIR" "$LOCAL_STATE"
capture_remote_preimages "$REMOTE_PREIMAGE_DIR" "$REMOTE_STATE_RECEIPT"
log "Preimage receipts: $LOCAL_PREIMAGE_DIR and $MINI_HOST:$REMOTE_PREIMAGE_DIR"

[[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || \
  die "SaneProcess HEAD divergence ($LOCAL_HEAD != $REMOTE_HEAD); reconcile through Git before control-plane sync"
[[ "$REMOTE_DIRTY" -eq 0 ]] || \
  die "Peer SaneProcess is dirty ($REMOTE_DIRTY path(s)); snapshot captured, no control-plane mutation performed"
if [[ "$LOCAL_DIRTY" -gt 0 ]]; then
  [[ "$ALLOW_REVIEWED_DIRTY" -eq 1 ]] || \
    die "Source SaneProcess is dirty ($LOCAL_DIRTY path(s)); use --allow-reviewed-dirty only after reviewing every manifest change"
  validate_reviewed_local_dirty_paths "$LOCAL_REPO" || die "Source dirty-work scope is not safe to sync"
fi

CHECK_INBOX_TEST="$HOME/SaneApps/infra/SaneProcess/scripts/automation/check_inbox_report_test.py"
if [[ -f "$CHECK_INBOX_TEST" ]]; then
  log "Validating check-inbox.sh against its contract suite before staging..."
  python3 "$CHECK_INBOX_TEST" >/tmp/check_inbox_gate.log 2>&1 || \
    die "check-inbox.sh failed its contract suite; complete manifest apply refused (see /tmp/check_inbox_gate.log)"
fi

stage_reviewed_manifest || die "Peer manifest staging or dependency verification failed"
verify_locked_state_unchanged
promote_reviewed_manifest || die "Peer manifest promotion failed and rollback was requested"

LOCAL_CONFIG_HASH_BEFORE=$(hash_path "$LOCAL_CODEX_CONFIG")
REMOTE_CONFIG_HASH_BEFORE=$(ssh "$MINI_HOST" "if [ -f \"$REMOTE_HOME/.codex/config.toml\" ]; then shasum -a 256 \"$REMOTE_HOME/.codex/config.toml\" | cut -d' ' -f1; else printf MISSING; fi")

ensure_local_codex_standalone

# Keep local Codex guard wiring consistent too.
mkdir -p "$HOME/.local/bin"
mkdir -p "$LOCAL_CODEX_BIN_DIR"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh" "$HOME/.local/bin/curl"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_open_guard.sh" "$HOME/.local/bin/open"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_rsync_guard.sh" "$HOME/.local/bin/rsync"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_security_guard.sh" "$HOME/.local/bin/security"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh" "$HOME/.local/bin/ssh"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/swift" "$HOME/.local/bin/swift"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/xcodebuild" "$HOME/.local/bin/xcodebuild"
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  cp "$REPO_CODEX_BIN_DIR/$bin_name" "$LOCAL_CODEX_BIN_DIR/$bin_name"
  chmod +x "$LOCAL_CODEX_BIN_DIR/$bin_name"
done

ensure_remote_codex_standalone

log "Syncing Codex skill registry and skills to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/skills\""
scp -q "$LOCAL_SKILLS_REGISTRY" "$MINI_HOST:$REMOTE_HOME/.codex/SKILLS_REGISTRY.md"
rsync -a --backup --backup-dir="$REMOTE_PREIMAGE_DIR/codex-skills-backup" \
  "$LOCAL_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.codex/skills/"

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  log "Syncing shared agent skills to $MINI_HOST..."
  ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.agents/skills\""
  rsync -a --backup --backup-dir="$REMOTE_PREIMAGE_DIR/agent-skills-backup" \
    "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/"
fi

log "Syncing Codex control-plane helpers to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/bin\""
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  scp -q "$REPO_CODEX_BIN_DIR/$bin_name" "$MINI_HOST:$REMOTE_HOME/.codex/bin/$bin_name"
done

ssh "$MINI_HOST" "
  set -e
  chmod +x \"$REMOTE_HOME/.codex/bin/check-mcps\"
  chmod +x \"$REMOTE_HOME/.codex/bin/github-mcp-bridge.mjs\"
  chmod +x \"$REMOTE_HOME/.codex/bin/xcode-mcpbridge-wrapper.sh\"
  mkdir -p \"$REMOTE_HOME/.local/bin\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh\" \"$REMOTE_HOME/.local/bin/curl\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_open_guard.sh\" \"$REMOTE_HOME/.local/bin/open\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_rsync_guard.sh\" \"$REMOTE_HOME/.local/bin/rsync\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_security_guard.sh\" \"$REMOTE_HOME/.local/bin/security\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh\" \"$REMOTE_HOME/.local/bin/ssh\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/swift\" \"$REMOTE_HOME/.local/bin/swift\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/xcodebuild\" \"$REMOTE_HOME/.local/bin/xcodebuild\"
" || die "Remote copy failed"

log "Verifying control-plane parity (Air ↔ Mini)..."
mismatches=0
for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  local_hash=$(shasum -a 256 "$HOME/$rel" | cut -d' ' -f1)
  remote_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/$rel\" | cut -d' ' -f1" 2>/dev/null || echo "")
  if [[ -z "$remote_hash" || "$local_hash" != "$remote_hash" ]]; then
    echo "MISMATCH: $rel" >&2
    mismatches=$((mismatches + 1))
  fi
done
if [[ "$mismatches" -gt 0 ]]; then
  die "Control-plane parity check failed ($mismatches mismatch(es))"
fi

local_registry_hash=$(shasum -a 256 "$LOCAL_SKILLS_REGISTRY" | cut -d' ' -f1)
remote_registry_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/.codex/SKILLS_REGISTRY.md\" | cut -d' ' -f1" 2>/dev/null || echo "")
[[ -n "$remote_registry_hash" && "$local_registry_hash" == "$remote_registry_hash" ]] || die "Codex skills registry parity check failed"

for bin_name in "${CODEX_BIN_FILES[@]}"; do
  local_bin_hash=$(shasum -a 256 "$REPO_CODEX_BIN_DIR/$bin_name" | cut -d' ' -f1)
  remote_bin_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/.codex/bin/$bin_name\" | cut -d' ' -f1" 2>/dev/null || echo "")
  [[ -n "$remote_bin_hash" && "$local_bin_hash" == "$remote_bin_hash" ]] || die "Codex bin parity check failed for $bin_name"
done

local_codex_cli=$("$HOME/.local/bin/codex" --version 2>/dev/null || true)
remote_codex_cli=$(ssh "$MINI_HOST" "\"$REMOTE_HOME/.local/bin/codex\" --version" 2>/dev/null || true)
[[ -n "$local_codex_cli" ]] || die "Local Codex CLI entrypoint is not usable"
[[ -n "$remote_codex_cli" ]] || die "Mini Codex CLI entrypoint is not usable"
if version_needs_update "$local_codex_cli" "$SUPPORTED_CODEX_CLI_VERSION"; then
  die "Local Codex CLI entrypoint is older than current supported version $SUPPORTED_CODEX_CLI_VERSION: $local_codex_cli"
fi
if version_needs_update "$remote_codex_cli" "$SUPPORTED_CODEX_CLI_VERSION"; then
  die "Mini Codex CLI entrypoint is older than current supported version $SUPPORTED_CODEX_CLI_VERSION: $remote_codex_cli"
fi

LOCAL_CONFIG_HASH_AFTER=$(hash_path "$LOCAL_CODEX_CONFIG")
REMOTE_CONFIG_HASH_AFTER=$(ssh "$MINI_HOST" "if [ -f \"$REMOTE_HOME/.codex/config.toml\" ]; then shasum -a 256 \"$REMOTE_HOME/.codex/config.toml\" | cut -d' ' -f1; else printf MISSING; fi")
[[ "$LOCAL_CONFIG_HASH_BEFORE" == "$LOCAL_CONFIG_HASH_AFTER" ]] || die "Local host-managed Codex config changed during sync"
[[ "$REMOTE_CONFIG_HASH_BEFORE" == "$REMOTE_CONFIG_HASH_AFTER" ]] || die "Peer host-managed Codex config changed during sync"

skills_dry_run=$(rsync -a --checksum --dry-run "$LOCAL_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.codex/skills/" 2>/dev/null || true)
if [[ -n "${skills_dry_run//[[:space:]]/}" ]]; then
  echo "$skills_dry_run" >&2
  die "Codex skills parity check failed"
fi

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  agents_skills_dry_run=$(rsync -a --checksum --dry-run "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/" 2>/dev/null || true)
  if [[ -n "${agents_skills_dry_run//[[:space:]]/}" ]]; then
    echo "$agents_skills_dry_run" >&2
    die "Shared agent skills parity check failed"
  fi
fi

if [[ "$RESTART_CODEX" -eq 1 ]]; then
  log "Restarting Codex on $MINI_HOST to reload the control-plane profile..."
  ssh "$MINI_HOST" 'pkill -f "/Applications/Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 || true; sleep 1; open -ga Codex'
  sleep 3
fi

log ""
log "Done. Shared skills, helpers, and repo-owned control-plane files are synchronized."
log "Host-managed Codex config files were hashed and verified unchanged."
log "File-backed memories use the separate conflict-preserving sync-memory-mini.sh lane."
log "Automation records were not inspected or changed; use automation_update for production mutations."
