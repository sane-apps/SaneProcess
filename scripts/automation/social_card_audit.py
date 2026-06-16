#!/usr/bin/env python3
"""Audit static SaneApps sites for reliable social link preview cards."""

from __future__ import annotations

import argparse
import os
import struct
import sys
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


def default_sane_apps_root() -> Path:
    configured = os.environ.get("SANE_APPS_ROOT")
    if configured:
        return Path(configured).expanduser()
    return Path(__file__).resolve().parents[4]


SANE_APPS_ROOT = default_sane_apps_root()
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
REQUIRED_META = [
    "og:title",
    "og:description",
    "og:url",
    "og:image",
    "og:image:secure_url",
    "og:image:type",
    "og:image:width",
    "og:image:height",
    "og:image:alt",
    "twitter:card",
    "twitter:url",
    "twitter:title",
    "twitter:description",
    "twitter:image",
    "twitter:image:alt",
]


@dataclass(frozen=True)
class Site:
    name: str
    root: Path
    domain: str
    expected_image_path: str
    page_image_paths: dict[str, str] = field(default_factory=dict)


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
        Site("SaneSync", root / "apps/SaneSync/docs", "https://sanesync.com", "/images/og-image.png"),
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


class SocialMetaParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.meta: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_name = tag.lower()
        values = dict(attrs)
        if tag_name == "title":
            self._in_title = True
            return
        if tag_name == "link":
            rel = values.get("rel")
            href = values.get("href")
            if rel and href and "canonical" in rel_tokens(rel):
                self.links["canonical"] = href
            return
        if tag_name != "meta":
            return
        key = values.get("property") or values.get("name")
        content = values.get("content")
        if key and content:
            self.meta[key] = content

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title += data


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit SaneApps static social preview metadata.")
    parser.add_argument("--json", action="store_true", help="Reserved for future structured output.")
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
            Site(name, Path(root).expanduser(), domain.rstrip("/"), image_path, overrides)
            for name, root, domain, image_path in args.site
        ]
    return build_default_sites(args.root.expanduser())


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as handle:
            header = handle.read(24)
    except FileNotFoundError:
        return None
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", header[16:24])


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


def expected_image_path(site: Site, path: Path) -> str:
    rel = path.relative_to(site.root).as_posix()
    return site.page_image_paths.get(rel, site.expected_image_path)


def local_image_path(site: Site, path: Path, image_url: str) -> Path | None:
    expected_path = expected_image_path(site, path)
    parsed = urlparse(image_url)
    if parsed.scheme != "https":
        return None
    if parsed.netloc != urlparse(site.domain).netloc:
        return None
    if parsed.path != expected_path:
        return None
    return site.root / parsed.path.lstrip("/")


def audit_page(site: Site, path: Path) -> list[str]:
    rel = path.relative_to(site.root)
    parser = SocialMetaParser()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    issues: list[str] = []
    for key in REQUIRED_META:
        if not parser.meta.get(key):
            issues.append(f"{site.name}/{rel}: missing {key}")

    if issues:
        return issues

    page_title = " ".join(parser.title.split())
    page_description = " ".join(parser.meta.get("description", "").split())
    canonical_url = parser.links.get("canonical", "")
    if page_title and parser.meta["og:title"] != page_title:
        issues.append(f"{site.name}/{rel}: og:title must match document title")
    if page_title and parser.meta["twitter:title"] != page_title:
        issues.append(f"{site.name}/{rel}: twitter:title must match document title")
    if page_description and parser.meta["og:description"] != page_description:
        issues.append(f"{site.name}/{rel}: og:description must match meta description")
    if page_description and parser.meta["twitter:description"] != page_description:
        issues.append(f"{site.name}/{rel}: twitter:description must match meta description")
    if canonical_url and parser.meta["og:url"] != canonical_url:
        issues.append(f"{site.name}/{rel}: og:url must match canonical URL")
    if canonical_url and parser.meta["twitter:url"] != canonical_url:
        issues.append(f"{site.name}/{rel}: twitter:url must match canonical URL")
    for key in ("og:title", "twitter:title", "og:description", "twitter:description"):
        if "&amp;" in parser.meta[key]:
            issues.append(f"{site.name}/{rel}: {key} appears double-escaped")
    if len(parser.meta["og:description"]) < 40:
        issues.append(f"{site.name}/{rel}: social description is too short")

    og_image = parser.meta["og:image"]
    twitter_image = parser.meta["twitter:image"]
    if og_image != parser.meta["og:image:secure_url"]:
        issues.append(f"{site.name}/{rel}: og:image and og:image:secure_url differ")
    if og_image != twitter_image:
        issues.append(f"{site.name}/{rel}: twitter:image does not match og:image")
    if parser.meta["twitter:card"] != "summary_large_image":
        issues.append(f"{site.name}/{rel}: twitter:card must be summary_large_image")
    if parser.meta["og:image:type"] != "image/png":
        issues.append(f"{site.name}/{rel}: og:image:type must be image/png")
    if parser.meta["og:image:width"] != "1200" or parser.meta["og:image:height"] != "630":
        issues.append(f"{site.name}/{rel}: social card dimensions must be 1200x630")
    if "?v=" not in og_image:
        issues.append(f"{site.name}/{rel}: og:image needs a cache-busting ?v= query")
    for key in ("og:image:alt", "twitter:image:alt"):
        alt_text = " ".join(parser.meta[key].split())
        if len(alt_text) < 24:
            issues.append(f"{site.name}/{rel}: {key} must describe the preview image")
        if alt_text.lower() in GENERIC_SOCIAL_ALTS:
            issues.append(f"{site.name}/{rel}: {key} is too generic")

    image_path = local_image_path(site, path, og_image)
    if not image_path:
        issues.append(f"{site.name}/{rel}: og:image must point to {site.domain}{expected_image_path(site, path)}")
        return issues

    size = png_size(image_path)
    if size != (1200, 630):
        issues.append(f"{site.name}/{rel}: local social image is {size or 'missing/non-png'}, expected 1200x630 PNG")
    return issues


def audit_sites(sites: list[Site] = DEFAULT_SITES) -> tuple[int, list[str]]:
    checked = 0
    issues: list[str] = []
    for site in sites:
        pages = html_files(site)
        if not pages:
            issues.append(f"{site.name}: no HTML files found at {site.root}")
            continue
        for path in pages:
            checked += 1
            issues.extend(audit_page(site, path))
    return checked, issues


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        sites = sites_from_args(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    checked, issues = audit_sites(sites)
    if issues:
        for issue in issues:
            print(f"❌ {issue}", file=sys.stderr)
        print(f"Social card audit failed: {len(issues)} issue(s) across {checked} page(s)", file=sys.stderr)
        return 1
    print(f"Social card audit passed for {checked} page(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
