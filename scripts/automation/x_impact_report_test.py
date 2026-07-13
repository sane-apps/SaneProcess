#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("x-impact-report.py")


def load_module():
    spec = importlib.util.spec_from_file_location("x_impact_report", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class XImpactReportTests(unittest.TestCase):
    def write_json(self, root: Path, name: str, payload: object) -> Path:
        path = root / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_backtest_matches_posts_to_sales_and_daily_lift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture_post_day = datetime.now(timezone.utc).date() - timedelta(days=1)

            def fixture_date(offset: int) -> str:
                return (fixture_post_day + timedelta(days=offset)).isoformat()

            post_log = root / "post-log.jsonl"
            post_log.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "posted_at": f"{fixture_date(0)}T10:00:00-04:00",
                        "product": "SaneClip",
                        "kind": "post",
                        "text": "SaneClip test https://saneclip.com",
                        "response": "{'data': {'id': '1234567890123456789'}}",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            snapshot = self.write_json(
                root,
                "own-posts.json",
                {
                    "fetched_at": f"{fixture_date(1)}T00:00:00Z",
                    "tweets": [
                        {
                            "id": "1234567890123456789",
                            "created_at": f"{fixture_date(0)}T14:00:00Z",
                            "text": "SaneClip test https://t.co/example",
                            "entities": {
                                "urls": [
                                    {
                                        "expanded_url": "https://saneclip.com",
                                        "display_url": "saneclip.com",
                                    }
                                ]
                            },
                            "public_metrics": {
                                "impression_count": 100,
                                "like_count": 2,
                                "reply_count": 1,
                                "retweet_count": 0,
                                "quote_count": 0,
                                "bookmark_count": 1,
                            },
                        }
                    ],
                },
            )
            sales = self.write_json(
                root,
                "sales.json",
                [
                    {
                        "product": "SaneClip",
                        "created_at": f"{fixture_date(0)}T16:00:00Z",
                        "net": 14.0,
                        "refunded": False,
                    },
                    {
                        "product": "SaneBar",
                        "created_at": f"{fixture_date(0)}T17:00:00Z",
                        "net": 14.0,
                        "refunded": False,
                    },
                ],
            )
            downloads = self.write_json(
                root,
                "downloads.json",
                {
                    "total": 0,
                    "rows": [
                        {"app": "saneclip", "date": fixture_date(-3), "count": 5},
                        {"app": "saneclip", "date": fixture_date(-2), "count": 5},
                        {"app": "saneclip", "date": fixture_date(-1), "count": 5},
                        {"app": "saneclip", "date": fixture_date(0), "count": 12},
                        {"app": "saneclip", "date": fixture_date(1), "count": 8},
                    ],
                },
            )
            events = self.write_json(
                root,
                "events.json",
                {
                    "events": [
                        {"app": "saneclip", "event": "checkout_clicked", "date": fixture_date(-3), "count": 1},
                        {"app": "saneclip", "event": "checkout_clicked", "date": fixture_date(-2), "count": 1},
                        {"app": "saneclip", "event": "checkout_clicked", "date": fixture_date(-1), "count": 1},
                        {"app": "saneclip", "event": "checkout_clicked", "date": fixture_date(0), "count": 4},
                        {"app": "saneclip", "event": "checkout_clicked", "date": fixture_date(1), "count": 3},
                    ]
                },
            )
            out = root / "out"
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--post-log",
                    str(post_log),
                    "--x-snapshot",
                    str(snapshot),
                    "--sales-json",
                    str(sales),
                    "--downloads-json",
                    str(downloads),
                    "--events-json",
                    str(events),
                    "--baseline-days",
                    "3",
                    "--days",
                    "30",
                    "--output-dir",
                    str(out),
                    "--json",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(Path(payload["paths"]["json_report"]).is_file())
            saved_payload = json.loads(Path(payload["paths"]["json_report"]).read_text(encoding="utf-8"))
            self.assertIn("markdown_report", saved_payload["paths"])
            post = payload["report"]["posts"][0]
            self.assertEqual(post["product"], "saneclip")
            self.assertEqual(post["metrics"]["impression_count"], 100)
            self.assertEqual(post["engagement_score"], 6)
            self.assertEqual(post["sales"]["48h"]["count"], 1)
            self.assertEqual(post["sales"]["48h"]["all_count"], 2)
            self.assertEqual(post["downloads"]["post_plus_next"], 20)
            self.assertEqual(post["downloads"]["expected_2d"], 10.0)
            self.assertEqual(post["events"]["checkout_clicked"]["post_plus_next"], 7)
            self.assertEqual(post["evidence"], "possible_sale_touch")

    def test_product_detection_prefers_url_domains(self):
        module = load_module()
        tweet = {
            "text": "No product name here https://t.co/example",
            "entities": {"urls": [{"expanded_url": "https://sanevideo.com/download"}]},
        }
        self.assertEqual(module.product_from_tweet(tweet), "sanevideo")

    def test_generic_saneapps_posts_do_not_claim_product_sale_matches(self):
        module = load_module()
        created_at = module.parse_dt("2026-06-10T10:00:00Z")
        post = module.Post(
            id="12345",
            created_at=created_at,
            product="saneapps",
            text="generic post",
            url="https://x.com/i/web/status/12345",
            kind="post",
            source_url="",
            metrics={},
            metrics_snapshot_at="fixture",
        )
        windows = module.sales_windows(
            post,
            [
                {
                    "product": "SaneBar",
                    "created_at": "2026-06-10T12:00:00Z",
                    "net": 14.0,
                    "refunded": False,
                }
            ],
        )
        self.assertEqual(windows["48h"]["all_count"], 1)
        self.assertEqual(windows["48h"]["count"], 0)

    def test_fetch_x_uses_x_api_venv_and_preserves_collection_errors(self):
        source = SCRIPT_PATH.with_name("x_impact_report_io.py").read_text(encoding="utf-8")

        self.assertIn("X_API_PYTHON", source)
        self.assertIn("maybe_reexec_x_venv(argv)", source)
        self.assertIn("os.execv(str(X_API_PYTHON)", source)
        self.assertIn("collection[\"errors\"].update(business_collection.get(\"errors\", {}))", source)


if __name__ == "__main__":
    unittest.main()
