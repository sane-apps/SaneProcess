#!/usr/bin/env python3
import importlib.util
import tempfile
import json
import os
import subprocess
import sys
import urllib.error
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("hosted-file-actions.py")
SCRIPT_SPEC = importlib.util.spec_from_file_location("hosted_file_actions", SCRIPT_PATH)
HOSTED_FILE_ACTIONS = importlib.util.module_from_spec(SCRIPT_SPEC)
assert SCRIPT_SPEC.loader is not None
SCRIPT_SPEC.loader.exec_module(HOSTED_FILE_ACTIONS)


class HostedFileActionTests(unittest.TestCase):
    def test_api_errors_fail_closed_without_disclosing_credentials(self):
        with mock.patch.object(HOSTED_FILE_ACTIONS.urllib.request, "urlopen", side_effect=urllib.error.URLError("secret-response")):
            with self.assertRaisesRegex(RuntimeError, "API read failed") as error:
                HOSTED_FILE_ACTIONS.fetch_json("https://api.lemonsqueezy.com/v1/files", "private-key")
            self.assertNotIn("secret-response", str(error.exception))
            self.assertNotIn("private-key", str(error.exception))
        for payload in (None, {}, {"data": None}, {"data": [], "errors": ["failure"]}):
            with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_json", return_value=payload):
                with self.assertRaises(RuntimeError):
                    HOSTED_FILE_ACTIONS.fetch_collection("/v1/files", "test")

    def test_collection_follows_pages_and_rejects_foreign_next_link(self):
        pages = [{"data": [{"id": "1"}], "links": {"next": "https://api.lemonsqueezy.com/v1/files?page=2"}}, {"data": [{"id": "2"}]}]
        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_json", side_effect=pages):
            self.assertEqual([r["id"] for r in HOSTED_FILE_ACTIONS.fetch_collection("/v1/files", "test")], ["1", "2"])
        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_json", return_value={"data": [], "links": {"next": "https://foreign.example/v1/files"}}) as fetch:
            with self.assertRaises(RuntimeError):
                HOSTED_FILE_ACTIONS.fetch_collection("/v1/files", "test")
            self.assertEqual(fetch.call_count, 1)

    def test_drafts_are_not_published_evidence(self):
        self.assertIsNone(HOSTED_FILE_ACTIONS.select_display_file([
            {"attributes": {"status": "draft", "name": "App-1.0.0.zip"}}
        ], "1.0.0"))

    def test_ambiguous_variant_mapping_fails_closed(self):
        with self.assertRaises(RuntimeError):
            HOSTED_FILE_ACTIONS.find_variant_record("1", [
                {"id": "a", "attributes": {"product_id": 1}},
                {"id": "b", "attributes": {"product_id": 1}},
            ])

    def test_published_variant_preferred_when_draft_sibling_exists(self):
        chosen = HOSTED_FILE_ACTIONS.find_variant_record("1", [
            {"id": "draft", "attributes": {"product_id": 1, "status": "pending", "name": ""}},
            {"id": "live", "attributes": {"product_id": 1, "status": "published", "name": "Default"}},
        ])
        self.assertEqual(chosen["id"], "live")

    def test_explicit_lemon_variant_id_wins(self):
        chosen = HOSTED_FILE_ACTIONS.find_variant_record(
            "1",
            [
                {"id": "draft", "attributes": {"product_id": 1, "status": "pending"}},
                {"id": "live", "attributes": {"product_id": 1, "status": "published"}},
            ],
            preferred_variant_id="draft",
        )
        self.assertEqual(chosen["id"], "draft")

    def test_newer_hosted_file_requires_release_evidence_not_downgrade(self):
        config = {"products": {"test": {"name": "App", "appcast": "https://example.com/feed"}}}
        inventory = [
            [{"id": "1", "attributes": {"name": "App"}}],
            [{"id": "2", "attributes": {"product_id": 1}}],
            [{"attributes": {"status": "published", "name": "App-1.0.2.zip"}}],
        ]
        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_collection", side_effect=inventory), mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_appcast_release", return_value=("1.0.1", "https://example.com/App-1.0.1.zip")):
            actions, snapshot = HOSTED_FILE_ACTIONS.build_snapshot_rows(config, "test")
        self.assertEqual(snapshot[0]["status"], "Needs release evidence")
        self.assertIn("do not downgrade or remove", actions[0]["instructions"])

    def test_release_parser_requires_matching_affirmative_snapshot(self):
        release = SCRIPT_PATH.parents[1].joinpath("release.sh").read_text()
        section = release.split("verify_lemonsqueezy_hosted_file_sync() {", 1)[1]
        parser = section.split("python3 - <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        good = {"app": "App", "expected_version": "1.0.1", "hosted_version": "1.0.1", "status": "In sync", "published_file_count": "1", "variant_id": "1"}
        fixtures = [({}, False), ({"current_actions": []}, False),
                    ({"snapshot": [good]}, True),
                    ({"snapshot": [{**good, "expected_version": "1.0.0"}]}, False),
                    ({"snapshot": [{**good, "published_file_count": "0"}]}, False),
                    ({"snapshot": [{**good, "hosted_version": "1.0.0"}]}, False),
                    ({"snapshot": [good, good]}, False)]
        for payload, passes in fixtures:
            with self.subTest(payload=payload):
                env = {**os.environ, "APP_NAME": "App", "EXPECTED_VERSION": "1.0.1", "HOSTED_FILE_ACTIONS_JSON": json.dumps(payload)}
                result = subprocess.run([sys.executable, "-c", parser], env=env, capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, passes, result.stderr)

    def test_extract_version_from_filename(self):
        self.assertEqual(
            HOSTED_FILE_ACTIONS.extract_version_from_filename("SaneBar-2.1.39.zip"),
            "2.1.39",
        )
        self.assertEqual(
            HOSTED_FILE_ACTIONS.extract_version_from_filename("SaneBar-1.0.0-beta-2.1.39.zip"),
            "2.1.39",
        )
        self.assertEqual(HOSTED_FILE_ACTIONS.extract_version_from_filename("README.txt"), "")

    def test_build_snapshot_rows_flags_drift_and_builds_dashboard_links(self):
        config = {
            "products": {
                "sanebar": {
                    "name": "SaneBar",
                    "appcast": "https://sanebar.com/appcast.xml",
                }
            }
        }
        products = [
            {
                "id": "778575",
                "attributes": {"name": "SaneBar", "slug": "sanebar"},
            }
        ]
        variants = [
            {
                "id": "1227172",
                "attributes": {"product_id": 778575},
            }
        ]
        files = [
            {
                "attributes": {
                    "status": "published",
                    "name": "SaneBar-2.1.36.zip",
                }
            }
        ]

        def fake_fetch_collection(path, _api_key):
            if "products" in path:
                return products
            if "variants?page" in path:
                return variants
            return files

        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_collection", side_effect=fake_fetch_collection), \
            mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_appcast_release", return_value=("2.1.39", "https://dist.sanebar.com/updates/SaneBar-2.1.39.zip")):
            actions, snapshot = HOSTED_FILE_ACTIONS.build_snapshot_rows(config, "test-key")

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["app"], "SaneBar")
        self.assertEqual(actions[0]["hosted_version"], "2.1.36")
        self.assertEqual(actions[0]["expected_version"], "2.1.39")
        self.assertEqual(actions[0]["published_file_count"], "1")
        self.assertEqual(actions[0]["extra_filenames"], "SaneBar-2.1.36.zip")
        self.assertEqual(actions[0]["dashboard_url"], "https://app.lemonsqueezy.com/products/778575")
        self.assertIn("variant 1227172", actions[0]["instructions"])
        self.assertIn("verify the published replacement download", actions[0]["instructions"])
        self.assertEqual(snapshot[0]["status"], "Needs dashboard sync")

    def test_build_snapshot_rows_flags_extra_published_files_when_latest_exists(self):
        config = {
            "products": {
                "sanebar": {
                    "name": "SaneBar",
                    "appcast": "https://sanebar.com/appcast.xml",
                }
            }
        }
        products = [
            {
                "id": "778575",
                "attributes": {"name": "SaneBar", "slug": "sanebar"},
            }
        ]
        variants = [
            {
                "id": "1227172",
                "attributes": {"product_id": 778575},
            }
        ]
        files = [
            {
                "attributes": {
                    "status": "published",
                    "name": "SaneBar-2.1.36.zip",
                }
            },
            {
                "attributes": {
                    "status": "published",
                    "name": "SaneBar-2.1.39.zip",
                }
            },
        ]

        def fake_fetch_collection(path, _api_key):
            if "products" in path:
                return products
            if "variants?page" in path:
                return variants
            return files

        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_collection", side_effect=fake_fetch_collection), \
            mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_appcast_release", return_value=("2.1.39", "https://dist.sanebar.com/updates/SaneBar-2.1.39.zip")):
            actions, snapshot = HOSTED_FILE_ACTIONS.build_snapshot_rows(config, "test-key")

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action_status"], "Needs dashboard cleanup")
        self.assertEqual(actions[0]["hosted_version"], "2.1.39")
        self.assertEqual(actions[0]["published_file_count"], "2")
        self.assertEqual(actions[0]["extra_filenames"], "SaneBar-2.1.36.zip")
        self.assertIn("verify the published replacement downloads correctly", actions[0]["instructions"])
        self.assertEqual(snapshot[0]["status"], "Needs dashboard cleanup")

    def test_build_snapshot_rows_does_not_infer_cleanup_when_appcast_version_is_missing(self):
        config = {
            "products": {
                "sanebar": {
                    "name": "SaneBar",
                    "appcast": "https://sanebar.com/appcast.xml",
                }
            }
        }
        products = [{"id": "778575", "attributes": {"name": "SaneBar", "slug": "sanebar"}}]
        variants = [{"id": "1227172", "attributes": {"product_id": 778575}}]
        files = [{"attributes": {"status": "published", "name": "SaneBar-2.1.39.zip"}}]

        def fake_fetch_collection(path, _api_key):
            if "products" in path:
                return products
            if "variants?page" in path:
                return variants
            return files

        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_collection", side_effect=fake_fetch_collection), \
            mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_appcast_release", return_value=("", "")):
            actions, snapshot = HOSTED_FILE_ACTIONS.build_snapshot_rows(config, "test-key")

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action_status"], "Needs appcast evidence")
        self.assertEqual(actions[0]["hosted_version"], "2.1.39")
        self.assertEqual(actions[0]["extra_filenames"], "—")
        self.assertIn("before changing Lemon Squeezy hosted files", actions[0]["instructions"])
        self.assertEqual(snapshot[0]["status"], "Needs appcast evidence")

    def test_build_snapshot_rows_matches_lemon_product_aliases(self):
        config = {
            "products": {
                "sanevideo": {
                    "name": "SaneVideo",
                    "appcast": "https://sanevideo.com/appcast.xml",
                }
            }
        }
        products = [
            {
                "id": "1087460",
                "attributes": {"name": "SaneVideo Pro", "slug": "sanevideo-pro"},
            }
        ]
        variants = [
            {
                "id": "1703963",
                "attributes": {"product_id": 1087460},
            }
        ]
        files = []

        def fake_fetch_collection(path, _api_key):
            if "products" in path:
                return products
            if "variants?page" in path:
                return variants
            return files

        with mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_collection", side_effect=fake_fetch_collection), \
            mock.patch.object(HOSTED_FILE_ACTIONS, "fetch_appcast_release", return_value=("1.0.1", "https://dist.sanevideo.com/updates/SaneVideo-1.0.1.zip")):
            actions, snapshot = HOSTED_FILE_ACTIONS.build_snapshot_rows(config, "test-key")

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["app"], "SaneVideo")
        self.assertEqual(actions[0]["product_id"], "1087460")
        self.assertEqual(actions[0]["product_slug"], "sanevideo-pro")
        self.assertEqual(actions[0]["action_status"], "Needs dashboard sync")
        self.assertEqual(actions[0]["variant_id"], "1703963")
        self.assertEqual(snapshot[0]["filename"], "—")

    def test_main_writes_json_out_and_xlsx(self):
        sample_actions = [
            {
                "app": "SaneBar",
                "action_status": "Needs dashboard sync",
                "expected_version": "2.1.39",
                "hosted_version": "2.1.36",
                "filename": "SaneBar-2.1.36.zip",
                "published_file_count": "1",
                "extra_filenames": "SaneBar-2.1.36.zip",
                "dashboard_url": "https://app.lemonsqueezy.com/products/778575",
                "dist_url": "https://dist.sanebar.com/updates/SaneBar-2.1.39.zip",
                "product_id": "778575",
                "product_slug": "sanebar",
                "variant_id": "1227172",
                "api_files_url": "https://api.lemonsqueezy.com/v1/variants/1227172/files",
                "instructions": "Replace it.",
                "note": "Dashboard-only action.",
            }
        ]
        sample_snapshot = [
            {
                "app": "SaneBar",
                "expected_version": "2.1.39",
                "hosted_version": "2.1.36",
                "filename": "SaneBar-2.1.36.zip",
                "published_file_count": "1",
                "extra_filenames": "SaneBar-2.1.36.zip",
                "dashboard_url": "https://app.lemonsqueezy.com/products/778575",
                "dist_url": "https://dist.sanebar.com/updates/SaneBar-2.1.39.zip",
                "product_id": "778575",
                "product_slug": "sanebar",
                "variant_id": "1227172",
                "api_files_url": "https://api.lemonsqueezy.com/v1/variants/1227172/files",
                "status": "Needs dashboard sync",
            }
        ]
        with tempfile.TemporaryDirectory() as tmp:
            output_path = Path(tmp) / "hosted_file_actions.xlsx"
            json_path = Path(tmp) / "hosted_file_actions.json"
            evidence_path = Path(tmp) / "hosted_file_actions.md"
            uploads_path = Path(tmp) / "LemonSqueezy-Uploads"
            uploads_path.mkdir()
            (uploads_path / "SaneBar-2.1.36.zip").write_text("stale", encoding="utf-8")
            with mock.patch.object(HOSTED_FILE_ACTIONS, "get_lemonsqueezy_api_key", return_value="test-key"), \
                mock.patch.object(HOSTED_FILE_ACTIONS, "load_product_config", return_value={"products": {}}), \
                mock.patch.object(HOSTED_FILE_ACTIONS, "build_snapshot_rows", return_value=(sample_actions, sample_snapshot)), \
                mock.patch.object(HOSTED_FILE_ACTIONS.sys, "argv", [
                    "hosted-file-actions.py",
                    "--xlsx",
                    str(output_path),
                    "--json-out",
                    str(json_path),
                    "--evidence-out",
                    str(evidence_path),
                    "--uploads-dir",
                    str(uploads_path),
                ]):
                HOSTED_FILE_ACTIONS.main()

            self.assertTrue(output_path.exists())
            self.assertTrue(json_path.exists())
            self.assertTrue(evidence_path.exists())
            with zipfile.ZipFile(output_path) as zf:
                workbook_xml = zf.read("xl/workbook.xml").decode("utf-8")
                sheet_xml = zf.read("xl/worksheets/sheet1.xml").decode("utf-8")
            self.assertIn('sheet name="Current Actions"', workbook_xml)
            self.assertIn('sheet name="Live Snapshot"', workbook_xml)
            self.assertIn("Needs dashboard sync", sheet_xml)
            self.assertIn("current_actions", json_path.read_text(encoding="utf-8"))
            self.assertIn("upload_folder", json_path.read_text(encoding="utf-8"))
            evidence = evidence_path.read_text(encoding="utf-8")
            self.assertIn("Hosted File Action Evidence", evidence)
            self.assertIn("Current actions: 1", evidence)
            self.assertIn("Upload Folder Audit", evidence)
            self.assertIn("SaneBar-2.1.36.zip", evidence)
            self.assertIn("SaneBar", evidence)

    def test_audit_upload_folder_flags_stale_and_missing_latest_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            uploads_path = Path(tmp)
            (uploads_path / "SaneBar-2.1.47.zip").write_text("old", encoding="utf-8")
            (uploads_path / "SaneSales-1.3.1.zip").write_text("current", encoding="utf-8")
            snapshot = [
                {
                    "app": "SaneBar",
                    "expected_version": "2.1.48",
                    "dist_url": "https://dist.sanebar.com/updates/SaneBar-2.1.48.zip",
                },
                {
                    "app": "SaneSales",
                    "expected_version": "1.3.1",
                    "dist_url": "https://dist.sanesales.com/updates/SaneSales-1.3.1.zip",
                },
            ]

            audit = HOSTED_FILE_ACTIONS.audit_upload_folder(uploads_path, snapshot)

            self.assertEqual(audit["stale_files"][0]["status"], "different_from_appcast")
            self.assertEqual(audit["ok_files"][0]["status"], "filename_match")
            self.assertEqual(audit["stale_files"][0]["filename"], "SaneBar-2.1.47.zip")
            self.assertEqual(audit["stale_files"][0]["expected_filename"], "SaneBar-2.1.48.zip")
            self.assertEqual(audit["missing_latest"][0]["expected_filename"], "SaneBar-2.1.48.zip")
            self.assertEqual(audit["ok_files"][0]["filename"], "SaneSales-1.3.1.zip")


if __name__ == "__main__":
    unittest.main()
