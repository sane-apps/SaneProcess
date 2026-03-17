#!/bin/bash
# frozen_string_literal: true
# nv-relnotes.sh - Generate release notes using nv council
# Usage: nv-relnotes.sh [path-to-repo]

set -euo pipefail

# Settings
NV_BIN="/Users/sj/.local/bin/nv"
OUTPUT_DIR="/Users/sj/SaneApps/infra/SaneProcess/outputs/relnotes"
DATE=$(date +%Y%m%d-%H%M%S)

# Release notes prompt
RELNOTES_PROMPT="Write user-facing release notes from these commits and any recent customer-facing research notes. Format as 3-5 bullet points. Focus on what changed for the user, not internal refactoring. Keep each bullet under 100 characters. No technical jargon. Do not omit shipped fixes just because the commit title is vague. Pay special attention to customer-visible fixes that were promised in support replies or issue comments."

# Parse arguments
REPO_PATH="${1:-.}"

# Check if nv exists
if [[ ! -x "$NV_BIN" ]]; then
  echo "Error: nv CLI not found at $NV_BIN" >&2
  exit 1
fi

# Check if repo path exists
if [[ ! -d "$REPO_PATH" ]]; then
  echo "Error: Repository not found at $REPO_PATH" >&2
  exit 1
fi

# Navigate to repo
cd "$REPO_PATH"

# Check if it's a git repo
if [[ ! -d ".git" ]]; then
  echo "Error: $REPO_PATH is not a git repository" >&2
  exit 1
fi

# Get repo name
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

echo "Generating release notes for: $REPO_NAME"
echo "Repository: $REPO_PATH"
echo ""

# Get the two most recent tags
TAGS=($(git tag --sort=-version:refname | head -n 2))

if [[ ${#TAGS[@]} -eq 0 ]]; then
  echo "Error: No tags found in repository" >&2
  exit 1
elif [[ ${#TAGS[@]} -eq 1 ]]; then
  echo "Only one tag found, comparing ${TAGS[0]} to HEAD"
  TAG1="${TAGS[0]}"
  TAG2="HEAD"
  LATEST_TAG="${TAGS[0]}"
else
  echo "Comparing ${TAGS[1]} to ${TAGS[0]}"
  TAG1="${TAGS[1]}"
  TAG2="${TAGS[0]}"
  LATEST_TAG="${TAGS[0]}"
fi

echo ""

# Get commit log
echo "Fetching commits..."
COMMIT_LOG=$(git log --oneline --no-merges "$TAG1".."$TAG2")

if [[ -z "$COMMIT_LOG" ]]; then
  echo "No commits found between $TAG1 and $TAG2" >&2
  exit 1
fi

# Get diff stats
echo "Fetching diff stats..."
DIFF_STATS=$(git diff --stat "$TAG1".."$TAG2")

# Pull recent research notes when available so customer-facing fixes do not get lost
RESEARCH_CONTEXT=""
if [[ -f ".claude/research.md" ]]; then
  echo "Fetching recent research notes..."
  RESEARCH_CONTEXT=$(tail -n 120 .claude/research.md)
fi

# Combine for context
CONTEXT="# Commits:\n$COMMIT_LOG\n\n# Changes:\n$DIFF_STATS"
if [[ -n "$RESEARCH_CONTEXT" ]]; then
  CONTEXT="${CONTEXT}\n\n# Recent Research Notes:\n$RESEARCH_CONTEXT"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Output file
OUTPUT_FILE="$OUTPUT_DIR/${REPO_NAME}-${LATEST_TAG}.md"

echo ""
echo "Querying council..."
echo ""

# Create temporary file for council output
TEMP_FILE=$(mktemp)

# Run nv council
if echo -e "$CONTEXT" | "$NV_BIN" --council "$RELNOTES_PROMPT" > "$TEMP_FILE" 2>&1; then
  echo "✅ Council consensus complete"
else
  echo "⚠️  Council query completed with warnings" >&2
fi

# Parse council output (nv --council outputs responses separated by headers)
# Extract the three responses and pick middle-length one

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "COUNCIL RESPONSES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cat "$TEMP_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Save full output
{
  echo "# Release Notes: $REPO_NAME $LATEST_TAG"
  echo ""
  echo "Generated: $DATE"
  echo "Comparing: $TAG1..$TAG2"
  echo ""
  echo "## Council Output"
  echo ""
  cat "$TEMP_FILE"
  echo ""
  echo "## Commits ($TAG1..$TAG2)"
  echo ""
  echo '```'
  echo "$COMMIT_LOG"
  echo '```'
  echo ""
  echo "## Diff Stats"
  echo ""
  echo '```'
  echo "$DIFF_STATS"
  echo '```'
} > "$OUTPUT_FILE"

echo "Release notes saved to: $OUTPUT_FILE"
echo ""

# Try to extract "best" response (middle-length)
# This is a simple heuristic - we look for the response with median length
# Note: This assumes nv --council outputs in a parseable format
# If the format is different, this section may need adjustment

# Count lines in each response (simple heuristic)
# Split on "Model:" or similar headers if they exist
# For now, just show where it's saved

echo "💡 Review all three council responses above and choose the best one."
echo "   Full output saved to: $OUTPUT_FILE"

# Cleanup
rm -f "$TEMP_FILE"
