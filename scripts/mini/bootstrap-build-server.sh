#!/bin/bash
# Verifies mini is ready for headless SaneApps build/sign/notarize/deploy.

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SEED_MISSING=false
if [ "${1:-}" = "--seed-missing" ]; then
    SEED_MISSING=true
fi

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
    security find-generic-password -s "${service}" -w 2>/dev/null || true
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

    return 1
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

seed_missing_services() {
    local service default_value secret_mode value

    local default_key_path="${HOME}/.private_keys/AuthKey_S34998ZCRT.p8"
    local default_key_id="S34998ZCRT"
    local default_issuer_id="c98b1e0a-8d10-4fce-a417-536b31c09bfb"

    local keychain_password_default="${SANEBAR_KEYCHAIN_PASSWORD:-${KEYCHAIN_PASSWORD:-${KEYCHAIN_PASS:-}}}"

    while IFS='|' read -r service default_value secret_mode; do
        if security find-generic-password -s "${service}" -w >/dev/null 2>&1; then
            continue
        fi

        case "${service}" in
            saneprocess.keychain.password)
                value="$(prompt_value "Enter login keychain password for ${service}" "${keychain_password_default}" "true")"
                ;;
            *)
                value="$(prompt_value "Enter value for ${service}" "${default_value}" "${secret_mode}")"
                ;;
        esac

        if [ -z "${value}" ]; then
            echo "Skipping ${service} (empty value)."
            continue
        fi

        if ! add_keychain_secret "${service}" "${value}"; then
            echo "Could not store ${service}."
            continue
        fi

        if security find-generic-password -s "${service}" -w >/dev/null 2>&1; then
            echo "Stored ${service}."
        else
            echo "Stored ${service}, but retrieval verification failed."
        fi
    done <<SECRETS
saneprocess.keychain.password||true
saneprocess.asc.key_id|${default_key_id}|false
saneprocess.asc.issuer_id|${default_issuer_id}|false
saneprocess.asc.key_path|${default_key_path}|false
saneprocess.notary.key_id|${default_key_id}|false
saneprocess.notary.issuer_id|${default_issuer_id}|false
saneprocess.notary.key_path|${default_key_path}|false
SECRETS
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

    if security find-generic-password -s "${service}" -w >/dev/null 2>&1; then
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
        fail "codesign:keychain-password" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
        return
    fi
    keychain_password="${SANEBAR_KEYCHAIN_PASSWORD}"

    security default-keychain -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security list-keychains -d user -s "${login_keychain}" >/dev/null 2>&1 || true
    security set-keychain-settings -lut 21600 "${login_keychain}" >/dev/null 2>&1 || true

    if ! security unlock-keychain -p "${keychain_password}" "${login_keychain}" >/dev/null 2>&1; then
        fail "codesign:unlock" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
        return
    fi

    local probe
    probe=$(/usr/bin/mktemp /tmp/bootstrap_codesign.XXXXXX)
    echo "sane" > "${probe}"

    if /usr/bin/codesign --force --sign "${signing_identity}" --timestamp=none "${probe}" >/dev/null 2>&1; then
        pass "codesign:probe"
    else
        fail "codesign:probe" "export SANEBAR_KEYCHAIN_PASSWORD='<login-keychain-password>'"
    fi

    rm -f "${probe}"
}

check_asc_jwt() {
    local asc_path=""

    if ! resolve_secret "ASC_AUTH_KEY_ID" "saneprocess.asc.key_id"; then
        fail "asc:key-id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
        return
    fi
    if ! resolve_secret "ASC_AUTH_ISSUER_ID" "saneprocess.asc.issuer_id"; then
        fail "asc:issuer-id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
        return
    fi
    if ! resolve_secret "ASC_AUTH_KEY_PATH" "saneprocess.asc.key_path"; then
        fail "asc:key-path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
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
        fail "asc:jwt" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
    fi
}

echo "SaneProcess mini bootstrap verification"
echo "PATH=${PATH}"

if [ "${SEED_MISSING}" = "true" ]; then
    echo "Seeding missing keychain services..."
    seed_missing_services
fi

# 1) Tooling
check_cmd "xcodegen" "command -v xcodegen" "brew install xcodegen"
check_cmd "ruby" "command -v ruby" "xcode-select --install"
check_cmd "xcodebuild" "command -v xcodebuild" "xcode-select --switch /Applications/Xcode.app/Contents/Developer"
check_cmd "security" "command -v security" "xcode-select --install"
check_cmd "notarytool" "xcrun -f notarytool" "xcode-select --switch /Applications/Xcode.app/Contents/Developer"

# 2) Required keychain services (presence only, values never printed)
check_keychain_service "saneprocess.keychain.password" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.asc.key_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.asc.issuer_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.asc.key_path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.notary.key_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.notary.issuer_id" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"
check_keychain_service "saneprocess.notary.key_path" "${REPO_ROOT}/scripts/mini/bootstrap-build-server.sh --seed-missing"

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
