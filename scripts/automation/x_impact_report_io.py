#!/usr/bin/env python3
"""Collection and CLI orchestration for X outreach impact reports."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from x_impact_report_core import (
    Post,
    build_report,
    merge_posts,
    normalize_product,
    posts_from_log,
    posts_from_snapshot,
    render_markdown,
)


DEFAULT_ROOT = Path.home() / "SaneApps" / "infra" / "SaneProcess"
DEFAULT_OUTREACH_DIR = DEFAULT_ROOT / "outputs" / "x-outreach"
DEFAULT_POST_LOG = DEFAULT_OUTREACH_DIR / "post-log.jsonl"
ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
X_API_PYTHON = Path(os.environ.get("SANE_X_API_PYTHON", "~/.local/share/x-api-venv/bin/python3")).expanduser()
KEY_ENV_MAP = {
    "consumer_key": "X_API_CONSUMER_KEY",
    "consumer_secret": "X_API_CONSUMER_SECRET",
    "access_token": "X_API_ACCESS_TOKEN",
    "access_token_secret": "X_API_ACCESS_TOKEN_SECRET",
}
LAST_KEYCHAIN_READ_AT = 0.0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Report X outreach engagement against sales/download/event data.")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="SaneProcess repo root.")
    parser.add_argument("--post-log", default=str(DEFAULT_POST_LOG), help="x-post.py JSONL history path.")
    parser.add_argument(
        "--x-snapshot",
        action="append",
        default=[],
        help="Existing X own-posts JSON snapshot. Repeatable. Defaults to outputs/x-outreach/own-posts-*.json.",
    )
    parser.add_argument("--fetch-x", action="store_true", help="Fetch recent own posts from X and save a snapshot.")
    parser.add_argument("--x-pages", type=int, default=10, help="Max X API pages to fetch when --fetch-x is used.")
    parser.add_argument("--sales-json", help="Existing SaneMaster sales --json file.")
    parser.add_argument("--downloads-json", help="Existing SaneMaster downloads --json file.")
    parser.add_argument("--events-json", help="Existing SaneMaster events --json file.")
    parser.add_argument("--collect", action="store_true", help="Collect fresh sales/downloads/events JSON first.")
    parser.add_argument("--days", type=int, default=30, help="Lookback days for downloads/events and report scope.")
    parser.add_argument("--baseline-days", type=int, default=7, help="Days before each post used for daily baseline.")
    parser.add_argument("--max-markdown-posts", type=int, default=25, help="Max individual posts to list in Markdown.")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTREACH_DIR / "impact"), help="Directory for saved reports.")
    parser.add_argument("--json", action="store_true", help="Print JSON report instead of Markdown.")
    return parser.parse_args(argv)

def maybe_reexec_x_venv(argv: list[str]) -> None:
    if "--fetch-x" not in argv or os.environ.get("SANE_X_IMPACT_NO_REEXEC") == "1":
        return
    if not X_API_PYTHON.is_file() or Path(sys.executable) == X_API_PYTHON:
        return
    try:
        import requests  # noqa: F401
        import requests_oauthlib  # noqa: F401
        return
    except ImportError:
        os.execv(str(X_API_PYTHON), [str(X_API_PYTHON), str(Path(__file__).with_name("x-impact-report.py")), *argv])

def load_json(path: Path | None, default: Any) -> Any:
    if not path:
        return default
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default

def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        try:
            rows.append(json.loads(raw_line))
        except json.JSONDecodeError:
            continue
    return rows

def load_env_cache() -> None:
    if not ENV_CACHE_FILE.is_file():
        return
    for raw_line in ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        if key in os.environ:
            continue
        parts = shlex.split(raw_value, posix=True)
        os.environ[key] = os.path.expandvars(parts[0] if len(parts) == 1 else raw_value.strip())

def get_secret(account: str) -> str:
    load_env_cache()
    env_name = KEY_ENV_MAP[account]
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        raise RuntimeError(f"Missing {env_name}; add it to ~/.config/nv/env or enable Keychain fallback.")
    global LAST_KEYCHAIN_READ_AT
    since_last = time.monotonic() - LAST_KEYCHAIN_READ_AT
    if LAST_KEYCHAIN_READ_AT and since_last < 1.25:
        time.sleep(1.25 - since_last)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "x-api", "-a", account, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    LAST_KEYCHAIN_READ_AT = time.monotonic()
    value = result.stdout.strip()
    if not value:
        raise RuntimeError(f"Missing Keychain secret x-api/{account}.")
    return value

def fetch_x_snapshot(output_dir: Path, pages: int) -> Path:
    try:
        import requests
        from requests_oauthlib import OAuth1
    except ImportError as exc:
        raise RuntimeError("X fetch requires requests and requests_oauthlib in the active Python environment.") from exc

    auth = OAuth1(
        get_secret("consumer_key"),
        get_secret("consumer_secret"),
        get_secret("access_token"),
        get_secret("access_token_secret"),
    )
    user_params = {"user.fields": "created_at,description,public_metrics,username,name"}
    user_response = requests.get("https://api.x.com/2/users/me", params=user_params, auth=auth, timeout=30)
    user_response.raise_for_status()
    me = user_response.json().get("data") or {}
    user_id = me.get("id")
    if not user_id:
        raise RuntimeError("X API did not return the authenticated user id.")

    tweets: list[dict[str, Any]] = []
    token = None
    for _ in range(max(1, pages)):
        params = {
            "max_results": "100",
            "tweet.fields": "created_at,public_metrics,entities,conversation_id,lang,possibly_sensitive,reply_settings",
            "exclude": "retweets",
        }
        if token:
            params["pagination_token"] = token
        response = requests.get(f"https://api.x.com/2/users/{user_id}/tweets", params=params, auth=auth, timeout=30)
        response.raise_for_status()
        payload = response.json()
        tweets.extend(payload.get("data") or [])
        token = (payload.get("meta") or {}).get("next_token")
        if not token:
            break
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"own-posts-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.json"
    path.write_text(
        json.dumps(
            {
                "fetched_at": datetime.now(timezone.utc).isoformat(),
                "me": me,
                "count": len(tweets),
                "tweets": tweets,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return path

def latest_matching(directory: Path, pattern: str) -> Path | None:
    matches = sorted(directory.glob(pattern))
    return matches[-1] if matches else None

def run_json_command(root: Path, output_dir: Path, label: str, args: list[str]) -> tuple[Path | None, str | None]:
    path = output_dir / f"{label}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.json"
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip() or f"{label} command failed"
    try:
        json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return None, f"{label} command returned non-JSON: {exc}"
    path.write_text(result.stdout if result.stdout.endswith("\n") else f"{result.stdout}\n", encoding="utf-8")
    return path, None

def collect_business_json(root: Path, output_dir: Path, days: int) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    commands = {
        "sales": ["ruby", "scripts/SaneMaster.rb", "sales", "--json"],
        "downloads": ["ruby", "scripts/SaneMaster.rb", "downloads", "--json", "--days", str(days)],
        "events": ["ruby", "scripts/SaneMaster.rb", "events", "--json", "--days", str(days)],
    }
    paths: dict[str, str] = {}
    errors: dict[str, str] = {}
    for label, command in commands.items():
        path, error = run_json_command(root, output_dir, label, command)
        if path:
            paths[label] = str(path)
        if error:
            errors[label] = error
    return {"paths": paths, "errors": errors}


def load_sales(path: Path | None) -> list[dict[str, Any]]:
    data = load_json(path, [])
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("orders") or data.get("rows") or []
    return []


def main(argv: list[str]) -> int:
    maybe_reexec_x_venv(argv)
    args = parse_args(argv)
    root = Path(args.root).expanduser()
    output_dir = Path(args.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    collection: dict[str, Any] = {"paths": {}, "errors": {}}
    snapshot_paths = [Path(path).expanduser() for path in args.x_snapshot]

    if args.fetch_x:
        try:
            snapshot_paths.append(fetch_x_snapshot(DEFAULT_OUTREACH_DIR, args.x_pages))
        except Exception as exc:  # noqa: BLE001 - this is a user-facing collector
            collection["errors"]["x"] = str(exc)

    if args.collect:
        business_collection = collect_business_json(root, output_dir, args.days)
        collection["paths"].update(business_collection.get("paths", {}))
        collection["errors"].update(business_collection.get("errors", {}))

    if not snapshot_paths:
        snapshot_paths = sorted(DEFAULT_OUTREACH_DIR.glob("own-posts-*.json"))

    sales_path = Path(args.sales_json).expanduser() if args.sales_json else None
    downloads_path = Path(args.downloads_json).expanduser() if args.downloads_json else None
    events_path = Path(args.events_json).expanduser() if args.events_json else None
    if not sales_path and collection["paths"].get("sales"):
        sales_path = Path(collection["paths"]["sales"])
    if not downloads_path and collection["paths"].get("downloads"):
        downloads_path = Path(collection["paths"]["downloads"])
    if not events_path and collection["paths"].get("events"):
        events_path = Path(collection["paths"]["events"])
    sales_path = sales_path or latest_matching(output_dir, "sales-*.json")
    downloads_path = downloads_path or latest_matching(output_dir, "downloads-*.json")
    events_path = events_path or latest_matching(output_dir, "events-*.json")

    log_posts = posts_from_log(load_jsonl(Path(args.post_log).expanduser()))
    snapshot_posts: dict[str, Post] = {}
    for snapshot_path in snapshot_paths:
        snapshot_posts.update(posts_from_snapshot(load_json(snapshot_path, {}), snapshot_path))
    posts = merge_posts(log_posts, snapshot_posts)
    report = build_report(
        posts=posts,
        sales_rows=load_sales(sales_path),
        downloads_payload=load_json(downloads_path, {}),
        events_payload=load_json(events_path, {}),
        baseline_days=args.baseline_days,
        lookback_days=args.days,
    )
    paths = {
        "post_log": str(Path(args.post_log).expanduser()),
        "x_snapshots": [str(path) for path in snapshot_paths],
        "sales_json": str(sales_path) if sales_path else "",
        "downloads_json": str(downloads_path) if downloads_path else "",
        "events_json": str(events_path) if events_path else "",
        "errors": collection.get("errors", {}),
    }
    payload = {"ok": True, "paths": paths, "report": report}
    stem = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    json_path = output_dir / f"x-impact-{stem}.json"
    md_path = output_dir / f"x-impact-{stem}.md"
    payload["paths"]["json_report"] = str(json_path)
    payload["paths"]["markdown_report"] = str(md_path)
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report, paths, args.max_markdown_posts), encoding="utf-8")
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_markdown(report, paths, args.max_markdown_posts))
        print(f"Saved JSON: {json_path}")
        print(f"Saved Markdown: {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

