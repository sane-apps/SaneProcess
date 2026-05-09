#!/usr/bin/env python3
import importlib.util
import tempfile
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
        self.assertIn("delete or unpublish old files", actions[0]["instructions"])
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
        self.assertIn("leave only SaneBar-2.1.39.zip published", actions[0]["instructions"])
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

            self.assertEqual(audit["stale_files"][0]["filename"], "SaneBar-2.1.47.zip")
            self.assertEqual(audit["stale_files"][0]["expected_filename"], "SaneBar-2.1.48.zip")
            self.assertEqual(audit["missing_latest"][0]["expected_filename"], "SaneBar-2.1.48.zip")
            self.assertEqual(audit["ok_files"][0]["filename"], "SaneSales-1.3.1.zip")


if __name__ == "__main__":
    unittest.main()
