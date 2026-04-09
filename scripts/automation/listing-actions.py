#!/usr/bin/env python3
"""Export listing/setup action items from SaneApps inbox history.

Creates a lightweight Excel workbook without external dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from listing_actions_rules import build_current_actions, build_email_history

ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parents[2] / "outputs" / "listing_actions"
API_BASE = "https://email-api.saneapps.com"
CURRENT_COLUMNS = [
    "site",
    "workflow",
    "action_status",
    "required",
    "latest_date",
    "latest_email_id",
    "latest_thread_status",
    "latest_subject",
    "action",
    "instructions",
    "primary_link",
    "secondary_link",
    "source_email_ids",
    "note",
]
HISTORY_COLUMNS = [
    "site",
    "workflow",
    "required",
    "created_at",
    "email_id",
    "status",
    "category",
    "from_email",
    "subject",
    "action",
    "instructions",
    "primary_link",
    "secondary_link",
    "all_urls",
    "note",
]


def load_env_cache():
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


def persist_secret_to_env_cache(value, *env_names):
    if not value or os.environ.get("SANE_ENV_CACHE_WRITE", "1") == "0":
        return
    names = [name for name in env_names if name]
    if not names:
        return
    ENV_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        ENV_CACHE_FILE.parent.chmod(0o700)
    except OSError:
        pass
    lines = []
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


def get_email_api_key():
    load_env_cache()
    for name in ("SANE_EMAIL_API_KEY", "EMAIL_API_KEY"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        print("Error: missing email API key.", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "sane-email-automation", "-a", "api_key", "-w"],
        capture_output=True,
        text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: missing email API key.", file=sys.stderr)
        sys.exit(1)
    persist_secret_to_env_cache(key, "SANE_EMAIL_API_KEY", "EMAIL_API_KEY")
    return key


def fetch_emails(api_key, page_size=200, max_pages=10):
    all_rows = []
    for page in range(max_pages):
        offset = page * page_size
        url = f"{API_BASE}/api/emails?limit={page_size}&offset={offset}"
        result = subprocess.run(
            ["curl", "-s", url, "-H", f"Authorization: Bearer {api_key}"],
            capture_output=True,
            text=True,
        )
        try:
            payload = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            print(f"Error: inbox API returned invalid JSON for offset {offset}.", file=sys.stderr)
            sys.exit(1)
        rows = payload.get("results", []) or []
        if not rows:
            break
        all_rows.extend(rows)
        if len(rows) < page_size:
            break
    return all_rows


def column_name(index):
    result = ""
    while index:
        index, remainder = divmod(index - 1, 26)
        result = chr(65 + remainder) + result
    return result


def worksheet_xml(headers, rows):
    all_rows = [headers] + rows
    last_col = column_name(len(headers))
    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
        f'  <dimension ref="A1:{last_col}{len(all_rows)}"/>',
        '  <sheetData>',
    ]
    for row_index, row in enumerate(all_rows, start=1):
        lines.append(f'    <row r="{row_index}">')
        for col_index, value in enumerate(row, start=1):
            if value is None or value == "":
                continue
            text = escape(str(value)).replace("\n", "&#10;")
            ref = f"{column_name(col_index)}{row_index}"
            lines.append(f'      <c r="{ref}" t="inlineStr"><is><t xml:space="preserve">{text}</t></is></c>')
        lines.append("    </row>")
    lines.extend(["  </sheetData>", "</worksheet>"])
    return "\n".join(lines)


def write_xlsx(path, sheets):
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(
            "[Content_Types].xml",
            """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>""",
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
  <dc:title>SaneBar listing action tracker</dc:title>
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
            """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Current Actions" sheetId="1" r:id="rId1"/>
    <sheet name="Email History" sheetId="2" r:id="rId2"/>
  </sheets>
</workbook>""",
        )
        zf.writestr(
            "xl/_rels/workbook.xml.rels",
            """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
</Relationships>""",
        )
        for index, (headers, rows) in enumerate(sheets, start=1):
            zf.writestr(f"xl/worksheets/sheet{index}.xml", worksheet_xml(headers, rows))


def rows_for_sheet(columns, records):
    return [[record.get(column, "") for column in columns] for record in records]


def output_path_from_args(args):
    if args.xlsx:
        return Path(args.xlsx).expanduser()
    stamp = datetime.now().strftime("%Y-%m-%d")
    return DEFAULT_OUTPUT_DIR / f"sanebar_listing_actions_{stamp}.xlsx"


def main():
    parser = argparse.ArgumentParser(description="Export listing/setup action tracker from inbox history.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of writing XLSX")
    parser.add_argument("--json-out", help="Also write JSON payload to a file while generating XLSX")
    parser.add_argument("--xlsx", help="Output XLSX path")
    parser.add_argument("--max-pages", type=int, default=10, help="Max inbox pages to fetch (200 emails/page)")
    args = parser.parse_args()

    api_key = get_email_api_key()
    history = build_email_history(fetch_emails(api_key, max_pages=max(args.max_pages, 1)))
    current = build_current_actions(history)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "current_actions": current,
        "email_history": history,
    }

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        print()
        return

    if args.json_out:
        json_out_path = Path(args.json_out).expanduser()
        json_out_path.parent.mkdir(parents=True, exist_ok=True)
        json_out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    output_path = output_path_from_args(args)
    write_xlsx(
        output_path,
        [
            (CURRENT_COLUMNS, rows_for_sheet(CURRENT_COLUMNS, current)),
            (HISTORY_COLUMNS, rows_for_sheet(HISTORY_COLUMNS, history)),
        ],
    )
    latest_path = output_path.parent / "latest.xlsx"
    latest_path.write_bytes(output_path.read_bytes())
    print(f"Wrote {output_path}")
    print(f"Updated {latest_path}")
    print(f"Current actions: {len(current)}")
    print(f"History rows: {len(history)}")


if __name__ == "__main__":
    main()
