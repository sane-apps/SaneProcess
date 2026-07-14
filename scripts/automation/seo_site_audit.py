#!/usr/bin/env python3
"""Audit static SaneApps sites for crawlable, structured SEO surfaces."""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urldefrag, urljoin, urlparse


def default_sane_apps_root() -> Path:
    configured = os.environ.get("SANE_APPS_ROOT")
    if configured:
        return Path(configured).expanduser()
    return Path(__file__).resolve().parents[4]


SANE_APPS_ROOT = default_sane_apps_root()
SITEMAP_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
GENERIC_SOCIAL_ALTS = {
    "saneapps social preview card",
    "sanebar social preview card",
    "saneclick social preview card",
    "saneclip social preview card",
    "sanehosts social preview card",
    "sanesales social preview card",
    "sanescan social preview card",
    "sanevideo social preview card",
    "sanesync social preview card",
}


@dataclass(frozen=True)
class Site:
    name: str
    root: Path
    domain: str
    expected_image_path: str
    page_image_paths: dict[str, str] = field(default_factory=dict)
    allow_appcast_links: bool = True


def build_default_sites(root: Path = SANE_APPS_ROOT) -> list[Site]:
    return [
        Site("SaneBar", root / "apps/SaneBar/docs", "https://sanebar.com", "/images/og-image.png"),
        Site("SaneClick", root / "apps/SaneClick/docs", "https://saneclick.com", "/images/og-image.png"),
        Site("SaneClip", root / "apps/SaneClip/docs", "https://saneclip.com", "/images/og-image.png"),
        Site("SaneHosts", root / "apps/SaneHosts/website", "https://sanehosts.com", "/og-image.png"),
        Site("SaneSales", root / "apps/SaneSales/docs", "https://sanesales.com", "/images/og-image.png"),
        Site(
            "SaneScan",
            root / "apps/SaneScan/website",
            "https://sanescan.saneapps.com",
            "/assets/social-card.png",
        ),
        Site("SaneVideo", root / "apps/SaneVideo/docs", "https://sanevideo.com", "/images/og-image.png"),
        Site(
            "SaneApps",
            root / "web/saneapps.com",
            "https://saneapps.com",
            "/og-image.png",
            {"bundle.html": "/bundle-og-image.png"},
        ),
    ]


DEFAULT_SITES = build_default_sites()


def rel_tokens(value: str | None) -> set[str]:
    return {token.lower() for token in (value or "").split()}


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.title = ""
        self.has_doctype = False
        self.html_lang = ""
        self.meta: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.anchors: list[str] = []
        self.anchor_attrs: list[dict[str, str]] = []
        self.images: list[dict[str, str]] = []
        self.ids: list[str] = []
        self.jsonld: list[str] = []
        self.h1_count = 0
        self._in_title = False
        self._in_jsonld = False
        self._jsonld_buffer = ""

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_name = tag.lower()
        values = {key: value or "" for key, value in attrs}
        if tag_name == "html":
            self.html_lang = values.get("lang", "")
        if "id" in values:
            self.ids.append(values["id"])
        if tag_name == "title":
            self._in_title = True
        elif tag_name == "meta":
            key = values.get("property") or values.get("name")
            if key:
                self.meta[key] = values.get("content", "")
        elif tag_name == "link":
            rel = values.get("rel")
            href = values.get("href")
            if rel and href and "canonical" in rel_tokens(rel):
                self.links["canonical"] = href
        elif tag_name == "a":
            href = values.get("href")
            if href:
                self.anchors.append(href)
                self.anchor_attrs.append(values)
        elif tag_name == "img":
            self.images.append(values)
        elif tag_name == "h1":
            self.h1_count += 1
        elif tag_name == "script" and values.get("type", "").lower() == "application/ld+json":
            self._in_jsonld = True
            self._jsonld_buffer = ""

    def handle_endtag(self, tag: str) -> None:
        tag_name = tag.lower()
        if tag_name == "title":
            self._in_title = False
        elif tag_name == "script" and self._in_jsonld:
            self.jsonld.append(self._jsonld_buffer)
            self._in_jsonld = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title += data
        if self._in_jsonld:
            self._jsonld_buffer += data

    def handle_decl(self, decl: str) -> None:
        if decl.strip().lower() == "doctype html":
            self.has_doctype = True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit SaneApps static SEO metadata and crawler assets.")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary.")
    parser.add_argument("--root", type=Path, default=SANE_APPS_ROOT, help="SaneApps workspace root to audit.")
    parser.add_argument(
        "--site",
        nargs=4,
        action="append",
        metavar=("NAME", "ROOT", "DOMAIN", "IMAGE_PATH"),
        help="Audit one explicit site root instead of the default SaneApps site set.",
    )
    parser.add_argument(
        "--page-image",
        action="append",
        default=[],
        metavar="RELATIVE_HTML=IMAGE_PATH",
        help="Override the expected social image path for a single HTML page.",
    )
    return parser.parse_args(argv)


def parse_page_image_overrides(values: list[str]) -> dict[str, str]:
    overrides: dict[str, str] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"invalid --page-image value: {value}")
        page, image_path = value.split("=", 1)
        page = page.strip().lstrip("/")
        image_path = image_path.strip()
        if not page or not image_path.startswith("/"):
            raise ValueError(f"invalid --page-image value: {value}")
        overrides[page] = image_path
    return overrides


def sites_from_args(args: argparse.Namespace) -> list[Site]:
    overrides = parse_page_image_overrides(args.page_image)
    if args.site:
        return [
            Site(
                name,
                Path(root).expanduser(),
                domain.rstrip("/"),
                image_path,
                overrides,
                allow_appcast_links=name != "SaneSync",
            )
            for name, root, domain, image_path in args.site
        ]
    return build_default_sites(args.root.expanduser())


def html_files(site: Site) -> list[Path]:
    if not site.root.is_dir():
        return []
    files: list[Path] = []
    for path in sorted(site.root.rglob("*.html")):
        rel = path.relative_to(site.root)
        if rel.parts and rel.parts[0] in {"assets", "images"}:
            continue
        files.append(path)
    return files


def parse_page(path: Path) -> PageParser:
    parser = PageParser()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    return parser


def ids_for_path(path: Path) -> set[str]:
    return set(parse_page(path).ids)


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as handle:
            header = handle.read(24)
    except FileNotFoundError:
        return None
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", header[16:24])


def local_path_for_url(site: Site, url: str) -> Path | None:
    parsed = urlparse(urljoin(site.domain + "/", url))
    if parsed.scheme not in {"http", "https"}:
        return None
    if parsed.netloc != urlparse(site.domain).netloc:
        return None
    clean_path = parsed.path
    if clean_path in {"", "/"}:
        return site.root / "index.html"
    candidates = []
    if clean_path.endswith("/"):
        candidates.append(site.root / clean_path.lstrip("/") / "index.html")
    else:
        candidates.append(site.root / clean_path.lstrip("/"))
        candidates.append(site.root / f"{clean_path.lstrip('/')}.html")
        candidates.append(site.root / clean_path.lstrip("/").rstrip("/") / "index.html")
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def expected_image_path(site: Site, path: Path) -> str:
    rel = path.relative_to(site.root).as_posix()
    return site.page_image_paths.get(rel, site.expected_image_path)


def local_social_image_path(site: Site, path: Path, image_url: str) -> Path | None:
    expected_path = expected_image_path(site, path)
    parsed = urlparse(image_url)
    if parsed.scheme != "https":
        return None
    if parsed.netloc != urlparse(site.domain).netloc:
        return None
    if parsed.path != expected_path:
        return None
    return site.root / expected_path.lstrip("/")


def schema_types(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, list):
        for item in value:
            found.update(schema_types(item))
    elif isinstance(value, dict):
        type_value = value.get("@type")
        if isinstance(type_value, str):
            found.add(type_value)
        elif isinstance(type_value, list):
            found.update(str(item) for item in type_value)
        for item in value.values():
            if isinstance(item, (dict, list)):
                found.update(schema_types(item))
    return found


def schema_download_url_issues(value: object, context: str = "") -> list[str]:
    issues: list[str] = []
    if isinstance(value, list):
        for item in value:
            issues.extend(schema_download_url_issues(item, context))
    elif isinstance(value, dict):
        for key, item in value.items():
            key_context = f"{context}.{key}" if context else key
            if key in {"downloadUrl", "installUrl"} and isinstance(item, str):
                if re.search(r"(lemonsqueezy\.com/checkout|go\.saneapps\.com/buy)", item):
                    issues.append(f"{key_context} must not point to a checkout or purchase redirect")
            if isinstance(item, (dict, list)):
                issues.extend(schema_download_url_issues(item, key_context))
    return issues


def expected_schema_types(site: Site, path: Path) -> set[str]:
    rel = path.relative_to(site.root).as_posix()
    stem = path.stem
    if rel == "index.html":
        return {"Organization"} if site.name == "SaneApps" else {"SoftwareApplication"}
    if rel == "bundle.html":
        return {"Product"}
    if rel == "guides.html":
        return {"CollectionPage"}
    if stem.startswith("how-to") or stem.startswith("block-") or stem in {
        "gas-mask-alternative",
        "best-private-document-scanner-iphone",
        "sanesales-vs-spreadsheets",
    }:
        return {"Article", "TechArticle"}
    if "privacy" in rel:
        return {"PrivacyPolicy", "WebPage"}
    return {"WebPage"}


def is_404(path: Path) -> bool:
    return path.name == "404.html"


def text(value: str | None) -> str:
    return " ".join((value or "").split())


def audit_jsonld(site: Site, path: Path, parser: PageParser) -> list[str]:
    rel = path.relative_to(site.root)
    issues: list[str] = []
    if is_404(path):
        return issues
    if not parser.jsonld:
        return [f"{site.name}/{rel}: missing JSON-LD structured data"]
    types: set[str] = set()
    for block in parser.jsonld:
        try:
            parsed = json.loads(block)
        except json.JSONDecodeError as exc:
            issues.append(f"{site.name}/{rel}: invalid JSON-LD: {exc.msg}")
            continue
        types.update(schema_types(parsed))
        for schema_issue in schema_download_url_issues(parsed):
            issues.append(f"{site.name}/{rel}: JSON-LD {schema_issue}")
    expected = expected_schema_types(site, path)
    if types.isdisjoint(expected):
        issues.append(f"{site.name}/{rel}: expected schema type {sorted(expected)}, found {sorted(types)}")
    return issues


def audit_page(site: Site, path: Path) -> tuple[str | None, list[str]]:
    rel = path.relative_to(site.root)
    parser = parse_page(path)
    issues: list[str] = []
    page_title = text(parser.title)
    page_description = text(parser.meta.get("description"))
    canonical_url = text(parser.links.get("canonical"))
    if not page_title:
        issues.append(f"{site.name}/{rel}: missing title")
    if not parser.has_doctype:
        issues.append(f"{site.name}/{rel}: missing <!doctype html>")
    if not parser.html_lang:
        issues.append(f"{site.name}/{rel}: missing html lang")
    if not canonical_url:
        issues.append(f"{site.name}/{rel}: missing canonical")
    if canonical_url and not canonical_url.startswith(site.domain):
        issues.append(f"{site.name}/{rel}: canonical must start with {site.domain}")

    if not is_404(path):
        if not 10 <= len(page_title) <= 90:
            issues.append(f"{site.name}/{rel}: title length {len(page_title)} outside 10..90")
        if not 45 <= len(page_description) <= 220:
            issues.append(f"{site.name}/{rel}: description length {len(page_description)} outside 45..220")
        robots = parser.meta.get("robots", "")
        if "noindex" in robots.lower():
            issues.append(f"{site.name}/{rel}: non-404 page must not be noindex")
        if parser.h1_count != 1:
            issues.append(f"{site.name}/{rel}: expected exactly one h1, found {parser.h1_count}")
    duplicate_ids = sorted({identifier for identifier in parser.ids if parser.ids.count(identifier) > 1})
    if duplicate_ids:
        issues.append(f"{site.name}/{rel}: duplicate IDs: {', '.join(duplicate_ids[:8])}")
    issues.extend(audit_jsonld(site, path, parser))

    for key in ("og:title", "twitter:title"):
        if parser.meta.get(key) != page_title:
            issues.append(f"{site.name}/{rel}: {key} must match document title")
        if "&amp;" in parser.meta.get(key, ""):
            issues.append(f"{site.name}/{rel}: {key} appears double-escaped")
    for key in ("og:description", "twitter:description"):
        if parser.meta.get(key) != page_description:
            issues.append(f"{site.name}/{rel}: {key} must match meta description")
        if "&amp;" in parser.meta.get(key, ""):
            issues.append(f"{site.name}/{rel}: {key} appears double-escaped")
    for key in ("og:url", "twitter:url"):
        if parser.meta.get(key) != canonical_url:
            issues.append(f"{site.name}/{rel}: {key} must match canonical")

    image_url = parser.meta.get("og:image", "")
    twitter_image = parser.meta.get("twitter:image", "")
    secure_image = parser.meta.get("og:image:secure_url", "")
    expected_social_image = f"{site.domain}{expected_image_path(site, path)}"
    if not local_social_image_path(site, path, image_url):
        issues.append(f"{site.name}/{rel}: og:image must point to {expected_social_image}")
    if "?v=" not in image_url:
        issues.append(f"{site.name}/{rel}: og:image needs a cache-busting query")
    if twitter_image != image_url or secure_image != image_url:
        issues.append(f"{site.name}/{rel}: social images must match")
    if parser.meta.get("twitter:card") != "summary_large_image":
        issues.append(f"{site.name}/{rel}: twitter:card must be summary_large_image")
    for key in ("og:image:alt", "twitter:image:alt"):
        alt_text = text(parser.meta.get(key))
        if len(alt_text) < 24:
            issues.append(f"{site.name}/{rel}: {key} must describe the preview image")
        if alt_text.lower() in GENERIC_SOCIAL_ALTS:
            issues.append(f"{site.name}/{rel}: {key} is too generic")
    local_social_image = local_social_image_path(site, path, image_url)
    if local_social_image is None or png_size(local_social_image) != (1200, 630):
        issues.append(f"{site.name}/{rel}: social image must be a local 1200x630 PNG")

    for image in parser.images:
        if not image.get("alt", "").strip():
            issues.append(f"{site.name}/{rel}: image {image.get('src', '<unknown>')} missing or empty alt")
        source = image.get("src", "")
        if not source or source.startswith(("data:", "http://", "https://")):
            continue
        target = local_path_for_url(site, source)
        if target and not target.exists():
            issues.append(f"{site.name}/{rel}: image source does not resolve locally: {source}")

    for anchor_attrs in parser.anchor_attrs:
        anchor = anchor_attrs.get("href", "")
        if anchor_attrs.get("target", "").lower() == "_blank":
            anchor_rel = rel_tokens(anchor_attrs.get("rel"))
            if not ({"noopener", "noreferrer"} & anchor_rel):
                issues.append(f'{site.name}/{rel}: target="_blank" link missing rel noopener/noreferrer: {anchor}')
        parsed_anchor = urlparse(urljoin(site.domain + "/", anchor))
        if not site.allow_appcast_links and parsed_anchor.path == "/appcast.xml":
            issues.append(f"{site.name}/{rel}: pre-release site must not link to appcast.xml")
        if anchor.startswith(("#", "mailto:", "tel:", "javascript:")):
            if anchor.startswith("#") and len(anchor) > 1 and anchor[1:] not in parser.ids:
                issues.append(f"{site.name}/{rel}: same-page anchor does not resolve: {anchor}")
            continue
        absolute = urldefrag(urljoin(site.domain + "/", anchor))[0]
        absolute_with_fragment = urljoin(site.domain + "/", anchor)
        clean_absolute, fragment = urldefrag(absolute_with_fragment)
        absolute = clean_absolute
        parsed = urlparse(absolute)
        if parsed.scheme not in {"http", "https"} or parsed.netloc != urlparse(site.domain).netloc:
            continue
        target = local_path_for_url(site, absolute)
        if target and not target.exists():
            issues.append(f"{site.name}/{rel}: internal link does not resolve locally: {anchor}")
            continue
        if target and fragment and fragment not in ids_for_path(target):
            issues.append(f"{site.name}/{rel}: internal anchor does not resolve locally: {anchor}")

    return canonical_url if canonical_url and not is_404(path) else None, issues


def sitemap_urls(site: Site) -> tuple[set[str], list[str]]:
    path = site.root / "sitemap.xml"
    if not path.exists():
        return set(), [f"{site.name}: missing sitemap.xml"]
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return set(), [f"{site.name}: invalid sitemap.xml: {exc}"]
    urls = {text(element.text) for element in tree.findall(f".//{SITEMAP_NS}loc") if text(element.text)}
    issues: list[str] = []
    for url in urls:
        if not url.startswith(site.domain):
            issues.append(f"{site.name}: sitemap URL outside domain: {url}")
        if url.endswith("appcast.xml"):
            issues.append(f"{site.name}: appcast.xml should not be listed in sitemap.xml")
    return urls, issues


def audit_robots(site: Site) -> list[str]:
    path = site.root / "robots.txt"
    if not path.exists():
        return [f"{site.name}: missing robots.txt"]
    content = path.read_text(encoding="utf-8", errors="replace")
    directives: list[tuple[str, str]] = []
    for line in content.splitlines():
        line = line.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        directives.append((key.strip().lower(), value.strip()))
    issues: list[str] = []
    if ("user-agent", "*") not in directives:
        issues.append(f"{site.name}: robots.txt missing User-agent: *")
    if ("allow", "/") not in directives:
        issues.append(f"{site.name}: robots.txt missing Allow: /")
    expected_sitemap = f"Sitemap: {site.domain}/sitemap.xml"
    if expected_sitemap not in content:
        issues.append(f"{site.name}: robots.txt missing {expected_sitemap}")
    if any(key == "disallow" and value == "/" for key, value in directives):
        issues.append(f"{site.name}: robots.txt must not disallow the full site")
    return issues


def audit_appcast(site: Site) -> list[str]:
    path = site.root / "appcast.xml"
    if not path.exists():
        return []

    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [f"{site.name}: invalid appcast.xml: {exc}"]

    root = tree.getroot()
    if root.tag != "rss":
        return [f"{site.name}: appcast.xml root must be rss"]
    if root.find("channel") is None:
        return [f"{site.name}: appcast.xml missing channel"]
    return []


def audit_site(site: Site) -> tuple[int, list[str]]:
    pages = html_files(site)
    if not pages:
        return 0, [f"{site.name}: no HTML files found at {site.root}"]
    issues: list[str] = []
    issues.extend(audit_appcast(site))
    canonical_sources: dict[str, list[str]] = {}
    for path in pages:
        canonical_url, page_issues = audit_page(site, path)
        issues.extend(page_issues)
        if canonical_url:
            canonical_sources.setdefault(canonical_url, []).append(path.relative_to(site.root).as_posix())
    for canonical_url, sources in sorted(canonical_sources.items()):
        if len(sources) > 1:
            issues.append(f"{site.name}: duplicate canonical URL {canonical_url} in {', '.join(sources[:8])}")
    canonical_urls = set(canonical_sources)
    sitemap, sitemap_issues = sitemap_urls(site)
    issues.extend(sitemap_issues)
    if canonical_urls != sitemap:
        missing = sorted(canonical_urls - sitemap)
        extra = sorted(sitemap - canonical_urls)
        if missing:
            issues.append(f"{site.name}: sitemap missing canonical URLs: {', '.join(missing[:8])}")
        if extra:
            issues.append(f"{site.name}: sitemap has non-canonical URLs: {', '.join(extra[:8])}")
    issues.extend(audit_robots(site))
    return len(pages), issues


def audit_sites(sites: list[Site] = DEFAULT_SITES) -> tuple[int, list[str]]:
    checked = 0
    issues: list[str] = []
    for site in sites:
        site_checked, site_issues = audit_site(site)
        checked += site_checked
        issues.extend(site_issues)
    return checked, issues


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        sites = sites_from_args(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    checked, issues = audit_sites(sites)
    if args.json:
        print(json.dumps({"checked": checked, "issues": issues}, indent=2))
    elif issues:
        for issue in issues:
            print(f"ERROR: {issue}", file=sys.stderr)
        print(f"SEO site audit failed: {len(issues)} issue(s) across {checked} page(s)", file=sys.stderr)
    else:
        print(f"SEO site audit passed for {checked} page(s)")
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
