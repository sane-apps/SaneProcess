#!/usr/bin/env python3
"""Run a bounded X opportunity scan from SaneApps outreach configs.

This script only searches and reports. It never posts, likes, follows, or sends
messages.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
DEFAULT_ROOT = Path.home() / "SaneApps"
KEY_ENV_MAP = {
    "consumer_key": "X_API_CONSUMER_KEY",
    "consumer_secret": "X_API_CONSUMER_SECRET",
    "access_token": "X_API_ACCESS_TOKEN",
    "access_token_secret": "X_API_ACCESS_TOKEN_SECRET",
}
_LAST_KEYCHAIN_READ_AT = 0.0
# SaneBar is retired (no longer paid or supported) — do not scout or link it.
# SaneCite is the priority product going forward.
PRODUCT_DOMAINS = {
    "SaneCite": ["sanecite.com"],
    "SaneClick": ["saneclick.com"],
    "SaneClip": ["saneclip.com"],
    "SaneHosts": ["sanehosts.com"],
    "SaneSales": ["sanesales.com"],
    "SaneScan": ["sanescan.saneapps.com"],
    "SaneVideo": ["sanevideo.com"],
}
SANEAPPS_URL = "https://saneapps.com"
GLOBAL_QUERIES = [
    '(privacy OR private OR "no cloud" OR local OR offline) ("Mac app" OR macOS) lang:en -is:retweet',
    '("looking for" OR recommend OR alternative) ("Mac app" OR macOS) (privacy OR local OR simple) lang:en -is:retweet',
    '("best Mac apps" OR "Mac productivity") (privacy OR utility OR local) lang:en -is:retweet',
]


class ScoutError(RuntimeError):
    """Raised when the scout cannot complete a requested live scan."""


@dataclass(frozen=True)
class ProductConfig:
    name: str
    path: Path
    keywords: list[str]
    status_note: str
    launch_classification: str
    domains: list[str]
    website_url: str

    @property
    def public_ready(self) -> bool:
        text = f"{self.status_note} {self.launch_classification}".lower()
        blocked_phrases = (
            "blocked_not_launch_ready",
            "pre_live",
            "not launch-ready",
            "not_launch_ready",
            "do_not_launch",
            "do not launch",
            "do not use this as public positioning",
            "strategic reset",
        )
        return not any(phrase in text for phrase in blocked_phrases)


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
            os.environ[key] = os.path.expandvars(parts[0] if len(parts) == 1 else raw_value.strip())
    except OSError:
        return


def persist_secret_to_env_cache(value: str, *env_names: str) -> None:
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
    lines = ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines() if ENV_CACHE_FILE.exists() else []
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


def get_secret(account: str) -> str:
    load_env_cache()
    env_name = KEY_ENV_MAP[account]
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        raise ScoutError(f"Missing {env_name}; add it to ~/.config/nv/env or enable Keychain fallback.")
    global _LAST_KEYCHAIN_READ_AT
    since_last = time.monotonic() - _LAST_KEYCHAIN_READ_AT
    if _LAST_KEYCHAIN_READ_AT and since_last < 1.25:
        time.sleep(1.25 - since_last)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "x-api", "-a", account, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    _LAST_KEYCHAIN_READ_AT = time.monotonic()
    value = result.stdout.strip()
    if not value:
        raise ScoutError(f"Missing Keychain secret x-api/{account}.")
    persist_secret_to_env_cache(value, env_name)
    return value


def parse_scalar(raw: str) -> str:
    value = raw.strip()
    if not value:
        return ""
    if value[0] in ("'", '"'):
        try:
            return str(ast.literal_eval(value))
        except (SyntaxError, ValueError):
            return value.strip("'\"")
    return value


def extract_top_level_scalar(text: str, key: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}:\s*(.*?)\s*$", re.MULTILINE)
    match = pattern.search(text)
    return parse_scalar(match.group(1)) if match else ""


def extract_nested_scalar(text: str, parent: str, key: str) -> str:
    lines = text.splitlines()
    in_parent = False
    for line in lines:
        if re.match(rf"^{re.escape(parent)}:\s*$", line):
            in_parent = True
            continue
        if in_parent and line and not line.startswith((" ", "\t")):
            return ""
        match = re.match(rf"^\s+{re.escape(key)}:\s*(.*?)\s*$", line)
        if in_parent and match:
            return parse_scalar(match.group(1))
    return ""


def extract_top_level_list(text: str, key: str) -> list[str]:
    lines = text.splitlines()
    values: list[str] = []
    in_block = False
    for line in lines:
        if re.match(rf"^{re.escape(key)}:\s*$", line):
            in_block = True
            continue
        if in_block and line and not line.startswith((" ", "\t")):
            break
        if not in_block:
            continue
        match = re.match(r"^\s*-\s*(.*?)\s*$", line)
        if match:
            value = parse_scalar(match.group(1))
            if value:
                values.append(value)
    return values


def load_product_config(path: Path) -> ProductConfig:
    text = path.read_text(encoding="utf-8")
    name = extract_top_level_scalar(text, "product") or path.parent.name
    status_note = extract_nested_scalar(text, "positioning", "status_note")
    classification = extract_nested_scalar(text, "launch_calendar", "classification")
    domains = PRODUCT_DOMAINS.get(name, []).copy()
    project_url = extract_nested_scalar(text, "project", "url")
    if project_url:
        domain = urlparse(project_url).netloc.lower()
        domain = domain[4:] if domain.startswith("www.") else domain
        if domain and domain not in domains:
            domains.append(domain)
    website_url = project_url or (f"https://{domains[0]}" if domains else SANEAPPS_URL)
    return ProductConfig(
        name=name,
        path=path,
        keywords=extract_top_level_list(text, "x_search_keywords"),
        status_note=status_note,
        launch_classification=classification,
        domains=domains,
        website_url=website_url,
    )


def default_outreach_files(root: Path) -> list[Path]:
    files = sorted((root / "apps").glob("*/.outreach.yml"))
    sane_ai = root / "SaneAI" / ".outreach.yml"
    if sane_ai.is_file():
        files.append(sane_ai)
    return files


def quoted_term(term: str) -> str:
    escaped = term.replace('"', '\\"')
    return f'"{escaped}"'


def mention_query(product: ProductConfig) -> dict[str, str]:
    terms = [product.name, product.name.lower(), *product.domains]
    unique_terms = []
    for term in terms:
        if term and term not in unique_terms:
            unique_terms.append(term)
    joined = " OR ".join(quoted_term(term) for term in unique_terms)
    return {
        "product": product.name,
        "query": f"({joined}) lang:en -is:retweet",
        "path": str(product.path),
        "kind": "mention",
        "website_url": product.website_url,
    }


def build_query_entry(product: ProductConfig, keyword: str, kind: str = "keyword") -> dict[str, str]:
    return {
        "product": product.name,
        "query": keyword,
        "path": str(product.path),
        "kind": kind,
        "website_url": product.website_url,
    }


def live_products(products: list[ProductConfig], include_blocked: bool) -> list[ProductConfig]:
    return [
        product for product in products
        if product.keywords or product.domains
        if include_blocked or product.public_ready
    ]


def select_queries(
    products: list[ProductConfig],
    limit: int,
    include_blocked: bool,
    mention_queries: bool,
    all_live: bool,
    global_queries: bool,
) -> list[dict[str, str]]:
    eligible = live_products(products, include_blocked)
    if all_live:
        candidates: list[dict[str, str]] = []
        if mention_queries:
            candidates.extend(mention_query(product) for product in eligible if product.domains)
        for product in sorted(eligible, key=lambda item: item.name.lower()):
            candidates.extend(build_query_entry(product, keyword) for keyword in product.keywords)
        if global_queries:
            candidates.extend(
                {"product": "SaneApps", "query": query, "path": "", "kind": "global", "website_url": SANEAPPS_URL}
                for query in GLOBAL_QUERIES
            )
        return candidates if limit <= 0 else candidates[:limit]

    day_offset = datetime.now(timezone.utc).timetuple().tm_yday
    ordered = sorted(eligible, key=lambda product: product.name.lower())
    if ordered:
        ordered = ordered[day_offset % len(ordered) :] + ordered[: day_offset % len(ordered)]
    rotated_keywords: list[tuple[ProductConfig, list[str]]] = []
    for product in ordered:
        if not product.keywords:
            continue
        keyword_offset = day_offset % len(product.keywords)
        keywords = product.keywords[keyword_offset:] + product.keywords[:keyword_offset]
        rotated_keywords.append((product, keywords))

    candidates: list[dict[str, str]] = []
    if mention_queries:
        candidates.extend(mention_query(product) for product in ordered if product.domains)
        if len(candidates) >= limit > 0:
            return candidates[:limit]
    max_keywords = max((len(keywords) for _, keywords in rotated_keywords), default=0)
    for index in range(max_keywords):
        for product, keywords in rotated_keywords:
            if index >= len(keywords):
                continue
            candidates.append(build_query_entry(product, keywords[index]))
            if len(candidates) >= limit > 0:
                return candidates
    if global_queries:
        candidates.extend(
            {"product": "SaneApps", "query": query, "path": "", "kind": "global", "website_url": SANEAPPS_URL}
            for query in GLOBAL_QUERIES
        )
    return candidates if limit <= 0 else candidates[:limit]


def page_to_items(page: Any) -> list[Any]:
    data = getattr(page, "data", None)
    if data is None and isinstance(page, dict):
        data = page.get("data") or page.get("results")
    if data is None:
        return []
    return data if isinstance(data, list) else [data]


def value_from(item: Any, key: str, default: Any = "") -> Any:
    if isinstance(item, dict):
        return item.get(key, default)
    return getattr(item, key, default)


def normalize_post(item: Any, entry: dict[str, str]) -> dict[str, Any]:
    post_id = str(value_from(item, "id", "") or "")
    author_id = str(value_from(item, "author_id", "") or "")
    metrics = value_from(item, "public_metrics", {}) or {}
    return {
        "product": entry["product"],
        "query": entry["query"],
        "kind": entry.get("kind", "keyword"),
        "website_url": entry.get("website_url", SANEAPPS_URL),
        "id": post_id,
        "url": f"https://x.com/i/web/status/{post_id}" if post_id else "",
        "author_id": author_id,
        "created_at": str(value_from(item, "created_at", "") or ""),
        "text": str(value_from(item, "text", "") or "").strip(),
        "metrics": metrics if isinstance(metrics, dict) else {},
    }


def run_live_search(queries: list[dict[str, str]], per_query: int) -> list[dict[str, Any]]:
    try:
        from xdk import Client
        from xdk.oauth1_auth import OAuth1
    except ImportError as exc:
        raise ScoutError("xdk is not installed in the selected Python environment.") from exc

    auth = OAuth1(
        api_key=get_secret("consumer_key"),
        api_secret=get_secret("consumer_secret"),
        callback="http://127.0.0.1:8976/oauth/callback",
        access_token=get_secret("access_token"),
        access_token_secret=get_secret("access_token_secret"),
    )
    client = Client(auth=auth)
    results: list[dict[str, Any]] = []
    api_max_results = min(max(per_query, 10), 100)
    for entry in queries:
        pages = client.posts.search_recent(
            query=entry["query"],
            max_results=api_max_results,
            tweet_fields=["public_metrics", "created_at", "author_id"],
        )
        for page in pages:
            for item in page_to_items(page)[:per_query]:
                results.append(normalize_post(item, entry))
            break
    return results


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    paths = [Path(path).expanduser() for path in args.outreach]
    if not paths:
        paths = default_outreach_files(Path(args.root).expanduser())
    products = [load_product_config(path) for path in paths if path.is_file()]
    missing_keywords = [
        {
            "product": product.name,
            "path": str(product.path),
            "public_ready": product.public_ready,
            "classification": product.launch_classification,
        }
        for product in products
        if not product.keywords
    ]
    selected = select_queries(
        products,
        args.limit,
        args.include_blocked,
        args.mention_queries,
        args.all_live,
        args.global_queries,
    )
    results: list[dict[str, Any]] = [] if args.dry_run else run_live_search(selected, args.per_query)
    return {
        "ok": True,
        "dry_run": args.dry_run,
        "searched_at": datetime.now(timezone.utc).isoformat(),
        "query_limit": args.limit,
        "per_query": args.per_query,
        "products": [
            {
                "name": product.name,
                "path": str(product.path),
                "keyword_count": len(product.keywords),
                "domains": product.domains,
                "website_url": product.website_url,
                "public_ready": product.public_ready,
                "classification": product.launch_classification,
            }
            for product in products
        ],
        "missing_keywords": missing_keywords,
        "queries": selected,
        "results": results,
    }


def print_markdown(payload: dict[str, Any]) -> None:
    print("# X Opportunity Scout")
    print()
    print(f"- Mode: {'dry run' if payload['dry_run'] else 'live search'}")
    print(f"- Queries selected: {len(payload['queries'])}")
    print(f"- Results returned: {len(payload['results'])}")
    public_missing = [item for item in payload["missing_keywords"] if item["public_ready"]]
    if public_missing:
        print("- Public-ready products missing keywords: " + ", ".join(item["product"] for item in public_missing))
    print()
    print("## Queries")
    for entry in payload["queries"]:
        print(f"- {entry['product']}: `{entry['query']}`")
    if payload["results"]:
        print()
        print("## Results")
        for result in payload["results"][:20]:
            text = re.sub(r"\s+", " ", result["text"]).strip()
            if len(text) > 180:
                text = text[:177].rstrip() + "..."
            print(f"- {result['product']}: {result['url']} - {text}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Search X for SaneApps outreach opportunities.")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="SaneApps root containing apps/*/.outreach.yml.")
    parser.add_argument("--outreach", action="append", default=[], help="Specific .outreach.yml path. Repeatable.")
    parser.add_argument("--limit", type=int, default=5, help="Maximum X queries per run.")
    parser.add_argument("--per-query", type=int, default=10, help="Maximum results per X query.")
    parser.add_argument("--include-blocked", action="store_true", help="Include pre-live/blocked product configs.")
    parser.add_argument("--mention-queries", action="store_true", help="Include app-name/domain mention searches.")
    parser.add_argument("--all-live", action="store_true", help="Search every live product mention and keyword query.")
    parser.add_argument("--global-queries", action="store_true", help="Include broad SaneApps category queries.")
    parser.add_argument("--dry-run", action="store_true", help="Select queries without calling the X API.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of markdown.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        payload = build_payload(args)
    except ScoutError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print_markdown(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
