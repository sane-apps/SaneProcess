#!/usr/bin/env bash
set -euo pipefail

# Safe test-mode switcher for SaneApps.
# - Never uses `security` keychain CLI.
# - Defaults to no-keychain launch path to avoid prompt floods.
# - Supports local and mini hosts.

APPS=(SaneBar SaneClip SaneClick SaneHosts SaneSales SaneSync SaneVideo)

HOST="local"
LAUNCH=0
REMOTE_INVOKE=0
KEEP_DUPLICATES=0
ALLOW_KEYCHAIN=0
ALLOW_UNSIGNED_INSTALL=0
ALLOW_DEVELOPMENT_SIGNATURE=0
VERIFY_LIVE=1
LIVE_VERIFY_SECONDS=30
LIVE_VERIFY_INTERVAL=5
RUN_SANEBAR_SMOKE=0

usage() {
  cat <<'USAGE'
Usage:
  app_test_mode.sh list [--host local|mini]
  app_test_mode.sh <app> status [--host local|mini]
  app_test_mode.sh <app> owner-check [--host local|mini]
  app_test_mode.sh <app> owner-install [--host local|mini]
  app_test_mode.sh <app> owner-pro [--host local|mini]
  app_test_mode.sh <app> owner-verify [--launch] [--host local|mini]
  app_test_mode.sh <app> <basic|free|pro> [--launch] [--host local|mini] [--keep-duplicates] [--allow-keychain]
    [--allow-unsigned-install] [--allow-development-signature]
    [--no-live-verify] [--live-seconds N] [--smoke]

Examples:
  app_test_mode.sh SaneBar basic --launch
  app_test_mode.sh SaneClick free --host mini --launch
  app_test_mode.sh SaneHosts pro --host local
  app_test_mode.sh SaneSales status --host mini
  app_test_mode.sh SaneClip owner-check
  app_test_mode.sh SaneClip owner-install
  app_test_mode.sh SaneClip owner-pro
  app_test_mode.sh SaneClip owner-verify --launch

Notes:
  - `free` and `basic` are the same mode.
  - Default launch is no-keychain (`SANEAPPS_DISABLE_KEYCHAIN=1` + `--sane-no-keychain`).
  - Use `--allow-keychain` only when you explicitly want real keychain behavior.
  - Runtime launches require a signed canonical install by default (stable TCC identity).
  - Use `--allow-unsigned-install` only for explicit debug investigations.
  - Local SaneBar launches require Developer ID signing by default; use
    `--allow-development-signature` only for explicit source-debug sessions.
  - Launches run a live-process check by default (`--live-seconds`, default: 30s).
  - Launch prints a warning if installed app binary looks older than local repo sources.
  - `--smoke` (SaneBar only) runs scripts/live_zone_smoke.rb for non-drag move + layout checks.
USAGE
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_known_app() {
  local needle="$1"
  for app in "${APPS[@]}"; do
    if [[ "$app" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

local_bundle_path() {
  local app="$1"
  local sys_app="/Applications/${app}.app"

  if [[ -d "$sys_app" ]]; then
    echo "$sys_app"
  else
    echo "$sys_app"
  fi
}

remote_bundle_path() {
  local app="$1"
  echo "/Applications/${app}.app"
}

fallback_bundle_id() {
  local app="$1"
  case "$app" in
    SaneBar) echo "com.sanebar.app" ;;
    SaneClick) echo "com.saneclick.SaneClick" ;;
    SaneClip) echo "com.saneclip.app" ;;
    SaneHosts) echo "com.mrsane.SaneHosts" ;;
    SaneSales) echo "com.sanesales.app" ;;
    SaneSync) echo "com.sanesync.SaneSync" ;;
    SaneVideo) echo "com.sanevideo.app" ;;
    *) echo "com.saneapps.$(to_lower "$app")" ;;
  esac
}

local_bundle_identifier() {
  local app="$1"
  local bundle info_plist id
  bundle="$(local_bundle_path "$app")"
  info_plist="$bundle/Contents/Info.plist"

  if [[ -f "$info_plist" ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      echo "$id"
      return 0
    fi
  fi

  fallback_bundle_id "$app"
}

remote_bundle_identifier() {
  local app="$1"
  local bundle id
  bundle="$(remote_bundle_path "$app")"
  id="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "APP=\"$bundle\"/Contents/Info.plist; /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"\$APP\" 2>/dev/null" || true)"
  if [[ -n "$id" ]]; then
    echo "$id"
  else
    fallback_bundle_id "$app"
  fi
}

bundle_identifier() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    remote_bundle_identifier "$app"
  else
    local_bundle_identifier "$app"
  fi
}

license_key_name() {
  local app="$1"
  if [[ "$app" == "SaneBar" ]]; then
    echo "pro_license_key"
  else
    echo "license_key"
  fi
}

license_date_name() {
  local app="$1"
  if [[ "$app" == "SaneBar" ]]; then
    echo "pro_last_validation"
  else
    echo "last_validation"
  fi
}

license_email_name() {
  local app="$1"
  if [[ "$app" == "SaneBar" ]]; then
    echo "pro_license_email"
  else
    echo "license_email"
  fi
}

keychain_service_name() {
  bundle_identifier "$1"
}

defaults_domain_for_app() {
  local app="$1"
  local bundle_id
  bundle_id="$(bundle_identifier "$app")"
  echo "${bundle_id}"
}

legacy_defaults_domain_for_app() {
  local app="$1"
  local bundle_id
  bundle_id="$(bundle_identifier "$app")"
  echo "${bundle_id}.no-keychain"
}

defaults_plist_path_for_domain() {
  local domain="$1"
  echo "$HOME/Library/Preferences/${domain}.plist"
}

swift_keychain_upsert_script() {
  cat <<'SWIFT'
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let service = env["APP_TEST_SERVICE"] ?? ""
let lastValidation = env["APP_TEST_LAST_VALIDATION"] ?? ""
let keyName = env["APP_TEST_LICENSE_KEY_NAME"] ?? "license_key"
let keyValue = env["APP_TEST_LICENSE_KEY_VALUE"] ?? ""
let emailName = env["APP_TEST_LICENSE_EMAIL_NAME"] ?? "license_email"
let emailValue = env["APP_TEST_LICENSE_EMAIL_VALUE"] ?? ""
let dateName = env["APP_TEST_LICENSE_DATE_NAME"] ?? "last_validation"

guard !service.isEmpty else {
    fputs("missing APP_TEST_SERVICE\n", stderr)
    exit(1)
}

func upsert(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account
    ]
    let attrs: [CFString: Any] = [
        kSecValueData: data,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
    ]
    let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    } else if status != errSecSuccess {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

do {
    try upsert(keyValue, account: keyName)
    if !emailValue.isEmpty {
        try upsert(emailValue, account: emailName)
    }
    try upsert(lastValidation, account: dateName)
} catch {
    fputs("keychain upsert failed: \(error)\n", stderr)
    exit(1)
}
SWIFT
}

swift_keychain_delete_script() {
  cat <<'SWIFT'
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let service = env["APP_TEST_SERVICE"] ?? ""
let keyName = env["APP_TEST_LICENSE_KEY_NAME"] ?? "license_key"
let emailName = env["APP_TEST_LICENSE_EMAIL_NAME"] ?? "license_email"
let dateName = env["APP_TEST_LICENSE_DATE_NAME"] ?? "last_validation"

guard !service.isEmpty else {
    fputs("missing APP_TEST_SERVICE\n", stderr)
    exit(1)
}

func delete(_ account: String) {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
        fputs("keychain delete failed for \(account): \(status)\n", stderr)
        exit(1)
    }
}

delete(keyName)
delete(emailName)
delete(dateName)
SWIFT
}

swift_keychain_read_script() {
  cat <<'SWIFT'
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let service = env["APP_TEST_SERVICE"] ?? ""
let keyName = env["APP_TEST_LICENSE_KEY_NAME"] ?? "license_key"
let emailName = env["APP_TEST_LICENSE_EMAIL_NAME"] ?? "license_email"
let dateName = env["APP_TEST_LICENSE_DATE_NAME"] ?? "last_validation"

guard !service.isEmpty else {
    fputs("missing APP_TEST_SERVICE\n", stderr)
    exit(1)
}

func read(_ account: String) -> String {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
        return "__STATUS__:\(status)"
    }
    return value
}

print("license_key=\(read(keyName))")
print("license_email=\(read(emailName))")
print("last_validation=\(read(dateName))")
SWIFT
}

run_keychain_swift_local() {
  local script="$1"
  shift
  env "$@" swift - >/dev/null 2>&1 <<SWIFT
$(printf '%s\n' "$script")
SWIFT
}

run_keychain_swift_remote() {
  local script="$1"
  shift
  local env_cmd=""
  local pair
  for pair in "$@"; do
    env_cmd+=" $(printf '%q' "$pair")"
  done
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "env$env_cmd swift - >/dev/null 2>&1" <<SWIFT
$(printf '%s\n' "$script")
SWIFT
}

read_keychain_state_local() {
  local service="$1"
  local key_name="$2"
  local email_name="$3"
  local date_name="$4"

  env \
    APP_TEST_SERVICE="$service" \
    APP_TEST_LICENSE_KEY_NAME="$key_name" \
    APP_TEST_LICENSE_EMAIL_NAME="$email_name" \
    APP_TEST_LICENSE_DATE_NAME="$date_name" \
    swift - <<'SWIFT'
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let service = env["APP_TEST_SERVICE"] ?? ""
let keyName = env["APP_TEST_LICENSE_KEY_NAME"] ?? "license_key"
let emailName = env["APP_TEST_LICENSE_EMAIL_NAME"] ?? "license_email"
let dateName = env["APP_TEST_LICENSE_DATE_NAME"] ?? "last_validation"

func read(_ account: String) -> String {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
        return "__STATUS__:\(status)"
    }
    return value
}

print("license_key=\(read(keyName))")
print("license_email=\(read(emailName))")
print("last_validation=\(read(dateName))")
SWIFT
}

read_keychain_state_remote() {
  local service="$1"
  local key_name="$2"
  local email_name="$3"
  local date_name="$4"

  ssh -o ConnectTimeout=5 -o BatchMode=yes mini \
    "env APP_TEST_SERVICE=$(printf '%q' "$service") APP_TEST_LICENSE_KEY_NAME=$(printf '%q' "$key_name") APP_TEST_LICENSE_EMAIL_NAME=$(printf '%q' "$email_name") APP_TEST_LICENSE_DATE_NAME=$(printf '%q' "$date_name") swift -" <<'SWIFT'
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let service = env["APP_TEST_SERVICE"] ?? ""
let keyName = env["APP_TEST_LICENSE_KEY_NAME"] ?? "license_key"
let emailName = env["APP_TEST_LICENSE_EMAIL_NAME"] ?? "license_email"
let dateName = env["APP_TEST_LICENSE_DATE_NAME"] ?? "last_validation"

func read(_ account: String) -> String {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
        return "__STATUS__:\(status)"
    }
    return value
}

print("license_key=\(read(keyName))")
print("license_email=\(read(emailName))")
print("last_validation=\(read(dateName))")
SWIFT
}

defaults_fallback_key() {
  local app="$1"
  local logical_key="$2"
  local bundle_id
  bundle_id="$(bundle_identifier "$app")"
  echo "sane.no-keychain.${bundle_id}.${logical_key}"
}

remove_login_item_local() {
  local app="$1"
  osascript -e "tell application \"System Events\" to if exists login item \"${app}\" then delete login item \"${app}\"" >/dev/null 2>&1 || true
}

remove_login_item_remote() {
  local app="$1"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "osascript -e 'tell application \"System Events\" to if exists login item \"${app}\" then delete login item \"${app}\"' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

ensure_single_install_local() {
  local app="$1"
  local canonical="$2"
  local candidates=(
    "/Applications/${app}.app"
    "/tmp/saneapps-staging.noindex/${app}.app"
    "/tmp/${app}.app"
  )

  for path in "${candidates[@]}"; do
    [[ -d "$path" ]] || continue
    [[ "$path" == "$canonical" ]] && continue
    if [[ "$KEEP_DUPLICATES" -eq 0 ]]; then
      local trash_dir="$HOME/.Trash"
      local base_name target
      base_name="$(basename "$path")"
      target="$trash_dir/$base_name"
      mkdir -p "$trash_dir"
      if [[ -e "$target" ]]; then
        target="$trash_dir/${base_name%.app}-$(date +%Y%m%d-%H%M%S)-$$.app"
      fi
      if mv "$path" "$target" 2>/dev/null; then
        echo "moved duplicate to Trash: $target"
      else
        echo "warning: failed to move duplicate to Trash: $path"
      fi
    fi
  done
}

ensure_single_install_remote() {
  local app="$1"
  local canonical="$2"
  local script
script=$(cat <<REMOTE
APP="$app"
CANONICAL="$canonical"
KEEP="$KEEP_DUPLICATES"
for path in "/Applications/\${APP}.app" "/tmp/saneapps-staging.noindex/\${APP}.app" "/tmp/\${APP}.app"; do
  [ -d "\$path" ] || continue
  [ "\$path" = "\$CANONICAL" ] && continue
  if [ "\$KEEP" = "0" ]; then
    trash_dir="\$HOME/.Trash"
    base_name=\$(basename "\$path")
    target="\$trash_dir/\$base_name"
    mkdir -p "\$trash_dir"
    if [ -e "\$target" ]; then
      target="\$trash_dir/\${base_name%.app}-\$(date +%Y%m%d-%H%M%S)-\$\$.app"
    fi
    if mv "\$path" "\$target" 2>/dev/null; then
      echo "moved duplicate to Trash: \$target"
    else
      echo "warning: failed to move duplicate to Trash: \$path"
    fi
  fi
done
REMOTE
)
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "$script"
}

latest_repo_source_epoch_local() {
  local app="$1"
  local repo="$HOME/SaneApps/apps/$app"
  if [[ ! -d "$repo" ]]; then
    echo ""
    return 0
  fi

  find "$repo" -type f \( \
    -name '*.swift' -o \
    -name '*.m' -o \
    -name '*.mm' -o \
    -name '*.h' -o \
    -name '*.plist' -o \
    -name '*.xcconfig' -o \
    -name 'project.yml' -o \
    -name 'Package.swift' -o \
    -path '*/project.pbxproj' \
  \) \
    ! -path '*/Tests/*' \
    ! -path '*/UITests/*' \
    ! -path '*/Scripts/*' \
    ! -path '*/docs/*' \
    ! -path '*/.claude/*' \
    -exec stat -f '%m' {} + 2>/dev/null | sort -nr | head -n 1
}

check_stale_install_local() {
  local app="$1"
  local bundle="$2"
  local binary="$bundle/Contents/MacOS/$app"
  local source_epoch binary_epoch source_ts binary_ts

  [[ -x "$binary" ]] || return 0

  source_epoch="$(latest_repo_source_epoch_local "$app")"
  [[ -n "$source_epoch" ]] || return 0
  binary_epoch="$(stat -f '%m' "$binary" 2>/dev/null || echo 0)"

  if [[ "$source_epoch" -gt "$binary_epoch" ]]; then
    source_ts="$(date -r "$source_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$source_epoch")"
    binary_ts="$(date -r "$binary_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$binary_epoch")"
    echo "warning: installed $app binary may be stale vs repo source (binary=$binary_ts, source=$source_ts)"
    echo "warning: recommended refresh: cd \"$HOME/SaneApps/apps/$app\" && ./scripts/SaneMaster.rb launch"
  fi
}

expected_team_id() {
  echo "${APP_TEST_MODE_EXPECTED_TEAM_ID:-M78L6FXD48}"
}

verify_install_identity_local() {
  local app="$1"
  local bundle="$2"
  local expected_bundle actual_bundle sign_output signed_identifier signed_team expected_signing_team
  local authority_lines
  local info_plist="$bundle/Contents/Info.plist"

  expected_bundle="$(fallback_bundle_id "$app")"
  actual_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  if [[ "$actual_bundle" != "$expected_bundle" ]]; then
    echo "error: $app install identity mismatch: expected CFBundleIdentifier '$expected_bundle' but found '$actual_bundle'" >&2
    exit 1
  fi

  sign_output="$(codesign -dv --verbose=2 "$bundle" 2>&1 || true)"
  signed_identifier="$(printf '%s\n' "$sign_output" | sed -n 's/^Identifier=//p' | head -n 1)"
  signed_team="$(printf '%s\n' "$sign_output" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  authority_lines="$(printf '%s\n' "$sign_output" | sed -n 's/^Authority=//p')"
  expected_signing_team="$(expected_team_id)"

  if [[ "$ALLOW_UNSIGNED_INSTALL" -eq 1 ]]; then
    return 0
  fi

  if [[ -z "$signed_team" || "$signed_team" == "not set" ]]; then
    echo "error: $app install is unsigned/ad-hoc (TeamIdentifier missing)." >&2
    echo "error: this causes Accessibility/TCC identity drift and permission loops." >&2
    echo "hint: install a signed $expected_bundle build before launch, or rerun with --allow-unsigned-install for explicit debug only." >&2
    exit 1
  fi

  if [[ "$signed_team" != "$expected_signing_team" ]]; then
    echo "error: $app signing team mismatch: expected '$expected_signing_team' but found '$signed_team'" >&2
    exit 1
  fi

  if [[ "$signed_identifier" != "$expected_bundle" ]]; then
    echo "error: $app code-sign identifier mismatch: expected '$expected_bundle' but found '$signed_identifier'" >&2
    exit 1
  fi

  # On local developer machines, keep SaneBar launches bound to official
  # Developer ID artifacts by default to avoid TCC identity duplication with
  # Apple Development builds staged from source.
  if [[ "$app" == "SaneBar" && "$REMOTE_INVOKE" -eq 0 && "$ALLOW_DEVELOPMENT_SIGNATURE" -eq 0 ]]; then
    if ! printf '%s\n' "$authority_lines" | grep -q '^Developer ID Application:'; then
      echo "error: local $app install is not Developer ID signed." >&2
      echo "error: this can create duplicate Accessibility identities and access loops." >&2
      echo "hint: install the official release app in /Applications, or rerun with --allow-development-signature for explicit source debugging." >&2
      exit 1
    fi
  fi
}

verify_install_identity_remote() {
  local app="$1"
  local bundle="$2"
  local expected_bundle remote_cmd identity_blob actual_bundle signed_identifier signed_team expected_signing_team

  expected_bundle="$(fallback_bundle_id "$app")"
  expected_signing_team="$(expected_team_id)"

  remote_cmd=$(cat <<REMOTE
APP_BUNDLE="$bundle"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
codesign -dv --verbose=2 "\$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=//p; s/^TeamIdentifier=//p'
REMOTE
)

  identity_blob="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "$remote_cmd" || true)"
  actual_bundle="$(printf '%s\n' "$identity_blob" | sed -n '1p')"
  signed_identifier="$(printf '%s\n' "$identity_blob" | sed -n '2p')"
  signed_team="$(printf '%s\n' "$identity_blob" | sed -n '3p')"

  if [[ "$actual_bundle" != "$expected_bundle" ]]; then
    echo "error: $app install identity mismatch on mini: expected CFBundleIdentifier '$expected_bundle' but found '$actual_bundle'" >&2
    exit 1
  fi

  if [[ "$ALLOW_UNSIGNED_INSTALL" -eq 1 ]]; then
    return 0
  fi

  if [[ -z "$signed_team" || "$signed_team" == "not set" ]]; then
    echo "error: $app install on mini is unsigned/ad-hoc (TeamIdentifier missing)." >&2
    echo "error: this causes Accessibility/TCC identity drift and permission loops." >&2
    echo "hint: install a signed $expected_bundle build on mini before launch, or rerun with --allow-unsigned-install for explicit debug only." >&2
    exit 1
  fi

  if [[ "$signed_team" != "$expected_signing_team" ]]; then
    echo "error: $app signing team mismatch on mini: expected '$expected_signing_team' but found '$signed_team'" >&2
    exit 1
  fi

  if [[ "$signed_identifier" != "$expected_bundle" ]]; then
    echo "error: $app code-sign identifier mismatch on mini: expected '$expected_bundle' but found '$signed_identifier'" >&2
    exit 1
  fi
}

cleanup_legacy_accessibility_local() {
  local app="$1"
  local bundle legacy
  bundle="$(fallback_bundle_id "$app")"
  legacy="${bundle%.app}.dev"
  [[ "$legacy" == "$bundle" ]] && return 0
  tccutil reset Accessibility "$legacy" >/dev/null 2>&1 || true
}

cleanup_legacy_accessibility_remote() {
  local app="$1"
  local bundle legacy
  bundle="$(fallback_bundle_id "$app")"
  legacy="${bundle%.app}.dev"
  [[ "$legacy" == "$bundle" ]] && return 0
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "tccutil reset Accessibility '$legacy' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

repair_accessibility_stale_rows_local() {
  local app="$1"
  local bundle="$2"
  local info_plist bundle_id user_db rows_raw stale_row_ids row row_id csreq_hex req_file requirement

  info_plist="$bundle/Contents/Info.plist"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  if [[ -z "$bundle_id" ]]; then
    bundle_id="$(fallback_bundle_id "$app")"
  fi

  user_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  [[ -f "$user_db" ]] || return 0

  rows_raw="$(sqlite3 "$user_db" "SELECT rowid || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='${bundle_id}';" 2>/dev/null || true)"
  [[ -n "$rows_raw" ]] || return 0

  stale_row_ids=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    row_id="${row%%|*}"
    csreq_hex="${row#*|}"
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue

    if [[ -z "$csreq_hex" ]]; then
      stale_row_ids="${stale_row_ids:+${stale_row_ids},}${row_id}"
      continue
    fi

    req_file="$(mktemp "/tmp/saneapps-ax-${app}-XXXXXX.csreq")"
    perl -e 'print pack("H*", shift)' "$csreq_hex" > "$req_file" 2>/dev/null || true
    requirement="$(csreq -r "$req_file" -t 2>/dev/null || true)"
    rm -f "$req_file"

    if [[ -z "$requirement" ]]; then
      stale_row_ids="${stale_row_ids:+${stale_row_ids},}${row_id}"
      continue
    fi

    if ! codesign -R="$requirement" "$bundle" >/dev/null 2>&1; then
      stale_row_ids="${stale_row_ids:+${stale_row_ids},}${row_id}"
    fi
  done <<< "$rows_raw"

  [[ -n "$stale_row_ids" ]] || return 0

  killall tccd >/dev/null 2>&1 || true
  sqlite3 "$user_db" "DELETE FROM access WHERE rowid IN (${stale_row_ids});" >/dev/null 2>&1 || true
  killall tccd >/dev/null 2>&1 || true
  echo "repaired stale Accessibility rows for $bundle_id: $stale_row_ids"
}

repair_accessibility_stale_rows_remote() {
  local app="$1"
  local bundle="$2"
  local app_q bundle_q
  printf -v app_q '%q' "$app"
  printf -v bundle_q '%q' "$bundle"

  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "APP_TEST_APP=${app_q} APP_TEST_BUNDLE=${bundle_q} bash -s" <<'REMOTE'
set -euo pipefail
APP="$APP_TEST_APP"
BUNDLE="$APP_TEST_BUNDLE"
INFO_PLIST="$BUNDLE/Contents/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)
if [ -z "$BUNDLE_ID" ]; then
  case "$APP" in
    SaneBar) BUNDLE_ID="com.sanebar.app" ;;
    SaneClick) BUNDLE_ID="com.saneclick.SaneClick" ;;
    SaneClip) BUNDLE_ID="com.saneclip.app" ;;
    SaneHosts) BUNDLE_ID="com.mrsane.SaneHosts" ;;
    SaneSales) BUNDLE_ID="com.sanesales.app" ;;
    SaneSync) BUNDLE_ID="com.sanesync.SaneSync" ;;
    SaneVideo) BUNDLE_ID="com.sanevideo.app" ;;
    *) BUNDLE_ID="com.saneapps.$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')" ;;
  esac
fi

USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
[ -f "$USER_DB" ] || exit 0

ROWS=$(sqlite3 "$USER_DB" "SELECT rowid || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='${BUNDLE_ID}';" 2>/dev/null || true)
[ -n "$ROWS" ] || exit 0
ROWS_FILE=$(mktemp "/tmp/saneapps-ax-${APP}-rows-XXXXXX.txt")
printf '%s\n' "$ROWS" > "$ROWS_FILE"

STALE_IDS=""
while IFS= read -r ROW; do
  [ -n "$ROW" ] || continue
  ROW_ID=${ROW%%|*}
  CSREQ_HEX=${ROW#*|}
  printf '%s' "$ROW_ID" | grep -Eq '^[0-9]+$' || continue

  if [ -z "$CSREQ_HEX" ]; then
    if [ -n "$STALE_IDS" ]; then STALE_IDS="$STALE_IDS,$ROW_ID"; else STALE_IDS="$ROW_ID"; fi
    continue
  fi

  REQ_FILE=$(mktemp "/tmp/saneapps-ax-${APP}-XXXXXX.csreq")
  perl -e 'print pack("H*", shift)' "$CSREQ_HEX" > "$REQ_FILE" 2>/dev/null || true
  REQUIREMENT=$(csreq -r "$REQ_FILE" -t 2>/dev/null || true)
  rm -f "$REQ_FILE"

  if [ -z "$REQUIREMENT" ]; then
    if [ -n "$STALE_IDS" ]; then STALE_IDS="$STALE_IDS,$ROW_ID"; else STALE_IDS="$ROW_ID"; fi
    continue
  fi

  if ! codesign -R="$REQUIREMENT" "$BUNDLE" >/dev/null 2>&1; then
    if [ -n "$STALE_IDS" ]; then STALE_IDS="$STALE_IDS,$ROW_ID"; else STALE_IDS="$ROW_ID"; fi
  fi
done < "$ROWS_FILE"
rm -f "$ROWS_FILE"

[ -n "$STALE_IDS" ] || exit 0
killall tccd >/dev/null 2>&1 || true
sqlite3 "$USER_DB" "DELETE FROM access WHERE rowid IN (${STALE_IDS});" >/dev/null 2>&1 || true
killall tccd >/dev/null 2>&1 || true
echo "repaired stale Accessibility rows for $BUNDLE_ID: $STALE_IDS"
REMOTE
}

set_app_mode_local() {
  local app="$1"
  local mode="$2"
  local domain legacy_domain domain_plist legacy_plist key_name date_name email_name key_key key_date key_email pro_value

  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  domain_plist="$(defaults_plist_path_for_domain "$domain")"
  legacy_plist="$(defaults_plist_path_for_domain "$legacy_domain")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"
  key_date="$(defaults_fallback_key "$app" "$date_name")"
  key_email="$(defaults_fallback_key "$app" "$email_name")"

  if [[ "$app" == "SaneBar" ]]; then
    pro_value="early-adopter"
  else
    pro_value="test-pro"
  fi

  case "$mode" in
    pro)
      defaults write "$domain" "$key_key" -string "$pro_value"
      defaults write "$domain_plist" "$key_key" -string "$pro_value"
      defaults write "$domain" "$key_date" -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      defaults write "$domain_plist" "$key_date" -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [[ "$app" != "SaneBar" ]]; then
        defaults write "$domain" "$key_email" -string "test@saneapps.local"
        defaults write "$domain_plist" "$key_email" -string "test@saneapps.local"
      fi
      defaults delete "$legacy_domain" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$legacy_domain" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$legacy_domain" "$key_email" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_email" >/dev/null 2>&1 || true
      ;;
    basic)
      defaults delete "$domain" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$domain_plist" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$domain" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$domain_plist" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$domain" "$key_email" >/dev/null 2>&1 || true
      defaults delete "$domain_plist" "$key_email" >/dev/null 2>&1 || true
      defaults delete "$legacy_domain" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_key" >/dev/null 2>&1 || true
      defaults delete "$legacy_domain" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_date" >/dev/null 2>&1 || true
      defaults delete "$legacy_domain" "$key_email" >/dev/null 2>&1 || true
      defaults delete "$legacy_plist" "$key_email" >/dev/null 2>&1 || true
      ;;
    *)
      echo "error: unsupported mode '$mode' (expected 'pro' or 'basic')" >&2
      exit 1
      ;;
  esac
}

set_app_mode_keychain_local() {
  local app="$1"
  local mode="$2"
  local service key_name date_name email_name pro_value now email_value

  service="$(keychain_service_name "$app")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$app" == "SaneBar" ]]; then
    pro_value="early-adopter"
    email_value=""
  else
    pro_value="test-pro"
    email_value="test@saneapps.local"
  fi

  case "$mode" in
    pro)
      run_keychain_swift_local "$(swift_keychain_upsert_script)" \
        APP_TEST_SERVICE="$service" \
        APP_TEST_LICENSE_KEY_NAME="$key_name" \
        APP_TEST_LICENSE_KEY_VALUE="$pro_value" \
        APP_TEST_LICENSE_EMAIL_NAME="$email_name" \
        APP_TEST_LICENSE_EMAIL_VALUE="$email_value" \
        APP_TEST_LICENSE_DATE_NAME="$date_name" \
        APP_TEST_LAST_VALIDATION="$now"
      ;;
    basic)
      run_keychain_swift_local "$(swift_keychain_delete_script)" \
        APP_TEST_SERVICE="$service" \
        APP_TEST_LICENSE_KEY_NAME="$key_name" \
        APP_TEST_LICENSE_EMAIL_NAME="$email_name" \
        APP_TEST_LICENSE_DATE_NAME="$date_name"
      ;;
    *)
      echo "error: unsupported keychain mode '$mode' (expected 'pro' or 'basic')" >&2
      exit 1
      ;;
  esac
}

set_app_mode_remote() {
  local app="$1"
  local mode="$2"
  local domain legacy_domain domain_plist legacy_plist key_name date_name email_name key_key key_date key_email pro_value now

  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  domain_plist="$(defaults_plist_path_for_domain "$domain")"
  legacy_plist="$(defaults_plist_path_for_domain "$legacy_domain")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"
  key_date="$(defaults_fallback_key "$app" "$date_name")"
  key_email="$(defaults_fallback_key "$app" "$email_name")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$app" == "SaneBar" ]]; then
    pro_value="early-adopter"
  else
    pro_value="test-pro"
  fi

  case "$mode" in
    pro)
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain' '$key_key' -string '$pro_value'"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain_plist' '$key_key' -string '$pro_value'"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain' '$key_date' -string '$now'"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain_plist' '$key_date' -string '$now'"
      if [[ "$app" != "SaneBar" ]]; then
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain' '$key_email' -string 'test@saneapps.local'"
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults write '$domain_plist' '$key_email' -string 'test@saneapps.local'"
      fi
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_email' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_email' >/dev/null 2>&1 || true"
      ;;
    basic)
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain_plist' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain_plist' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain' '$key_email' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$domain_plist' '$key_email' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_key' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_date' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_domain' '$key_email' >/dev/null 2>&1 || true"
      ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults delete '$legacy_plist' '$key_email' >/dev/null 2>&1 || true"
      ;;
    *)
      echo "error: unsupported mode '$mode' (expected 'pro' or 'basic')" >&2
      exit 1
      ;;
  esac
}

set_app_mode_keychain_remote() {
  local app="$1"
  local mode="$2"
  local service key_name date_name email_name pro_value now email_value

  service="$(keychain_service_name "$app")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$app" == "SaneBar" ]]; then
    pro_value="early-adopter"
    email_value=""
  else
    pro_value="test-pro"
    email_value="test@saneapps.local"
  fi

  case "$mode" in
    pro)
      run_keychain_swift_remote "$(swift_keychain_upsert_script)" \
        APP_TEST_SERVICE="$service" \
        APP_TEST_LICENSE_KEY_NAME="$key_name" \
        APP_TEST_LICENSE_KEY_VALUE="$pro_value" \
        APP_TEST_LICENSE_EMAIL_NAME="$email_name" \
        APP_TEST_LICENSE_EMAIL_VALUE="$email_value" \
        APP_TEST_LICENSE_DATE_NAME="$date_name" \
        APP_TEST_LAST_VALIDATION="$now"
      ;;
    basic)
      run_keychain_swift_remote "$(swift_keychain_delete_script)" \
        APP_TEST_SERVICE="$service" \
        APP_TEST_LICENSE_KEY_NAME="$key_name" \
        APP_TEST_LICENSE_EMAIL_NAME="$email_name" \
        APP_TEST_LICENSE_DATE_NAME="$date_name"
      ;;
    *)
      echo "error: unsupported keychain mode '$mode' (expected 'pro' or 'basic')" >&2
      exit 1
      ;;
  esac
}

app_status_local() {
  local app="$1"
  local domain legacy_domain key_name key_key current

  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  key_name="$(license_key_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"

  current="$(defaults read "$domain" "$key_key" 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    current="$(defaults read "$legacy_domain" "$key_key" 2>/dev/null || true)"
  fi
  if [[ -n "$current" ]]; then
    echo "$app mode: pro (no-keychain fallback)"
  else
    echo "$app mode: basic (no-keychain fallback)"
  fi
}

app_status_remote() {
  local app="$1"
  local domain legacy_domain key_name key_key current

  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  key_name="$(license_key_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"

  current="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults read '$domain' '$key_key' 2>/dev/null || true")"
  if [[ -z "$current" ]]; then
    current="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults read '$legacy_domain' '$key_key' 2>/dev/null || true")"
  fi
  if [[ -n "$current" ]]; then
    echo "$app mode: pro (no-keychain fallback)"
  else
    echo "$app mode: basic (no-keychain fallback)"
  fi
}

print_duplicate_paths_local() {
  local app="$1"
  local canonical="$2"
  local found=0
  local path
  for path in "/Applications/${app}.app" "/tmp/saneapps-staging.noindex/${app}.app" "/tmp/${app}.app"; do
    [[ -d "$path" ]] || continue
    [[ "$path" == "$canonical" ]] && continue
    echo "  - $path"
    found=1
  done
  if [[ "$found" -eq 0 ]]; then
    echo "  - none"
  fi
}

print_running_processes_local() {
  local app="$1"
  local matches
  matches="$(ps ax -o pid= -o command= | grep "/${app}\.app/Contents/MacOS/${app}" | grep -v grep || true)"
  if [[ -n "$matches" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "  - $line"
    done <<< "$matches"
  else
    echo "  - none"
  fi
}

app_owner_check_local() {
  local app="$1"
  local bundle info_plist expected_bundle actual_bundle sign_output signed_identifier signed_team
  local entitlements cloudkit_status app_group_status login_item domain legacy_domain key_name key_key fallback_mode
  local keychain_service date_name email_name keychain_blob keychain_license keychain_email keychain_date keychain_status
  local prod_rows legacy_rows legacy_bundle

  bundle="$(local_bundle_path "$app")"
  expected_bundle="$(fallback_bundle_id "$app")"
  legacy_bundle="${expected_bundle%.app}.dev"
  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"
  keychain_service="$(keychain_service_name "$app")"
  fallback_mode="basic"
  if [[ -n "$(defaults read "$domain" "$key_key" 2>/dev/null || true)" || -n "$(defaults read "$legacy_domain" "$key_key" 2>/dev/null || true)" ]]; then
    fallback_mode="pro"
  fi
  keychain_blob="$(read_keychain_state_local "$keychain_service" "$key_name" "$email_name" "$date_name")"
  keychain_license="$(printf '%s\n' "$keychain_blob" | sed -n 's/^license_key=//p' | head -n 1)"
  keychain_email="$(printf '%s\n' "$keychain_blob" | sed -n 's/^license_email=//p' | head -n 1)"
  keychain_date="$(printf '%s\n' "$keychain_blob" | sed -n 's/^last_validation=//p' | head -n 1)"
  keychain_status="absent"
  if [[ -n "$keychain_license" && "$keychain_license" != __STATUS__:* ]]; then
    keychain_status="present"
  elif [[ "$keychain_license" == __STATUS__:* || "$keychain_email" == __STATUS__:* || "$keychain_date" == __STATUS__:* ]]; then
    keychain_status="error"
  fi

  echo "$app owner check (host=$(display_host))"
  echo "canonical path: $bundle"
  echo "expected bundle id: $expected_bundle"
  echo "fallback no-keychain mode: $fallback_mode"
  echo "keychain license: $keychain_status"
  if [[ "$keychain_status" == "present" ]]; then
    echo "keychain email: ${keychain_email:-unknown}"
    echo "last validation: ${keychain_date:-unknown}"
  fi

  if [[ -d "$bundle" ]]; then
    info_plist="$bundle/Contents/Info.plist"
    actual_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
    sign_output="$(codesign -dv --verbose=2 "$bundle" 2>&1 || true)"
    signed_identifier="$(printf '%s\n' "$sign_output" | sed -n 's/^Identifier=//p' | head -n 1)"
    signed_team="$(printf '%s\n' "$sign_output" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null || true)"
    cloudkit_status="no"
    if printf '%s\n' "$entitlements" | grep -q "iCloud.com.saneclip.app"; then
      cloudkit_status="yes"
    fi
    app_group_status="no"
    if printf '%s\n' "$entitlements" | grep -q "group.com.saneclip.app"; then
      app_group_status="yes"
    fi

    echo "installed: yes"
    echo "bundle id: ${actual_bundle:-unknown}"
    echo "signed identifier: ${signed_identifier:-missing}"
    echo "signed team: ${signed_team:-missing}"
    echo "cloudkit entitlement: $cloudkit_status"
    echo "app group entitlement: $app_group_status"
  else
    echo "installed: no"
  fi

  echo "duplicate installs:"
  print_duplicate_paths_local "$app" "$bundle"

  echo "running processes:"
  print_running_processes_local "$app"

  if osascript -e "tell application \"System Events\" to exists login item \"$app\"" 2>/dev/null | grep -q "true"; then
    login_item="present"
  else
    login_item="absent"
  fi
  echo "login item: $login_item"

  prod_rows="$(sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "SELECT COUNT(*) FROM access WHERE service='kTCCServiceAccessibility' AND client='${expected_bundle}';" 2>/dev/null || echo "0")"
  legacy_rows="$(sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "SELECT COUNT(*) FROM access WHERE service='kTCCServiceAccessibility' AND client='${legacy_bundle}';" 2>/dev/null || echo "0")"
  echo "accessibility rows:"
  echo "  - ${expected_bundle}: ${prod_rows:-0}"
  if [[ "$legacy_bundle" != "$expected_bundle" ]]; then
    echo "  - ${legacy_bundle}: ${legacy_rows:-0}"
  fi

  if [[ -d "$bundle" ]]; then
    check_stale_install_local "$app" "$bundle"
  fi
}

app_owner_check_remote() {
  local app="$1"
  local bundle expected_bundle legacy_bundle sign_output signed_identifier signed_team entitlements
  local domain legacy_domain key_name key_key fallback_mode keychain_service date_name email_name keychain_blob keychain_license keychain_email keychain_date keychain_status

  bundle="$(remote_bundle_path "$app")"
  expected_bundle="$(fallback_bundle_id "$app")"
  legacy_bundle="${expected_bundle%.app}.dev"
  domain="$(defaults_domain_for_app "$app")"
  legacy_domain="$(legacy_defaults_domain_for_app "$app")"
  key_name="$(license_key_name "$app")"
  date_name="$(license_date_name "$app")"
  email_name="$(license_email_name "$app")"
  key_key="$(defaults_fallback_key "$app" "$key_name")"
  keychain_service="$(keychain_service_name "$app")"
  fallback_mode="basic"
  if [[ -n "$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults read '$domain' '$key_key' 2>/dev/null || true")" || -n "$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "defaults read '$legacy_domain' '$key_key' 2>/dev/null || true")" ]]; then
    fallback_mode="pro"
  fi
  keychain_blob="$(read_keychain_state_remote "$keychain_service" "$key_name" "$email_name" "$date_name")"
  keychain_license="$(printf '%s\n' "$keychain_blob" | sed -n 's/^license_key=//p' | head -n 1)"
  keychain_email="$(printf '%s\n' "$keychain_blob" | sed -n 's/^license_email=//p' | head -n 1)"
  keychain_date="$(printf '%s\n' "$keychain_blob" | sed -n 's/^last_validation=//p' | head -n 1)"
  keychain_status="absent"
  if [[ -n "$keychain_license" && "$keychain_license" != __STATUS__:* ]]; then
    keychain_status="present"
  elif [[ "$keychain_license" == __STATUS__:* || "$keychain_email" == __STATUS__:* || "$keychain_date" == __STATUS__:* ]]; then
    keychain_status="error"
  fi

  echo "$app owner check (host=$(display_host))"
  echo "canonical path: $bundle"
  echo "expected bundle id: $expected_bundle"
  echo "fallback no-keychain mode: $fallback_mode"
  echo "keychain license: $keychain_status"
  if [[ "$keychain_status" == "present" ]]; then
    echo "keychain email: ${keychain_email:-unknown}"
    echo "last validation: ${keychain_date:-unknown}"
  fi

  if ssh -o ConnectTimeout=5 -o BatchMode=yes mini "[ -d '$bundle' ]" >/dev/null 2>&1; then
    sign_output="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "codesign -dv --verbose=2 '$bundle' 2>&1" || true)"
    signed_identifier="$(printf '%s\n' "$sign_output" | sed -n 's/^Identifier=//p' | head -n 1)"
    signed_team="$(printf '%s\n' "$sign_output" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    entitlements="$(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "codesign -d --entitlements :- '$bundle' 2>/dev/null" || true)"
    echo "installed: yes"
    echo "bundle id: $(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$bundle/Contents/Info.plist' 2>/dev/null || true")"
    echo "signed identifier: ${signed_identifier:-missing}"
    echo "signed team: ${signed_team:-missing}"
    if printf '%s\n' "$entitlements" | grep -q "iCloud.com.saneclip.app"; then
      echo "cloudkit entitlement: yes"
    else
      echo "cloudkit entitlement: no"
    fi
  else
    echo "installed: no"
  fi

  echo "duplicate installs:"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "for path in '/Applications/${app}.app' '/tmp/saneapps-staging.noindex/${app}.app' '/tmp/${app}.app'; do [ -d \"\$path\" ] || continue; [ \"\$path\" = '$bundle' ] && continue; echo \"  - \$path\"; done" || true

  echo "running processes:"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "ps ax -o pid= -o command= | grep '/${app}.app/Contents/MacOS/${app}' | grep -v grep || echo '  - none'" || true

  if ssh -o ConnectTimeout=5 -o BatchMode=yes mini "osascript -e 'tell application \"System Events\" to exists login item \"${app}\"' 2>/dev/null" | grep -q "true"; then
    echo "login item: present"
  else
    echo "login item: absent"
  fi

  echo "accessibility rows:"
  echo "  - ${expected_bundle}: $(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "sqlite3 \"\$HOME/Library/Application Support/com.apple.TCC/TCC.db\" \"SELECT COUNT(*) FROM access WHERE service='kTCCServiceAccessibility' AND client='${expected_bundle}';\" 2>/dev/null || echo 0")"
  if [[ "$legacy_bundle" != "$expected_bundle" ]]; then
    echo "  - ${legacy_bundle}: $(ssh -o ConnectTimeout=5 -o BatchMode=yes mini "sqlite3 \"\$HOME/Library/Application Support/com.apple.TCC/TCC.db\" \"SELECT COUNT(*) FROM access WHERE service='kTCCServiceAccessibility' AND client='${legacy_bundle}';\" 2>/dev/null || echo 0")"
  fi
}

app_owner_check() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    app_owner_check_remote "$app"
  else
    app_owner_check_local "$app"
  fi
}

owner_install_local() {
  local app="$1"
  local bundle

  bundle="$(local_bundle_path "$app")"
  if [[ ! -d "$bundle" ]]; then
    if ! bootstrap_install_local "$app"; then
      echo "error: app not found at $bundle and bootstrap failed" >&2
      exit 1
    fi
  fi

  bundle="$(local_bundle_path "$app")"
  ensure_single_install_local "$app" "$bundle"
  verify_install_identity_local "$app" "$bundle"
  cleanup_legacy_accessibility_local "$app"
  repair_accessibility_stale_rows_local "$app" "$bundle"
  check_stale_install_local "$app" "$bundle"
  echo "$app owner install prepared (host=$(display_host))"
}

owner_install_remote() {
  local app="$1"
  local bundle

  bundle="$(remote_bundle_path "$app")"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "[ -d \"$bundle\" ]" >/dev/null 2>&1; then
    if ! bootstrap_install_remote "$app"; then
      echo "error: app not found at $bundle on mini and bootstrap failed" >&2
      exit 1
    fi
  fi

  bundle="$(remote_bundle_path "$app")"
  ensure_single_install_remote "$app" "$bundle"
  verify_install_identity_remote "$app" "$bundle"
  cleanup_legacy_accessibility_remote "$app"
  repair_accessibility_stale_rows_remote "$app" "$bundle"
  echo "$app owner install prepared (host=$(display_host))"
}

owner_install() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    owner_install_remote "$app"
  else
    owner_install_local "$app"
  fi
}

owner_pro_local() {
  local app="$1"
  set_app_mode_keychain_local "$app" "pro"
  set_app_mode_local "$app" "pro"
  echo "$app owner Pro seeded (keychain + fallback, host=$(display_host))"
}

owner_pro_remote() {
  local app="$1"
  set_app_mode_keychain_remote "$app" "pro"
  set_app_mode_remote "$app" "pro"
  echo "$app owner Pro seeded (keychain + fallback, host=$(display_host))"
}

owner_pro() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    owner_pro_remote "$app"
  else
    owner_pro_local "$app"
  fi
}

launch_owner_app_local() {
  local app="$1"
  local bundle binary

  bundle="$(local_bundle_path "$app")"
  if [[ ! -d "$bundle" ]]; then
    echo "error: owner launch requires installed app at $bundle" >&2
    exit 1
  fi

  ensure_single_install_local "$app" "$bundle"
  pkill -x "$app" >/dev/null 2>&1 || true

  binary="$bundle/Contents/MacOS/$app"
  if [[ ! -x "$binary" ]]; then
    echo "error: executable not found at $binary" >&2
    exit 1
  fi
  verify_install_identity_local "$app" "$bundle"
  cleanup_legacy_accessibility_local "$app"
  repair_accessibility_stale_rows_local "$app" "$bundle"
  check_stale_install_local "$app" "$bundle"

  open "$bundle"

  sleep 2
  if pgrep -x "$app" >/dev/null 2>&1; then
    echo "$app owner launch succeeded (host=$(display_host))"
    echo "log command: log stream --predicate 'process == \"$app\"' --style compact"
  else
    echo "error: $app owner launch not confirmed after initial check (host=$(display_host))"
    /usr/bin/log show --style compact --last 2m --predicate "process == \"$app\"" | tail -n 120 || true
    exit 1
  fi

  if [[ "$VERIFY_LIVE" -eq 1 ]]; then
    local elapsed=0
    while [[ "$elapsed" -lt "$LIVE_VERIFY_SECONDS" ]]; do
      if ! pgrep -x "$app" >/dev/null 2>&1; then
        echo "error: $app exited during owner live check at t=${elapsed}s (host=$(display_host))"
        /usr/bin/log show --style compact --last 2m --predicate "process == \"$app\"" | tail -n 120 || true
        exit 1
      fi
      sleep "$LIVE_VERIFY_INTERVAL"
      elapsed=$((elapsed + LIVE_VERIFY_INTERVAL))
    done
    echo "$app remained live for ${LIVE_VERIFY_SECONDS}s (host=$(display_host))"
  fi
}

launch_owner_app_remote() {
  local app="$1"
  local bundle binary

  bundle="$(remote_bundle_path "$app")"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "[ -d \"$bundle\" ]" >/dev/null 2>&1; then
    echo "error: owner launch requires installed app at $bundle on mini" >&2
    exit 1
  fi

  ensure_single_install_remote "$app" "$bundle"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pkill -x '$app' >/dev/null 2>&1 || true"

  binary="$bundle/Contents/MacOS/$app"
  verify_install_identity_remote "$app" "$bundle"
  cleanup_legacy_accessibility_remote "$app"
  repair_accessibility_stale_rows_remote "$app" "$bundle"

  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "open '$bundle'"
  sleep 2

  if ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pgrep -x '$app' >/dev/null 2>&1"; then
    echo "$app owner launch succeeded (host=$(display_host))"
    echo "log command: ssh mini \"log stream --predicate 'process == \\\"$app\\\"' --style compact\""
  else
    echo "error: $app owner launch not confirmed after initial check (host=$(display_host))"
    ssh -o ConnectTimeout=5 -o BatchMode=yes mini "/usr/bin/log show --style compact --last 2m --predicate 'process == \"$app\"' | tail -n 120" || true
    exit 1
  fi

  if [[ "$VERIFY_LIVE" -eq 1 ]]; then
    local elapsed=0
    while [[ "$elapsed" -lt "$LIVE_VERIFY_SECONDS" ]]; do
      if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pgrep -x '$app' >/dev/null 2>&1"; then
        echo "error: $app exited during owner live check at t=${elapsed}s (host=$(display_host))"
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "/usr/bin/log show --style compact --last 2m --predicate 'process == \"$app\"' | tail -n 120" || true
        exit 1
      fi
      sleep "$LIVE_VERIFY_INTERVAL"
      elapsed=$((elapsed + LIVE_VERIFY_INTERVAL))
    done
    echo "$app remained live for ${LIVE_VERIFY_SECONDS}s (host=$(display_host))"
  fi
}

launch_owner_app() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    launch_owner_app_remote "$app"
  else
    launch_owner_app_local "$app"
  fi
}

owner_verify() {
  local app="$1"
  owner_install "$app"
  app_owner_check "$app"
  if [[ "$LAUNCH" -eq 1 ]]; then
    launch_owner_app "$app"
  fi
}

bootstrap_install_local() {
  local app="$1"
  local repo="$HOME/SaneApps/apps/$app"

  if [[ ! -d "$repo" ]]; then
    return 1
  fi

  echo "info: $app not installed. Bootstrapping from $repo ..."
  (
    cd "$repo"
    SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs
  ) >/tmp/"$(to_lower "$app")"-bootstrap.log 2>&1
}

bootstrap_install_remote() {
  local app="$1"
  local remote_repo="\$HOME/SaneApps/apps/$app"
  local remote_cmd

  remote_cmd=$(cat <<REMOTE
set -e
repo="$remote_repo"
if [ ! -d "\$repo" ]; then
  exit 1
fi
cd "\$repo"
SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs >/tmp/$(to_lower "$app")-bootstrap.log 2>&1
REMOTE
)

  echo "info: $app not installed on mini. Bootstrapping from \$HOME/SaneApps/apps/$app ..."
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "$remote_cmd"
}

launch_app_local() {
  local app="$1"
  local mode="$2"
  local bundle binary

  bundle="$(local_bundle_path "$app")"
  if [[ ! -d "$bundle" ]]; then
    if ! bootstrap_install_local "$app"; then
      echo "error: app not found at $bundle and bootstrap failed" >&2
      exit 1
    fi
    bundle="$(local_bundle_path "$app")"
    if [[ ! -d "$bundle" ]]; then
      echo "error: app bootstrap did not produce install at $bundle" >&2
      exit 1
    fi
  fi

  ensure_single_install_local "$app" "$bundle"
  pkill -x "$app" >/dev/null 2>&1 || true
  remove_login_item_local "$app"

  binary="$bundle/Contents/MacOS/$app"
  if [[ ! -x "$binary" ]]; then
    echo "error: executable not found at $binary" >&2
    exit 1
  fi
  verify_install_identity_local "$app" "$bundle"
  cleanup_legacy_accessibility_local "$app"
  repair_accessibility_stale_rows_local "$app" "$bundle"
  check_stale_install_local "$app" "$bundle"

  local open_cmd=(open "$bundle")
  local launch_args=()
  if [[ "$ALLOW_KEYCHAIN" -eq 1 ]]; then
    if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
      open_cmd+=(--env SANEAPPS_FORCE_FREE_MODE=1)
    fi
  else
    open_cmd+=(--env SANEAPPS_DISABLE_KEYCHAIN=1)
    launch_args+=(--sane-no-keychain)
    if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
      open_cmd+=(--env SANEAPPS_FORCE_FREE_MODE=1)
    fi
  fi

  if [[ ${#launch_args[@]} -gt 0 ]]; then
    open_cmd+=(--args "${launch_args[@]}")
  fi

  "${open_cmd[@]}"

  sleep 2
  if pgrep -x "$app" >/dev/null 2>&1; then
    if [[ "$ALLOW_KEYCHAIN" -eq 0 ]]; then
      if ! ps ax -o comm=,command= | awk -v app="$app" -v needle="$binary --sane-no-keychain" '
        $1 == app && index($0, needle) > 0 { found = 1 }
        END { exit found ? 0 : 1 }
      ' >/dev/null 2>&1; then
        echo "warning: Launch Services dropped --sane-no-keychain for $app; relaunching executable directly"
        pkill -x "$app" >/dev/null 2>&1 || true
        local -a direct_env=(env)
        direct_env+=(SANEAPPS_DISABLE_KEYCHAIN=1)
        if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
          direct_env+=(SANEAPPS_FORCE_FREE_MODE=1)
        fi
        nohup "${direct_env[@]}" "$binary" --sane-no-keychain >/tmp/"$(to_lower "$app")"-app_test_mode.log 2>&1 &
        sleep 2
      fi
    fi
    echo "$app launched in $mode mode (host=$(display_host))"
    echo "log command: log stream --predicate 'process == \"$app\"' --style compact"
  else
    echo "error: $app launch not confirmed after initial check (host=$(display_host))"
    /usr/bin/log show --style compact --last 2m --predicate "process == \"$app\"" | tail -n 120 || true
    exit 1
  fi

  if [[ "$VERIFY_LIVE" -eq 1 ]]; then
    local elapsed=0
    while [[ "$elapsed" -lt "$LIVE_VERIFY_SECONDS" ]]; do
      if ! pgrep -x "$app" >/dev/null 2>&1; then
        echo "error: $app exited during live check at t=${elapsed}s (host=$(display_host))"
        /usr/bin/log show --style compact --last 2m --predicate "process == \"$app\"" | tail -n 120 || true
        exit 1
      fi
      sleep "$LIVE_VERIFY_INTERVAL"
      elapsed=$((elapsed + LIVE_VERIFY_INTERVAL))
    done
    echo "$app remained live for ${LIVE_VERIFY_SECONDS}s (host=$(display_host))"
  fi
}

launch_app_remote() {
  local app="$1"
  local mode="$2"
  local bundle binary script

  bundle="$(remote_bundle_path "$app")"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "[ -d \"$bundle\" ]" >/dev/null 2>&1; then
    if ! bootstrap_install_remote "$app"; then
      echo "error: app not found at $bundle on mini and bootstrap failed" >&2
      exit 1
    fi
    bundle="$(remote_bundle_path "$app")"
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "[ -d \"$bundle\" ]" >/dev/null 2>&1; then
      echo "error: app bootstrap did not produce install at $bundle on mini" >&2
      exit 1
    fi
  fi

  ensure_single_install_remote "$app" "$bundle"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pkill -x '$app' >/dev/null 2>&1 || true"
  remove_login_item_remote "$app"

  binary="$bundle/Contents/MacOS/$app"
  verify_install_identity_remote "$app" "$bundle"
  cleanup_legacy_accessibility_remote "$app"
  repair_accessibility_stale_rows_remote "$app" "$bundle"

  if [[ "$ALLOW_KEYCHAIN" -eq 1 ]]; then
    if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
      script="open '$bundle' --env SANEAPPS_FORCE_FREE_MODE=1"
    else
      script="open '$bundle'"
    fi
  else
    if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
      script="open '$bundle' --env SANEAPPS_DISABLE_KEYCHAIN=1 --env SANEAPPS_FORCE_FREE_MODE=1 --args --sane-no-keychain"
    else
      script="open '$bundle' --env SANEAPPS_DISABLE_KEYCHAIN=1 --args --sane-no-keychain"
    fi
  fi

  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "$script"
  sleep 2

  if ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pgrep -x '$app' >/dev/null 2>&1"; then
    if [[ "$ALLOW_KEYCHAIN" -eq 0 ]]; then
      if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "ps ax -o comm=,command= | awk -v app='$app' -v needle='$binary --sane-no-keychain' '\$1 == app && index(\$0, needle) > 0 { found = 1 } END { exit found ? 0 : 1 }' >/dev/null 2>&1"; then
        echo "warning: Launch Services dropped --sane-no-keychain for $app on mini; relaunching executable directly"
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pkill -x '$app' >/dev/null 2>&1 || true"
        local direct_env="env SANEAPPS_DISABLE_KEYCHAIN=1"
        if [[ "$mode" == "basic" && "$app" != "SaneBar" ]]; then
          direct_env="$direct_env SANEAPPS_FORCE_FREE_MODE=1"
        fi
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "nohup $direct_env '$binary' --sane-no-keychain >/tmp/$(to_lower "$app")-app_test_mode.log 2>&1 &"
        sleep 2
      fi
    fi
    echo "$app launched in $mode mode (host=$(display_host))"
    echo "log command: ssh mini \"log stream --predicate 'process == \\\"$app\\\"' --style compact\""
  else
    echo "error: $app launch not confirmed after initial check (host=$(display_host))"
    ssh -o ConnectTimeout=5 -o BatchMode=yes mini "/usr/bin/log show --style compact --last 2m --predicate 'process == \"$app\"' | tail -n 120" || true
    exit 1
  fi

  if [[ "$VERIFY_LIVE" -eq 1 ]]; then
    local elapsed=0
    while [[ "$elapsed" -lt "$LIVE_VERIFY_SECONDS" ]]; do
      if ! ssh -o ConnectTimeout=5 -o BatchMode=yes mini "pgrep -x '$app' >/dev/null 2>&1"; then
        echo "error: $app exited during live check at t=${elapsed}s (host=$(display_host))"
        ssh -o ConnectTimeout=5 -o BatchMode=yes mini "/usr/bin/log show --style compact --last 2m --predicate 'process == \"$app\"' | tail -n 120" || true
        exit 1
      fi
      sleep "$LIVE_VERIFY_INTERVAL"
      elapsed=$((elapsed + LIVE_VERIFY_INTERVAL))
    done
    echo "$app remained live for ${LIVE_VERIFY_SECONDS}s (host=$(display_host))"
  fi
}

display_host() {
  if [[ -n "${APP_TEST_MODE_ORIGIN_HOST:-}" ]]; then
    echo "$APP_TEST_MODE_ORIGIN_HOST"
  else
    echo "$HOST"
  fi
}

set_app_mode() {
  local app="$1"
  local mode="$2"
  if [[ "$HOST" == "mini" ]]; then
    set_app_mode_remote "$app" "$mode"
  else
    set_app_mode_local "$app" "$mode"
  fi
}

app_status() {
  local app="$1"
  if [[ "$HOST" == "mini" ]]; then
    app_status_remote "$app"
  else
    app_status_local "$app"
  fi
}

launch_app() {
  local app="$1"
  local mode="$2"
  if [[ "$HOST" == "mini" ]]; then
    launch_app_remote "$app" "$mode"
  else
    launch_app_local "$app" "$mode"
  fi
}

run_sanebar_smoke() {
  local app="$1"
  local repo="$HOME/SaneApps/apps/$app"
  local smoke_script="$repo/scripts/live_zone_smoke.rb"

  if [[ "$app" != "SaneBar" ]]; then
    echo "error: --smoke is currently supported only for SaneBar" >&2
    exit 1
  fi

  if [[ ! -x "$smoke_script" ]]; then
    echo "error: smoke script missing or not executable: $smoke_script" >&2
    exit 1
  fi

  echo "running SaneBar live zone smoke..."
  (
    cd "$repo"
    ./scripts/live_zone_smoke.rb
  )
}

parse_global_flags() {
  local argv=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        HOST="${2:-}"
        shift 2
        ;;
      --launch)
        LAUNCH=1
        shift
        ;;
      --remote-invoke)
        REMOTE_INVOKE=1
        shift
        ;;
      --keep-duplicates)
        KEEP_DUPLICATES=1
        shift
        ;;
      --allow-keychain)
        ALLOW_KEYCHAIN=1
        shift
        ;;
      --allow-unsigned-install)
        ALLOW_UNSIGNED_INSTALL=1
        shift
        ;;
      --allow-development-signature)
        ALLOW_DEVELOPMENT_SIGNATURE=1
        shift
        ;;
      --no-live-verify)
        VERIFY_LIVE=0
        shift
        ;;
      --live-seconds)
        LIVE_VERIFY_SECONDS="${2:-}"
        if [[ -z "$LIVE_VERIFY_SECONDS" || ! "$LIVE_VERIFY_SECONDS" =~ ^[0-9]+$ ]]; then
          echo "error: --live-seconds requires an integer value" >&2
          exit 1
        fi
        shift 2
        ;;
      --smoke)
        RUN_SANEBAR_SMOKE=1
        shift
        ;;
      *)
        argv+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#argv[@]} -eq 0 ]]; then
    ARGV=()
  else
    ARGV=("${argv[@]}")
  fi
}

delegate_to_mini() {
  local remote_script="/tmp/saneapps_app_test_mode.sh"
  local remote_args=()
  local arg

  for arg in "${ORIGINAL_ARGS[@]}"; do
    if [[ "$arg" == "--host" ]]; then
      SKIP_NEXT=1
      continue
    fi
    if [[ "${SKIP_NEXT:-0}" -eq 1 ]]; then
      SKIP_NEXT=0
      continue
    fi
    remote_args+=("$arg")
  done

  remote_args+=("--host" "local" "--remote-invoke")

  local quoted=""
  for arg in "${remote_args[@]}"; do
    quoted+=" $(printf '%q' "$arg")"
  done

  scp -q -o ConnectTimeout=5 "$0" "mini:$remote_script"
  ssh -o ConnectTimeout=5 -o BatchMode=yes mini "bash -lc 'chmod +x \"$remote_script\" && APP_TEST_MODE_ORIGIN_HOST=mini \"$remote_script\"$quoted'"
}

ORIGINAL_ARGS=("$@")
parse_global_flags "$@"

if [[ "$HOST" != "local" && "$HOST" != "mini" ]]; then
  echo "error: --host must be 'local' or 'mini'" >&2
  exit 1
fi

if [[ "$HOST" == "mini" && "$REMOTE_INVOKE" -eq 0 ]]; then
  delegate_to_mini
  exit $?
fi

if [[ ${#ARGV[@]} -lt 1 ]]; then
  usage
  exit 1
fi

if [[ "${ARGV[0]}" == "list" ]]; then
  printf '%s\n' "${APPS[@]}"
  exit 0
fi

if [[ ${#ARGV[@]} -lt 2 ]]; then
  usage
  exit 1
fi

APP="${ARGV[0]}"
ACTION="${ARGV[1]}"

if ! is_known_app "$APP"; then
  echo "error: unknown app '$APP'" >&2
  echo "run: app_test_mode.sh list"
  exit 1
fi

if [[ "$ACTION" == "free" ]]; then
  ACTION="basic"
fi

if [[ "$ACTION" == "status" ]]; then
  app_status "$APP"
  exit 0
fi

if [[ "$ACTION" == "owner-check" ]]; then
  app_owner_check "$APP"
  exit 0
fi

if [[ "$ACTION" == "owner-install" ]]; then
  owner_install "$APP"
  exit 0
fi

if [[ "$ACTION" == "owner-pro" ]]; then
  owner_pro "$APP"
  exit 0
fi

if [[ "$ACTION" == "owner-verify" ]]; then
  owner_verify "$APP"
  exit 0
fi

if [[ "$ACTION" != "pro" && "$ACTION" != "basic" ]]; then
  echo "error: action must be 'pro', 'basic', 'free', 'status', 'owner-check', 'owner-install', 'owner-pro', or 'owner-verify'" >&2
  usage
  exit 1
fi

set_app_mode "$APP" "$ACTION"
echo "$APP set to $ACTION (host=$(display_host), no-keychain fallback state)"

if [[ "$LAUNCH" -eq 1 ]]; then
  launch_app "$APP" "$ACTION"
fi

if [[ "$RUN_SANEBAR_SMOKE" -eq 1 ]]; then
  run_sanebar_smoke "$APP"
fi
