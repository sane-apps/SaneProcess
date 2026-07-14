#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("social_card_audit.py")


def load_module():
    spec = importlib.util.spec_from_file_location("social_card_audit", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SocialCardAuditTests(unittest.TestCase):
    def test_fixture_detects_missing_social_card_metadata(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "index.html").write_text(
                "<!doctype html><html><head><title>Fixture</title></head><body></body></html>",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("missing og:image" in issue for issue in issues))
            self.assertTrue(any("missing twitter:card" in issue for issue in issues))

    def test_fixture_detects_truncated_apostrophe_description(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "images").mkdir()
            (root / "images" / "og-image.png").write_bytes(
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
                + (1200).to_bytes(4, "big")
                + (630).to_bytes(4, "big")
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html><head>
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
</head><body></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("og:description must match meta description" in issue for issue in issues))
            self.assertTrue(any("twitter:description must match meta description" in issue for issue in issues))

    def test_fixture_detects_malformed_social_image_path_and_generic_alt(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "images").mkdir()
            (root / "images" / "og-image.png").write_bytes(
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
                + (1200).to_bytes(4, "big")
                + (630).to_bytes(4, "big")
            )
            (root / "index.html").write_text(
                """<!doctype html>
<html><head>
<title>SaneBar Fixture</title>
<meta name="description" content="Fixture description long enough for the social card audit guard.">
<link rel="canonical alternate" href="https://fixture.test/">
<meta property="og:type" content="website">
<meta property="og:title" content="SaneBar Fixture">
<meta property="og:description" content="Fixture description long enough for the social card audit guard.">
<meta property="og:url" content="https://fixture.test/">
<meta property="og:image" content="https://fixture.test/images/og-image.png-old?v=test">
<meta property="og:image:secure_url" content="https://fixture.test/images/og-image.png-old?v=test">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="SaneBar social preview card">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:url" content="https://fixture.test/">
<meta name="twitter:title" content="SaneBar Fixture">
<meta name="twitter:description" content="Fixture description long enough for the social card audit guard.">
<meta name="twitter:image" content="https://fixture.test/images/og-image.png-old?v=test">
<meta name="twitter:image:alt" content="SaneBar social preview card">
</head><body></body></html>""",
                encoding="utf-8",
            )
            site = module.Site("Fixture", root, "https://fixture.test", "/images/og-image.png")
            checked, issues = module.audit_sites([site])
            self.assertEqual(checked, 1)
            self.assertTrue(any("og:image must point to https://fixture.test/images/og-image.png" in issue for issue in issues))
            self.assertTrue(any("og:image:alt is too generic" in issue for issue in issues))
            self.assertFalse(any("og:url must match canonical" in issue for issue in issues))

    def test_current_saneapps_sites_have_social_cards(self):
        module = load_module()
        checked, issues = module.audit_sites()
        # The live page count moves as active sites gain pages; assert broad
        # coverage without pinning the exact count or retired products.
        self.assertGreaterEqual(checked, 98)
        self.assertEqual([], issues)


if __name__ == "__main__":
    unittest.main()
