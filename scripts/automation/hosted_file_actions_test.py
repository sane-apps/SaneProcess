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
        self.assertEqual(actions[0]["dashboard_url"], "https://app.lemonsqueezy.com/products/778575")
        self.assertIn("variant 1227172", actions[0]["instructions"])
        self.assertEqual(snapshot[0]["status"], "Needs dashboard sync")

    def test_main_writes_json_out_and_xlsx(self):
        sample_actions = [
            {
                "app": "SaneBar",
                "action_status": "Needs dashboard sync",
                "expected_version": "2.1.39",
                "hosted_version": "2.1.36",
                "filename": "SaneBar-2.1.36.zip",
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
            with mock.patch.object(HOSTED_FILE_ACTIONS, "get_lemonsqueezy_api_key", return_value="test-key"), \
                mock.patch.object(HOSTED_FILE_ACTIONS, "load_product_config", return_value={"products": {}}), \
                mock.patch.object(HOSTED_FILE_ACTIONS, "build_snapshot_rows", return_value=(sample_actions, sample_snapshot)), \
                mock.patch.object(HOSTED_FILE_ACTIONS.sys, "argv", [
                    "hosted-file-actions.py",
                    "--xlsx",
                    str(output_path),
                    "--json-out",
                    str(json_path),
                ]):
                HOSTED_FILE_ACTIONS.main()

            self.assertTrue(output_path.exists())
            self.assertTrue(json_path.exists())
            with zipfile.ZipFile(output_path) as zf:
                workbook_xml = zf.read("xl/workbook.xml").decode("utf-8")
                sheet_xml = zf.read("xl/worksheets/sheet1.xml").decode("utf-8")
            self.assertIn('sheet name="Current Actions"', workbook_xml)
            self.assertIn('sheet name="Live Snapshot"', workbook_xml)
            self.assertIn("Needs dashboard sync", sheet_xml)
            self.assertIn("current_actions", json_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
