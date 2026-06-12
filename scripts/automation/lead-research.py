#!/usr/bin/env python3
"""Discover candidate sites with Exa and build site dossiers with Firecrawl.

Usage:
  lead-research.py --query "mac app review sites"
  lead-research.py --query "security newsletters for developers" --site-limit 8
  lead-research.py --domain setapp.com --domain macstories.net
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, parse, request

EXA_SEARCH_URL = "https://api.exa.ai/search"
EXA_CONTENTS_URL = "https://api.exa.ai/contents"
FIRECRAWL_MAP_URL = "https://api.firecrawl.dev/v2/map"
FIRECRAWL_SCRAPE_URL = "https://api.firecrawl.dev/v2/scrape"
OUTPUT_DIR = Path(__file__).resolve().parents[2] / "outputs" / "leads"
ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
US_LOCATION = {"country": "US", "languages": ["en-US"]}
PAGE_HINTS = (
    "pricing about features integrations customers case studies "
    "reviews docs contact security blog press partners"
)
POSITIVE_PATH_HINTS = {
    "pricing": 9,
    "about": 8,
    "feature": 8,
    "features": 8,
    "integrations": 7,
    "customers": 7,
    "case-study": 7,
    "case-studies": 7,
    "partner": 7,
    "affiliate": 7,
    "review": 6,
    "docs": 6,
    "documentation": 6,
    "security": 5,
    "contact": 5,
    "blog": 4,
    "press": 4,
    "company": 4,
}
NEGATIVE_PATH_HINTS = {
    "login": -10,
    "signin": -10,
    "sign-in": -10,
    "signup": -10,
    "sign-up": -10,
    "cart": -10,
    "checkout": -10,
    "privacy": -6,
    "terms": -6,
    "cookie": -6,
    "wp-admin": -10,
    "cdn-cgi": -10,
    "account": -8,
    "app.": -8,
}


class ResearchError(RuntimeError):
    """Raised when an external API call fails."""


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

@dataclass
class CandidateSite:
    domain: str
    root_url: str
    source_url: str
    source_title: str
    source_published_date: str | None
    source_description: str


def slugify(value: str) -> str:
    text = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return text or "lead-research"


def normalize_domain(url_or_domain: str) -> str:
    parsed = parse.urlparse(url_or_domain if "://" in url_or_domain else f"https://{url_or_domain}")
    host = (parsed.netloc or parsed.path).lower()
    return host[4:] if host.startswith("www.") else host


def root_url_for(url_or_domain: str) -> str:
    domain = normalize_domain(url_or_domain)
    return f"https://{domain}"


def canonicalize_url(url: str) -> str:
    parsed = parse.urlparse(url)
    domain = normalize_domain(url)
    path = parsed.path or "/"
    path = "/" if path == "" else path.rstrip("/") or "/"
    return parse.urlunparse(("https", domain, path, "", "", ""))


def source_path_segments(url: str) -> list[str]:
    path = parse.urlparse(url).path.strip("/")
    return [segment for segment in path.split("/") if segment]


def summarize_text(text: str, limit: int = 320) -> str:
    compact = re.sub(r"\s+", " ", text or "").strip()
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1].rstrip() + "…"


def get_secret(env_var: str, service: str, account: str = "api_key") -> str:
    load_env_cache()
    value = os.environ.get(env_var, "").strip()
    if value:
        return value
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        raise ResearchError(
            f"Missing secret for {env_var}. Set it in ~/.config/nv/env or the environment."
        )
    result = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    if value:
        persist_secret_to_env_cache(value, env_var)
        return value
    raise ResearchError(
        f"Missing secret for {env_var}. Set it in ~/.config/nv/env or the environment, or add it to keychain with:\n"
        f"security add-generic-password -s {service} -a {account} -w YOUR_KEY"
    )


def post_json(url: str, payload: dict[str, Any], headers: dict[str, str], timeout: int = 60) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=body, method="POST")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "SaneProcessLeadResearch/1.0")
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise ResearchError(f"{url} returned HTTP {exc.code}: {detail[:400]}") from exc
    except error.URLError as exc:
        raise ResearchError(f"{url} request failed: {exc.reason}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ResearchError(f"{url} returned invalid JSON: {raw[:400]}") from exc


def exa_search(query: str, limit: int, api_key: str) -> list[dict[str, Any]]:
    payload = {
        "query": query,
        "type": "auto",
        "num_results": max(limit, 1),
        "contents": {
            "text": {
                "max_characters": 1200,
            }
        },
    }
    response = post_json(
        EXA_SEARCH_URL,
        payload,
        {
            "x-api-key": api_key,
            "Content-Type": "application/json",
        },
    )
    return response.get("results", [])


def exa_contents(url: str, api_key: str, max_characters: int = 1200) -> dict[str, Any]:
    payload = {
        "urls": [url],
        "text": {
            "max_characters": max_characters,
        },
    }
    response = post_json(
        EXA_CONTENTS_URL,
        payload,
        {
            "x-api-key": api_key,
            "Content-Type": "application/json",
        },
    )
    results = response.get("results", [])
    if not results:
        raise ResearchError(f"Exa contents returned no result for {url}")
    result = results[0]
    return {
        "url": result.get("url") or url,
        "title": result.get("title") or "",
        "status_code": "exa-contents",
        "description": result.get("author") or "",
        "markdown": result.get("text") or "",
        "excerpt": summarize_text(result.get("text") or ""),
        "fallback_source": "exa-contents",
    }


def dedupe_sites(results: list[dict[str, Any]], site_limit: int) -> list[CandidateSite]:
    sites: list[CandidateSite] = []
    seen: set[str] = set()
    for result in results:
        url = result.get("url") or ""
        if not url:
            continue
        domain = normalize_domain(url)
        if not domain or domain in seen:
            continue
        seen.add(domain)
        sites.append(
            CandidateSite(
                domain=domain,
                root_url=root_url_for(url),
                source_url=url,
                source_title=result.get("title") or domain,
                source_published_date=result.get("publishedDate"),
                source_description=summarize_text(result.get("text") or result.get("description") or ""),
            )
        )
        if len(sites) >= site_limit:
            break

    return sites


def map_site(url: str, api_key: str, limit: int) -> list[dict[str, Any]]:
    payload = {
        "url": url,
        "search": PAGE_HINTS,
        "sitemap": "include",
        "includeSubdomains": False,
        "ignoreQueryParameters": True,
        "limit": limit,
        "timeout": 60000,
        "location": US_LOCATION,
    }
    response = post_json(
        FIRECRAWL_MAP_URL,
        payload,
        {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    links = response.get("links")
    if links is None:
        links = (response.get("data") or {}).get("links", [])
    normalized: list[dict[str, Any]] = []
    for item in links or []:
        if isinstance(item, str):
            normalized.append({"url": item, "title": "", "description": ""})
        elif isinstance(item, dict):
            normalized.append(item)
    return normalized


def score_mapped_url(
    url: str,
    title: str,
    description: str,
    domain: str,
    primary: str | None = None,
    source_segments: list[str] | None = None,
) -> int:
    parsed = parse.urlparse(url)
    path = (parsed.path or "/").lower()
    score = 0
    if normalize_domain(url) == domain:
        score += 2
    if path in ("", "/"):
        score += 8
    if primary and url.rstrip("/") == primary.rstrip("/"):
        score += 6
    haystack = " ".join((path, title.lower(), description.lower()))
    for fragment, weight in POSITIVE_PATH_HINTS.items():
        if fragment in haystack:
            score += weight
    for fragment, weight in NEGATIVE_PATH_HINTS.items():
        if fragment in haystack:
            score += weight
    segments = source_segments or []
    if segments:
        shared_prefix = 0
        page_segments = [segment for segment in path.strip("/").split("/") if segment]
        for source_segment, page_segment in zip(segments, page_segments):
            if source_segment.lower() != page_segment.lower():
                break
            shared_prefix += 1
        score += shared_prefix * 12
        if shared_prefix == len(segments) and len(segments) > 0:
            score += 10
    return score


def choose_pages(
    site: CandidateSite,
    mapped_links: list[dict[str, Any]],
    page_limit: int,
) -> list[dict[str, str]]:
    ranked: list[tuple[int, dict[str, str]]] = []
    seen_urls: set[str] = set()
    source_segments = source_path_segments(site.source_url)

    seed_urls = [
        {"url": site.root_url, "title": "Homepage", "description": ""},
        {"url": site.source_url, "title": site.source_title, "description": site.source_description},
    ]

    for item in seed_urls + mapped_links:
        raw_url = item.get("url") or ""
        canonical_url = canonicalize_url(raw_url)
        if not raw_url or canonical_url in seen_urls:
            continue
        seen_urls.add(canonical_url)
        title = item.get("title") or ""
        description = item.get("description") or ""
        score = score_mapped_url(
            raw_url,
            title,
            description,
            site.domain,
            primary=site.source_url,
            source_segments=source_segments,
        )
        ranked.append((score, {"url": raw_url, "title": title, "description": description}))

    ranked.sort(key=lambda entry: (-entry[0], len(entry[1]["url"])))
    selected = [item for _, item in ranked[:page_limit]]
    selected.sort(key=lambda item: item["url"])
    return selected


def scrape_page(url: str, api_key: str) -> dict[str, Any]:
    payload = {
        "url": url,
        "formats": ["markdown"],
        "onlyMainContent": True,
        "timeout": 30000,
        "blockAds": True,
        "removeBase64Images": True,
        "proxy": "basic",
        "location": US_LOCATION,
    }
    response = post_json(
        FIRECRAWL_SCRAPE_URL,
        payload,
        {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    data = response.get("data") or {}
    metadata = data.get("metadata") or {}
    markdown = data.get("markdown") or ""
    return {
        "url": url,
        "title": metadata.get("title") or "",
        "status_code": metadata.get("statusCode"),
        "description": metadata.get("description") or "",
        "markdown": markdown,
        "excerpt": summarize_text(markdown),
    }


def estimate_hobby_cost_usd(credits: int) -> float:
    return round((credits / 3000.0) * 16.0, 2)


def should_use_exa_fallback(domain: str, error_text: str) -> bool:
    lower = error_text.lower()
    return domain == "reddit.com" or "do not support this site" in lower


def render_markdown_report(report: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append(f"# Lead Research: {report['query']}")
    lines.append("")
    lines.append(f"- Generated: {report['generated_at']}")
    lines.append(f"- Candidate sites: {len(report['sites'])}")
    lines.append(f"- Exa searches: {report['cost_estimate']['exa_search_requests']}")
    lines.append(f"- Firecrawl credits used: ~{report['cost_estimate']['firecrawl_credits']}")
    lines.append(
        f"- Firecrawl Hobby equivalent: ~${report['cost_estimate']['firecrawl_hobby_equivalent_usd']:.2f}"
    )
    lines.append("")

    for site in report["sites"]:
        lines.append(f"## {site['domain']}")
        lines.append("")
        lines.append(f"- Search hit: [{site['source_title']}]({site['source_url']})")
        if site.get("source_published_date"):
            lines.append(f"- Search date: {site['source_published_date']}")
        if site.get("source_description"):
            lines.append(f"- Search note: {site['source_description']}")
        if site.get("map_error"):
            lines.append(f"- Map warning: {site['map_error']}")
        lines.append(f"- Pages scraped: {len(site['pages'])}")
        lines.append("")
        for page in site["pages"]:
            title = page.get("title") or page["url"]
            lines.append(f"### [{title}]({page['url']})")
            if page.get("status_code"):
                lines.append(f"- Status: {page['status_code']}")
            if page.get("fallback_source"):
                lines.append(f"- Fallback: {page['fallback_source']}")
            if page.get("error"):
                lines.append(f"- Error: {page['error']}")
            if page.get("excerpt"):
                lines.append("")
                lines.append(page["excerpt"])
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def save_report(report: dict[str, Any], output_path: str | None) -> tuple[Path, Path]:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    slug = slugify(report["query"])
    base_path = Path(output_path) if output_path else OUTPUT_DIR / f"{slug}-{timestamp}"
    json_path = base_path.with_suffix(".json")
    md_path = base_path.with_suffix(".md")
    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown_report(report), encoding="utf-8")
    return json_path, md_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Find candidate websites with Exa and build read-friendly site dossiers with Firecrawl."
    )
    parser.add_argument("query_terms", nargs="*", help="Lead research query if --query is omitted")
    parser.add_argument("--query", help="Search query to send to Exa")
    parser.add_argument("--domain", action="append", default=[], help="Known domain to research directly")
    parser.add_argument("--search-results", type=int, default=12, help="How many Exa results to request")
    parser.add_argument("--site-limit", type=int, default=5, help="How many unique domains to research")
    parser.add_argument("--page-limit", type=int, default=4, help="How many pages to scrape per site")
    parser.add_argument("--map-limit", type=int, default=25, help="How many URLs to request from Firecrawl map")
    parser.add_argument("--skip-map", action="store_true", help="Scrape homepage/source pages only")
    parser.add_argument("--json", action="store_true", help="Print the final JSON report to stdout")
    parser.add_argument("--out", help="Output path stem for the saved .json and .md files")
    return parser.parse_args()


def resolve_query(args: argparse.Namespace) -> str:
    if args.query:
        return args.query.strip()
    if args.query_terms:
        return " ".join(args.query_terms).strip()
    if args.domain:
        return f"direct-domain-research-{'-'.join(slugify(item) for item in args.domain)}"
    raise ResearchError("Provide a query or at least one --domain.")


def main() -> int:
    args = parse_args()
    query = resolve_query(args)
    exa_key = None
    firecrawl_key = None

    try:
        firecrawl_key = get_secret("FIRECRAWL_API_KEY", "firecrawl")
        sites: list[CandidateSite]

        if args.domain:
            sites = [
                CandidateSite(
                    domain=normalize_domain(domain),
                    root_url=root_url_for(domain),
                    source_url=root_url_for(domain),
                    source_title=normalize_domain(domain),
                    source_published_date=None,
                    source_description="Direct domain mode",
                )
                for domain in args.domain[: args.site_limit]
            ]
        else:
            exa_key = get_secret("EXA_API_KEY", "exa")
            results = exa_search(query, args.search_results, exa_key)
            sites = dedupe_sites(results, args.site_limit)

        if not sites:
            raise ResearchError("No candidate sites found.")

        site_reports: list[dict[str, Any]] = []
        firecrawl_credits = 0

        for site in sites:
            mapped_links: list[dict[str, Any]] = []
            map_error = None
            if not args.skip_map:
                try:
                    mapped_links = map_site(site.root_url, firecrawl_key, args.map_limit)
                    firecrawl_credits += 1
                except ResearchError as exc:
                    map_error = str(exc)

            pages = choose_pages(site, mapped_links, args.page_limit)
            scraped_pages: list[dict[str, Any]] = []
            for page in pages:
                try:
                    scraped = scrape_page(page["url"], firecrawl_key)
                    scraped_pages.append(scraped)
                    firecrawl_credits += 1
                except ResearchError as exc:
                    if should_use_exa_fallback(site.domain, str(exc)):
                        if not exa_key:
                            try:
                                exa_key = get_secret("EXA_API_KEY", "exa")
                            except ResearchError:
                                exa_key = None
                        if exa_key:
                            try:
                                scraped_pages.append(exa_contents(page["url"], exa_key))
                                continue
                            except ResearchError as exa_exc:
                                scraped_pages.append(
                                    {
                                        "url": page["url"],
                                        "title": page.get("title") or "",
                                        "status_code": None,
                                        "description": "",
                                        "markdown": "",
                                        "excerpt": "",
                                        "error": str(exa_exc),
                                    }
                                )
                                continue
                    scraped_pages.append(
                        {
                            "url": page["url"],
                            "title": page.get("title") or "",
                            "status_code": None,
                            "description": "",
                            "markdown": "",
                            "excerpt": "",
                            "error": str(exc),
                        }
                    )

            site_reports.append(
                {
                    "domain": site.domain,
                    "root_url": site.root_url,
                    "source_url": site.source_url,
                    "source_title": site.source_title,
                    "source_published_date": site.source_published_date,
                    "source_description": site.source_description,
                    "map_error": map_error,
                    "mapped_links": mapped_links,
                    "pages": scraped_pages,
                }
            )

        report = {
            "query": query,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "settings": {
                "search_results": args.search_results,
                "site_limit": args.site_limit,
                "page_limit": args.page_limit,
                "map_limit": args.map_limit,
                "skip_map": args.skip_map,
                "direct_domains": args.domain,
            },
            "cost_estimate": {
                "exa_search_requests": 0 if args.domain else 1,
                "firecrawl_credits": firecrawl_credits,
                "firecrawl_hobby_equivalent_usd": estimate_hobby_cost_usd(firecrawl_credits),
            },
            "sites": site_reports,
        }

        json_path, md_path = save_report(report, args.out)
        if args.json:
            json.dump(report, sys.stdout, indent=2)
            print()
        else:
            print(f"Lead research saved to:")
            print(f"  {json_path}")
            print(f"  {md_path}")
            print()
            print(f"Sites: {len(site_reports)}")
            print(f"Firecrawl credits used: ~{firecrawl_credits}")
            print(f"Firecrawl Hobby equivalent: ~${estimate_hobby_cost_usd(firecrawl_credits):.2f}")

        return 0
    except ResearchError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
