#!/bin/bash
# Verifies mini is ready for headless SaneApps build/sign/notarize/deploy.

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SECRETS_ENV_DIR="${HOME}/.config/saneprocess"
SECRETS_ENV_FILE="${SECRETS_ENV_DIR}/secrets.env"

SEED_MISSING=false
EXPORT_ENV_FILE=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --seed-missing)
            SEED_MISSING=true
            ;;
        --export-env-file)
            EXPORT_ENV_FILE=true
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--seed-missing] [--export-env-file]"
            exit 1
            ;;
    esac
    shift
done

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    local check_name="$1"
    local remediation="$2"
    echo "FAIL  ${check_name}"
    echo "      Remediation: ${remediation}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

keychain_get() {
    local service="$1"
    local value=""
    value=$(security find-generic-password -s "${service}" -w 2>/dev/null || true)
    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return 0
    fi

    if [ "${service}" = "saneprocess.sparkle.private_key" ]; then
        value=$(security find-generic-password -s "https://sparkle-project.org" -a "EdDSA Private Key" -w 2>/dev/null || true)
        if [ -n "${value}" ]; then
            printf '%s' "${value}"
            return 0
        fi
    fi

    return 0
}

keychain_has() {
    local service="$1"
    if security find-generic-password -s "${service}" -w >/dev/null 2>&1; then
        return 0
    fi

    if [ "${service}" = "saneprocess.sparkle.private_key" ] && security find-generic-password -s "https://sparkle-project.org" -a "EdDSA Private Key" -w >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

env_key_for_service() {
    case "$1" in
        saneprocess.keychain.password) echo "SANEBAR_KEYCHAIN_PASSWORD" ;;
        saneprocess.asc.key_id) echo "ASC_AUTH_KEY_ID" ;;
        saneprocess.asc.issuer_id) echo "ASC_AUTH_ISSUER_ID" ;;
        saneprocess.asc.key_path) echo "ASC_AUTH_KEY_PATH" ;;
        saneprocess.notary.key_id) echo "NOTARY_API_KEY_ID" ;;
        saneprocess.notary.issuer_id) echo "NOTARY_API_ISSUER_ID" ;;
        saneprocess.notary.key_path) echo "NOTARY_API_KEY_PATH" ;;
        saneprocess.sparkle.private_key) echo "SPARKLE_PRIVATE_KEY" ;;
        *) echo "" ;;
    esac
}

service_for_env_key() {
    case "$1" in
        SANEBAR_KEYCHAIN_PASSWORD) echo "saneprocess.keychain.password" ;;
        ASC_AUTH_KEY_ID) echo "saneprocess.asc.key_id" ;;
        ASC_AUTH_ISSUER_ID) echo "saneprocess.asc.issuer_id" ;;
        ASC_AUTH_KEY_PATH) echo "saneprocess.asc.key_path" ;;
        NOTARY_API_KEY_ID) echo "saneprocess.notary.key_id" ;;
        NOTARY_API_ISSUER_ID) echo "saneprocess.notary.issuer_id" ;;
        NOTARY_API_KEY_PATH) echo "saneprocess.notary.key_path" ;;
        SPARKLE_PRIVATE_KEY) echo "saneprocess.sparkle.private_key" ;;
        *) echo "" ;;
    esac
}

default_for_service() {
    local default_key_path="${HOME}/.private_keys/AuthKey_S34998ZCRT.p8"
    case "$1" in
        saneprocess.keychain.password)
            echo "${SANEBAR_KEYCHAIN_PASSWORD:-${KEYCHAIN_PASSWORD:-${KEYCHAIN_PASS:-}}}"
            ;;
        saneprocess.asc.key_id|saneprocess.notary.key_id)
            echo "S34998ZCRT"
            ;;
        saneprocess.asc.issuer_id|saneprocess.notary.issuer_id)
            echo "c98b1e0a-8d10-4fce-a417-536b31c09bfb"
            ;;
        saneprocess.asc.key_path|saneprocess.notary.key_path)
            echo "${default_key_path}"
            ;;
        saneprocess.sparkle.private_key)
            echo "${SPARKLE_PRIVATE_KEY:-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

secret_mode_for_service() {
    case "$1" in
        saneprocess.keychain.password|saneprocess.sparkle.private_key) echo "true" ;;
        *) echo "false" ;;
    esac
}

add_keychain_secret() {
    local service="$1"
    local value="$2"
    security add-generic-password -U -a "saneprocess" -s "${service}" -w "${value}" >/dev/null
}

prompt_value() {
    local prompt="$1"
    local default_value="$2"
    local secret_mode="$3"
    local value=""

    if [ "${secret_mode}" = "true" ]; then
        read -r -s -p "${prompt}" value < /dev/tty
        echo ""
    else
        if [ -n "${default_value}" ]; then
            read -r -p "${prompt} [${default_value}]: " value < /dev/tty
            value="${value:-${default_value}}"
        else
            read -r -p "${prompt}: " value < /dev/tty
        fi
    fi

    if [ -z "${value}" ] && [ -n "${default_value}" ]; then
        value="${default_value}"
    fi

    printf '%s' "${value}"
}

ensure_service_value() {
    local service="$1"
    local allow_prompt="$2"
    local value

    value="$(keychain_get "${service}")"
    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return 0
    fi

    if [ "${allow_prompt}" != "true" ]; then
        return 1
    fi

    local default_value secret_mode prompt
    default_value="$(default_for_service "${service}")"
    secret_mode="$(secret_mode_for_service "${service}")"
    prompt="Enter value for ${service}"
    if [ "${service}" = "saneprocess.keychain.password" ]; then
        prompt="Enter login keychain password for ${service}"
    fi

    value="$(prompt_value "${prompt}" "${default_value}" "${secret_mode}")"
    if [ -z "${value}" ]; then
        return 1
    fi

    if ! add_keychain_secret "${service}" "${value}"; then
        return 1
    fi

    value="$(keychain_get "${service}")"
    if [ -z "${value}" ]; then
        return 1
    fi

    printf '%s' "${value}"
    return 0
}

env_file_get() {
    local key="$1"
    if [ ! -f "${SECRETS_ENV_FILE}" ]; then
        return 1
    fi

    local value file_escaped
    file_escaped="$(printf '%q' "${SECRETS_ENV_FILE}")"
    value=$(/bin/bash -lc "set -a; source ${file_escaped} >/dev/null 2>&1 || exit 1; printf '%s' \"\${${key}:-}\"" 2>/dev/null || true)
    if [ -z "${value}" ]; then
        return 1
    fi

    printf '%s' "${value}"
    return 0
}

resolve_secret() {
    local var_name="$1"
    local service="$2"

    local current="${!var_name:-}"
    if [ -n "${current}" ]; then
        printf -v "${var_name}" '%s' "${current}"
        export "${var_name}"
        return 0
    fi

    local keychain_value
    keychain_value="$(keychain_get "${service}")"
    if [ -n "${keychain_value}" ]; then
        printf -v "${var_name}" '%s' "${keychain_value}"
        export "${var_name}"
        return 0
    fi

    local file_value
    file_value="$(env_file_get "${var_name}" || true)"
    if [ -n "${file_value}" ]; then
        printf -v "${var_name}" '%s' "${file_value}"
        export "${var_name}"
        return 0
    fi

    return 1
}

write_secrets_env_file() {
    local tmp_file

    mkdir -p "${SECRETS_ENV_DIR}"
    chmod 700 "${SECRETS_ENV_DIR}" 2>/dev/null || true

    tmp_file=$(/usr/bin/mktemp "${SECRETS_ENV_DIR}/secrets.env.XXXXXX")
    chmod 600 "${tmp_file}"

    local env_key service value
    for env_key in \
        SANEBAR_KEYCHAIN_PASSWORD \
        ASC_AUTH_KEY_ID \
        ASC_AUTH_ISSUER_ID \
        ASC_AUTH_KEY_PATH \
        NOTARY_API_KEY_ID \
        NOTARY_API_ISSUER_ID \
        NOTARY_API_KEY_PATH \
        SPARKLE_PRIVATE_KEY; do
        service="$(service_for_env_key "${env_key}")"
        if [ -z "${service}" ]; then
            rm -f "${tmp_file}"
            echo "Unknown env key mapping: ${env_key}"
            return 1
        fi

        if ! value="$(ensure_service_value "${service}" "true")"; then
            rm -f "${tmp_file}"
            echo "Could not read/store ${service}."
            return 1
        fi

        printf '%s=%q\n' "${env_key}" "${value}" >> "${tmp_file}"
    done

    mv "${tmp_file}" "${SECRETS_ENV_FILE}"
    chmod 600 "${SECRETS_ENV_FILE}"
    echo "Wrote ${SECRETS_ENV_FILE}"
    return 0
}

seed_missing_services() {
    local service
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        if keychain_has "${service}"; then
            continue
        fi
        if ensure_service_value "${service}" "true" >/dev/null; then
            echo "Stored ${service}."
        else
            echo "Could not store ${service}."
        fi
    done <<SERVICES
saneprocess.keychain.password
saneprocess.asc.key_id
saneprocess.asc.issuer_id
saneprocess.asc.key_path
saneprocess.notary.key_id
saneprocess.notary.issuer_id
saneprocess.notary.key_path
saneprocess.sparkle.private_key
SERVICES
}

check_cmd() {
    local tool="$1"
    local probe_cmd="$2"
    local remediation="$3"

    if eval "${probe_cmd}" >/dev/null 2>&1; then
        pass "tool:${tool}"
    else
        fail "tool:${tool}" "${remediation}"
    fi
}

check_keychain_service() {
    local service="$1"
    local remediation="$2"
    local env_key fallback

    if keychain_has "${service}"; then
        pass "keychain:${service}"
        return
    fi

    env_key="$(env_key_for_service "${service}")"
    fallback=""
    if [ -n "${env_key}" ]; then
        fallback="$(env_file_get "${env_key}" || true)"
    fi

    if [ -n "${fallback}" ]; then
        pass "keychain:${service}"
    else
        fail "keychain:${service}" "${remediation}"
    fi
}

check_codesign_probe() {
    local signing_identity="${SIGNING_IDENTITY:-Developer ID Application}"
    local login_keychain="${HOME}/Library/Keychains/login.keychain-db"
    local keychain_password=""

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${signing_identity}"; then
        fail "codesign:identity" "security find-identity -v -p codesigning"
        return
    fi

    if ! resolve_secret "SANEBAR_KEYCHAIN_PASSWORD" "saneprocess.keychain.password"; then
        fail "codesign:keychain-password" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
        return
    fi
    keychain_password="${SANEBAR_KEYCHAIN_PASSWORD}"

    security default-keychain -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security list-keychains -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security set-keychain-settings -lut 21600 "${login_keychain}" >/dev/null 2>&1 || true

    if ! security unlock-keychain -p "${keychain_password}" "${login_keychain}" >/dev/null 2>&1; then
        fail "codesign:unlock" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
        return
    fi

    local probe
    probe=$(/usr/bin/mktemp /tmp/bootstrap_codesign.XXXXXX)
    echo "sane" > "${probe}"

    if /usr/bin/codesign --force --sign "${signing_identity}" --timestamp=none "${probe}" >/dev/null 2>&1; then
        pass "codesign:probe"
    else
        fail "codesign:probe" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
    fi

    rm -f "${probe}"
}

check_asc_jwt() {
    local asc_path=""

    if ! resolve_secret "ASC_AUTH_KEY_ID" "saneprocess.asc.key_id"; then
        fail "asc:key-id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
        return
    fi
    if ! resolve_secret "ASC_AUTH_ISSUER_ID" "saneprocess.asc.issuer_id"; then
        fail "asc:issuer-id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
        return
    fi
    if ! resolve_secret "ASC_AUTH_KEY_PATH" "saneprocess.asc.key_path"; then
        fail "asc:key-path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
        return
    fi

    asc_path="${ASC_AUTH_KEY_PATH/#\~/${HOME}}"
    if [ ! -f "${asc_path}" ]; then
        fail "asc:key-file" "security add-generic-password -U -a saneprocess -s saneprocess.asc.key_path -w '${HOME}/.private_keys/AuthKey_S34998ZCRT.p8'"
        return
    fi

    if ASC_AUTH_KEY_PATH="${asc_path}" ASC_AUTH_KEY_ID="${ASC_AUTH_KEY_ID}" ASC_AUTH_ISSUER_ID="${ASC_AUTH_ISSUER_ID}" ruby <<'RUBY' >/dev/null 2>&1
require 'base64'
require 'json'
require 'openssl'

key = OpenSSL::PKey::EC.new(File.read(ENV.fetch('ASC_AUTH_KEY_PATH')))
now = Time.now.to_i
header = { alg: 'ES256', kid: ENV.fetch('ASC_AUTH_KEY_ID'), typ: 'JWT' }
payload = {
  iss: ENV.fetch('ASC_AUTH_ISSUER_ID'),
  iat: now,
  exp: now + 600,
  aud: 'appstoreconnect-v1'
}
enc = ->(obj) { Base64.urlsafe_encode64(JSON.generate(obj), padding: false) }
unsigned = "#{enc.call(header)}.#{enc.call(payload)}"
signature = key.dsa_sign_asn1(unsigned)
token = "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
exit(token.count('.') == 2 ? 0 : 1)
RUBY
    then
        pass "asc:jwt"
    else
        fail "asc:jwt" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
    fi
}

echo "SaneProcess mini bootstrap verification"
echo "PATH=${PATH}"

if [ "${SEED_MISSING}" = "true" ]; then
    echo "Seeding missing keychain services..."
    seed_missing_services
fi

if [ "${EXPORT_ENV_FILE}" = "true" ]; then
    echo "Exporting ${SECRETS_ENV_FILE} from keychain..."
    if ! write_secrets_env_file; then
        echo "Failed to export ${SECRETS_ENV_FILE}."
        exit 1
    fi
fi

# 1) Tooling
check_cmd "xcodegen" "command -v xcodegen" "brew install xcodegen"
check_cmd "ruby" "command -v ruby" "xcode-select --install"
check_cmd "xcodebuild" "command -v xcodebuild" "xcode-select --switch /Applications/Xcode.app/Contents/Developer"
check_cmd "security" "command -v security" "xcode-select --install"
check_cmd "notarytool" "xcrun -f notarytool" "xcode-select --switch /Applications/Xcode.app/Contents/Developer"

# 2) Required keychain/file-backed secrets
check_keychain_service "saneprocess.keychain.password" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.asc.key_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.asc.issuer_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.asc.key_path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.notary.key_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.notary.issuer_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.notary.key_path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"
check_keychain_service "saneprocess.sparkle.private_key" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --export-env-file"

# 3) Headless codesign probe
check_codesign_probe

# 4) ASC JWT generation probe
check_asc_jwt

echo ""
echo "Summary: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi

exit 0
