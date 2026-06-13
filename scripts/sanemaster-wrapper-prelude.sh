#!/bin/bash
# Shared SaneMaster project-wrapper prelude.
#
# App-local wrappers may source this before delegating to SaneProcess so
# headless secret loading and signing/keychain preflight stay in shared infra.

saneprocess_project_root() {
  if [ -n "${PROJECT_ROOT:-}" ]; then
    printf '%s\n' "${PROJECT_ROOT}"
  else
    pwd
  fi
}

saneprocess_load_headless_secrets_env() {
  local candidate
  local secrets_files=(
    "${SANEPROCESS_SECRETS_FILE:-}"
    "${HOME}/.config/saneprocess/secrets.env"
    "${HOME}/.saneprocess/secrets.env"
  )

  for candidate in "${secrets_files[@]}"; do
    [ -n "${candidate}" ] || continue
    [ -f "${candidate}" ] || continue
    set -a
    # shellcheck disable=SC1090
    . "${candidate}"
    set +a
    return 0
  done

  return 1
}

saneprocess_hydrate_project_metadata() {
  local manifest name scheme root
  root="$(saneprocess_project_root)"
  manifest="${root}/.saneprocess"
  [ -f "${manifest}" ] || return 0

  name="$(awk -F': ' '$1=="name"{print $2; exit}' "${manifest}" | tr -d '"' | xargs)"
  scheme="$(awk -F': ' '$1=="scheme"{print $2; exit}' "${manifest}" | tr -d '"' | xargs)"

  if [ -n "${name}" ] && [ -z "${SANEMASTER_PROJECT:-}" ]; then
    export SANEMASTER_PROJECT="${name}"
  fi

  if [ -n "${scheme}" ] && [ -z "${SANEMASTER_SCHEME:-}" ]; then
    export SANEMASTER_SCHEME="${scheme}"
  fi

  if [ -n "${name}" ]; then
    if [ -z "${SANEMASTER_TEST_TARGET:-}" ]; then
      export SANEMASTER_TEST_TARGET="${name}Tests"
    fi
    if [ -z "${SANEMASTER_UI_TEST_TARGET:-}" ]; then
      export SANEMASTER_UI_TEST_TARGET="${name}UITests"
    fi
  fi
}

saneprocess_login_keychain() {
  printf '%s\n' "${SANEMASTER_KEYCHAIN_PATH:-${SANEBAR_KEYCHAIN_PATH:-${KEYCHAIN_PATH:-${HOME}/Library/Keychains/login.keychain-db}}}"
}

saneprocess_keychain_password() {
  printf '%s\n' "${SANEMASTER_KEYCHAIN_PASSWORD:-${SANEBAR_KEYCHAIN_PASSWORD:-${KEYCHAIN_PASSWORD:-${KEYCHAIN_PASS:-}}}}"
}

saneprocess_prepare_signing_keychain() {
  local keychain password identities identity

  keychain="$(saneprocess_login_keychain)"
  [ -f "${keychain}" ] || return 0

  # Keep lookup deterministic in SSH/headless shells.
  security default-keychain -d user -s "${keychain}" >/dev/null 2>&1 || true

  if [[ "${OTHER_CODE_SIGN_FLAGS:-}" != *"--keychain"* ]]; then
    export OTHER_CODE_SIGN_FLAGS="--keychain ${keychain}${OTHER_CODE_SIGN_FLAGS:+ ${OTHER_CODE_SIGN_FLAGS}}"
  fi

  password="$(saneprocess_keychain_password)"
  [ -n "${password}" ] || return 0

  # Only modify session/search behavior when explicit credentials are supplied.
  security list-keychains -d user -s "${keychain}" /Library/Keychains/System.keychain >/dev/null 2>&1 || true
  security set-keychain-settings -lut 21600 "${keychain}" >/dev/null 2>&1 || true
  security unlock-keychain -p "${password}" "${keychain}" >/dev/null 2>&1 || true

  identities="$(
    security find-identity -v -p codesigning "${keychain}" 2>/dev/null |
      sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p'
  )"
  [ -n "${identities}" ] || return 0

  printf '%s\n' "${identities}" | while IFS= read -r identity; do
    [ -n "${identity}" ] || continue
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "${password}" \
      -D "${identity}" \
      -t private \
      "${keychain}" >/dev/null 2>&1 || true
  done
}

saneprocess_resolved_build_config() {
  local command arg requested
  command="${1:-}"
  shift || true

  for arg in "$@"; do
    case "${arg}" in
    --proddebug)
      echo "ProdDebug"
      return 0
      ;;
    --release)
      echo "Release"
      return 0
      ;;
    esac
  done

  requested="${SANEMASTER_BUILD_CONFIG:-${SANEBAR_BUILD_CONFIG:-}}"
  case "${requested}" in
  Debug | debug)
    echo "Debug"
    return 0
    ;;
  ProdDebug | proddebug)
    echo "ProdDebug"
    return 0
    ;;
  Release | release)
    echo "Release"
    return 0
    ;;
  esac

  case "${command}" in
  test_mode | tm | launch | build)
    # Default to release-style signing for runtime tests so Accessibility/TCC
    # trust identity stays stable across launches.
    echo "Release"
    ;;
  *)
    echo "Debug"
    ;;
  esac
}

saneprocess_requires_signed_build() {
  local command config
  command="${1:-}"
  shift || true

  case "${command}" in
  test_mode | tm | launch | build)
    config="$(saneprocess_resolved_build_config "${command}" "$@")"
    [[ "${config}" == "ProdDebug" || "${config}" == "Release" ]]
    ;;
  *)
    return 1
    ;;
  esac
}

saneprocess_headless_keychain_blocking() {
  local keychain info
  keychain="$(saneprocess_login_keychain)"
  [ -f "${keychain}" ] || return 1

  info="$(security show-keychain-info "${keychain}" 2>&1 || true)"
  [[ "${info}" == *"User interaction is not allowed"* ]]
}

saneprocess_enforce_signing_preflight() {
  local keychain password command explicit_signed_config allow_unsigned_fallback
  command="${1:-}"
  shift || true

  saneprocess_requires_signed_build "${command}" "$@" || return 0

  keychain="$(saneprocess_login_keychain)"
  password="$(saneprocess_keychain_password)"
  explicit_signed_config="0"
  for arg in "$@"; do
    case "${arg}" in
    --proddebug | --release)
      explicit_signed_config="1"
      ;;
    esac
  done
  allow_unsigned_fallback="${SANEMASTER_ALLOW_UNSIGNED_FALLBACK:-0}"

  if saneprocess_headless_keychain_blocking && [ -z "${password}" ]; then
    if [[ "${allow_unsigned_fallback}" != "0" && "${explicit_signed_config}" == "0" ]]; then
      case "${command}" in
      launch | test_mode | tm)
        export SANEMASTER_BUILD_CONFIG="Debug"
        export SANEMASTER_UNSIGNED_FALLBACK_ACTIVE="1"
        cat <<EOF
WARNING: Signed ${command} blocked in headless session (keychain locked).
   Falling back to unsigned Debug build for this run.
   Set SANEMASTER_ALLOW_UNSIGNED_FALLBACK=0 to keep strict mode.
   Set SANEMASTER_ALLOW_UNSIGNED_FALLBACK=1 only for explicit debug-only runs.

EOF
        return 0
        ;;
      esac
    fi
    cat <<EOF
ERROR: Signed ${command} build blocked: login keychain is not accessible in this headless session.
   Keychain: ${keychain}

   Provide one of these before rerunning:
   1) export SANEMASTER_KEYCHAIN_PASSWORD='***'   (or SANEBAR_KEYCHAIN_PASSWORD / KEYCHAIN_PASSWORD / KEYCHAIN_PASS)
   2) Run from an interactive GUI login session on the Mini.

EOF
    return 1
  fi
}

saneprocess_requires_codesign_prep() {
  case "${1:-}" in
  test_mode | tm | launch | build | verify)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

saneprocess_apply_user_app_preference() {
  local command app_name
  command="${1:-}"
  app_name="${SANEMASTER_PROJECT:-${SANEBAR_APP_NAME:-}}"
  [ -n "${app_name}" ] || app_name="$(basename "$(saneprocess_project_root)")"

  if [[ "${SANEMASTER_PREFER_USER_APP:-${SANEBAR_PREFER_USER_APP:-0}}" == "1" ]] &&
     [[ -z "${SANEMASTER_CANONICAL_APP_PATH:-}" ]]; then
    case "${command}" in
    launch | test_mode | tm)
      if [[ -d "/Applications/${app_name}.app" ]]; then
        export SANEMASTER_CANONICAL_APP_PATH="/Applications/${app_name}.app"
      else
        export SANEMASTER_CANONICAL_APP_PATH="${HOME}/Applications/${app_name}.app"
      fi
      ;;
    esac
  fi
}

saneprocess_prepare_project_wrapper() {
  local command
  command="${1:-}"
  shift || true

  saneprocess_load_headless_secrets_env || true
  saneprocess_hydrate_project_metadata
  saneprocess_apply_user_app_preference "${command}"

  if saneprocess_requires_codesign_prep "${command}"; then
    saneprocess_prepare_signing_keychain
  fi

  saneprocess_enforce_signing_preflight "${command}" "$@"
}
