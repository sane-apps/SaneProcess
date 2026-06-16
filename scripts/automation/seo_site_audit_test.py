#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("seo_site_audit.py")


def load_module():
    spec = importlib.util.spec_from_file_location("seo_site_audit", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_png(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        + (1200).to_bytes(4, "big")
        + (630).to_bytes(4, "big")
    )


class SeoSiteAuditTests(unittest.TestCase):
    def test_fixture_detects_metadata_schema_and_sitemap_gaps(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text("User-agent: *\nDisallow: /\n", encoding="utf-8")
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/appcast.xml</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html lang="en"><head>
<title>Fixture App</title>
<meta name="description" content="This app doesn't truncate apostrophes in link previews anymore.">
<link rel="canonical" href="https://fixture.test/">
<meta property="og:type" content="website">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="This app doesn">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Fixture social preview card">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="This app doesn">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png?v=test">
<meta name="twitter:image:alt" content="Fixture social preview card">
</head><body><h1 id="dup">Fixture App</h1><p id="dup">Duplicate id</p><a href="#missing">Missing anchor</a><img src="/images/og-image.png"></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("og:description must match meta description" in issue for issue in issues))
            self.assertTrue(any("missing JSON-LD" in issue for issue in issues))
            self.assertTrue(any("appcast.xml should not be listed" in issue for issue in issues))
            self.assertTrue(any("robots.txt must not disallow the full site" in issue for issue in issues))
            self.assertTrue(any("missing or empty alt" in issue for issue in issues))
            self.assertTrue(any("duplicate IDs" in issue for issue in issues))
            self.assertTrue(any("same-page anchor does not resolve" in issue for issue in issues))

    def test_fixture_detects_missing_doctype_and_html_lang(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text("User-agent: *\nAllow: /\n\nSitemap: https://fixture.test/sitemap.xml\n", encoding="utf-8")
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            (root / "index.html").write_text(
                """<html><head>
<title>Fixture App</title>
<meta name="description" content="Fixture description long enough for the technical SEO audit guard.">
<link rel="canonical" href="https://fixture.test/">
<meta property="og:type" content="website">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Fixture social preview card">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png?v=test">
<meta name="twitter:image:alt" content="Fixture social preview card">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Fixture App"}</script>
</head><body><h1>Fixture App</h1></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("missing <!doctype html>" in issue for issue in issues))
            self.assertTrue(any("missing html lang" in issue for issue in issues))

    def test_fixture_detects_duplicate_canonical_urls(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text("User-agent: *\nAllow: /\n\nSitemap: https://fixture.test/sitemap.xml\n", encoding="utf-8")
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            html = """<!doctype html>
<html lang="en"><head>
<title>Fixture App</title>
<meta name="description" content="Fixture description long enough for the technical SEO audit guard.">
<link rel="canonical" href="https://fixture.test/">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:alt" content="Fixture app preview card with product name">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png?v=test">
<meta name="twitter:image:alt" content="Fixture app preview card with product name">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Fixture App"}</script>
</head><body><h1>Fixture App</h1></body></html>"""
            (root / "index.html").write_text(html, encoding="utf-8")
            (root / "copy.html").write_text(html, encoding="utf-8")
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 2)
            self.assertTrue(any("duplicate canonical URL" in issue for issue in issues))

    def test_fixture_allows_partial_robots_disallow_and_tokenized_canonical_rel(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text(
                "User-agent: *\nAllow: /\nDisallow: /private/\n\nSitemap: https://fixture.test/sitemap.xml\n",
                encoding="utf-8",
            )
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html lang="en"><head>
<title>Fixture App</title>
<meta name="description" content="Fixture description long enough for the technical SEO audit guard.">
<link rel="alternate CANONICAL" href="https://fixture.test/">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:alt" content="Fixture app preview card with product name">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png?v=test">
<meta name="twitter:image:alt" content="Fixture app preview card with product name">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Fixture App"}</script>
</head><body><h1>Fixture App</h1></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertFalse(any("missing canonical" in issue for issue in issues))
            self.assertFalse(any("must not disallow the full site" in issue for issue in issues))

    def test_fixture_detects_malformed_social_image_and_checkout_download_schema(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text("User-agent: *\nAllow: /\n\nSitemap: https://fixture.test/sitemap.xml\n", encoding="utf-8")
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html lang="en"><head>
<title>Fixture App</title>
<meta name="description" content="Fixture description long enough for the technical SEO audit guard.">
<link rel="canonical" href="https://fixture.test/">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png-old?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png-old?v=test">
<meta property="og:image:alt" content="Fixture app preview card with product name">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png-old?v=test">
<meta name="twitter:image:alt" content="Fixture app preview card with product name">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Fixture App","downloadUrl":"https://go.saneapps.com/buy/fixture"}</script>
</head><body><h1>Fixture App</h1></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("og:image must point to https://fixture.test/images/og-image.png" in issue for issue in issues))
            self.assertTrue(any("downloadUrl must not point to a checkout" in issue for issue in issues))

    def test_site_cli_marks_sanesync_as_pre_release_for_appcast_links(self):
        module = load_module()
        args = module.parse_args([
            "--site",
            "SaneSync",
            "/tmp/sanesync-fixture",
            "https://sanesync.com",
            "/images/og-image.png",
        ])
        site = module.sites_from_args(args)[0]
        self.assertFalse(site.allow_appcast_links)

    def test_pre_release_appcast_file_is_validated_but_not_banned(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_png(root / "images" / "og-image.png")
            (root / "robots.txt").write_text("User-agent: *\nAllow: /\n\nSitemap: https://fixture.test/sitemap.xml\n", encoding="utf-8")
            (root / "sitemap.xml").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://fixture.test/</loc></url>
</urlset>
""",
                encoding="utf-8",
            )
            (root / "appcast.xml").write_text(
                """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><title>Fixture Updates</title></channel>
</rss>
""",
                encoding="utf-8",
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html lang="en"><head>
<title>Fixture App</title>
<meta name="description" content="Fixture description long enough for the technical SEO audit guard.">
<link rel="canonical" href="https://fixture.test/">
<meta property="og:type" content="website">
<meta property="og:title" content="Fixture App">
<meta property="og:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png?v=test">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Fixture app preview card with product name">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="Fixture App">
<meta name="twitter:description" content="Fixture description long enough for the technical SEO audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png?v=test">
<meta name="twitter:image:alt" content="Fixture app preview card with product name">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Fixture App"}</script>
</head><body><h1>Fixture App</h1></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png", allow_appcast_links=False)
            checked, issues = module.audit_sites([site])
            self.assertEqual(1, checked)
            self.assertFalse(any("appcast.xml" in issue for issue in issues), issues)

    def test_current_saneapps_sites_pass_seo_audit(self):
        module = load_module()
        checked, issues = module.audit_sites()
        self.assertEqual(100, checked)
        self.assertEqual([], issues)


if __name__ == "__main__":
    unittest.main()
