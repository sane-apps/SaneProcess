#!/bin/bash
set -euo pipefail

PROJECT_ROOT="${1:-}"
if [[ -z "${PROJECT_ROOT}" ]]; then
  echo "Usage: public-source-build-guard.sh <project_root>" >&2
  exit 1
fi

README_PATH="${PROJECT_ROOT}/README.md"
PROJECT_YML_PATH="${PROJECT_ROOT}/project.yml"

if [[ ! -f "${README_PATH}" || ! -f "${PROJECT_YML_PATH}" ]]; then
  exit 0
fi

if ! grep -Eqi 'build from source|for developers|git clone https://github.com/sane-apps/' "${README_PATH}"; then
  exit 0
fi

issues=()

if grep -Eq '^[[:space:]]+path:[[:space:]]+\.\./\.\./infra/SaneUI[[:space:]]*$' "${PROJECT_YML_PATH}"; then
  issues+=("project.yml still points SaneUI at ../../infra/SaneUI")
fi

while IFS= read -r pbxproj; do
  [[ -n "${pbxproj}" ]] || continue
  if grep -q 'relativePath = ../../infra/SaneUI;' "${pbxproj}"; then
    rel_path="${pbxproj#${PROJECT_ROOT}/}"
    issues+=("${rel_path} still contains XCLocalSwiftPackageReference ../../infra/SaneUI")
  fi
done < <(find "${PROJECT_ROOT}" \
  -maxdepth 3 \
  -path '*/project.pbxproj' \
  -type f \
  ! -path '*/.git/*' \
  ! -path '*/.worktrees/*' \
  ! -path '*/build/*' \
  ! -path '*/DerivedData/*' \
  2>/dev/null | sort)

if [[ ${#issues[@]} -gt 0 ]]; then
  echo "BLOCKED: public source-build guard failed for ${PROJECT_ROOT}" >&2
  for issue in "${issues[@]}"; do
    echo "  - ${issue}" >&2
  done
  echo "Fix the repo to use the remote SaneUI package before release." >&2
  exit 1
fi

echo "PASS: public source-build guard ok for ${PROJECT_ROOT}"
