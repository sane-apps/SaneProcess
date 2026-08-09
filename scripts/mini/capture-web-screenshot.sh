#!/bin/bash
# capture-web-screenshot.sh — reliable Mini website screenshot for visual receipts.
#
# Uses Playwright with the Mini's Brave executable in headless mode: renders OFF-SCREEN, so there is no
# GUI-session focus problem and no Codex/Terminal window contamination — unlike
# capture-mini-screenshot.sh, which is for the macOS app UI and refuses a dirty workspace.
#
# THIS EXISTS SO NOBODY EVER CLAIMS "a Mini screenshot isn't possible" AGAIN.
# The tools are here. Use them.
#
# Usage:
#   capture-web-screenshot.sh <url> <output_dir> --source-root PROJECT_ROOT [--viewport desktop|375] [--label NAME] [--app APP] [--version VER]
#
# Example:
#   capture-web-screenshot.sh https://sanebar.com apps/SaneBar/outputs/visual-audit-2188 \
#     --viewport 375 --label donate --app SaneBar --version 2.1.88
#
# After running: OPEN the PNG, confirm the change renders, then set "inspected": true
# in the receipt (top-level AND in the screenshot entry) and fill in "result".
# Do NOT fabricate inspection — the gate validator requires inspected:true on purpose.
set -uo pipefail

source_snapshot() {
  ruby -rjson -rdigest -rpathname -rshellwords -e '
    root = Pathname.new(ARGV.fetch(0)).realpath
    git_root = `git -C #{Shellwords.escape(root.to_s)} rev-parse --show-toplevel 2>/dev/null`.strip
    abort "ERROR: source root is not an exact Git root: #{root}" unless $?.success? && Pathname.new(git_root).realpath == root
    head = `git -C #{Shellwords.escape(root.to_s)} rev-parse HEAD`.strip
    branch = `git -C #{Shellwords.escape(root.to_s)} branch --show-current`.strip
    status = IO.popen(["git", "-C", root.to_s, "status", "--porcelain=v1", "-z"], &:read)
    paths = IO.popen(["git", "-C", root.to_s, "ls-files", "-co", "--exclude-standard", "-z"], &:read).split("\0").reject(&:empty?).sort
    records = paths.map do |relative|
      candidate = root.join(relative)
      abort "ERROR: source path escapes target root: #{relative}" if Pathname.new(relative).absolute? || relative.split("/").include?("..")
      abort "ERROR: source path is not a regular file: #{relative}" if candidate.symlink? || !candidate.file?
      resolved = candidate.realpath
      abort "ERROR: source path escapes target root: #{relative}" unless resolved.to_s.start_with?(root.to_s + File::SEPARATOR)
      bytes = File.binread(resolved)
      "#{Digest::SHA256.hexdigest(bytes)}\t#{bytes.bytesize}\t#{relative}\n"
    end.join
    puts JSON.generate({root: root.to_s, head: head, branch: branch, dirty: !status.empty?, status_sha256: Digest::SHA256.hexdigest(status), file_count: paths.length, manifest_sha256: Digest::SHA256.hexdigest(records)})
  ' "$1" 2>&1
}

source_identity_equal() {
  ruby -rjson -e '
    keys = %w[head branch dirty status_sha256 file_count manifest_sha256]
    left, right = ARGV.map { |value| JSON.parse(value) }
    abort "source mismatch" unless keys.all? { |key| left[key] == right[key] }
  ' "$1" "$2"
}

if [ "${1:-}" = "--source-snapshot" ]; then
  [ $# -eq 2 ] || { echo "usage: $0 --source-snapshot PROJECT_ROOT" >&2; exit 2; }
  source_snapshot "$2"
  exit $?
fi

if [ "${1:-}" = "--source-parity" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --source-parity ROOT_A ROOT_B" >&2; exit 2; }
  left_snapshot="$(source_snapshot "$2")" || { printf "%s\n" "$left_snapshot" >&2; exit 5; }
  right_snapshot="$(source_snapshot "$3")" || { printf "%s\n" "$right_snapshot" >&2; exit 5; }
  source_identity_equal "$left_snapshot" "$right_snapshot"
  exit $?
fi

shell_quote() {
  printf "%q" "$1"
}

MINI_HOST="${MINI_HOST:-stephans-mac-mini.local}"
URL="${1:-}"
OUT_DIR="${2:-}"
if [ -z "$URL" ] || [ -z "$OUT_DIR" ]; then
  echo "usage: capture-web-screenshot.sh <url> <output_dir> --source-root PROJECT_ROOT [--viewport desktop|375] [--label NAME] [--app APP] [--version VER]" >&2
  exit 2
fi
shift 2
LABEL="web"; APP="unknown"; VER="unknown"; VIEWPORT_LABEL="desktop"; DRY_RUN=false; SOURCE_ROOT=""; REMOTE_SOURCE_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2;;
    --app) APP="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --viewport) VIEWPORT_LABEL="$2"; shift 2;;
    --source-root) SOURCE_ROOT="$2"; shift 2;;
    --remote-source-root) REMOTE_SOURCE_ROOT="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$SOURCE_ROOT" ] || { echo "ERROR: --source-root is required" >&2; exit 2; }
SOURCE_ROOT="$(cd "$SOURCE_ROOT" 2>/dev/null && pwd -P)" || { echo "ERROR: source root does not exist" >&2; exit 2; }
LOCAL_SOURCE_PRE="$(source_snapshot "$SOURCE_ROOT")" || { printf "%s\n" "$LOCAL_SOURCE_PRE" >&2; exit 5; }
OUTPUT_PATH="$(ruby -rpathname -e '
  path = Pathname.new(ARGV.fetch(0)).expand_path
  suffix = []
  until path.exist? || path.root?
    suffix.unshift(path.basename.to_s)
    path = path.parent
  end
  abort "output ancestor does not exist" unless path.exist?
  puts suffix.reduce(path.realpath) { |base, part| base.join(part) }
' "$OUT_DIR")"
case "$OUTPUT_PATH" in
  "$SOURCE_ROOT"/outputs/*) ;;
  *) echo "ERROR: output directory must stay inside ${SOURCE_ROOT}/outputs" >&2; exit 2;;
esac

case "$VIEWPORT_LABEL" in
  desktop) VIEWPORT_WIDTH=1440; VIEWPORT_HEIGHT=1000;;
  375) VIEWPORT_WIDTH=375; VIEWPORT_HEIGHT=900;;
  *) echo "unsupported viewport: $VIEWPORT_LABEL (expected desktop or 375)" >&2; exit 2;;
esac

if $DRY_RUN; then
  printf '{"browser":"Brave","viewport_label":"%s","width":%s,"height":%s}\n' \
    "$VIEWPORT_LABEL" "$VIEWPORT_WIDTH" "$VIEWPORT_HEIGHT"
  exit 0
fi

if [ -z "$REMOTE_SOURCE_ROOT" ]; then
  case "$SOURCE_ROOT" in
    */SaneApps/*) REMOTE_SOURCE_ROOT="__MINI_HOME__/SaneApps/${SOURCE_ROOT#*/SaneApps/}";;
    *) echo "ERROR: --remote-source-root is required outside SaneApps" >&2; exit 2;;
  esac
fi

if [[ "$REMOTE_SOURCE_ROOT" == __MINI_HOME__/* ]]; then
  MINI_HOME="$(ssh "$MINI_HOST" 'printf %s "$HOME"')" || { echo "ERROR: cannot resolve Mini home" >&2; exit 3; }
  REMOTE_SOURCE_ROOT="${MINI_HOME}/${REMOTE_SOURCE_ROOT#__MINI_HOME__/}"
fi
remote_source_root="$(shell_quote "$REMOTE_SOURCE_ROOT")"
REMOTE_SOURCE_PRE="$(ssh "$MINI_HOST" "bash -s -- --source-snapshot ${remote_source_root}" < "$0")" || {
  printf "%s\n" "$REMOTE_SOURCE_PRE" >&2
  echo "ERROR: Mini source snapshot failed" >&2
  exit 5
}
if ! source_identity_equal "$LOCAL_SOURCE_PRE" "$REMOTE_SOURCE_PRE"; then
  echo "ERROR: Air and Mini website source/config do not match" >&2
  exit 5
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
PNG_NAME="${APP}-${LABEL}-${VIEWPORT_LABEL}-mini-${STAMP}.png"
REMOTE_PNG="/tmp/${PNG_NAME}"
mkdir -p "$OUT_DIR"
RESOLVED_OUT_DIR="$(cd "$OUT_DIR" && pwd -P)" || exit 2
case "$RESOLVED_OUT_DIR" in
  "$SOURCE_ROOT"/outputs/*) ;;
  *) echo "ERROR: resolved output directory escapes ${SOURCE_ROOT}/outputs" >&2; exit 2;;
esac

BRAVE_EXECUTABLE="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
PLAYWRIGHT_NODE_PATH="/opt/homebrew/lib/node_modules"
remote_brave="$(shell_quote "$BRAVE_EXECUTABLE")"
echo "→ Checking Playwright and Brave on ${MINI_HOST}..."
if ! ssh "$MINI_HOST" "test -x ${remote_brave} && NODE_PATH=${PLAYWRIGHT_NODE_PATH} node -e \"require('playwright')\""; then
  echo "ERROR: Mini Brave or the Playwright Node package is unavailable." >&2
  exit 3
fi

echo "→ Capturing ${URL} (${VIEWPORT_LABEL} ${VIEWPORT_WIDTH}x${VIEWPORT_HEIGHT}, full page, headless Brave)..."
remote_url="$(shell_quote "$URL")"
remote_png="$(shell_quote "$REMOTE_PNG")"
if ! ssh "$MINI_HOST" \
  "NODE_PATH=${PLAYWRIGHT_NODE_PATH} node - ${remote_url} ${remote_png} ${VIEWPORT_WIDTH} ${VIEWPORT_HEIGHT}" <<'NODE'
const { chromium } = require("playwright");
const [url, outputPath, widthText, heightText] = process.argv.slice(2);
(async () => {
  const browser = await chromium.launch({
    executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    headless: true
  });
  try {
    const page = await browser.newPage({
      viewport: { width: Number(widthText), height: Number(heightText) }
    });
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(4000);
    await page.screenshot({ path: outputPath, fullPage: true });
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
NODE
then
  echo "ERROR: Playwright + Brave capture failed on the Mini." >&2
  exit 4
fi


LOCAL_SOURCE_POST="$(source_snapshot "$SOURCE_ROOT")" || { printf "%s\n" "$LOCAL_SOURCE_POST" >&2; exit 5; }
REMOTE_SOURCE_POST="$(ssh "$MINI_HOST" "bash -s -- --source-snapshot ${remote_source_root}" < "$0")" || {
  printf "%s\n" "$REMOTE_SOURCE_POST" >&2
  ssh "$MINI_HOST" "rm -f ${remote_png}" >/dev/null 2>&1 || true
  exit 5
}
if ! source_identity_equal "$LOCAL_SOURCE_PRE" "$LOCAL_SOURCE_POST" || \
   ! source_identity_equal "$REMOTE_SOURCE_PRE" "$REMOTE_SOURCE_POST" || \
   ! source_identity_equal "$LOCAL_SOURCE_POST" "$REMOTE_SOURCE_POST"; then
  ssh "$MINI_HOST" "rm -f ${remote_png}" >/dev/null 2>&1 || true
  echo "ERROR: website source/config changed during capture" >&2
  exit 5
fi

echo "→ Copying screenshot back to ${OUT_DIR}/${PNG_NAME}..."
scp "${MINI_HOST}:${REMOTE_PNG}" "${OUT_DIR}/${PNG_NAME}"
ssh "$MINI_HOST" "rm -f ${remote_png}" >/dev/null 2>&1 || true

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECEIPT="${OUT_DIR}/customer_ui_action_receipt.json"
ruby -rjson -e '
  source = JSON.parse(ARGV.fetch(0))
  receipt = {
    type: "visual_audit", status: "passed", host: ARGV.fetch(1), inspected: false,
    app: ARGV.fetch(2), app_version: ARGV.fetch(3), commit: source.fetch("head"),
    generated_at: ARGV.fetch(4),
    captured_with: "Playwright headless Brave on the Mini (capture-web-screenshot.sh)",
    url: ARGV.fetch(5),
    viewport: {label: ARGV.fetch(6), width: Integer(ARGV.fetch(7)), height: Integer(ARGV.fetch(8))},
    source: {
      target_root: source.fetch("root"), remote_root: ARGV.fetch(9),
      git_head: source.fetch("head"), git_branch: source.fetch("branch"), git_dirty: source.fetch("dirty"),
      git_status_sha256: source.fetch("status_sha256"), manifest_file_count: source.fetch("file_count"),
      manifest_sha256: source.fetch("manifest_sha256"), air_mini_parity: true
    },
    screenshots: [{path: ARGV.fetch(10), view: "#{ARGV.fetch(5)} full page at #{ARGV.fetch(6)} #{ARGV.fetch(7)}x#{ARGV.fetch(8)}", result: "TODO: describe what you SEE rendering correctly", inspected: false}],
    notes: "Scaffold from capture-web-screenshot.sh. OPEN the PNG, confirm the change renders, then set inspected:true (top-level + screenshot) and fill in result. Do NOT fabricate."
  }
  puts JSON.pretty_generate(receipt)
' "$LOCAL_SOURCE_POST" "$MINI_HOST" "$APP" "$VER" "$NOW_ISO" "$URL" "$VIEWPORT_LABEL" "$VIEWPORT_WIDTH" "$VIEWPORT_HEIGHT" "$REMOTE_SOURCE_ROOT" "$PNG_NAME" > "$RECEIPT"

echo ""
echo "✅ Screenshot: ${OUT_DIR}/${PNG_NAME}"
echo "✅ Receipt scaffold: ${RECEIPT}  (inspected=false — gate stays red until you inspect)"
echo ""
echo "NEXT (required, honest step):"
echo "  1. Open ${OUT_DIR}/${PNG_NAME}; confirm the change actually renders."
echo "  2. In ${RECEIPT}: set inspected=true (top-level + screenshot entry) and fill in result."
