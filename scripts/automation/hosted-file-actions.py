#!/usr/bin/env python3
"""Export Lemon Squeezy hosted-file dashboard actions for direct-download apps.

Lemon Squeezy exposes read APIs for products/variants/files, but not a public upload
API for replacing hosted software files. This script turns version drift into a
repeatable owner-action workbook with exact product, variant, and dashboard links.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

LISTING_ACTIONS_PATH = SCRIPT_DIR / "listing-actions.py"
LISTING_ACTIONS_SPEC = importlib.util.spec_from_file_location("listing_actions", LISTING_ACTIONS_PATH)
LISTING_ACTIONS = importlib.util.module_from_spec(LISTING_ACTIONS_SPEC)
assert LISTING_ACTIONS_SPEC and LISTING_ACTIONS_SPEC.loader is not None
LISTING_ACTIONS_SPEC.loader.exec_module(LISTING_ACTIONS)


ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
PRODUCTS_YML = Path(__file__).resolve().parents[2] / "config" / "products.yml"
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parents[2] / "outputs" / "hosted_file_actions"
DEFAULT_UPLOADS_DIR = Path("~/Desktop/LemonSqueezy-Uploads").expanduser()
API_BASE = "https://api.lemonsqueezy.com"
PRODUCT_NAME_ALIASES = {
    "SaneVideo": ["SaneVideo Pro"],
}

CURRENT_COLUMNS = [
    "app",
    "action_status",
    "expected_version",
    "hosted_version",
    "filename",
    "published_file_count",
    "extra_filenames",
    "dashboard_url",
    "dist_url",
    "product_id",
    "product_slug",
    "variant_id",
    "api_files_url",
    "instructions",
    "note",
]

SNAPSHOT_COLUMNS = [
    "app",
    "expected_version",
    "hosted_version",
    "filename",
    "published_file_count",
    "extra_filenames",
    "dashboard_url",
    "dist_url",
    "product_id",
    "product_slug",
    "variant_id",
    "api_files_url",
    "status",
]

UPLOAD_FOLDER_COLUMNS = [
    "status",
    "app",
    "filename",
    "expected_filename",
    "path",
]


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "_None._\n"
    header = "| " + " | ".join(headers) + " |"
    separator = "| " + " | ".join(["---"] * len(headers)) + " |"
    body = [
        "| " + " | ".join(str(cell).replace("\n", " ").replace("|", "\\|") for cell in row) + " |"
        for row in rows
    ]
    return "\n".join([header, separator, *body]) + "\n"


def load_env_cache() -> None:
    if not ENV_CACHE_FILE.is_file():
        return
    try:
        for raw_line in ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, raw_value = line.split("=", 1)
            key = key.strip()
            if not key or key in os.environ:
                continue
            parts = shlex.split(raw_value, posix=True)
            value = parts[0] if len(parts) == 1 else raw_value.strip()
            os.environ[key] = os.path.expandvars(value)
    except OSError:
        return


def persist_secret_to_env_cache(value: str, *env_names: str) -> None:
    if not value or os.environ.get("SANE_ENV_CACHE_WRITE", "0") == "0":
        return
    names = [name for name in env_names if name]
    if not names:
        return
    ENV_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        ENV_CACHE_FILE.parent.chmod(0o700)
    except OSError:
        pass
    lines: list[str] = []
    if ENV_CACHE_FILE.exists():
        lines = ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines()
    filtered = []
    for line in lines:
        stripped = line.strip()
        if any(stripped.startswith(f"export {name}=") for name in names):
            continue
        filtered.append(line)
    for name in names:
        filtered.append(f"export {name}={shlex.quote(value)}")
    ENV_CACHE_FILE.write_text("\n".join(filtered) + "\n", encoding="utf-8")
    ENV_CACHE_FILE.chmod(0o600)


def get_lemonsqueezy_api_key() -> str:
    load_env_cache()
    value = os.environ.get("LEMONSQUEEZY_API_KEY", "").strip()
    if value:
        return value
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        print("Error: missing Lemon Squeezy API key.", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "lemonsqueezy", "-a", "api_key", "-w"],
        capture_output=True,
        text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: missing Lemon Squeezy API key.", file=sys.stderr)
        sys.exit(1)
    persist_secret_to_env_cache(key, "LEMONSQUEEZY_API_KEY")
    return key


def load_product_config() -> dict[str, Any]:
    ruby = (
        "require 'yaml'; require 'json'; "
        f"puts JSON.dump(YAML.load_file({json.dumps(str(PRODUCTS_YML))}))"
    )
    try:
        result = subprocess.run(["ruby", "-e", ruby], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"Error: could not load products.yml from {PRODUCTS_YML}: {exc}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def fetch_json(url: str, api_key: str | None = None) -> dict[str, Any] | list[Any] | None:
    headers = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
        headers["Accept"] = "application/vnd.api+json"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def fetch_text(url: str) -> str:
    try:
        result = subprocess.run(
            [
                "curl",
                "-fsSL",
                "--connect-timeout",
                "5",
                "--max-time",
                "20",
                "-A",
                "SaneProcess/1.0",
                url,
            ],
            capture_output=True,
            text=True,
            timeout=25,
        )
    except subprocess.TimeoutExpired:
        return ""
    return result.stdout if result.returncode == 0 else ""


def fetch_collection(path: str, api_key: str) -> list[dict[str, Any]]:
    payload = fetch_json(f"{API_BASE}{path}", api_key=api_key)
    if not isinstance(payload, dict):
        return []
    data = payload.get("data")
    return data if isinstance(data, list) else []


def fetch_appcast_release(url: str) -> tuple[str, str]:
    body = fetch_text(url)
    if not body:
        return "", ""
    latest_item_match = re.search(r"<item\b.*?</item>", body, re.DOTALL)
    latest_item = latest_item_match.group(0) if latest_item_match else body
    enclosure_match = re.search(r'<enclosure[^>]*\burl="([^"]+)"', latest_item, re.DOTALL)
    version_match = re.search(r'sparkle:shortVersionString="([^"]+)"', latest_item)
    if not version_match:
        version_match = re.search(
            r"<sparkle:shortVersionString>\s*([^<]+)\s*</sparkle:shortVersionString>",
            latest_item,
            re.DOTALL,
        )
    version = version_match.group(1).strip() if version_match else ""
    enclosure_url = enclosure_match.group(1).strip() if enclosure_match else ""
    return version, enclosure_url


def extract_version_from_filename(filename: str) -> str:
    matches = re.findall(r"(\d+\.\d+\.\d+)", filename or "")
    return matches[-1] if matches else ""


def file_name(record: dict[str, Any] | None) -> str:
    return str((record or {}).get("attributes", {}).get("name", "")).strip()


def published_files(files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        record
        for record in files
        if str(record.get("attributes", {}).get("status", "")) == "published"
    ]


def select_display_file(
    files: list[dict[str, Any]],
    expected_version: str,
) -> dict[str, Any] | None:
    candidates = published_files(files) or files
    for record in candidates:
        if expected_version and extract_version_from_filename(file_name(record)) == expected_version:
            return record
    return candidates[0] if candidates else None


def stale_published_file_names(
    files: list[dict[str, Any]],
    expected_version: str,
) -> list[str]:
    stale_names: list[str] = []
    for record in published_files(files):
        name = file_name(record)
        if not name:
            continue
        version = extract_version_from_filename(name)
        if not expected_version or version != expected_version:
            stale_names.append(name)
    return stale_names


def dashboard_url_for(product_id: str) -> str:
    return f"https://app.lemonsqueezy.com/products/{product_id}" if product_id else ""


def file_api_url_for(variant_id: str) -> str:
    return f"{API_BASE}/v1/variants/{variant_id}/files" if variant_id else ""


def find_product_record(app_name: str, products: list[dict[str, Any]]) -> dict[str, Any] | None:
    accepted_names = {app_name, *PRODUCT_NAME_ALIASES.get(app_name, [])}
    for record in products:
        name = str(record.get("attributes", {}).get("name", "")).strip()
        if name in accepted_names or name.startswith(f"{app_name}:"):
            return record
    return None


def find_variant_record(product_id: str, variants: list[dict[str, Any]]) -> dict[str, Any] | None:
    for record in variants:
        if str(record.get("attributes", {}).get("product_id", "")) == str(product_id):
            return record
    return None


def build_snapshot_rows(config: dict[str, Any], api_key: str) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    products = fetch_collection("/v1/products?page[size]=100", api_key)
    variants = fetch_collection("/v1/variants?page[size]=100", api_key)
    actions: list[dict[str, str]] = []
    snapshot_rows: list[dict[str, str]] = []

    for _, product in (config.get("products") or {}).items():
        app_name = str(product.get("name", "")).strip()
        appcast_url = str(product.get("appcast", "")).strip()
        if not app_name or not appcast_url:
            continue

        expected_version, dist_url = fetch_appcast_release(appcast_url)
        product_record = find_product_record(app_name, products)
        if not product_record:
            continue
        product_id = str(product_record.get("id", "")).strip()
        product_slug = str(product_record.get("attributes", {}).get("slug", "")).strip()
        variant_record = find_variant_record(product_id, variants)
        variant_id = str(variant_record.get("id", "")).strip() if variant_record else ""

        files = fetch_collection(f"/v1/variants/{variant_id}/files?page[size]=100", api_key) if variant_id else []
        visible_files = published_files(files)
        displayed_file = select_display_file(files, expected_version)
        filename = file_name(displayed_file)
        hosted_version = extract_version_from_filename(filename)
        extra_filenames = stale_published_file_names(files, expected_version) if expected_version else []
        if not expected_version:
            status = "Needs appcast evidence"
        elif hosted_version == expected_version and not extra_filenames:
            status = "In sync"
        elif hosted_version == expected_version:
            status = "Needs dashboard cleanup"
        else:
            status = "Needs dashboard sync"

        row = {
            "app": app_name,
            "expected_version": expected_version,
            "hosted_version": hosted_version or "—",
            "filename": filename or "—",
            "published_file_count": str(len(visible_files)),
            "extra_filenames": ", ".join(extra_filenames) or "—",
            "dashboard_url": dashboard_url_for(product_id),
            "dist_url": dist_url,
            "product_id": product_id,
            "product_slug": product_slug,
            "variant_id": variant_id,
            "api_files_url": file_api_url_for(variant_id),
            "status": status,
        }
        snapshot_rows.append(row)

        if status == "In sync":
            continue

        if status == "Needs appcast evidence":
            instructions = (
                f"Check {appcast_url} from the Mini, confirm the latest Sparkle version, "
                "then rerun this tracker before changing Lemon Squeezy hosted files."
            )
        elif status == "Needs dashboard cleanup":
            instructions = (
                f"Open {row['dashboard_url']}, go to Files for variant {variant_id or 'Default'}, "
                f"delete or unpublish every old file ({row['extra_filenames']}), and leave only "
                f"{filename or f'{app_name}-{expected_version}.zip'} published for customers."
            )
        else:
            instructions = (
                f"Open {row['dashboard_url']}, go to Files for variant {variant_id or 'Default'}, "
                f"replace the published file with the {expected_version} archive from {dist_url or appcast_url}, "
                "delete or unpublish old files, and confirm only the appcast-matching ZIP remains published."
            )

        actions.append(
            {
                **row,
                "action_status": status,
                "instructions": instructions,
                "note": "Lemon Squeezy exposes read APIs for hosted files, but file replacement and cleanup are still dashboard actions.",
            }
        )

    actions.sort(key=lambda row: row["app"])
    snapshot_rows.sort(key=lambda row: row["app"])
    return actions, snapshot_rows


def rows_for_sheet(columns: list[str], records: list[dict[str, str]]) -> list[list[str]]:
    return [[record.get(column, "") for column in columns] for record in records]


def expected_filename_for_snapshot(row: dict[str, str]) -> str:
    dist_url = str(row.get("dist_url") or "").strip()
    if dist_url:
        filename = dist_url.rstrip("/").split("/")[-1]
        if filename.endswith(".zip"):
            return filename
    app = str(row.get("app") or "").strip()
    version = str(row.get("expected_version") or "").strip()
    return f"{app}-{version}.zip" if app and version else ""


def audit_upload_folder(path: Path, snapshot: list[dict[str, str]]) -> dict[str, Any]:
    expected_by_app: dict[str, str] = {}
    for row in snapshot:
        app = str(row.get("app") or "").strip()
        expected = expected_filename_for_snapshot(row)
        if app and expected:
            expected_by_app[app] = expected

    result: dict[str, Any] = {
        "path": str(path),
        "exists": path.is_dir(),
        "stale_files": [],
        "missing_latest": [],
        "unexpected_files": [],
        "ok_files": [],
    }
    if not path.is_dir():
        return result

    app_names = sorted(expected_by_app, key=len, reverse=True)
    seen_expected: set[str] = set()
    for candidate in sorted(path.glob("*.zip")):
        if not candidate.is_file():
            continue
        matched_app = next(
            (app for app in app_names if candidate.name.startswith(f"{app}-")),
            "",
        )
        if not matched_app:
            result["unexpected_files"].append({
                "status": "unexpected",
                "app": "",
                "filename": candidate.name,
                "expected_filename": "",
                "path": str(candidate),
            })
            continue
        expected = expected_by_app[matched_app]
        row = {
            "status": "ok" if candidate.name == expected else "stale",
            "app": matched_app,
            "filename": candidate.name,
            "expected_filename": expected,
            "path": str(candidate),
        }
        if candidate.name == expected:
            seen_expected.add(expected)
            result["ok_files"].append(row)
        else:
            result["stale_files"].append(row)

    for app, expected in sorted(expected_by_app.items()):
        if expected not in seen_expected:
            result["missing_latest"].append({
                "status": "missing_latest",
                "app": app,
                "filename": "",
                "expected_filename": expected,
                "path": str(path / expected),
            })
    return result


def upload_folder_rows(upload_folder: dict[str, Any] | None) -> list[dict[str, str]]:
    if not upload_folder:
        return []
    rows: list[dict[str, str]] = []
    for key in ("stale_files", "missing_latest", "unexpected_files", "ok_files"):
        rows.extend(upload_folder.get(key) or [])
    if not upload_folder.get("exists"):
        rows.append({
            "status": "missing_folder",
            "app": "",
            "filename": "",
            "expected_filename": "",
            "path": str(upload_folder.get("path") or ""),
        })
    return rows


def write_named_xlsx(path: Path, sheets: list[tuple[str, list[str], list[list[str]]]]) -> None:
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path.parent.mkdir(parents=True, exist_ok=True)
    overrides = [
        f'  <Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        for index in range(1, len(sheets) + 1)
    ]
    workbook_sheets = [
        f'    <sheet name="{name}" sheetId="{index}" r:id="rId{index}"/>'
        for index, (name, _, _) in enumerate(sheets, start=1)
    ]
    workbook_rels = [
        f'  <Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>'
        for index, _sheet in enumerate(sheets, start=1)
    ]
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(
            "[Content_Types].xml",
            "\n".join(
                [
                    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
                    '  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
                    '  <Default Extension="xml" ContentType="application/xml"/>',
                    '  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
                    *overrides,
                    '  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
                    '  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
                    '</Types>',
                ]
            ),
        )
        zf.writestr(
            "_rels/.rels",
            """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>""",
        )
        zf.writestr(
            "docProps/core.xml",
            f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:creator>Codex</dc:creator>
  <cp:lastModifiedBy>Codex</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">{created}</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">{created}</dcterms:modified>
  <dc:title>SaneApps hosted file action tracker</dc:title>
</cp:coreProperties>""",
        )
        zf.writestr(
            "docProps/app.xml",
            """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>Codex</Application>
</Properties>""",
        )
        zf.writestr(
            "xl/workbook.xml",
            "\n".join(
                [
                    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
                    "  <sheets>",
                    *workbook_sheets,
                    "  </sheets>",
                    "</workbook>",
                ]
            ),
        )
        zf.writestr(
            "xl/_rels/workbook.xml.rels",
            "\n".join(
                [
                    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
                    *workbook_rels,
                    "</Relationships>",
                ]
            ),
        )
        for index, (_name, headers, rows) in enumerate(sheets, start=1):
            zf.writestr(
                f"xl/worksheets/sheet{index}.xml",
                LISTING_ACTIONS.worksheet_xml(headers, rows),
            )


def output_path_from_args(args: argparse.Namespace) -> Path:
    if args.xlsx:
        return Path(args.xlsx).expanduser()
    stamp = datetime.now().strftime("%Y-%m-%d")
    return DEFAULT_OUTPUT_DIR / f"saneapps_hosted_file_actions_{stamp}.xlsx"


def copy_latest_atomic(source: Path, latest_path: Path) -> None:
    latest_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".latest-", suffix=".xlsx", dir=latest_path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(source.read_bytes())
        os.replace(tmp_path, latest_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def write_evidence(path: Path, payload: dict[str, Any]) -> None:
    current_actions = payload.get("current_actions") or []
    snapshot = payload.get("snapshot") or []
    upload_folder = payload.get("upload_folder") or {}
    generated_at = str(payload.get("generated_at") or "")
    path.parent.mkdir(parents=True, exist_ok=True)

    action_rows = [
        [
            row.get("app", ""),
            row.get("expected_version", ""),
            row.get("hosted_version", ""),
            row.get("published_file_count", ""),
            row.get("extra_filenames", ""),
            row.get("dashboard_url", ""),
            row.get("dist_url", ""),
        ]
        for row in current_actions
    ]
    snapshot_rows = [
        [
            row.get("app", ""),
            row.get("expected_version", ""),
            row.get("hosted_version", ""),
            row.get("status", ""),
        ]
        for row in snapshot
    ]
    upload_rows = [
        [
            row.get("status", ""),
            row.get("app", ""),
            row.get("filename", ""),
            row.get("expected_filename", ""),
            row.get("path", ""),
        ]
        for row in upload_folder_rows(upload_folder)
        if row.get("status") != "ok"
    ]

    path.write_text(
        "\n".join(
            [
                "# Hosted File Action Evidence",
                "",
                f"Generated: {generated_at}",
                f"Current actions: {len(current_actions)}",
                f"Upload folder stale/missing rows: {len(upload_rows)}",
                "",
                "Lemon Squeezy exposes read APIs for hosted files, but replacement is still a dashboard action.",
                "After replacing files, delete or unpublish old hosted ZIPs, rerun this exporter, and keep the new evidence file with the release notes.",
                "The local LemonSqueezy-Uploads folder should contain only the latest ZIP for each direct-download app.",
                "",
                "## Current Actions",
                "",
                markdown_table(["App", "Expected", "Hosted", "Published", "Old files", "Dashboard", "Dist"], action_rows).rstrip(),
                "",
                "## Upload Folder Audit",
                "",
                markdown_table(["Status", "App", "File", "Expected", "Path"], upload_rows).rstrip(),
                "",
                "## Live Snapshot",
                "",
                markdown_table(["App", "Expected", "Hosted", "Status"], snapshot_rows).rstrip(),
                "",
            ]
        ),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export Lemon Squeezy hosted-file dashboard action tracker."
    )
    parser.add_argument("--json", action="store_true", help="Print JSON instead of writing XLSX")
    parser.add_argument("--json-out", help="Also write JSON payload to a file while generating XLSX")
    parser.add_argument("--evidence-out", help="Also write Markdown release evidence to a file")
    parser.add_argument(
        "--uploads-dir",
        default=str(DEFAULT_UPLOADS_DIR),
        help="Audit the local LemonSqueezy-Uploads staging folder for stale ZIPs",
    )
    parser.add_argument("--xlsx", help="Output XLSX path")
    args = parser.parse_args()

    api_key = get_lemonsqueezy_api_key()
    config = load_product_config()
    current_actions, snapshot = build_snapshot_rows(config, api_key)
    upload_folder = audit_upload_folder(Path(args.uploads_dir).expanduser(), snapshot)
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "current_actions": current_actions,
        "snapshot": snapshot,
        "upload_folder": upload_folder,
    }

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        print()
        return

    if args.json_out:
        json_out_path = Path(args.json_out).expanduser()
        json_out_path.parent.mkdir(parents=True, exist_ok=True)
        json_out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if args.evidence_out:
        evidence_path = Path(args.evidence_out).expanduser()
        write_evidence(evidence_path, payload)

    output_path = output_path_from_args(args)
    write_named_xlsx(
        output_path,
        [
            ("Current Actions", CURRENT_COLUMNS, rows_for_sheet(CURRENT_COLUMNS, current_actions)),
            ("Live Snapshot", SNAPSHOT_COLUMNS, rows_for_sheet(SNAPSHOT_COLUMNS, snapshot)),
            ("Upload Folder Audit", UPLOAD_FOLDER_COLUMNS, rows_for_sheet(UPLOAD_FOLDER_COLUMNS, upload_folder_rows(upload_folder))),
        ],
    )
    latest_path = output_path.parent / "latest.xlsx"
    copy_latest_atomic(output_path, latest_path)
    print(f"Wrote {output_path}")
    print(f"Updated {latest_path}")
    print(f"Current actions: {len(current_actions)}")
    print(f"Snapshot rows: {len(snapshot)}")
    stale_uploads = len(upload_folder.get("stale_files") or [])
    missing_uploads = len(upload_folder.get("missing_latest") or [])
    unexpected_uploads = len(upload_folder.get("unexpected_files") or [])
    print(f"Upload folder stale: {stale_uploads}, missing latest: {missing_uploads}, unexpected: {unexpected_uploads}")
    if args.evidence_out:
        print(f"Wrote evidence {Path(args.evidence_out).expanduser()}")


if __name__ == "__main__":
    main()
