#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-issues}"
shift || true

SCOPE="org-wide"
LIMIT="${STATUS_GITHUB_LIMIT:-200}"
FORMAT="text"
ORG="sane-apps"
SUPPORT_REPOS=(
  "sane-apps/SaneBar"
  "sane-apps/SaneClick"
  "sane-apps/SaneClip"
  "sane-apps/SaneHosts"
  "sane-apps/SaneSales"
  "sane-apps/SaneSync"
  "sane-apps/SaneVideo"
  "sane-apps/SaneAI"
)

usage() {
  cat <<'USAGE'
Usage: github-queue.sh issues|prs [--scope org-wide|support-apps] [--limit N] [--format text|markdown]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="${2:?Missing value for --scope}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:?Missing value for --limit}"
      shift 2
      ;;
    --format)
      FORMAT="${2:?Missing value for --format}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "issues" && "$MODE" != "prs" ]]; then
  echo "Unknown mode: $MODE" >&2
  usage >&2
  exit 2
fi

if [[ "$SCOPE" != "org-wide" && "$SCOPE" != "support-apps" ]]; then
  echo "Unknown scope: $SCOPE" >&2
  usage >&2
  exit 2
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "markdown" ]]; then
  echo "Unknown format: $FORMAT" >&2
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) not installed"
  exit 1
fi

print_header() {
  if [[ "$FORMAT" == "markdown" ]]; then
    printf 'Scope: %s\n\n' "$SCOPE"
  else
    printf 'Scope: %s\n' "$SCOPE"
  fi
}

search_org() {
  if [[ "$MODE" == "issues" ]]; then
    gh search issues --owner "$ORG" --state open --limit "$LIMIT" \
      --json repository,number,title,labels,updatedAt,url \
      --jq '
        group_by(.repository.nameWithOwner)[]
        | "## " + .[0].repository.nameWithOwner + "\n"
          + (map(
              "  #" + (.number | tostring)
              + "\tOPEN\t" + .title
              + "\t" + (([.labels[].name] | join(", ")) // "")
              + "\t" + .updatedAt
            ) | join("\n"))
      '
  else
    gh search prs --owner "$ORG" --state open --limit "$LIMIT" \
      --json repository,number,title,labels,updatedAt,author,isDraft,url \
      --jq '
        group_by(.repository.nameWithOwner)[]
        | "## " + .[0].repository.nameWithOwner + "\n"
          + (map(
              "  #" + (.number | tostring)
              + "\t" + (if .isDraft then "DRAFT" else "OPEN" end)
              + "\t" + .title
              + "\t" + .author.login
              + "\t" + (([.labels[].name] | join(", ")) // "")
              + "\t" + .updatedAt
            ) | join("\n"))
      '
  fi
}

search_support_apps() {
  local found=0
  local repo rows
  for repo in "${SUPPORT_REPOS[@]}"; do
    if [[ "$MODE" == "issues" ]]; then
      rows=$(gh issue list --repo "$repo" --state open --limit "$LIMIT" 2>/dev/null || true)
    else
      rows=$(gh pr list --repo "$repo" --state open --limit "$LIMIT" 2>/dev/null || true)
    fi
    if [[ -n "$rows" ]]; then
      printf '## %s\n' "$repo"
      printf '%s\n' "$rows" | sed 's/^/  /'
      found=1
    fi
  done
  [[ "$found" -eq 1 ]]
}

print_header

if [[ "$SCOPE" == "org-wide" ]]; then
  output="$(search_org 2>&1)" || {
    echo "Unable to fetch org-wide $MODE (auth missing or GitHub search unavailable)."
    echo "$output"
    exit 1
  }
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    echo "No open GitHub $MODE found."
  fi
else
  if ! search_support_apps; then
    echo "No open GitHub $MODE found in support-apps scope."
  fi
fi
