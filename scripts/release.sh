#!/bin/bash
# frozen_string_literal: false
#
# Unified Release Script
# Builds, signs, notarizes, and packages a ZIP for any SaneApps project
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure Homebrew-installed tools resolve in non-interactive shells (CI/SSH).
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Shared Sparkle public key for all SaneApps direct-distribution builds.
SHARED_SPARKLE_PUBLIC_KEY="7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU="

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

extract_http_status() {
    local url="$1"
    curl -sI -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000"
}

extract_content_length() {
    local url="$1"
    curl -sI "${url}" 2>/dev/null | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); print $2}' | tail -1
}

appcast_item_count_for_version() {
    local appcast_content="$1"
    APPCAST_CONTENT="${appcast_content}" python3 - "${VERSION}" "${BUILD_NUMBER}" <<'PY'
import os
import re
import sys

xml = os.environ.get("APPCAST_CONTENT", "")
version = sys.argv[1]
build = sys.argv[2]

def matches_item(item: str) -> bool:
    if f'sparkle:shortVersionString="{version}"' in item:
        return True
    if f'sparkle:version="{build}"' in item:
        return True
    if re.search(rf"<sparkle:shortVersionString>\s*{re.escape(version)}\s*</sparkle:shortVersionString>", item):
        return True
    if re.search(rf"<sparkle:version>\s*{re.escape(build)}\s*</sparkle:version>", item):
        return True
    return False

count = 0
for match in re.finditer(r"<item>.*?</item>", xml, flags=re.S):
    item = match.group(0)
    if matches_item(item):
        count += 1

print(count)
PY
}

appcast_length_for_version() {
    local appcast_content="$1"
    APPCAST_CONTENT="${appcast_content}" python3 - "${VERSION}" "${BUILD_NUMBER}" <<'PY'
import os
import re
import sys

xml = os.environ.get("APPCAST_CONTENT", "")
version = sys.argv[1]
build = sys.argv[2]

def matches_item(item: str) -> bool:
    if f'sparkle:shortVersionString="{version}"' in item:
        return True
    if f'sparkle:version="{build}"' in item:
        return True
    if re.search(rf"<sparkle:shortVersionString>\s*{re.escape(version)}\s*</sparkle:shortVersionString>", item):
        return True
    if re.search(rf"<sparkle:version>\s*{re.escape(build)}\s*</sparkle:version>", item):
        return True
    return False

for match in re.finditer(r"<item>.*?</item>", xml, flags=re.S):
    item = match.group(0)
    if not matches_item(item):
        continue

    enclosure = re.search(r"<enclosure\b[^>]*>", item, flags=re.S)
    if not enclosure:
        continue

    length_match = re.search(r'length="([0-9]+)"', enclosure.group(0))
    if length_match:
        print(length_match.group(1))
        sys.exit(0)

print("")
PY
}

prune_existing_appcast_entries() {
    local appcast_path="$1"
    local removed_count
    removed_count=$(python3 - "${appcast_path}" "${VERSION}" "${BUILD_NUMBER}" <<'PY'
import re
import sys

path, version, build = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

def matches_item(item: str) -> bool:
    if f'sparkle:shortVersionString="{version}"' in item:
        return True
    if f'sparkle:version="{build}"' in item:
        return True
    if re.search(rf"<sparkle:shortVersionString>\s*{re.escape(version)}\s*</sparkle:shortVersionString>", item):
        return True
    if re.search(rf"<sparkle:version>\s*{re.escape(build)}\s*</sparkle:version>", item):
        return True
    return False

removed = 0
parts = []
last = 0
for match in re.finditer(r"<item>.*?</item>", xml, flags=re.S):
    item = match.group(0)
    if matches_item(item):
        parts.append(xml[last:match.start()])
        last = match.end()
        removed += 1

parts.append(xml[last:])
new_xml = "".join(parts)

if removed > 0:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_xml)

print(removed)
PY
)
    if [ "${removed_count}" -gt 0 ] 2>/dev/null; then
        log_warn "Removed ${removed_count} stale appcast entr$( [ "${removed_count}" = "1" ] && echo "y" || echo "ies" ) for v${VERSION} before insert"
    fi
}

wait_for_live_appcast_version() {
    local appcast_url="$1"
    local max_attempts="${APPCAST_VERIFY_ATTEMPTS:-15}"
    local sleep_seconds="${APPCAST_VERIFY_SLEEP_SECONDS:-8}"
    local attempt=1

    while [ "${attempt}" -le "${max_attempts}" ]; do
        local status
        status=$(extract_http_status "${appcast_url}")
        if [ "${status}" = "200" ]; then
            local appcast_content
            appcast_content=$(curl -fsSL "${appcast_url}" 2>/dev/null || true)
            if [ -n "${appcast_content}" ]; then
                local count
                count=$(appcast_item_count_for_version "${appcast_content}")
                if [ "${count}" = "1" ]; then
                    log_info "Appcast propagated with exactly one v${VERSION} entry (attempt ${attempt}/${max_attempts})"
                    return 0
                fi
                log_warn "Appcast propagation attempt ${attempt}/${max_attempts}: expected 1 matching item, found ${count}"
            fi
        else
            log_warn "Appcast propagation attempt ${attempt}/${max_attempts}: HTTP ${status}"
        fi

        if [ "${attempt}" -lt "${max_attempts}" ]; then
            sleep "${sleep_seconds}"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

appstore_duplicate_build_upload_detected() {
    local latest_log_dir
    latest_log_dir=$(ls -td /var/folders/*/*/*/T/${APP_NAME}_*.xcdistributionlogs 2>/dev/null | head -1 || true)
    if [ -z "${latest_log_dir}" ]; then
        return 1
    fi

    local content_log="${latest_log_dir}/ContentDelivery.log"
    if [ ! -f "${content_log}" ]; then
        return 1
    fi

    if grep -Eqi "ENTITY_ERROR\.ATTRIBUTE\.INVALID\.DUPLICATE|bundle version must be higher than the previously uploaded version" "${content_log}"; then
        return 0
    fi

    return 1
}

run_post_release_checks() {
    local dist_url="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip"
    local appcast_url="https://${SITE_HOST}/appcast.xml"
    local checkout_url="https://go.saneapps.com/buy/${LOWER_APP_NAME}"

    log_info "Running strict post-release checks..."

    local dist_status
    dist_status=$(curl -A "Sparkle/2" -sI -o /dev/null -w '%{http_code}' "${dist_url}" 2>/dev/null || echo "000")
    if [ "${dist_status}" != "200" ] && [ "${dist_status}" != "206" ]; then
        log_error "Download URL failed: ${dist_url} returned HTTP ${dist_status}"
        return 1
    fi

    local dist_length
    dist_length=$(curl -A "Sparkle/2" -sI "${dist_url}" 2>/dev/null | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); print $2}' | tail -1)
    if [ -z "${dist_length}" ]; then
        log_error "Download URL missing Content-Length: ${dist_url}"
        return 1
    fi

    if [ "${USE_SPARKLE}" = true ]; then
        local appcast_status
        appcast_status=$(extract_http_status "${appcast_url}")
        if [ "${appcast_status}" != "200" ]; then
            log_error "Appcast URL failed: ${appcast_url} returned HTTP ${appcast_status}"
            return 1
        fi

        local appcast_content
        appcast_content=$(curl -fsSL "${appcast_url}" 2>/dev/null || true)
        if [ -z "${appcast_content}" ]; then
            log_error "Could not fetch appcast content from ${appcast_url}"
            return 1
        fi

        if command -v xmllint >/dev/null 2>&1; then
            if ! xmllint --noout - <<< "${appcast_content}" >/dev/null 2>&1; then
                log_error "Appcast XML is invalid at ${appcast_url}"
                return 1
            fi
        else
            if ! APPCAST_CONTENT="${appcast_content}" python3 - <<'PY' >/dev/null 2>&1
import os
import xml.etree.ElementTree as ET

ET.fromstring(os.environ.get("APPCAST_CONTENT", ""))
PY
            then
                log_error "Appcast XML parse failed at ${appcast_url}"
                return 1
            fi
        fi

        local appcast_item_count
        appcast_item_count=$(appcast_item_count_for_version "${appcast_content}")
        if [ "${appcast_item_count}" != "1" ]; then
            log_error "Appcast has ${appcast_item_count} entries for v${VERSION} (expected exactly 1)"
            return 1
        fi

        if grep -Eqi 'github\.com/[^/]+/[^/]+/releases/download' <<< "${appcast_content}"; then
            log_error "Appcast contains GitHub release download URLs (forbidden). Use dist.* direct-distribution URLs only."
            return 1
        fi

        local appcast_length
        appcast_length=$(appcast_length_for_version "${appcast_content}")
        if [ -z "${appcast_length}" ]; then
            log_error "Appcast entry for v${VERSION} missing enclosure length"
            return 1
        fi

        if [ "${appcast_length}" != "${dist_length}" ]; then
            log_error "Length mismatch: appcast=${appcast_length}, dist=${dist_length}"
            return 1
        fi
    fi

    local checkout_status
    checkout_status=$(extract_http_status "${checkout_url}")
    if [ "${checkout_status}" != "200" ] && [ "${checkout_status}" != "301" ] && [ "${checkout_status}" != "302" ]; then
        log_error "Checkout URL failed: ${checkout_url} returned HTTP ${checkout_status}"
        return 1
    fi

    if [ -n "${HOMEBREW_TAP_REPO}" ]; then
        local cask_file="Casks/${LOWER_APP_NAME}.rb"
        local cask_raw_url="https://raw.githubusercontent.com/${HOMEBREW_TAP_REPO}/main/${cask_file}"
        local cask_api_path="repos/${HOMEBREW_TAP_REPO}/contents/${cask_file}?ref=main"
        local cask_status
        cask_status=$(extract_http_status "${cask_raw_url}")
        if [ "${cask_status}" = "404" ]; then
            log_warn "No Homebrew cask found for ${APP_NAME} (${cask_raw_url}); skipping Homebrew verification."
        elif [ "${cask_status}" != "200" ]; then
            log_error "Could not fetch Homebrew cask: ${cask_raw_url} (HTTP ${cask_status})"
            return 1
        else
        local cask_attempt=1
        local cask_max_attempts="${HOMEBREW_VERIFY_ATTEMPTS:-10}"
        local cask_sleep_seconds="${HOMEBREW_VERIFY_SLEEP_SECONDS:-6}"
        local cask_ok=false
        local cask_verified_source=""

        while [ "${cask_attempt}" -le "${cask_max_attempts}" ]; do
            local cask_body
            cask_body=$(curl -fsSL "${cask_raw_url}" 2>/dev/null || true)
            if [ -n "${cask_body}" ] && \
               grep -q "version \"${VERSION}\"" <<< "${cask_body}" && \
               grep -q "sha256 \"${SHA256}\"" <<< "${cask_body}"; then
                cask_ok=true
                cask_verified_source="raw"
                break
            fi

            # raw.githubusercontent can lag behind Git refs after push; verify against GitHub API as fallback.
            if command -v gh >/dev/null 2>&1; then
                local cask_api_body
                cask_api_body=$(gh api "${cask_api_path}" --jq '.content' 2>/dev/null | tr -d '\n' | python3 -c 'import base64,sys; data=sys.stdin.read().strip(); print(base64.b64decode(data).decode("utf-8"), end="")' 2>/dev/null || true)
                if [ -n "${cask_api_body}" ] && \
                   grep -q "version \"${VERSION}\"" <<< "${cask_api_body}" && \
                   grep -q "sha256 \"${SHA256}\"" <<< "${cask_api_body}"; then
                    cask_ok=true
                    cask_verified_source="github-api"
                    break
                fi
            fi

            if [ "${cask_attempt}" -lt "${cask_max_attempts}" ]; then
                sleep "${cask_sleep_seconds}"
            fi
            cask_attempt=$((cask_attempt + 1))
        done

        if [ "${cask_ok}" != "true" ]; then
            log_error "Homebrew cask did not converge to v${VERSION} / ${SHA256:0:12}... at ${cask_raw_url}"
            return 1
        fi

        if [ "${cask_verified_source}" = "github-api" ]; then
            log_warn "Homebrew verification passed via GitHub API; raw.githubusercontent is still propagating."
        fi
        fi
    fi

    log_info "Post-release checks passed."
    return 0
}

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --project PATH      Project root (defaults to current directory)"
    echo "  --config PATH       Config file (defaults to <project>/.saneprocess if present)"
    echo "  --full              Version bump, tests, git commit (no GitHub release publishing)"
    echo "  --deploy            Upload to R2, update appcast, deploy website (run after build)"
    echo "  --skip-notarize      Skip notarization (for local testing)"
    echo "  --skip-build         Skip build step (use existing archive)"
    echo "  --version X.Y.Z      Set version number"
    echo "  --notes \"...\"      Release notes for changelog/release metadata (required with --full)"
    echo "  --allow-republish    Allow republishing an already-live version/build"
    echo "  --allow-unsynced-peer  Bypass Air/mini reconcile gate for this release"
    echo "  --skip-appstore      Skip App Store archive/export/upload even if enabled in config"
    echo "  --website-only       Deploy website + appcast only (no build/R2/signing)"
    echo "  --preflight-only     Run all release gates and exit (no build/publish)"
    echo "  -h, --help           Show this help"
}

ensure_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

ensure_git_clean() {
    if [ -n "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]; then
        log_error "Git working directory not clean. Commit or stash changes first."
        exit 1
    fi
}

shell_true() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

default_peer_host_for_project() {
    case "${PROJECT_ROOT}" in
        /Users/sj/*)
            echo "mini"
            ;;
        /Users/stephansmac/*)
            echo "air"
            ;;
        *)
            echo "mini"
            ;;
    esac
}

default_peer_repo_path_for_project() {
    case "${PROJECT_ROOT}" in
        /Users/sj/*)
            echo "/Users/stephansmac/${PROJECT_ROOT#/Users/sj/}"
            ;;
        /Users/stephansmac/*)
            echo "/Users/sj/${PROJECT_ROOT#/Users/stephansmac/}"
            ;;
        *)
            echo ""
            ;;
    esac
}

enforce_machine_reconcile() {
    if ! shell_true "${RELEASE_RECONCILE_ENABLED}"; then
        return 0
    fi

    if [ "${ALLOW_UNSYNCED_PEER}" = true ]; then
        log_warn "Machine reconcile gate bypassed (--allow-unsynced-peer)."
        return 0
    fi

    ensure_cmd ssh
    ensure_cmd git

    local peer_host peer_repo_path peer_branch
    local local_branch local_head local_dirty
    local peer_head="" peer_ref_branch="" peer_dirty=""
    local peer_report peer_path_escaped

    peer_host="${RELEASE_PEER_HOST:-$(default_peer_host_for_project)}"
    peer_repo_path="${RELEASE_PEER_REPO_PATH:-$(default_peer_repo_path_for_project)}"
    peer_branch="${RELEASE_PEER_BRANCH:-main}"

    if [ -z "${peer_host}" ] || [ -z "${peer_repo_path}" ]; then
        log_error "Machine reconcile gate is enabled but peer host/path could not be resolved."
        log_error "Set release.reconcile.peer_host and release.reconcile.peer_repo_path in .saneprocess, or use --allow-unsynced-peer."
        exit 1
    fi

    local_branch=$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    local_head=$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || true)
    local_dirty=$(git -C "${PROJECT_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    if [ -z "${local_head}" ]; then
        log_error "Unable to read local git HEAD for machine reconcile gate."
        exit 1
    fi

    if [ "${local_dirty}" != "0" ]; then
        log_error "Local repo is not clean (${local_dirty} change(s)). Resolve before release."
        exit 1
    fi

    if [ -n "${peer_branch}" ] && [ "${local_branch}" != "${peer_branch}" ]; then
        log_error "Local branch is '${local_branch}', expected '${peer_branch}' for release."
        exit 1
    fi

    peer_path_escaped=$(printf '%q' "${peer_repo_path}")
    if ! peer_report=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "${peer_host}" \
        "cd ${peer_path_escaped} >/dev/null 2>&1 && printf 'HEAD=%s\nBRANCH=%s\nDIRTY=%s\n' \"\$(git rev-parse HEAD 2>/dev/null || echo)\" \"\$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)\" \"\$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')\""); then
        log_error "Could not query peer repo ${peer_host}:${peer_repo_path}."
        log_error "Fix connectivity/repo path first, or use --allow-unsynced-peer for emergencies."
        exit 1
    fi

    while IFS='=' read -r key value; do
        case "${key}" in
            HEAD) peer_head="${value}" ;;
            BRANCH) peer_ref_branch="${value}" ;;
            DIRTY) peer_dirty="${value}" ;;
        esac
    done <<< "${peer_report}"

    if [ -z "${peer_head}" ] || [ -z "${peer_ref_branch}" ] || [ -z "${peer_dirty}" ]; then
        log_error "Peer repo state parse failed for ${peer_host}:${peer_repo_path}."
        exit 1
    fi

    if [ "${peer_dirty}" != "0" ]; then
        log_error "Peer repo has ${peer_dirty} uncommitted change(s): ${peer_host}:${peer_repo_path}"
        log_error "Reconcile both machines before release, or use --allow-unsynced-peer for emergencies."
        exit 1
    fi

    if [ -n "${peer_branch}" ] && [ "${peer_ref_branch}" != "${peer_branch}" ]; then
        log_error "Peer branch is '${peer_ref_branch}', expected '${peer_branch}'."
        exit 1
    fi

    if [ "${local_head}" != "${peer_head}" ]; then
        log_error "Air/mini are not reconciled."
        log_error "Local (${local_branch}) HEAD: ${local_head}"
        log_error "Peer  (${peer_ref_branch}) HEAD: ${peer_head}"
        log_error "Merge/sync both machines first, or use --allow-unsynced-peer for emergencies."
        exit 1
    fi

    log_info "Machine reconcile gate passed: local and ${peer_host} are synced at ${local_head:0:12}"
}

resolve_path() {
    local path="$1"
    if [ -z "${path}" ]; then
        echo ""
        return 0
    fi
    if [[ "${path}" = /* ]]; then
        echo "${path}"
    else
        echo "${PROJECT_ROOT}/${path}"
    fi
}

remove_path() {
    local path="$1"
    if [ -e "${path}" ]; then
        if command -v trash >/dev/null 2>&1; then
            trash "${path}"
        else
            rm -rf "${path}"
        fi
    fi
}

project_version_from_semver() {
    local semver="$1"
    local project_version
    # Parse major.minor.patch and compute major*1000 + minor*100 + patch
    # This ensures 2.0.0 (2000) > 1.0.23 (1023) for Sparkle version comparison
    local major minor patch
    major=$(echo "$semver" | cut -d. -f1)
    minor=$(echo "$semver" | cut -d. -f2)
    patch=$(echo "$semver" | cut -d. -f3)
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
    project_version=$(( major * 1000 + minor * 100 + patch ))
    if [ "${project_version}" -eq 0 ]; then
        project_version="1"
    fi
    echo "${project_version}"
}

restore_version_bump() {
    if [ -n "${VERSION_BUMP_RESTORE_CMD}" ]; then
        eval "${VERSION_BUMP_RESTORE_CMD}"
        return
    fi

    if [ -f "${PROJECT_ROOT}/project.yml" ]; then
        git -C "${PROJECT_ROOT}" restore --staged --worktree "project.yml" 2>/dev/null || \
            git -C "${PROJECT_ROOT}" checkout -- "project.yml" 2>/dev/null || true
    fi
}

bump_project_version() {
    local version="$1"
    local project_version
    project_version=$(project_version_from_semver "${version}")

    if [ -n "${VERSION_BUMP_CMD}" ]; then
        eval "${VERSION_BUMP_CMD}"
        return
    fi

    if [ ! -f "${PROJECT_ROOT}/project.yml" ]; then
        log_error "No version bump method. Set VERSION_BUMP_CMD or add project.yml."
        exit 1
    fi

    sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${version}\"/" "${PROJECT_ROOT}/project.yml"
    sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${project_version}\"/" "${PROJECT_ROOT}/project.yml"
}

run_tests() {
    log_info "Running tests..."

    local cache_root="${PROJECT_ROOT}/.build/cache"
    local clang_cache="${cache_root}/clang"
    local swiftpm_cache="${cache_root}/swiftpm"
    mkdir -p "${clang_cache}" "${swiftpm_cache}"

    if [ -d "${HOME}/Library/Caches/org.swift.swiftpm" ] && [ ! -d "${swiftpm_cache}/repositories" ]; then
        cp -R "${HOME}/Library/Caches/org.swift.swiftpm/." "${swiftpm_cache}/" 2>/dev/null || true
    fi

    local args=(test -scheme "${SCHEME}" -destination 'platform=macOS' -quiet)
    if [ -n "${WORKSPACE}" ]; then
        args=(-workspace "${WORKSPACE}" "${args[@]}")
    elif [ -n "${XCODEPROJ}" ]; then
        args=(-project "${XCODEPROJ}" "${args[@]}")
    fi

    if XDG_CACHE_HOME="${cache_root}" \
       CLANG_MODULE_CACHE_PATH="${clang_cache}" \
       SWIFTPM_CACHE_PATH="${swiftpm_cache}" \
       xcodebuild "${args[@]}"; then
        log_info "All tests passed"
    else
        log_error "Tests failed! Aborting release."
        restore_version_bump
        exit 1
    fi
}

update_changelog() {
    local changelog="${PROJECT_ROOT}/CHANGELOG.md"
    if [ ! -f "${changelog}" ]; then
        log_warn "No CHANGELOG.md found — skipping changelog update"
        return 0
    fi

    local date_str
    date_str=$(date +%Y-%m-%d)
    local tmp_changelog="${changelog}.tmp"
    local entry_file="${changelog}.entry"

    # Write entry to temp file (avoids awk -v backslash escaping issues)
    cat > "${entry_file}" <<CLEOF
## [${VERSION}] - ${date_str}

${RELEASE_NOTES}

---

CLEOF

    if grep -q '^## \[' "${changelog}"; then
        # Insert before the first existing version entry
        local first_entry_line
        first_entry_line=$(grep -n '^## \[' "${changelog}" | head -1 | cut -d: -f1)
        head -n $((first_entry_line - 1)) "${changelog}" > "${tmp_changelog}"
        cat "${entry_file}" >> "${tmp_changelog}"
        tail -n +${first_entry_line} "${changelog}" >> "${tmp_changelog}"
    else
        # No existing entries — append after header
        cp "${changelog}" "${tmp_changelog}"
        echo "" >> "${tmp_changelog}"
        cat "${entry_file}" >> "${tmp_changelog}"
    fi

    mv "${tmp_changelog}" "${changelog}"
    rm -f "${entry_file}"
    log_info "CHANGELOG.md updated with v${VERSION} entry"
}

commit_version_bump() {
    git -C "${PROJECT_ROOT}" add "${VERSION_BUMP_FILES[@]}"
    # Also stage CHANGELOG.md if it was updated
    if [ -f "${PROJECT_ROOT}/CHANGELOG.md" ]; then
        git -C "${PROJECT_ROOT}" add "CHANGELOG.md"
    fi
    if git -C "${PROJECT_ROOT}" commit -m "Bump version to ${VERSION}" >/dev/null 2>&1; then
        log_info "Version bump committed"
    else
        log_warn "No version bump commit created (maybe no changes)"
    fi
}

create_github_release() {
    log_warn "Skipping GitHub release creation (policy: no release publishing on GitHub)."
    return 0
}

upload_github_release_asset() {
    log_warn "Skipping GitHub release asset upload (policy: no binary distribution on GitHub)."
    return 0
}

write_export_options_plist() {
    local plist_path="$1"

    if [ -n "${EXPORT_OPTIONS_PLIST}" ]; then
        cp "${EXPORT_OPTIONS_PLIST}" "${plist_path}"
        return
    fi

    cat > "${plist_path}" << OPT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
OPT

    if [ ${#EXPORT_OPTIONS_PROFILES[@]} -gt 0 ]; then
        echo "    <key>provisioningProfiles</key>" >> "${plist_path}"
        echo "    <dict>" >> "${plist_path}"
        for entry in "${EXPORT_OPTIONS_PROFILES[@]}"; do
            local bundle_id="${entry%%:*}"
            local profile_name="${entry#*:}"
            echo "        <key>${bundle_id}</key>" >> "${plist_path}"
            echo "        <string>${profile_name}</string>" >> "${plist_path}"
        done
        echo "    </dict>" >> "${plist_path}"
    fi

    if [ -n "${EXPORT_OPTIONS_EXTRA_XML}" ]; then
        echo "${EXPORT_OPTIONS_EXTRA_XML}" >> "${plist_path}"
    fi

    cat >> "${plist_path}" << OPT
</dict>
</plist>
OPT
}

preflight_check_dylibs() {
    # Verify all dynamic libraries referenced by the binary are present in the bundle.
    # Catches the Sparkle-missing-from-App-Store-build class of crash-on-launch.
    local app_path="$1"
    local label="$2"
    local main_exec
    main_exec=$(defaults read "${app_path}/Contents/Info" CFBundleExecutable 2>/dev/null || true)
    if [ -z "${main_exec}" ]; then
        log_warn "Could not read CFBundleExecutable for dylib check"
        return 0
    fi

    local binary="${app_path}/Contents/MacOS/${main_exec}"
    if [ ! -f "${binary}" ]; then
        log_warn "Binary not found for dylib check: ${binary}"
        return 0
    fi

    local missing=0
    while IFS= read -r line; do
        line=$(echo "${line}" | xargs) # trim whitespace
        [ -z "${line}" ] && continue

        # Extract the library path (first field before the parenthesized version info)
        local lib
        lib=$(echo "${line}" | awk '{print $1}')
        [ -z "${lib}" ] && continue

        # Skip weak references — they don't crash if missing (LC_LOAD_WEAK_DYLIB)
        # otool -L shows: "... (compatibility version X.Y.Z, current version X.Y.Z, weak)"
        if echo "${line}" | grep -q ", weak)"; then
            continue
        fi

        # Resolve @rpath references against the app's Frameworks dir
        if [[ "${lib}" == @rpath/* ]]; then
            local framework_name="${lib#@rpath/}"
            local resolved="${app_path}/Contents/Frameworks/${framework_name}"
            if [ ! -f "${resolved}" ]; then
                log_error "MISSING DYLIB (${label}): ${lib}"
                log_error "  Expected at: ${resolved}"
                missing=$((missing + 1))
            fi
        elif [[ "${lib}" == @executable_path/* ]]; then
            local rel_path="${lib#@executable_path/}"
            local resolved="${app_path}/Contents/MacOS/${rel_path}"
            if [ ! -f "${resolved}" ]; then
                log_error "MISSING DYLIB (${label}): ${lib}"
                log_error "  Expected at: ${resolved}"
                missing=$((missing + 1))
            fi
        fi
        # /usr/lib and /System paths are OS-provided, skip
    done < <(otool -L "${binary}" 2>/dev/null | tail -n +2)

    if [ "${missing}" -gt 0 ]; then
        log_error ""
        log_error "${missing} missing dynamic library reference(s) in ${label} build."
        log_error "The app WILL crash on launch (dyld: Library not loaded)."
        log_error ""
        log_error "Common cause: binary was compiled with a framework (e.g., Sparkle)"
        log_error "that isn't included in the App Store build. Use a separate build"
        log_error "configuration (e.g., Release-AppStore) with conditional compilation"
        log_error "flags (#if !APP_STORE) to exclude the framework at compile time."
        return 1
    fi

    log_info "Dylib preflight (${label}): all references resolved"
    return 0
}

write_export_options_appstore_plist() {
    local plist_path="$1"
    cat > "${plist_path}" << 'OPT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
OPT
    echo "    <string>${TEAM_ID}</string>" >> "${plist_path}"
    cat >> "${plist_path}" << 'OPT'
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
OPT
}

create_empty_entitlements_plist() {
    local entitlements_path="$1"
    cat > "${entitlements_path}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
}

binary_has_get_task_allow() {
    local binary_path="$1"
    if codesign -d --entitlements :- "${binary_path}" 2>/dev/null | grep -q "get-task-allow"; then
        return 0
    fi
    return 1
}

binary_has_strong_sparkle_load() {
    local binary_path="$1"
    python3 - "${binary_path}" <<'PY'
import subprocess
import sys

binary = sys.argv[1]
try:
    out = subprocess.check_output(["otool", "-l", binary], text=True, stderr=subprocess.DEVNULL)
except Exception:
    sys.exit(1)

lines = out.splitlines()
for i, line in enumerate(lines):
    if line.strip() != "cmd LC_LOAD_DYLIB":
        continue
    for j in range(i + 1, min(i + 12, len(lines))):
        s = lines[j].strip()
        if s.startswith("name ") and "Sparkle.framework" in s:
            sys.exit(0)

sys.exit(1)
PY
}

sign_app_bundle_developer_id() {
    local bundle_path="$1"
    local entitlements_path="$2"

    # --deep is intentional here because helper apps embedded in zips frequently
    # contain Swift runtime dylibs and frameworks which also need a Developer ID signature.
    codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp \
        --entitlements "${entitlements_path}" --deep "${bundle_path}"
}

fix_and_verify_zipped_apps_in_app() {
    local host_app_path="$1"

    # Some libraries embed helper .app bundles inside .zip resources. Apple notarization
    # validates those payloads, but codesign --verify --deep does NOT inspect inside zips.
    local tmp_root
    tmp_root=$(/usr/bin/mktemp -d /tmp/release_notary_preflight.XXXX)
    local empty_entitlements="${tmp_root}/empty.entitlements"
    create_empty_entitlements_plist "${empty_entitlements}"

    # Only scan Resources for zips to keep runtime low.
    local resources_path="${host_app_path}/Contents/Resources"
    if [ ! -d "${resources_path}" ]; then
        remove_path "${tmp_root}"
        return 0
    fi

    local zip_found=false
    while IFS= read -r -d '' zip_path; do
        zip_found=true

        local unzip_dir="${tmp_root}/unzip"
        remove_path "${unzip_dir}"
        mkdir -p "${unzip_dir}"

        # If the zip doesn't contain an .app, skip it.
        if ! ditto -x -k "${zip_path}" "${unzip_dir}" 2>/dev/null; then
            log_warn "Could not unzip resource: ${zip_path} (skipping)"
            continue
        fi

        local apps_in_zip
        apps_in_zip=$(find "${unzip_dir}" -name "*.app" -maxdepth 6 2>/dev/null || true)
        if [ -z "${apps_in_zip}" ]; then
            continue
        fi

        log_info "Fixing embedded helper app(s) in: ${zip_path}"

        # Re-sign each embedded app bundle.
        while IFS= read -r embedded_app; do
            [ -n "${embedded_app}" ] || continue

            local embedded_exec
            embedded_exec=$(defaults read "${embedded_app}/Contents/Info" CFBundleExecutable 2>/dev/null || true)
            if [ -n "${embedded_exec}" ] && [ -f "${embedded_app}/Contents/MacOS/${embedded_exec}" ]; then
                if binary_has_get_task_allow "${embedded_app}/Contents/MacOS/${embedded_exec}"; then
                    log_warn "Removing get-task-allow by re-signing: ${embedded_app}"
                fi
            fi

            sign_app_bundle_developer_id "${embedded_app}" "${empty_entitlements}"

            if [ -n "${embedded_exec}" ] && [ -f "${embedded_app}/Contents/MacOS/${embedded_exec}" ]; then
                if binary_has_get_task_allow "${embedded_app}/Contents/MacOS/${embedded_exec}"; then
                    log_error "Embedded helper still has get-task-allow after signing: ${embedded_app}"
                    remove_path "${tmp_root}"
                    exit 1
                fi
            fi
        done <<< "${apps_in_zip}"

        # Recreate zip from the extracted directory.
        rm -f "${zip_path}"
        (cd "${unzip_dir}" && ditto -c -k --sequesterRsrc . "${zip_path}")
    done < <(find "${resources_path}" -type f -name "*.zip" -print0 2>/dev/null || true)

    if [ "${zip_found}" = true ]; then
        log_info "Embedded zip helper preflight complete."
    fi

    remove_path "${tmp_root}"
}

sanity_check_app_for_notarization() {
    local host_app_path="$1"
    local main_exec
    main_exec=$(defaults read "${host_app_path}/Contents/Info" CFBundleExecutable 2>/dev/null || true)
    if [ -z "${main_exec}" ] || [ ! -f "${host_app_path}/Contents/MacOS/${main_exec}" ]; then
        log_error "Could not determine main executable for: ${host_app_path}"
        exit 1
    fi

    if binary_has_get_task_allow "${host_app_path}/Contents/MacOS/${main_exec}"; then
        log_error "Main app executable has get-task-allow (Debug entitlement). Release builds must not include this."
        exit 1
    fi

    # Check all executables inside the bundle for debug entitlement.
    while IFS= read -r -d '' exec_path; do
        if binary_has_get_task_allow "${exec_path}"; then
            log_error "Found get-task-allow in embedded executable: ${exec_path}"
            exit 1
        fi
    done < <(find "${host_app_path}" -type f -path "*/Contents/MacOS/*" -print0 2>/dev/null || true)
}


check_required_commands() {
    local missing=()
    local cmd
    for cmd in git xcodebuild codesign xcrun hdiutil ditto; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi

    return 0
}

check_git_clean_gate() {
    if [ -n "$(git -C "${PROJECT_ROOT}" status --porcelain 2>/dev/null)" ]; then
        log_error "Git working directory is not clean."
        return 1
    fi
    return 0
}

check_reconcile_gate() {
    if (enforce_machine_reconcile); then
        return 0
    fi
    return 1
}

check_signing_identity_gate() {
    if ! command -v security >/dev/null 2>&1; then
        log_error "security CLI not available."
        return 1
    fi

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_IDENTITY}"; then
        log_error "Signing identity not found: ${SIGNING_IDENTITY}"
        return 1
    fi

    return 0
}

resolve_sparkle_private_key() {
    local sparkle_key="${SPARKLE_PRIVATE_KEY:-}"
    if [ -n "${sparkle_key}" ]; then
        printf '%s' "${sparkle_key}"
        return 0
    fi

    sparkle_key=$(security find-generic-password -w -s "saneprocess.sparkle.private_key" 2>/dev/null || true)
    if [ -n "${sparkle_key}" ]; then
        printf '%s' "${sparkle_key}"
        return 0
    fi

    sparkle_key=$(security find-generic-password -w -s "https://sparkle-project.org" -a "EdDSA Private Key" 2>/dev/null || true)
    if [ -n "${sparkle_key}" ]; then
        printf '%s' "${sparkle_key}"
        return 0
    fi

    return 1
}

derive_sparkle_public_key() {
    local sparkle_private_key="$1"
    if [ -z "${sparkle_private_key}" ]; then
        return 1
    fi

    SPARKLE_PRIVATE_KEY_INPUT="${sparkle_private_key}" swift -e '
import Foundation
import CryptoKit

guard let keyBase64 = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY_INPUT"],
      let keyData = Data(base64Encoded: keyBase64) else {
    fputs("invalid private key\n", stderr)
    exit(2)
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    fputs("unable to derive public key\n", stderr)
    exit(3)
}
' 2>/dev/null
}

check_sparkle_keypair_gate() {
    if [ "${USE_SPARKLE}" != "true" ]; then
        return 0
    fi

    if ! command -v swift >/dev/null 2>&1; then
        log_error "swift is required to validate Sparkle private/public keypair."
        return 1
    fi

    local sparkle_private_key
    sparkle_private_key=$(resolve_sparkle_private_key || true)
    if [ -z "${sparkle_private_key}" ]; then
        log_error "Sparkle private key not found."
        log_error "Set SPARKLE_PRIVATE_KEY or add Keychain item:"
        log_error "  service=saneprocess.sparkle.private_key"
        log_error "  or service=https://sparkle-project.org account=EdDSA Private Key"
        return 1
    fi

    local derived_public_key
    derived_public_key=$(derive_sparkle_public_key "${sparkle_private_key}" || true)
    if [ -z "${derived_public_key}" ]; then
        log_error "Unable to derive Sparkle public key from private key."
        return 1
    fi

    if [ "${derived_public_key}" != "${SHARED_SPARKLE_PUBLIC_KEY}" ]; then
        log_error "Sparkle keypair mismatch."
        log_error "  Expected public key: ${SHARED_SPARKLE_PUBLIC_KEY}"
        log_error "  Derived public key:  ${derived_public_key}"
        log_error "Wrong Sparkle private key would break customer auto-updates."
        return 1
    fi

    log_info "Sparkle private/public keypair matches shared key."
    return 0
}

prepare_signing_session() {
    local login_keychain="${HOME}/Library/Keychains/login.keychain-db"
    local keychain_password="${SANEBAR_KEYCHAIN_PASSWORD:-${KEYCHAIN_PASSWORD:-${KEYCHAIN_PASS:-}}}"

    security default-keychain -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security list-keychains -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security set-keychain-settings -lut 21600 "${login_keychain}" >/dev/null 2>&1 || true

    if [ -n "${keychain_password}" ]; then
        if ! security unlock-keychain -p "${keychain_password}" "${login_keychain}" >/dev/null 2>&1; then
            log_error "Keychain unlock failed with provided password env var."
            log_error "Check SANEBAR_KEYCHAIN_PASSWORD / KEYCHAIN_PASSWORD / KEYCHAIN_PASS."
            return 1
        fi
    fi

    local codesign_probe
    codesign_probe=$(/usr/bin/mktemp /tmp/codesign_probe.XXXXXX)
    echo "sane" > "${codesign_probe}"
    if ! /usr/bin/codesign --force --sign "${SIGNING_IDENTITY}" --timestamp=none "${codesign_probe}" >/dev/null 2>&1; then
        rm -f "${codesign_probe}"
        log_error "Codesign cannot access signing key in this session."
        log_error "For headless releases, set SANEBAR_KEYCHAIN_PASSWORD (or KEYCHAIN_PASSWORD/KEYCHAIN_PASS)."
        return 1
    fi
    rm -f "${codesign_probe}"

    return 0
}

resolve_notary_auth() {
    if [ "${SKIP_NOTARIZE}" = true ]; then
        NOTARY_AUTH_MODE="skipped"
        return 0
    fi

    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        NOTARY_AUTH_MODE="keychain-profile"
        return 0
    fi

    local key_path="${NOTARY_API_KEY_PATH}"
    local key_id="${NOTARY_API_KEY_ID}"
    local issuer_id="${NOTARY_API_ISSUER_ID}"

    local any_set=0
    [ -n "${key_path}" ] && any_set=1
    [ -n "${key_id}" ] && any_set=1
    [ -n "${issuer_id}" ] && any_set=1

    local missing=()
    [ -n "${key_path}" ] || missing+=("NOTARY_API_KEY_PATH")
    [ -n "${key_id}" ] || missing+=("NOTARY_API_KEY_ID")
    [ -n "${issuer_id}" ] || missing+=("NOTARY_API_ISSUER_ID")

    if [ "${any_set}" -eq 1 ] && [ ${#missing[@]} -gt 0 ]; then
        log_error "Notary API fallback is partially configured. Missing: ${missing[*]}"
        return 1
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        if [ ! -f "${key_path}" ]; then
            log_error "NOTARY_API_KEY_PATH does not exist: ${key_path}"
            return 1
        fi
        NOTARY_AUTH_MODE="api-key"
        return 0
    fi

    log_error "Notary auth unavailable. Keychain profile '${NOTARY_PROFILE}' is inaccessible and API fallback is unset."
    log_error "Set NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID or repair notary keychain profile."
    return 1
}

prepare_xcode_provisioning_auth() {
    XCODE_PROVISIONING_AUTH_ARGS=()

    local key_path="${ASC_AUTH_KEY_PATH}"
    local key_id="${ASC_AUTH_KEY_ID}"
    local issuer_id="${ASC_AUTH_ISSUER_ID}"

    if [ -z "${key_path}" ] || [ -z "${key_id}" ] || [ -z "${issuer_id}" ]; then
        log_warn "ASC auth key values incomplete; xcodebuild will use interactive account auth."
        return 0
    fi

    if [ ! -f "${key_path}" ]; then
        log_warn "ASC auth key not found at ${key_path}; xcodebuild will use interactive account auth."
        return 0
    fi

    XCODE_PROVISIONING_AUTH_ARGS=(
        -authenticationKeyPath "${key_path}"
        -authenticationKeyID "${key_id}"
        -authenticationKeyIssuerID "${issuer_id}"
    )

    log_info "Using ASC API key auth for provisioning updates."
    return 0
}

check_version_bump_gate() {
    if [ -n "${VERSION_BUMP_CMD}" ]; then
        if [ ${#VERSION_BUMP_FILES[@]} -eq 0 ]; then
            log_error "VERSION_BUMP_CMD is set but VERSION_BUMP_FILES is empty."
            return 1
        fi

        local vf
        local missing=()
        for vf in "${VERSION_BUMP_FILES[@]}"; do
            if [ ! -f "${PROJECT_ROOT}/${vf}" ]; then
                missing+=("${vf}")
            fi
        done
        if [ ${#missing[@]} -gt 0 ]; then
            log_error "VERSION_BUMP_FILES missing: ${missing[*]}"
            return 1
        fi

        if [ -z "${VERSION}" ]; then
            log_warn "No --version provided; skipping execution test of VERSION_BUMP_CMD."
            return 0
        fi

        if [ -n "$(git -C "${PROJECT_ROOT}" status --porcelain 2>/dev/null)" ]; then
            log_error "Repo must be clean to simulate VERSION_BUMP_CMD."
            return 1
        fi

        bump_project_version "${VERSION}"

        local changed=0
        for vf in "${VERSION_BUMP_FILES[@]}"; do
            if ! git -C "${PROJECT_ROOT}" diff --quiet -- "${vf}" 2>/dev/null; then
                changed=1
            fi
        done

        restore_version_bump

        if [ "${changed}" -ne 1 ]; then
            log_error "VERSION_BUMP_CMD ran but produced no file changes."
            return 1
        fi

        return 0
    fi

    if [ -f "${PROJECT_ROOT}/project.yml" ]; then
        return 0
    fi

    log_error "No version bump strategy found (no VERSION_BUMP_CMD and no project.yml)."
    return 1
}

check_appstore_gate() {
    if [ "${APPSTORE_ENABLED}" != "true" ] || [ "${SKIP_APPSTORE}" = true ]; then
        return 0
    fi

    if [ -z "${APPSTORE_APP_ID}" ] || ! [[ "${APPSTORE_APP_ID}" =~ ^[0-9]+$ ]]; then
        log_error "APPSTORE_APP_ID is missing or invalid: '${APPSTORE_APP_ID}'"
        return 1
    fi

    if [ -z "${APPSTORE_CONTACT_EMAIL}" ]; then
        log_error "App Store contact email is missing (appstore.contact.email)."
        return 1
    fi

    return 0
}

run_release_preflight_only() {
    local failures=0

    run_gate() {
        local name="$1"
        shift
        if "$@"; then
            log_info "[PASS] ${name}"
        else
            log_error "[FAIL] ${name}"
            failures=$((failures + 1))
        fi
    }

    log_info "Running release preflight-only checks..."

    run_gate "Required commands" check_required_commands
    run_gate "Git clean" check_git_clean_gate
    run_gate "Machine reconcile" check_reconcile_gate
    run_gate "Version bump configuration" check_version_bump_gate
    run_gate "Signing identity" check_signing_identity_gate
    run_gate "Sparkle keypair" check_sparkle_keypair_gate
    run_gate "Keychain/signing session" prepare_signing_session
    run_gate "Notarization authentication" resolve_notary_auth
    run_gate "App Store configuration" check_appstore_gate

    if [ "${failures}" -gt 0 ]; then
        log_error "Preflight-only failed with ${failures} failing gate(s)."
        return 1
    fi

    log_info "Preflight-only checks passed."
    return 0
}

# Defaults/flags
PROJECT_ROOT=""
CONFIG_PATH=""
SKIP_NOTARIZE=false
SKIP_BUILD=false
FULL_RELEASE=false
VERSION=""
RELEASE_NOTES=""
XCODEGEN_DONE=false
RUN_GH_RELEASE=false
RUN_DEPLOY=false
WEBSITE_ONLY=false
ALLOW_REPUBLISH=false
ALLOW_UNSYNCED_PEER=false
SKIP_APPSTORE=false
PREFLIGHT_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --project)
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --config)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --notes)
            RELEASE_NOTES="$2"
            shift 2
            ;;
        --allow-republish)
            ALLOW_REPUBLISH=true
            shift
            ;;
        --allow-unsynced-peer)
            ALLOW_UNSYNCED_PEER=true
            shift
            ;;
        --skip-appstore)
            SKIP_APPSTORE=true
            shift
            ;;
        --full)
            FULL_RELEASE=true
            shift
            ;;
        --deploy)
            RUN_DEPLOY=true
            shift
            ;;
        --website-only)
            WEBSITE_ONLY=true
            shift
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "${PROJECT_ROOT}" ]; then
    PROJECT_ROOT="$(pwd)"
fi
PROJECT_ROOT="$(cd "${PROJECT_ROOT}" && pwd)"

if [ -z "${CONFIG_PATH}" ] && [ -f "${PROJECT_ROOT}/.saneprocess" ]; then
    CONFIG_PATH="${PROJECT_ROOT}/.saneprocess"
fi
if [ -z "${CONFIG_PATH}" ] && [ -f "${PROJECT_ROOT}/release.env" ]; then
    CONFIG_PATH="${PROJECT_ROOT}/release.env"
fi

if [ -n "${CONFIG_PATH}" ]; then
    if [ ! -f "${CONFIG_PATH}" ]; then
        log_error "Config file not found: ${CONFIG_PATH}"
        exit 1
    fi
    if [[ "${CONFIG_PATH}" = *.yml ]] || [[ "${CONFIG_PATH}" = *.yaml ]] || [[ "$(basename "${CONFIG_PATH}")" = ".saneprocess" ]]; then
        SANEPROCESS_ENV_LOADER="$(cd "$(dirname "$0")" && pwd)/saneprocess_env.rb"
        if [ ! -f "${SANEPROCESS_ENV_LOADER}" ]; then
            log_error "Missing saneprocess_env.rb (required to read YAML config)"
            exit 1
        fi
        # shellcheck disable=SC2046
        eval "$("${SANEPROCESS_ENV_LOADER}" "${CONFIG_PATH}")"
    else
        # shellcheck source=/dev/null
        set -a
        . "${CONFIG_PATH}"
        set +a
    fi
fi

APP_NAME="${APP_NAME:-$(basename "${PROJECT_ROOT}")}" 
SCHEME="${SCHEME:-${APP_NAME}}"
LOWER_APP_NAME="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"
BUNDLE_ID="${BUNDLE_ID:-com.${LOWER_APP_NAME}.app}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID env var or pass --team-id}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_ROOT}/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${BUILD_DIR}/${APP_NAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${BUILD_DIR}/Export}"
RELEASE_DIR="${RELEASE_DIR:-${PROJECT_ROOT}/releases}"
DIST_HOST="${DIST_HOST:-dist.${LOWER_APP_NAME}.com}"
SITE_HOST="${SITE_HOST:-${LOWER_APP_NAME}.com}"
R2_BUCKET="${R2_BUCKET:-sanebar-downloads}"  # Shared bucket for ALL SaneApps
USE_SPARKLE="${USE_SPARKLE:-true}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-15.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
NOTARY_API_KEY_PATH="${NOTARY_API_KEY_PATH:-}"
NOTARY_API_KEY_ID="${NOTARY_API_KEY_ID:-}"
NOTARY_API_ISSUER_ID="${NOTARY_API_ISSUER_ID:-}"
NOTARY_AUTH_MODE=""
ASC_AUTH_KEY_PATH="${ASC_AUTH_KEY_PATH:-${HOME}/.private_keys/AuthKey_S34998ZCRT.p8}"
ASC_AUTH_KEY_ID="${ASC_AUTH_KEY_ID:-S34998ZCRT}"
ASC_AUTH_ISSUER_ID="${ASC_AUTH_ISSUER_ID:-c98b1e0a-8d10-4fce-a417-536b31c09bfb}"
GITHUB_REPO="${GITHUB_REPO:-sane-apps/${APP_NAME}}"
HOMEBREW_TAP_REPO="${HOMEBREW_TAP_REPO:-sane-apps/homebrew-tap}"
XCODEGEN="${XCODEGEN:-false}"
DMG_WINDOW_POS="${DMG_WINDOW_POS:-200 120}"
DMG_WINDOW_SIZE="${DMG_WINDOW_SIZE:-800 400}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-100}"
DMG_APP_ICON_POS="${DMG_APP_ICON_POS:-200 185}"
DMG_DROP_POS="${DMG_DROP_POS:-600 185}"
DMG_HIDE_EXTENSION="${DMG_HIDE_EXTENSION:-true}"
DMG_NO_INTERNET_ENABLE="${DMG_NO_INTERNET_ENABLE:-false}"
VERIFY_STAPLE="${VERIFY_STAPLE:-false}"
RELEASE_RECONCILE_ENABLED="${RELEASE_RECONCILE_ENABLED:-true}"
RELEASE_PEER_HOST="${RELEASE_PEER_HOST:-}"
RELEASE_PEER_REPO_PATH="${RELEASE_PEER_REPO_PATH:-}"
RELEASE_PEER_BRANCH="${RELEASE_PEER_BRANCH:-main}"

WORKSPACE="${WORKSPACE:-}"
XCODEPROJ="${XCODEPROJ:-}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
EXPORT_OPTIONS_EXTRA_XML="${EXPORT_OPTIONS_EXTRA_XML:-}"
VERSION_BUMP_CMD="${VERSION_BUMP_CMD:-}"
VERSION_BUMP_RESTORE_CMD="${VERSION_BUMP_RESTORE_CMD:-}"

if ! declare -p EXPORT_OPTIONS_PROFILES >/dev/null 2>&1; then
    EXPORT_OPTIONS_PROFILES=()
fi
if ! declare -p ARCHIVE_EXTRA_ARGS >/dev/null 2>&1; then
    ARCHIVE_EXTRA_ARGS=()
fi
if ! declare -p CREATE_DMG_EXTRA_ARGS >/dev/null 2>&1; then
    CREATE_DMG_EXTRA_ARGS=()
fi
if ! declare -p VERSION_BUMP_FILES >/dev/null 2>&1; then
    VERSION_BUMP_FILES=("project.yml")
fi
if ! declare -p APPSTORE_BUILD_FLAGS >/dev/null 2>&1; then
    APPSTORE_BUILD_FLAGS=()
fi
if ! declare -p APPSTORE_STRIP_FRAMEWORKS >/dev/null 2>&1; then
    APPSTORE_STRIP_FRAMEWORKS=()
fi
if ! declare -p XCODE_PROVISIONING_AUTH_ARGS >/dev/null 2>&1; then
    XCODE_PROVISIONING_AUTH_ARGS=()
fi

WORKSPACE="$(resolve_path "${WORKSPACE}")"
XCODEPROJ="$(resolve_path "${XCODEPROJ}")"
EXPORT_OPTIONS_PLIST="$(resolve_path "${EXPORT_OPTIONS_PLIST}")"
DMG_FILE_ICON="$(resolve_path "${DMG_FILE_ICON}")"
DMG_VOLUME_ICON="$(resolve_path "${DMG_VOLUME_ICON}")"
DMG_BACKGROUND="$(resolve_path "${DMG_BACKGROUND}")"
DMG_BACKGROUND_GENERATOR="$(resolve_path "${DMG_BACKGROUND_GENERATOR}")"
ASC_AUTH_KEY_PATH="$(resolve_path "${ASC_AUTH_KEY_PATH}")"
# Resolve helper scripts: check project first, fall back to SaneProcess scripts dir
SANEPROCESS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${SIGN_UPDATE_SCRIPT}" ]; then
    if [ -f "${PROJECT_ROOT}/scripts/sign_update.swift" ]; then
        SIGN_UPDATE_SCRIPT="${PROJECT_ROOT}/scripts/sign_update.swift"
    else
        SIGN_UPDATE_SCRIPT="${SANEPROCESS_SCRIPTS_DIR}/sign_update.swift"
    fi
fi
SIGN_UPDATE_SCRIPT="$(resolve_path "${SIGN_UPDATE_SCRIPT}")"

if [ -z "${SET_DMG_ICON_SCRIPT}" ]; then
    if [ -f "${PROJECT_ROOT}/scripts/set_dmg_icon.swift" ]; then
        SET_DMG_ICON_SCRIPT="${PROJECT_ROOT}/scripts/set_dmg_icon.swift"
    else
        SET_DMG_ICON_SCRIPT="${SANEPROCESS_SCRIPTS_DIR}/set_dmg_icon.swift"
    fi
fi
SET_DMG_ICON_SCRIPT="$(resolve_path "${SET_DMG_ICON_SCRIPT}")"

# Pre-flight validation: check that configured resources exist BEFORE building
if [ -n "${DMG_FILE_ICON}" ] && [ ! -f "${DMG_FILE_ICON}" ]; then
    log_error "DMG file icon not found: ${DMG_FILE_ICON}"
    log_error "Set release.dmg.file_icon in .saneprocess to a valid path, or remove it"
    exit 1
fi
if [ -n "${DMG_VOLUME_ICON}" ] && [ ! -f "${DMG_VOLUME_ICON}" ]; then
    log_error "DMG volume icon not found: ${DMG_VOLUME_ICON}"
    log_error "Set release.dmg.volume_icon in .saneprocess to a valid path, or remove it"
    exit 1
fi
if [ -n "${DMG_BACKGROUND}" ] && [ ! -f "${DMG_BACKGROUND}" ]; then
    log_error "DMG background not found: ${DMG_BACKGROUND}"
    log_error "Set release.dmg.background in .saneprocess to a valid path, or remove it"
    exit 1
fi

cd "${PROJECT_ROOT}"

# Website-only deploy (no build, no R2, no signing — just push website + appcast to Pages)
if [ "${WEBSITE_ONLY}" = true ]; then
    PAGES_PROJECT="${LOWER_APP_NAME}-site"
    # Prefer website/ dir (has full HTML site), fall back to docs/
    if [ -d "${PROJECT_ROOT}/website" ]; then
        DEPLOY_DIR="${PROJECT_ROOT}/website"
        # Ensure appcast.xml is included
        if [ -f "${PROJECT_ROOT}/docs/appcast.xml" ] && [ ! -f "${DEPLOY_DIR}/appcast.xml" ]; then
            cp "${PROJECT_ROOT}/docs/appcast.xml" "${DEPLOY_DIR}/appcast.xml"
            log_info "Copied appcast.xml from docs/ to website/"
        fi
    elif [ -d "${PROJECT_ROOT}/docs" ]; then
        DEPLOY_DIR="${PROJECT_ROOT}/docs"
    else
        log_error "No website/ or docs/ directory found"
        exit 1
    fi
    log_info "Deploying website to Cloudflare Pages (${PAGES_PROJECT}) from ${DEPLOY_DIR}..."
    npx wrangler pages deploy "${DEPLOY_DIR}" \
        --project-name="${PAGES_PROJECT}" \
        --commit-dirty=true \
        --commit-message="Website update $(date +%Y-%m-%d)"
    log_info "Website deploy complete."
    # Verify
    if [ -f "${DEPLOY_DIR}/appcast.xml" ]; then
        APPCAST_URL="https://${SITE_HOST}/appcast.xml"
        APPCAST_STATUS=$(extract_http_status "${APPCAST_URL}")
        if [ "${APPCAST_STATUS}" != "200" ]; then
            log_error "Appcast URL failed after deploy: ${APPCAST_URL} returned HTTP ${APPCAST_STATUS}"
            exit 1
        fi
        APPCAST_CONTENT=$(curl -fsSL "${APPCAST_URL}" 2>/dev/null || true)
        if [ -z "${APPCAST_CONTENT}" ]; then
            log_error "Failed to fetch appcast content after deploy: ${APPCAST_URL}"
            exit 1
        fi
        if command -v xmllint >/dev/null 2>&1; then
            if ! xmllint --noout - <<< "${APPCAST_CONTENT}" >/dev/null 2>&1; then
                log_error "Appcast XML invalid after website-only deploy: ${APPCAST_URL}"
                exit 1
            fi
        fi
        log_info "Appcast verified at ${APPCAST_URL}"
    fi
    exit 0
fi

if [ "${PREFLIGHT_ONLY}" = true ]; then
    if run_release_preflight_only; then
        exit 0
    fi
    exit 1
fi

# Full release flow
if [ "${FULL_RELEASE}" = true ]; then
    if [ -z "${VERSION}" ]; then
        log_error "--full requires --version X.Y.Z"
        exit 1
    fi
    if [ -z "${RELEASE_NOTES}" ]; then
        log_error "--full requires --notes \"Release notes\""
        exit 1
    fi

    ensure_cmd git
    ensure_git_clean
    enforce_machine_reconcile

    # ─── Pre-release safety gates (learned from 46 issues + 200 emails) ───

    # Gate 1: UserDefaults / migration change detection
    # Settings migration is #1 cause of customer bugs (50% of critical issues)
    DEFAULTS_CHANGED=$(git -C "${PROJECT_ROOT}" diff HEAD~5..HEAD --name-only -- '*.swift' | \
        xargs grep -l 'UserDefaults\|setDefaultsIfNeeded\|registerDefaults\|migration\|migrate' 2>/dev/null | head -5)
    if [ -n "${DEFAULTS_CHANGED}" ]; then
        log_warn "═══ UPGRADE SAFETY WARNING ═══"
        log_warn "These files touch UserDefaults/migration logic:"
        echo "${DEFAULTS_CHANGED}" | while read f; do log_warn "  - ${f}"; done
        log_warn "This is the #1 cause of customer regressions (v1.0.20 broke 5+ users)."
        log_warn "BEFORE SHIPPING: test upgrade path from previous version with existing user data."
        log_warn "════════════════════════════════"
    fi

    # Gate 2: Pending customer emails
    EMAIL_API_KEY=$(security find-generic-password -s sane-email-automation -a api_key -w 2>/dev/null || echo "")
    if [ -n "${EMAIL_API_KEY}" ]; then
        PENDING_COUNT=$(curl -s "https://email-api.saneapps.com/api/emails/pending" \
            -H "Authorization: Bearer ${EMAIL_API_KEY}" 2>/dev/null | \
            python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [ "${PENDING_COUNT}" -gt 0 ] 2>/dev/null; then
            log_warn "${PENDING_COUNT} pending customer email(s) — review before shipping."
        fi
    fi

    # Gate 3: Open GitHub issues
    if [ -n "${GITHUB_REPO}" ] && command -v gh >/dev/null 2>&1; then
        OPEN_ISSUES=$(gh issue list --repo "${GITHUB_REPO}" --state open --json number 2>/dev/null | \
            python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [ "${OPEN_ISSUES}" -gt 0 ] 2>/dev/null; then
            log_warn "${OPEN_ISSUES} open GitHub issue(s) — review before shipping."
        fi
    fi

    # Gate 4: Evening release warning (8-18hr discovery window if broken)
    HOUR=$(date +%H)
    if [ "${HOUR}" -ge 17 ] || [ "${HOUR}" -lt 6 ]; then
        log_warn "Evening/night release detected ($(date +%H:%M))."
        log_warn "Bugs won't be discovered until morning. Prefer morning releases."
    fi

    # Gate 5: License validation endpoint reachable
    LICENSE_API="https://api.lemonsqueezy.com/v1/licenses/validate"
    LICENSE_STATUS=$(curl -sI -o /dev/null -w '%{http_code}' "${LICENSE_API}" 2>/dev/null || echo "000")
    if [ "${LICENSE_STATUS}" = "000" ]; then
        log_warn "LemonSqueezy license API unreachable (network error)."
        log_warn "Licensing features won't work for new activations until API is back."
    elif [ "${LICENSE_STATUS}" -ge 400 ] && [ "${LICENSE_STATUS}" -lt 500 ]; then
        # 4xx is expected for a bare POST with no body — means API is responding
        log_info "License API reachable (${LICENSE_STATUS} — expected without payload)"
    elif [ "${LICENSE_STATUS}" -ge 500 ]; then
        log_warn "LemonSqueezy API returned ${LICENSE_STATUS} — may be experiencing issues."
    fi

    # README sync check — warn if features aren't documented
    README_CHECK="${SCRIPT_DIR}/automation/nv-readme-check.sh"
    if [ -f "${README_CHECK}" ] && [ -x "${README_CHECK}" ]; then
        log_info "Checking README sync with shipped features..."
        if ! "${README_CHECK}" "${PROJECT_ROOT}" 2>/dev/null; then
            log_warn "README may be out of date with shipped features (see above)."
            log_warn "Consider updating README.md before release. Continuing..."
        fi
    fi

    run_tests

    log_info "Bumping version to ${VERSION}..."
    bump_project_version "${VERSION}"

    VERSION_BUMP_CHANGED=0
    for vf in "${VERSION_BUMP_FILES[@]}"; do
        if ! git -C "${PROJECT_ROOT}" diff --quiet -- "${vf}" 2>/dev/null; then
            VERSION_BUMP_CHANGED=1
        fi
    done
    if [ "${VERSION_BUMP_CHANGED}" -ne 1 ]; then
        log_error "Version bump produced no tracked file changes. Aborting release."
        restore_version_bump
        exit 1
    fi

    update_changelog

    if [ "${XCODEGEN}" = true ]; then
        ensure_cmd xcodegen
        log_info "Regenerating Xcode project..."
        xcodegen generate
        XCODEGEN_DONE=true
    fi

    commit_version_bump
    RUN_GH_RELEASE=false
fi

# Clean up previous builds (skip if reusing existing archive)
if [ "${SKIP_BUILD}" = false ]; then
    log_info "Cleaning previous build artifacts..."
    remove_path "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}"

# Generate project if requested
if [ "${XCODEGEN}" = true ] && [ "${XCODEGEN_DONE}" = false ]; then
    ensure_cmd xcodegen
    log_info "Generating Xcode project..."
    xcodegen generate
fi

ensure_cmd xcodebuild
ensure_cmd codesign
ensure_cmd xcrun
ensure_cmd hdiutil
ensure_cmd ditto

# Fail early if signing/notarization prerequisites are missing.
if ! prepare_signing_session; then
    exit 1
fi

if ! resolve_notary_auth; then
    exit 1
fi

if ! prepare_xcode_provisioning_auth; then
    exit 1
fi

if [ "${NOTARY_AUTH_MODE}" = "api-key" ]; then
    log_info "Using notarytool API key fallback auth."
elif [ "${NOTARY_AUTH_MODE}" = "keychain-profile" ]; then
    log_info "Using notarytool keychain profile auth (${NOTARY_PROFILE})."
fi

# Build archive
if [ "${SKIP_BUILD}" = false ]; then
    log_info "Building release archive..."

    archive_args=(archive -scheme "${SCHEME}" -configuration Release -archivePath "${ARCHIVE_PATH}" -destination "generic/platform=macOS" OTHER_CODE_SIGN_FLAGS="--timestamp")
    if [ -n "${WORKSPACE}" ]; then
        archive_args=(-workspace "${WORKSPACE}" "${archive_args[@]}")
    elif [ -n "${XCODEPROJ}" ]; then
        archive_args=(-project "${XCODEPROJ}" "${archive_args[@]}")
    fi
    if [ ${#ARCHIVE_EXTRA_ARGS[@]} -gt 0 ]; then
        archive_args+=("${ARCHIVE_EXTRA_ARGS[@]}")
    fi

    xcodebuild "${archive_args[@]}" 2>&1 | tee "${BUILD_DIR}/build.log"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Archive build failed! Check ${BUILD_DIR}/build.log"
        exit 1
    fi

    # Verify bundle ID inside archive
    archive_app_path="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
    if [ ! -d "${archive_app_path}" ]; then
        log_error "Archive app not found at ${archive_app_path}"
        exit 1
    fi

    archive_bundle_id=$(defaults read "${archive_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    if [ -z "${archive_bundle_id}" ]; then
        log_error "Unable to read CFBundleIdentifier from archive app"
        exit 1
    fi

    if [ "${archive_bundle_id}" != "${BUNDLE_ID}" ]; then
        log_error "Bundle ID mismatch: expected ${BUNDLE_ID}, got ${archive_bundle_id}"
        exit 1
    fi
fi

# Export archive
log_info "Creating export options..."
EXPORT_OPTIONS_PATH="${BUILD_DIR}/ExportOptions.plist"
write_export_options_plist "${EXPORT_OPTIONS_PATH}"

log_info "Exporting signed app..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
    -allowProvisioningUpdates \
    "${XCODE_PROVISIONING_AUTH_ARGS[@]}" \
    2>&1 | tee -a "${BUILD_DIR}/build.log"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_error "Export failed! Check ${BUILD_DIR}/build.log"
    exit 1
fi

APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"

# Notarization preflight
fix_and_verify_zipped_apps_in_app "${APP_PATH}"
sanity_check_app_for_notarization "${APP_PATH}"

# Verify code signature
log_info "Verifying code signature..."
codesign --verify --deep --strict "${APP_PATH}"
log_info "Code signature verified!"

# Verify Sparkle configuration
if [ "${USE_SPARKLE}" = true ]; then
    log_info "Verifying Sparkle configuration..."
    PLIST_FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
    PLIST_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
    if [ -z "${PLIST_FEED}" ]; then
        log_error "SUFeedURL missing from Info.plist!"
        exit 1
    fi
    if [ -z "${PLIST_KEY}" ]; then
        log_error "SUPublicEDKey missing from Info.plist!"
        exit 1
    fi
    # Verify key VALUE matches the shared SaneApps key (not just exists)
    # Per-project keys broke updates for ALL shipped customers
    if [ "${PLIST_KEY}" != "${SHARED_SPARKLE_PUBLIC_KEY}" ]; then
        log_error "SUPublicEDKey MISMATCH! Built app has wrong Sparkle key."
        log_error "  Expected: ${SHARED_SPARKLE_PUBLIC_KEY}"
        log_error "  Got:      ${PLIST_KEY}"
        log_error "This will break auto-update for ALL existing customers!"
        exit 1
    fi
    log_info "SUFeedURL: ${PLIST_FEED}"
    log_info "SUPublicEDKey: ${PLIST_KEY} (verified)"
fi

# App Store build + export (if enabled in .saneprocess)
# CRITICAL: App Store builds need a SEPARATE archive with a different configuration
# (e.g., Release-AppStore) to exclude direct-distribution frameworks like Sparkle.
# Reusing the Developer ID archive would produce a binary that links Sparkle at
# @rpath but doesn't include it — instant dyld crash on launch.
if [ "${APPSTORE_ENABLED}" = "true" ] && [ "${SKIP_APPSTORE}" = false ]; then
    APPSTORE_CONFIG="${APPSTORE_CONFIGURATION:-Release-AppStore}"
    APPSTORE_SCHEME_VALUE="${APPSTORE_SCHEME:-${SCHEME}}"
    APPSTORE_ARCHIVE="${BUILD_DIR}/${APP_NAME}-AppStore.xcarchive"
    APPSTORE_EXPORT_PATH="${BUILD_DIR}/Export-AppStore"
    mkdir -p "${APPSTORE_EXPORT_PATH}"

    if [ "${SKIP_BUILD}" = false ]; then
        log_info ""
        log_info "Building App Store archive (configuration: ${APPSTORE_CONFIG})..."

        appstore_archive_args=(archive -scheme "${APPSTORE_SCHEME_VALUE}" -configuration "${APPSTORE_CONFIG}" \
            -archivePath "${APPSTORE_ARCHIVE}" \
            -destination "generic/platform=macOS" OTHER_CODE_SIGN_FLAGS="--timestamp" \
            -allowProvisioningUpdates)
        if [ -n "${APPSTORE_ENTITLEMENTS}" ]; then
            has_entitlements_flag=false
            for build_flag in "${APPSTORE_BUILD_FLAGS[@]}"; do
                if [[ "${build_flag}" == CODE_SIGN_ENTITLEMENTS=* ]]; then
                    has_entitlements_flag=true
                    break
                fi
            done
            if [ "${has_entitlements_flag}" = false ]; then
                appstore_archive_args+=("CODE_SIGN_ENTITLEMENTS=${APPSTORE_ENTITLEMENTS}")
            fi
        fi
        if [ ${#APPSTORE_BUILD_FLAGS[@]} -gt 0 ]; then
            appstore_archive_args+=("${APPSTORE_BUILD_FLAGS[@]}")
        fi
        if [ ${#XCODE_PROVISIONING_AUTH_ARGS[@]} -gt 0 ]; then
            appstore_archive_args+=("${XCODE_PROVISIONING_AUTH_ARGS[@]}")
        fi
        if [ -n "${WORKSPACE}" ]; then
            appstore_archive_args=(-workspace "${WORKSPACE}" "${appstore_archive_args[@]}")
        elif [ -n "${XCODEPROJ}" ]; then
            appstore_archive_args=(-project "${XCODEPROJ}" "${appstore_archive_args[@]}")
        fi
        if [ ${#ARCHIVE_EXTRA_ARGS[@]} -gt 0 ]; then
            appstore_archive_args+=("${ARCHIVE_EXTRA_ARGS[@]}")
        fi

        xcodebuild "${appstore_archive_args[@]}" 2>&1 | tee -a "${BUILD_DIR}/build.log"

        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "App Store archive build failed! Check ${BUILD_DIR}/build.log"
            exit 1
        fi
    fi

    if [ ${#APPSTORE_STRIP_FRAMEWORKS[@]} -gt 0 ]; then
        for framework_name in "${APPSTORE_STRIP_FRAMEWORKS[@]}"; do
            framework_path="${APPSTORE_ARCHIVE}/Products/Applications/${APP_NAME}.app/Contents/Frameworks/${framework_name}"
            if [ -d "${framework_path}" ]; then
                log_info "Removing ${framework_name} from App Store archive..."
                remove_path "${framework_path}"
            fi
        done
    fi

    # Weaken Sparkle dylib reference in the archive binary.
    # SPM links Sparkle unconditionally; this changes LC_LOAD_DYLIB → LC_LOAD_WEAK_DYLIB
    # so dyld skips the missing framework instead of crashing on launch.
    APPSTORE_APP_IN_ARCHIVE="${APPSTORE_ARCHIVE}/Products/Applications/${APP_NAME}.app"
    if [ -d "${APPSTORE_APP_IN_ARCHIVE}" ]; then
        ARCHIVE_EXEC=$(defaults read "${APPSTORE_APP_IN_ARCHIVE}/Contents/Info" CFBundleExecutable 2>/dev/null || true)
        if [ -n "${ARCHIVE_EXEC}" ]; then
            ARCHIVE_BINARY="${APPSTORE_APP_IN_ARCHIVE}/Contents/MacOS/${ARCHIVE_EXEC}"
            if [ -f "${ARCHIVE_BINARY}" ]; then
                if otool -L "${ARCHIVE_BINARY}" 2>/dev/null | grep -q "Sparkle.framework"; then
                    if binary_has_strong_sparkle_load "${ARCHIVE_BINARY}"; then
                        log_info "Weakening Sparkle dylib reference in App Store binary..."
                        if ! ruby "${SCRIPT_DIR}/weaken_sparkle.rb" "${ARCHIVE_BINARY}"; then
                            log_error "Failed to weaken Sparkle reference. App Store build may crash on launch."
                            exit 1
                        fi
                    else
                        log_info "Sparkle dylib already weak-linked in App Store binary."
                    fi
                fi
            fi
        fi
    fi

    # Dylib preflight: verify no missing dynamic library references BEFORE uploading
    # This catches the Sparkle-not-stripped class of crash before we upload to ASC
    appstore_app="${APPSTORE_ARCHIVE}/Products/Applications/${APP_NAME}.app"
    if [ -d "${appstore_app}" ]; then
        if ! preflight_check_dylibs "${appstore_app}" "App Store"; then
            log_error "App Store dylib preflight FAILED — aborting before upload."
            log_error "The binary references frameworks not present in the bundle."
            log_error "Ensure ${APPSTORE_CONFIG} configuration excludes direct-distribution"
            log_error "frameworks (Sparkle, etc.) via compiler flags (#if !APP_STORE)."
            exit 1
        fi
    fi

    log_info "Exporting for App Store..."
    APPSTORE_PLIST="${BUILD_DIR}/ExportOptions-AppStore.plist"
    write_export_options_appstore_plist "${APPSTORE_PLIST}"

    xcodebuild -exportArchive \
        -archivePath "${APPSTORE_ARCHIVE}" \
        -exportPath "${APPSTORE_EXPORT_PATH}" \
        -exportOptionsPlist "${APPSTORE_PLIST}" \
        -allowProvisioningUpdates \
        "${XCODE_PROVISIONING_AUTH_ARGS[@]}" \
        2>&1 | tee -a "${BUILD_DIR}/build.log"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "App Store export failed! Check ${BUILD_DIR}/build.log"
        exit 1
    fi

    APPSTORE_PKG="${APPSTORE_EXPORT_PATH}/${APP_NAME}.pkg"
    if [ ! -f "${APPSTORE_PKG}" ]; then
        log_error "App Store export succeeded but no .pkg was produced at ${APPSTORE_PKG}"
        log_error "Headless release requires a local .pkg for API-key upload."
        exit 1
    else
        log_info "App Store artifact: ${APPSTORE_PKG}"
    fi
fi

# Get version from app
if [ -z "${VERSION}" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0.0")
fi
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1")
log_info "Version: ${VERSION} (${BUILD_NUMBER})"

# Package as ZIP (simpler, app icon survives HTTP download, no resource fork issues)
ZIP_NAME="${APP_NAME}-${VERSION}"
NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}.zip"

# Create temporary zip for notarization submission
log_info "Creating ZIP for notarization..."
ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"

# Notarize (if not skipped)
if [ "${SKIP_NOTARIZE}" = false ]; then
    log_info "Submitting for notarization..."
    log_warn "This may take several minutes..."

    if [ "${NOTARY_AUTH_MODE}" = "api-key" ]; then
        xcrun notarytool submit "${NOTARIZE_ZIP}" \
            --key "${NOTARY_API_KEY_PATH}" \
            --key-id "${NOTARY_API_KEY_ID}" \
            --issuer "${NOTARY_API_ISSUER_ID}" \
            --wait
    else
        xcrun notarytool submit "${NOTARIZE_ZIP}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait
    fi

    log_info "Stapling notarization ticket to app..."
    xcrun stapler staple "${APP_PATH}"

    if [ "${VERIFY_STAPLE}" = true ]; then
        log_info "Verifying staple..."
        xcrun stapler validate "${APP_PATH}"
    fi

    log_info "Notarization complete!"
else
    log_warn "Skipping notarization (--skip-notarize flag set)"
fi

# Create final distribution ZIP (with stapled notarization ticket)
log_info "Creating distribution ZIP..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

# Clean up temp notarization zip
rm -f "${NOTARIZE_ZIP}"

# Copy to releases folder
FINAL_ZIP="${RELEASE_DIR}/${ZIP_NAME}.zip"
remove_path "${FINAL_ZIP}"
ditto "${ZIP_PATH}" "${FINAL_ZIP}"

log_info "========================================"
log_info "Release build complete!"
log_info "========================================"
log_info "ZIP: ${FINAL_ZIP}"
log_info "Version: ${VERSION}"

# Metadata used by deploy and post-release checks (always compute).
SHA256=$(shasum -a 256 "${FINAL_ZIP}" | awk '{print $1}')
FILE_SIZE=$(stat -f%z "${FINAL_ZIP}")

# Generate Sparkle Signature
if [ "${USE_SPARKLE}" = true ] && command -v swift >/dev/null 2>&1; then
    log_info ""
    log_info "--- Generating Release Metadata ---"

    log_info "Fetching Sparkle Private Key from Keychain..."
    SPARKLE_KEY=$(resolve_sparkle_private_key || true)

    if [ -n "${SPARKLE_KEY}" ]; then
        DERIVED_SPARKLE_PUBLIC_KEY=$(derive_sparkle_public_key "${SPARKLE_KEY}" || true)
        if [ -z "${DERIVED_SPARKLE_PUBLIC_KEY}" ]; then
            log_error "Unable to derive Sparkle public key from private key."
            exit 1
        fi
        if [ "${DERIVED_SPARKLE_PUBLIC_KEY}" != "${SHARED_SPARKLE_PUBLIC_KEY}" ]; then
            log_error "Sparkle keypair mismatch during signing."
            log_error "  Expected public key: ${SHARED_SPARKLE_PUBLIC_KEY}"
            log_error "  Derived public key:  ${DERIVED_SPARKLE_PUBLIC_KEY}"
            exit 1
        fi

        log_info "Sparkle Key found. Generating signature..."

        if [ -f "${SIGN_UPDATE_SCRIPT}" ]; then
            SIGNATURE=$(swift "${SIGN_UPDATE_SCRIPT}" "${FINAL_ZIP}" "${SPARKLE_KEY}" 2>/dev/null || echo "")
        else
            SIGNATURE=""
        fi

        if [ -n "${SIGNATURE}" ]; then
            DATE=$(date +"%a, %d %b %Y %H:%M:%S %z")

            echo -e "${GREEN}Sparkle AppCast Item:${NC}"
            cat <<EOF
        <item>
            <title>${VERSION}</title>
            <pubDate>${DATE}</pubDate>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <description>
                <![CDATA[
                <h2>Changes</h2>
                <p>${RELEASE_NOTES:-Update to version ${VERSION}}</p>
                ]]>
            </description>
            <enclosure url="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip"
                       sparkle:version="${BUILD_NUMBER}"
                       sparkle:shortVersionString="${VERSION}"
                       length="${FILE_SIZE}"
                       type="application/octet-stream"
                       sparkle:edSignature="${SIGNATURE}"/>
        </item>
EOF
        else
            log_error "Failed to generate Sparkle signature. Check Swift and key format."
        fi
    else
        log_warn "Sparkle Private Key not found in Keychain. Skipping signature generation."
    fi

    echo ""
    echo -e "${GREEN}Release Info:${NC}"
    echo "Version: ${VERSION} (Build ${BUILD_NUMBER})"
    echo "SHA256: ${SHA256}"
    echo "Size: ${FILE_SIZE} bytes"

    cat > "${BUILD_DIR}/${APP_NAME}-${VERSION}.meta" <<METAEOF
VERSION=${VERSION}
BUILD=${BUILD_NUMBER}
SHA256=${SHA256}
SIZE=${FILE_SIZE}
SIGNATURE=${SIGNATURE:-UNSIGNED}
METAEOF
    log_info "Saved release metadata to ${BUILD_DIR}/${APP_NAME}-${VERSION}.meta"
fi

if [ "${RUN_GH_RELEASE}" = true ]; then
    log_info ""
    log_info "Creating/updating GitHub release..."
    create_github_release
    upload_github_release_asset
fi

# Guardrail: by default do not republish an already-live Sparkle version/build.
ensure_not_republishing_live_version() {
    if [ "${ALLOW_REPUBLISH}" = true ]; then
        log_warn "Republish override enabled (--allow-republish)."
        return 0
    fi

    if [ "${USE_SPARKLE}" != "true" ]; then
        return 0
    fi

    local appcast_url="https://${SITE_HOST}/appcast.xml"
    local appcast_content
    appcast_content=$(curl -fsSL "${appcast_url}" 2>/dev/null || true)
    if [ -z "${appcast_content}" ]; then
        # If appcast is unavailable we cannot prove duplicate; continue and let later checks fail if needed.
        return 0
    fi

    local live_count
    live_count=$(appcast_item_count_for_version "${appcast_content}")
    if [ "${live_count}" -ge 1 ]; then
        log_error "Refusing to republish v${VERSION} (${BUILD_NUMBER}): live appcast already has ${live_count} entr$( [ "${live_count}" = "1" ] && echo "y" || echo "ies" )."
        log_error "Sparkle users on v${VERSION} will not receive an update without a version/build bump."
        log_error "Bump version (recommended) or rerun with --allow-republish for emergency replacement."
        exit 1
    fi
}

# ─── Deploy: R2 upload + appcast update + Pages deploy ───
if [ "${RUN_DEPLOY}" = true ]; then
    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "  DEPLOYING TO PRODUCTION"
    log_info "═══════════════════════════════════════════"

    ensure_not_republishing_live_version

    # Step 1: Upload ZIP to R2
    log_info "Uploading ZIP to R2 bucket ${R2_BUCKET}..."
    ensure_cmd npx
    R2_OBJECT_KEY="updates/${APP_NAME}-${VERSION}.zip"
    npx wrangler r2 object put "${R2_BUCKET}/${R2_OBJECT_KEY}" \
        --file="${FINAL_ZIP}" --remote
    log_info "R2 upload complete."

    # Verify R2 upload
    log_info "Verifying download URL..."
    HTTP_STATUS=$(curl -A "Sparkle/2" -sI "https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip" | head -1 | awk '{print $2}')
    if [ "${HTTP_STATUS}" != "200" ] && [ "${HTTP_STATUS}" != "206" ]; then
        log_error "R2 verification FAILED! https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip returned ${HTTP_STATUS}"
        log_error "Check dist Worker routing and anti-bot rules for non-browser user agents."
        exit 1
    fi
    log_info "Download verified: https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip (${HTTP_STATUS})"

    # Step 1b: Clean up old versions from R2
    # Only the current version should exist — old files attract bot traffic and waste storage.
    # Uses Cloudflare REST API (wrangler has no object list command).
    log_info "Cleaning old ${APP_NAME} versions from R2..."
    CF_TOKEN=$(security find-generic-password -s cloudflare -a api_token -w 2>/dev/null)
    if [ -z "${CF_TOKEN}" ]; then
        CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
    fi
    CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-2c267ab06352ba2522114c3081a8c5fa}"

    if [ -n "${CF_TOKEN}" ]; then
        # List all objects in bucket via CF API, filter to this app's old versions.
        # Single-quoted -c string avoids bash expansion of != and other specials.
        # App name and version passed via sys.argv; JSON piped via stdin.
        R2_API_URL="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets/${R2_BUCKET}/objects"
        OLD_KEYS=$(curl -s "${R2_API_URL}" -H "Authorization: Bearer ${CF_TOKEN}" \
            | python3 -c '
import sys, json
app_name, version = sys.argv[1], sys.argv[2]
keep = f"updates/{app_name}-{version}.zip"
legacy_keep = f"{app_name}-{version}.zip"
prefixes = (f"updates/{app_name}-", f"{app_name}-")
data = json.load(sys.stdin)
for obj in data.get("result", []):
    key = obj.get("key", "")
    if any(key.startswith(p) for p in prefixes) and key not in (keep, legacy_keep):
        print(key)
' "${APP_NAME}" "${VERSION}" 2>/dev/null)

        OLD_COUNT=0
        if [ -n "${OLD_KEYS}" ]; then
            while IFS= read -r OLD_KEY; do
                ENCODED_KEY=$(python3 -c "from urllib.parse import quote; print(quote('${OLD_KEY}', safe=''))")
                DEL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                    "${R2_API_URL}/${ENCODED_KEY}" \
                    -H "Authorization: Bearer ${CF_TOKEN}")
                if [ "${DEL_STATUS}" = "200" ]; then
                    log_info "  Deleted old version: ${OLD_KEY}"
                    OLD_COUNT=$((OLD_COUNT + 1))
                else
                    log_warn "  Failed to delete: ${OLD_KEY} (HTTP ${DEL_STATUS}, non-fatal)"
                fi
            done <<< "${OLD_KEYS}"
            log_info "Cleaned ${OLD_COUNT} old version(s) from R2."
        else
            log_info "No old versions to clean up."
        fi
    else
        log_warn "Skipping R2 cleanup — no Cloudflare API token available."
        log_warn "Old versions may accumulate. Set 'cloudflare' keychain entry or CLOUDFLARE_API_TOKEN env var."
    fi

    # Step 2: Update appcast.xml
    if [ "${USE_SPARKLE}" = true ] && [ -n "${SIGNATURE}" ] && [ "${SIGNATURE}" != "UNSIGNED" ]; then
        APPCAST_PATH="${PROJECT_ROOT}/docs/appcast.xml"
        if [ -f "${APPCAST_PATH}" ]; then
            log_info "Updating appcast.xml with v${VERSION}..."
            PUB_DATE=$(date -R)

            NEW_ITEM=$(cat <<APPCASTEOF
        <item>
            <title>${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <description>
                <![CDATA[
                <h2>Changes</h2>
                <p>${RELEASE_NOTES:-Update to version ${VERSION}}</p>
                ]]>
            </description>
            <enclosure url="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip"
                       sparkle:version="${BUILD_NUMBER}"
                       sparkle:shortVersionString="${VERSION}"
                       length="${FILE_SIZE}"
                       type="application/octet-stream"
                       sparkle:edSignature="${SIGNATURE}"/>
        </item>
APPCASTEOF
)
            # Remove stale entries for this version/build first to avoid duplicate release items.
            prune_existing_appcast_entries "${APPCAST_PATH}"

            # Insert new item before first existing <item>, or before </channel> if empty.
            APPCAST_NEW_ITEM="${NEW_ITEM}" python3 - "${APPCAST_PATH}" <<'PY'
import os
import sys

path = sys.argv[1]
new_item = os.environ.get("APPCAST_NEW_ITEM", "").rstrip() + "\n"

with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

item_idx = xml.find("<item>")
if item_idx != -1:
    xml = xml[:item_idx] + new_item + xml[item_idx:]
elif "</channel>" in xml:
    xml = xml.replace("</channel>", f"{new_item}</channel>", 1)
else:
    raise SystemExit("appcast.xml missing </channel>")

with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

            # Validate local appcast before deploy.
            if command -v xmllint >/dev/null 2>&1; then
                if ! xmllint --noout "${APPCAST_PATH}" >/dev/null 2>&1; then
                    log_error "Local appcast is invalid XML after update: ${APPCAST_PATH}"
                    exit 1
                fi
            fi
            LOCAL_APPCAST_CONTENT=$(cat "${APPCAST_PATH}")
            LOCAL_COUNT=$(appcast_item_count_for_version "${LOCAL_APPCAST_CONTENT}")
            if [ "${LOCAL_COUNT}" != "1" ]; then
                log_error "Local appcast contains ${LOCAL_COUNT} entries for v${VERSION} (expected 1)"
                exit 1
            fi

            log_info "Appcast updated with v${VERSION} entry."
        else
            log_warn "No appcast.xml found at ${APPCAST_PATH}. Skipping appcast update."
        fi
    else
        log_warn "No Sparkle signature available. Skipping appcast update."
        log_warn "Run with USE_SPARKLE=true and ensure EdDSA key is in Keychain."
    fi

    # Step 2.5: Auto-update website download links to current version
    # Prevents stale download URLs (v1.5.0 link shipped with v2.1.0 — never again)
    DOCS_DIR="${PROJECT_ROOT}/docs"
    WEBSITE_DIR="${PROJECT_ROOT}/website"
    DOWNLOAD_URL="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip"

    for SITE_DIR in "${DOCS_DIR}" "${WEBSITE_DIR}"; do
        INDEX_HTML="${SITE_DIR}/index.html"
        if [ -f "${INDEX_HTML}" ]; then
            # Replace any old download links (SaneBar-X.Y.Z.zip) with current version
            OLD_LINKS=$(grep -c "${APP_NAME}-[0-9].*\.zip" "${INDEX_HTML}" 2>/dev/null)
            OLD_LINKS=${OLD_LINKS:-0}
            if [ "${OLD_LINKS}" -gt 0 ]; then
                sed -i '' "s|${APP_NAME}-[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\.zip|${APP_NAME}-${VERSION}.zip|g" "${INDEX_HTML}"
                log_info "Updated ${OLD_LINKS} download link(s) in $(basename "${SITE_DIR}")/index.html → ${APP_NAME}-${VERSION}.zip"
            fi
            # Update softwareVersion in JSON-LD structured data
            if grep -q '"softwareVersion"' "${INDEX_HTML}" 2>/dev/null; then
                sed -i '' "s|\"softwareVersion\": \"[^\"]*\"|\"softwareVersion\": \"${VERSION}\"|g" "${INDEX_HTML}"
                log_info "Updated softwareVersion in $(basename "${SITE_DIR}")/index.html → ${VERSION}"
            fi
        fi
    done

    # Step 3: Deploy website + appcast to Cloudflare Pages
    PAGES_PROJECT="${LOWER_APP_NAME}-site"
    if [ -d "${DOCS_DIR}" ]; then
        log_info "Deploying website + appcast to Cloudflare Pages (${PAGES_PROJECT})..."
        npx wrangler pages deploy "${DOCS_DIR}" \
            --project-name="${PAGES_PROJECT}" \
            --commit-dirty=true \
            --commit-message="Release v${VERSION}"
        log_info "Pages deploy complete."

        # Verify appcast propagation and uniqueness (blocking) for Sparkle apps.
        if [ "${USE_SPARKLE}" = true ]; then
            log_info "Verifying appcast propagation..."
            if ! wait_for_live_appcast_version "https://${SITE_HOST}/appcast.xml"; then
                log_error "Appcast propagation failed for v${VERSION}. Aborting release."
                exit 1
            fi
        fi
    else
        log_warn "No docs/ directory found. Skipping Pages deploy."
    fi

    # Step 4: Verify checkout/purchase link still works
    # LemonSqueezy slug change broke 26 URLs for 44 hours ($40 lost)
    CHECKOUT_URL="https://go.saneapps.com/buy/${LOWER_APP_NAME}"
    CHECKOUT_STATUS=$(curl -sI -o /dev/null -w '%{http_code}' "${CHECKOUT_URL}" 2>/dev/null || echo "000")
    if [ "${CHECKOUT_STATUS}" = "200" ] || [ "${CHECKOUT_STATUS}" = "301" ] || [ "${CHECKOUT_STATUS}" = "302" ]; then
        log_info "Checkout link verified: ${CHECKOUT_URL} (${CHECKOUT_STATUS})"
    elif [ "${CHECKOUT_STATUS}" = "000" ]; then
        log_warn "Could not reach checkout URL: ${CHECKOUT_URL} (network error)"
    else
        log_warn "Checkout link may be broken: ${CHECKOUT_URL} returned ${CHECKOUT_STATUS}"
        log_warn "Test the purchase flow manually before announcing this release."
    fi

    # Step 5: App Store submission (if enabled)
    if [ "${APPSTORE_ENABLED}" = "true" ] && [ "${SKIP_APPSTORE}" = true ]; then
        log_warn "App Store submission skipped (--skip-appstore)."
    fi

    if [ "${APPSTORE_ENABLED}" = "true" ] && [ "${SKIP_APPSTORE}" = false ]; then
        log_info ""
        log_info "═══════════════════════════════════════════"
        log_info "  SUBMITTING TO APP STORE"
        log_info "═══════════════════════════════════════════"

        APPSTORE_SCRIPT="${SCRIPT_DIR}/appstore_submit.rb"

        if [ ! -f "${APPSTORE_SCRIPT}" ]; then
            log_error "appstore_submit.rb not found at ${APPSTORE_SCRIPT}"
            exit 1
        fi

        if [ -z "${APPSTORE_PKG}" ] || [ ! -f "${APPSTORE_PKG}" ]; then
            log_error "No App Store .pkg found. Build with App Store export first (don't use --skip-build)."
            exit 1
        else
            ruby "${APPSTORE_SCRIPT}" \
                --pkg "${APPSTORE_PKG}" \
                --app-id "${APPSTORE_APP_ID}" \
                --version "${VERSION}" \
                --platform macos \
                --project-root "${PROJECT_ROOT}"
        fi

        # iOS build and submission (if configured)
        if echo "${APPSTORE_PLATFORMS}" | grep -q "ios"; then
            IOS_SCHEME="${APPSTORE_IOS_SCHEME:-${SCHEME}}"
            log_info ""
            log_info "Building iOS for App Store (scheme: ${IOS_SCHEME})..."

            IOS_ARCHIVE="${BUILD_DIR}/${APP_NAME}-iOS.xcarchive"
            ios_args=(archive -scheme "${IOS_SCHEME}" -configuration Release \
                      -archivePath "${IOS_ARCHIVE}" \
                      -destination "generic/platform=iOS" \
                      -allowProvisioningUpdates)
            if [ ${#XCODE_PROVISIONING_AUTH_ARGS[@]} -gt 0 ]; then
                ios_args+=("${XCODE_PROVISIONING_AUTH_ARGS[@]}")
            fi
            [ -n "${XCODEPROJ}" ] && ios_args=(-project "${XCODEPROJ}" "${ios_args[@]}")
            xcodebuild "${ios_args[@]}" 2>&1 | tee -a "${BUILD_DIR}/build.log"

            if [ ${PIPESTATUS[0]} -ne 0 ]; then
                log_warn "iOS archive failed — skipping iOS App Store submission"
            else
                IOS_EXPORT="${BUILD_DIR}/Export-AppStore-iOS"
                mkdir -p "${IOS_EXPORT}"
                xcodebuild -exportArchive \
                    -archivePath "${IOS_ARCHIVE}" \
                    -exportPath "${IOS_EXPORT}" \
                    -exportOptionsPlist "${APPSTORE_PLIST}" \
                    -allowProvisioningUpdates \
                    "${XCODE_PROVISIONING_AUTH_ARGS[@]}" \
                    2>&1 | tee -a "${BUILD_DIR}/build.log"

                IOS_IPA="${IOS_EXPORT}/${APP_NAME}.ipa"
                if [ -f "${IOS_IPA}" ]; then
                    ruby "${APPSTORE_SCRIPT}" \
                        --pkg "${IOS_IPA}" \
                        --app-id "${APPSTORE_APP_ID}" \
                        --version "${VERSION}" \
                        --platform ios \
                        --project-root "${PROJECT_ROOT}"
                else
                    log_warn "iOS export produced no .ipa — skipping iOS submission"
                fi
            fi
        fi
    fi

    # Step 6: Commit version/link sync files that release updates indirectly
    PROJECT_PBXPROJ_REL="${APP_NAME}.xcodeproj/project.pbxproj"
    if [ -n "${XCODEPROJ}" ]; then
        if [[ "${XCODEPROJ}" == "${PROJECT_ROOT}/"* ]]; then
            PROJECT_PBXPROJ_REL="${XCODEPROJ#${PROJECT_ROOT}/}/project.pbxproj"
        else
            PROJECT_PBXPROJ_REL="$(basename "${XCODEPROJ}")/project.pbxproj"
        fi
    fi

    VERSION_SYNC_FILES=()
    for f in "project.yml" "${PROJECT_PBXPROJ_REL}" "docs/index.html"; do
        if [ -f "${PROJECT_ROOT}/${f}" ] && ! git -C "${PROJECT_ROOT}" diff --quiet -- "${f}" 2>/dev/null; then
            VERSION_SYNC_FILES+=("${f}")
        fi
    done

    if [ ${#VERSION_SYNC_FILES[@]} -gt 0 ]; then
        log_info "Committing version metadata/site link sync..."
        git -C "${PROJECT_ROOT}" add "${VERSION_SYNC_FILES[@]}"
        if ! git -C "${PROJECT_ROOT}" diff --cached --quiet; then
            git -C "${PROJECT_ROOT}" commit -m "chore: sync ${VERSION} version metadata and site download links"
            git -C "${PROJECT_ROOT}" push
            log_info "Version metadata/site link commit pushed."
        fi
    fi

    # Step 7: Commit appcast changes
    if [ -f "${APPCAST_PATH}" ] && [ -n "$(git -C "${PROJECT_ROOT}" diff --name-only docs/appcast.xml 2>/dev/null)" ]; then
        log_info "Committing appcast update..."
        git -C "${PROJECT_ROOT}" add docs/appcast.xml
        git -C "${PROJECT_ROOT}" commit -m "chore: update appcast for v${VERSION}"
        git -C "${PROJECT_ROOT}" push
        log_info "Appcast commit pushed."
    fi

    # Step 8: Update Homebrew cask (if tap repo configured)
    CASK_FILE="Casks/${LOWER_APP_NAME}.rb"
    HOMEBREW_TAP_DIR="/tmp/homebrew-tap-update-$$"
    if [ -n "${HOMEBREW_TAP_REPO}" ]; then
        log_info "Updating Homebrew cask in ${HOMEBREW_TAP_REPO}..."

        # Clone the tap repo
        if git clone --depth 1 "https://github.com/${HOMEBREW_TAP_REPO}.git" "${HOMEBREW_TAP_DIR}" 2>/dev/null; then
            if [ -f "${HOMEBREW_TAP_DIR}/${CASK_FILE}" ]; then
                # Update version and SHA256 in the cask formula
                sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "${HOMEBREW_TAP_DIR}/${CASK_FILE}"
                sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${SHA256}\"/" "${HOMEBREW_TAP_DIR}/${CASK_FILE}"

                # Commit and push
                cd "${HOMEBREW_TAP_DIR}"
                git add "${CASK_FILE}"
                if git diff --cached --quiet; then
                    log_info "Homebrew cask already up to date."
                else
                    git commit -m "chore: update ${LOWER_APP_NAME} to ${VERSION}"
                    git push
                    log_info "Homebrew cask updated to v${VERSION} (SHA: ${SHA256:0:12}...)"
                fi
                cd "${PROJECT_ROOT}"
            else
                log_warn "No cask found at ${CASK_FILE} in ${HOMEBREW_TAP_REPO}. Skipping."
            fi
            remove_path "${HOMEBREW_TAP_DIR}"
        else
            log_warn "Could not clone ${HOMEBREW_TAP_REPO}. Skipping Homebrew update."
        fi
    fi

    # Step 9: Verify Homebrew cask is correct (post-push sanity check)
    if [ -n "${HOMEBREW_TAP_REPO}" ]; then
        CASK_RAW_URL="https://raw.githubusercontent.com/${HOMEBREW_TAP_REPO}/main/${CASK_FILE}"
        CASK_CHECK=$(curl -s "${CASK_RAW_URL}" 2>/dev/null)
        if echo "${CASK_CHECK}" | grep -q "version \"${VERSION}\""; then
            log_info "Homebrew cask verified: v${VERSION} live at ${CASK_RAW_URL}"
        else
            log_warn "Homebrew cask may not have propagated. Check: ${CASK_RAW_URL}"
        fi
    fi

    # Step 10: Auto-update email webhook product config
    # The email webhook has product→filename mappings for purchase download links.
    # Previously this was a manual reminder — now it's automated for ALL apps.
    WEBHOOK_JS="${HOME}/SaneApps/infra/sane-email-automation/src/handlers/webhook-lemonsqueezy.js"
    if [ -f "${WEBHOOK_JS}" ]; then
        # Match: 'AppName': { file: 'AppName-X.Y.Z.zip', ... } or .dmg
        OLD_ENTRY=$(grep "'${APP_NAME}'" "${WEBHOOK_JS}" 2>/dev/null || true)
        if [ -n "${OLD_ENTRY}" ]; then
            # Determine extension from current entry (zip or dmg)
            CURRENT_EXT=$(echo "${OLD_ENTRY}" | grep -o '\.\(zip\|dmg\)' | head -1)
            CURRENT_EXT="${CURRENT_EXT:-.zip}"
            sed -i '' "s|'${APP_NAME}': { file: '${APP_NAME}-[^']*'|'${APP_NAME}': { file: '${APP_NAME}-${VERSION}${CURRENT_EXT}'|" "${WEBHOOK_JS}"
            log_info "Updated email webhook: ${APP_NAME} → ${APP_NAME}-${VERSION}${CURRENT_EXT}"

            # Commit and deploy
            WEBHOOK_DIR="$(dirname "$(dirname "$(dirname "${WEBHOOK_JS}")")")"
            if cd "${WEBHOOK_DIR}" 2>/dev/null; then
                git add -A && git commit -m "chore: update ${LOWER_APP_NAME} to ${VERSION}" --no-verify 2>/dev/null && \
                    git push 2>/dev/null && \
                    log_info "Webhook committed and pushed."
                npx wrangler deploy --keep-vars 2>/dev/null && \
                    log_info "Webhook deployed to Cloudflare Workers." || \
                    log_warn "Webhook deploy failed — deploy manually: cd ${WEBHOOK_DIR} && npx wrangler deploy --keep-vars"
                cd "${PROJECT_ROOT}"
            fi
        else
            log_warn "No '${APP_NAME}' entry found in webhook — add it manually to ${WEBHOOK_JS}"
        fi
    else
        log_warn "Email webhook file not found at ${WEBHOOK_JS} — update PRODUCT_CONFIG manually"
    fi

    # Step 11: Strict post-release verification gate
    if ! run_post_release_checks; then
        log_error "Post-release verification failed. Release is NOT considered complete."
        exit 1
    fi

    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "  RELEASE v${VERSION} DEPLOYED SUCCESSFULLY"
    log_info "═══════════════════════════════════════════"
    log_info "  ZIP:      https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.zip"
    log_info "  Appcast:  https://${SITE_HOST}/appcast.xml"
    log_info "  Homebrew: brew install --cask sane-apps/tap/${LOWER_APP_NAME}"
    log_info "═══════════════════════════════════════════"
else
    log_info ""
    log_info "To test: open \"${FINAL_ZIP}\""
    log_info ""
    log_info "To deploy to production, re-run with --deploy flag:"
    log_info "  ./scripts/release.sh --version ${VERSION} --skip-build --deploy"
fi

open "${RELEASE_DIR}"
