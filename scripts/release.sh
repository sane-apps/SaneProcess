#!/bin/bash
# frozen_string_literal: false
#
# Unified Release Script
# Builds, signs, notarizes, and packages a DMG for any SaneApps project
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --project PATH      Project root (defaults to current directory)"
    echo "  --config PATH       Config file (defaults to <project>/.saneprocess if present)"
    echo "  --full              Version bump, tests, git commit, GitHub release"
    echo "  --deploy            Upload to R2, update appcast, deploy website (run after build)"
    echo "  --skip-notarize      Skip notarization (for local testing)"
    echo "  --skip-build         Skip build step (use existing archive)"
    echo "  --version X.Y.Z      Set version number"
    echo "  --notes \"...\"      Release notes for GitHub (required with --full)"
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
    project_version=$(echo "$semver" | tr -d '.' | sed 's/^0*//')
    if [ -z "${project_version}" ]; then
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

commit_version_bump() {
    git -C "${PROJECT_ROOT}" add "${VERSION_BUMP_FILES[@]}"
    if git -C "${PROJECT_ROOT}" commit -m "Bump version to ${VERSION}" >/dev/null 2>&1; then
        log_info "Version bump committed"
    else
        log_warn "No version bump commit created (maybe no changes)"
    fi
}

create_github_release() {
    local repo="${GITHUB_REPO}"
    if gh release view "v${VERSION}" --repo "${repo}" >/dev/null 2>&1; then
        log_warn "GitHub release v${VERSION} already exists"
        return 0
    fi

    gh release create "v${VERSION}" \
        --repo "${repo}" \
        --title "v${VERSION}" \
        --notes "${RELEASE_NOTES}"
    log_info "GitHub release created: v${VERSION}"
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
        --full)
            FULL_RELEASE=true
            shift
            ;;
        --deploy)
            RUN_DEPLOY=true
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
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Your Name (${TEAM_ID})}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_ROOT}/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${BUILD_DIR}/${APP_NAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${BUILD_DIR}/Export}"
RELEASE_DIR="${RELEASE_DIR:-${PROJECT_ROOT}/releases}"
DIST_HOST="${DIST_HOST:-dist.${LOWER_APP_NAME}.com}"
SITE_HOST="${SITE_HOST:-${LOWER_APP_NAME}.com}"
R2_BUCKET="${R2_BUCKET:-${LOWER_APP_NAME}-downloads}"
USE_SPARKLE="${USE_SPARKLE:-true}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-15.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
GITHUB_REPO="${GITHUB_REPO:-sane-apps/${APP_NAME}}"
XCODEGEN="${XCODEGEN:-false}"
DMG_WINDOW_POS="${DMG_WINDOW_POS:-200 120}"
DMG_WINDOW_SIZE="${DMG_WINDOW_SIZE:-800 400}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-100}"
DMG_APP_ICON_POS="${DMG_APP_ICON_POS:-200 185}"
DMG_DROP_POS="${DMG_DROP_POS:-600 185}"
DMG_HIDE_EXTENSION="${DMG_HIDE_EXTENSION:-true}"
DMG_NO_INTERNET_ENABLE="${DMG_NO_INTERNET_ENABLE:-false}"
VERIFY_STAPLE="${VERIFY_STAPLE:-false}"

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

WORKSPACE="$(resolve_path "${WORKSPACE}")"
XCODEPROJ="$(resolve_path "${XCODEPROJ}")"
EXPORT_OPTIONS_PLIST="$(resolve_path "${EXPORT_OPTIONS_PLIST}")"
DMG_FILE_ICON="$(resolve_path "${DMG_FILE_ICON}")"
DMG_VOLUME_ICON="$(resolve_path "${DMG_VOLUME_ICON}")"
DMG_BACKGROUND="$(resolve_path "${DMG_BACKGROUND}")"
DMG_BACKGROUND_GENERATOR="$(resolve_path "${DMG_BACKGROUND_GENERATOR}")"
SIGN_UPDATE_SCRIPT="$(resolve_path "${SIGN_UPDATE_SCRIPT:-${PROJECT_ROOT}/scripts/sign_update.swift}")"
SET_DMG_ICON_SCRIPT="$(resolve_path "${SET_DMG_ICON_SCRIPT:-${PROJECT_ROOT}/scripts/set_dmg_icon.swift}")"

cd "${PROJECT_ROOT}"

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
    ensure_cmd gh
    ensure_git_clean

    # README sync check — warn if features aren't documented
    README_CHECK="${SCRIPT_DIR}/automation/nv-readme-check.sh"
    if [ -f "${README_CHECK}" ] && [ -x "${README_CHECK}" ]; then
        log_info "Checking README sync with shipped features..."
        if ! "${README_CHECK}" "${PROJECT_ROOT}" 2>/dev/null; then
            log_warn "README may be out of date with shipped features (see above)."
            log_warn "Consider updating README.md before release. Continuing..."
        fi
    fi

    log_info "Bumping version to ${VERSION}..."
    bump_project_version "${VERSION}"

    if [ "${XCODEGEN}" = true ]; then
        ensure_cmd xcodegen
        log_info "Regenerating Xcode project..."
        xcodegen generate
        XCODEGEN_DONE=true
    fi

    run_tests
    commit_version_bump
    RUN_GH_RELEASE=true
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
    log_info "SUFeedURL: ${PLIST_FEED}"
    log_info "SUPublicEDKey: ${PLIST_KEY}"
fi

# Get version from app
if [ -z "${VERSION}" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0.0")
fi
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1")
log_info "Version: ${VERSION} (${BUILD_NUMBER})"

# Create DMG
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"

if [ -n "${DMG_BACKGROUND_GENERATOR}" ] && [ -f "${DMG_BACKGROUND_GENERATOR}" ]; then
    log_info "Generating DMG background..."
    swift "${DMG_BACKGROUND_GENERATOR}"
fi

# Remove old DMG if it exists (create-dmg won't overwrite)
rm -f "${DMG_PATH}"

log_info "Creating DMG..."

if [ -z "${DMG_VOLUME_ICON}" ] && [ -f "${APP_PATH}/Contents/Resources/AppIcon.icns" ]; then
    DMG_VOLUME_ICON="${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

if command -v create-dmg >/dev/null 2>&1; then
    log_info "Using create-dmg..."
    DMG_ARGS=(
        --volname "${APP_NAME}"
        --window-pos ${DMG_WINDOW_POS}
        --window-size ${DMG_WINDOW_SIZE}
        --icon-size "${DMG_ICON_SIZE}"
        --icon "${APP_NAME}.app" ${DMG_APP_ICON_POS}
        --app-drop-link ${DMG_DROP_POS}
    )

    if [ "${DMG_HIDE_EXTENSION}" = true ]; then
        DMG_ARGS+=(--hide-extension "${APP_NAME}.app")
    fi

    if [ -n "${DMG_VOLUME_ICON}" ] && [ -f "${DMG_VOLUME_ICON}" ]; then
        DMG_ARGS+=(--volicon "${DMG_VOLUME_ICON}")
    fi

    if [ -n "${DMG_BACKGROUND}" ] && [ -f "${DMG_BACKGROUND}" ]; then
        DMG_ARGS+=(--background "${DMG_BACKGROUND}")
    fi

    if [ "${DMG_NO_INTERNET_ENABLE}" = true ]; then
        DMG_ARGS+=(--no-internet-enable)
    fi

    if [ ${#CREATE_DMG_EXTRA_ARGS[@]} -gt 0 ]; then
        DMG_ARGS+=("${CREATE_DMG_EXTRA_ARGS[@]}")
    fi

    create-dmg "${DMG_ARGS[@]}" "${DMG_PATH}" "${APP_PATH}"
else
    log_warn "create-dmg not found, using basic DMG creation..."
    DMG_TEMP="${BUILD_DIR}/dmg_temp"
    remove_path "${DMG_TEMP}"
    mkdir -p "${DMG_TEMP}"
    cp -R "${APP_PATH}" "${DMG_TEMP}/"
    ln -s /Applications "${DMG_TEMP}/Applications"
    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${DMG_TEMP}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    remove_path "${DMG_TEMP}"
fi

# Set DMG file icon (for Finder)
if [ -n "${DMG_FILE_ICON}" ]; then
    if [ -f "${DMG_FILE_ICON}" ] && [ -f "${SET_DMG_ICON_SCRIPT}" ]; then
        log_info "Setting DMG file icon..."
        swift "${SET_DMG_ICON_SCRIPT}" "${DMG_FILE_ICON}" "${DMG_PATH}"
    else
        log_warn "DMG file icon skipped (missing icon or set_dmg_icon.swift)"
    fi
fi

# Sign DMG
log_info "Signing DMG..."
codesign --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"
codesign --verify "${DMG_PATH}"
log_info "DMG signature verified!"

# Notarize (if not skipped)
if [ "${SKIP_NOTARIZE}" = false ]; then
    log_info "Submitting for notarization..."
    log_warn "This may take several minutes..."

    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    log_info "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_PATH}"

    if [ "${VERIFY_STAPLE}" = true ]; then
        log_info "Verifying staple..."
        xcrun stapler validate "${DMG_PATH}"
    fi

    log_info "Notarization complete!"
else
    log_warn "Skipping notarization (--skip-notarize flag set)"
fi

# Copy to releases folder (use ditto to preserve custom icon/xattrs)
FINAL_DMG="${RELEASE_DIR}/${DMG_NAME}.dmg"
remove_path "${FINAL_DMG}"
ditto "${DMG_PATH}" "${FINAL_DMG}"

log_info "========================================"
log_info "Release build complete!"
log_info "========================================"
log_info "DMG: ${FINAL_DMG}"
log_info "Version: ${VERSION}"

# Generate Sparkle Signature
if [ "${USE_SPARKLE}" = true ] && command -v swift >/dev/null 2>&1; then
    log_info ""
    log_info "--- Generating Release Metadata ---"
    SHA256=$(shasum -a 256 "${FINAL_DMG}" | awk '{print $1}')
    FILE_SIZE=$(stat -f%z "${FINAL_DMG}")

    log_info "Fetching Sparkle Private Key from Keychain..."
    SPARKLE_KEY=$(security find-generic-password -w -s "https://sparkle-project.org" -a "EdDSA Private Key" 2>/dev/null || echo "")

    if [ -n "${SPARKLE_KEY}" ]; then
        log_info "Sparkle Key found. Generating signature..."

        if [ -f "${SIGN_UPDATE_SCRIPT}" ]; then
            SIGNATURE=$(swift "${SIGN_UPDATE_SCRIPT}" "${FINAL_DMG}" "${SPARKLE_KEY}" 2>/dev/null || echo "")
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
                <p>See CHANGELOG.md for details</p>
                ]]>
            </description>
            <enclosure url="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg"
                       sparkle:version="${BUILD_NUMBER}"
                       sparkle:shortVersionString="${VERSION}"
                       length="${FILE_SIZE}"
                       type="application/x-apple-diskimage"
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
    log_info "IMPORTANT: After uploading to R2, run any post-release/appcast update script"
fi

if [ "${RUN_GH_RELEASE}" = true ]; then
    log_info ""
    log_info "Creating GitHub release (notes only, NO DMG attached)..."
    create_github_release
fi

# ─── Deploy: R2 upload + appcast update + Pages deploy ───
if [ "${RUN_DEPLOY}" = true ]; then
    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "  DEPLOYING TO PRODUCTION"
    log_info "═══════════════════════════════════════════"

    # Step 1: Upload DMG to R2
    log_info "Uploading DMG to R2 bucket ${R2_BUCKET}..."
    ensure_cmd npx
    npx wrangler r2 object put "${R2_BUCKET}/${APP_NAME}-${VERSION}.dmg" \
        --file="${FINAL_DMG}" --remote
    log_info "R2 upload complete."

    # Verify R2 upload
    log_info "Verifying download URL..."
    HTTP_STATUS=$(curl -sI "https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg" | head -1 | awk '{print $2}')
    if [ "${HTTP_STATUS}" != "200" ]; then
        log_error "R2 verification FAILED! https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg returned ${HTTP_STATUS}"
        log_error "Check R2 bucket key format — Worker may strip /updates/ prefix."
        exit 1
    fi
    log_info "Download verified: https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg (200 OK)"

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
            <enclosure url="https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg"
                       sparkle:version="${BUILD_NUMBER}"
                       sparkle:shortVersionString="${VERSION}"
                       length="${FILE_SIZE}"
                       type="application/x-apple-diskimage"
                       sparkle:edSignature="${SIGNATURE}"/>
        </item>
APPCASTEOF
)
            # Insert new item after <title>...</title> (before first existing <item>)
            # Use perl for reliable multiline insertion
            perl -i -0pe "s|(<title>[^<]+</title>\n)(\s*<item>)|\$1${NEW_ITEM}\n\$2|" "${APPCAST_PATH}"

            log_info "Appcast updated with v${VERSION} entry."
        else
            log_warn "No appcast.xml found at ${APPCAST_PATH}. Skipping appcast update."
        fi
    else
        log_warn "No Sparkle signature available. Skipping appcast update."
        log_warn "Run with USE_SPARKLE=true and ensure EdDSA key is in Keychain."
    fi

    # Step 3: Deploy website + appcast to Cloudflare Pages
    PAGES_PROJECT="${LOWER_APP_NAME}-site"
    DOCS_DIR="${PROJECT_ROOT}/docs"
    if [ -d "${DOCS_DIR}" ]; then
        log_info "Deploying website + appcast to Cloudflare Pages (${PAGES_PROJECT})..."
        npx wrangler pages deploy "${DOCS_DIR}" \
            --project-name="${PAGES_PROJECT}" \
            --commit-dirty=true \
            --commit-message="Release v${VERSION}"
        log_info "Pages deploy complete."

        # Verify appcast is live
        log_info "Verifying appcast..."
        APPCAST_CHECK=$(curl -s "https://${SITE_HOST}/appcast.xml" | head -5)
        if echo "${APPCAST_CHECK}" | grep -q "${VERSION}"; then
            log_info "Appcast verified: v${VERSION} is live at https://${SITE_HOST}/appcast.xml"
        else
            log_warn "Appcast may not have propagated yet. Check https://${SITE_HOST}/appcast.xml manually."
        fi
    else
        log_warn "No docs/ directory found. Skipping Pages deploy."
    fi

    # Step 4: Commit appcast changes
    if [ -f "${APPCAST_PATH}" ] && [ -n "$(git -C "${PROJECT_ROOT}" diff --name-only docs/appcast.xml 2>/dev/null)" ]; then
        log_info "Committing appcast update..."
        git -C "${PROJECT_ROOT}" add docs/appcast.xml
        git -C "${PROJECT_ROOT}" commit -m "chore: update appcast for v${VERSION}"
        git -C "${PROJECT_ROOT}" push
        log_info "Appcast commit pushed."
    fi

    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "  RELEASE v${VERSION} DEPLOYED SUCCESSFULLY"
    log_info "═══════════════════════════════════════════"
    log_info "  DMG:     https://${DIST_HOST}/updates/${APP_NAME}-${VERSION}.dmg"
    log_info "  Appcast: https://${SITE_HOST}/appcast.xml"
    log_info "  GitHub:  https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}"
    log_info "═══════════════════════════════════════════"
else
    log_info ""
    log_info "To test: open \"${FINAL_DMG}\""
    log_info ""
    log_info "To deploy to production, re-run with --deploy flag:"
    log_info "  ./scripts/release.sh --version ${VERSION} --skip-build --deploy"
    log_info ""
    log_info "Or deploy manually:"
    log_info "  1. npx wrangler r2 object put ${R2_BUCKET}/${APP_NAME}-${VERSION}.dmg --file=\"${FINAL_DMG}\" --remote"
    log_info "  2. Update docs/appcast.xml"
    log_info "  3. npx wrangler pages deploy ./docs --project-name=${LOWER_APP_NAME}-site"
fi

open "${RELEASE_DIR}"
