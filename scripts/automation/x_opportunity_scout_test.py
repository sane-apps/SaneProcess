#!/usr/bin/env python3
from __future__ import annotations

import json
import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("x-opportunity-scout.py")
HEARTBEAT_SCRIPT_PATH = Path.home() / "SaneApps" / "infra" / "scripts" / "x-opportunity-scout.py"


class XOpportunityScoutTests(unittest.TestCase):
    def load_module(self):
        spec = importlib.util.spec_from_file_location("x_opportunity_scout_under_test", SCRIPT_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def load_heartbeat_module(self):
        spec = importlib.util.spec_from_file_location("heartbeat_x_opportunity_scout_under_test", HEARTBEAT_SCRIPT_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def write_outreach(self, root: Path, app: str, body: str) -> Path:
        path = root / "apps" / app / ".outreach.yml"
        path.parent.mkdir(parents=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        return path

    def run_scout(self, root: Path, *args: str) -> dict:
        result = subprocess.run(
            ["python3", str(SCRIPT_PATH), "--root", str(root), "--dry-run", "--json", *args],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)

    def test_dry_run_selects_queries_without_x_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneBar",
                """
                product: SaneBar
                positioning:
                  status_note: "Live app."
                launch_calendar:
                  classification: "public_testing_ready"
                x_search_keywords:
                  - '"menu bar" macOS lang:en -is:retweet'
                  - 'Bartender alternative mac lang:en -is:retweet'
                """,
            )
            payload = self.run_scout(root, "--limit", "1")
            self.assertTrue(payload["ok"])
            self.assertTrue(payload["dry_run"])
            self.assertEqual(len(payload["queries"]), 1)
            self.assertEqual(payload["queries"][0]["product"], "SaneBar")

    def test_public_ready_missing_keywords_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneVideo",
                """
                product: SaneVideo
                positioning:
                  status_note: "Public testing positioning."
                launch_calendar:
                  classification: "public_testing_ready"
                """,
            )
            payload = self.run_scout(root)
            missing = [item for item in payload["missing_keywords"] if item["public_ready"]]
            self.assertEqual([item["product"] for item in missing], ["SaneVideo"])

    def test_blocked_products_are_not_queried_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneSync",
                """
                product: SaneSync
                positioning:
                  status_note: "Do not use this as public positioning."
                launch_calendar:
                  classification: "blocked_not_launch_ready"
                x_search_keywords:
                  - 'local ai file automation mac lang:en -is:retweet'
                """,
            )
            payload = self.run_scout(root)
            self.assertEqual(payload["queries"], [])

            payload = self.run_scout(root, "--include-blocked")
            self.assertEqual(len(payload["queries"]), 1)
            self.assertEqual(payload["queries"][0]["product"], "SaneSync")

    def test_released_launch_blocked_products_still_get_searched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneClip",
                """
                product: SaneClip
                launch_calendar:
                  classification: "released_but_launch_blocked_until_risk_cleanup"
                x_search_keywords:
                  - 'clipboard manager mac lang:en -is:retweet'
                """,
            )
            payload = self.run_scout(root)
            self.assertEqual(len(payload["queries"]), 1)
            self.assertEqual(payload["queries"][0]["product"], "SaneClip")

    def test_query_selection_round_robins_products(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneBar",
                """
                product: SaneBar
                launch_calendar:
                  classification: "meaningfully_launched"
                x_search_keywords:
                  - 'bar one'
                  - 'bar two'
                """,
            )
            self.write_outreach(
                root,
                "SaneVideo",
                """
                product: SaneVideo
                launch_calendar:
                  classification: "public_testing_ready"
                x_search_keywords:
                  - 'video one'
                  - 'video two'
                """,
            )
            payload = self.run_scout(root, "--limit", "2")
            products = {entry["product"] for entry in payload["queries"]}
            self.assertEqual(products, {"SaneBar", "SaneVideo"})

    def test_all_live_mode_includes_mentions_keywords_and_global_queries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_outreach(
                root,
                "SaneBar",
                """
                product: SaneBar
                project:
                  url: "https://sanebar.com"
                launch_calendar:
                  classification: "meaningfully_launched"
                x_search_keywords:
                  - 'menu bar mac lang:en -is:retweet'
                """,
            )
            payload = self.run_scout(
                root,
                "--all-live",
                "--mention-queries",
                "--global-queries",
                "--limit",
                "0",
            )
            queries = payload["queries"]
            self.assertTrue(any(entry["kind"] == "mention" for entry in queries))
            self.assertTrue(any(entry["kind"] == "keyword" for entry in queries))
            self.assertTrue(any(entry["kind"] == "global" for entry in queries))
            self.assertTrue(any("sanebar.com" in entry["query"] for entry in queries))
            product_queries = [entry for entry in queries if entry["product"] == "SaneBar"]
            self.assertTrue(product_queries)
            self.assertTrue(all(entry["website_url"] == "https://sanebar.com" for entry in product_queries))
            global_queries = [entry for entry in queries if entry["product"] == "SaneApps"]
            self.assertTrue(global_queries)
            self.assertTrue(all(entry["website_url"] == "https://saneapps.com" for entry in global_queries))

    def test_live_search_does_not_request_user_expansions(self):
        module = self.load_module()
        captured: dict[str, object] = {}

        class FakePosts:
            def search_recent(self, **kwargs):
                captured.update(kwargs)
                return [
                    types.SimpleNamespace(
                        data=[
                            {
                                "id": "123",
                                "author_id": "456",
                                "created_at": "2026-06-16T12:00:00Z",
                                "text": "Looking for a private Mac video tool.",
                                "public_metrics": {"like_count": 3},
                            }
                        ]
                    )
                ]

        class FakeClient:
            def __init__(self, auth):
                self.auth = auth
                self.posts = FakePosts()

        class FakeOAuth1:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

        old_xdk = sys.modules.get("xdk")
        old_auth = sys.modules.get("xdk.oauth1_auth")
        fake_xdk = types.ModuleType("xdk")
        fake_xdk.Client = FakeClient
        fake_auth = types.ModuleType("xdk.oauth1_auth")
        fake_auth.OAuth1 = FakeOAuth1
        sys.modules["xdk"] = fake_xdk
        sys.modules["xdk.oauth1_auth"] = fake_auth
        original_get_secret = module.get_secret
        module.get_secret = lambda account: f"{account}-secret"
        try:
            results = module.run_live_search(
                [
                    {
                        "product": "SaneVideo",
                        "query": '"SaneVideo" lang:en -is:retweet',
                        "kind": "mention",
                        "website_url": "https://sanevideo.com",
                    }
                ],
                per_query=3,
            )
        finally:
            module.get_secret = original_get_secret
            if old_xdk is None:
                sys.modules.pop("xdk", None)
            else:
                sys.modules["xdk"] = old_xdk
            if old_auth is None:
                sys.modules.pop("xdk.oauth1_auth", None)
            else:
                sys.modules["xdk.oauth1_auth"] = old_auth

        self.assertEqual(len(results), 1)
        self.assertEqual(captured["max_results"], 10)
        self.assertEqual(captured["tweet_fields"], ["public_metrics", "created_at", "author_id"])
        self.assertNotIn("expansions", captured)
        self.assertNotIn("user_fields", captured)

    def test_live_search_trims_candidates_after_x_minimum_result_request(self):
        module = self.load_module()
        captured: dict[str, object] = {}

        class FakePosts:
            def search_recent(self, **kwargs):
                captured.update(kwargs)
                return [
                    types.SimpleNamespace(
                        data=[
                            {
                                "id": str(100 + index),
                                "author_id": "456",
                                "created_at": "2026-06-16T12:00:00Z",
                                "text": f"candidate {index}",
                                "public_metrics": {},
                            }
                            for index in range(10)
                        ]
                    )
                ]

        class FakeClient:
            def __init__(self, auth):
                self.auth = auth
                self.posts = FakePosts()

        class FakeOAuth1:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

        old_xdk = sys.modules.get("xdk")
        old_auth = sys.modules.get("xdk.oauth1_auth")
        fake_xdk = types.ModuleType("xdk")
        fake_xdk.Client = FakeClient
        fake_auth = types.ModuleType("xdk.oauth1_auth")
        fake_auth.OAuth1 = FakeOAuth1
        sys.modules["xdk"] = fake_xdk
        sys.modules["xdk.oauth1_auth"] = fake_auth
        original_get_secret = module.get_secret
        module.get_secret = lambda account: f"{account}-secret"
        try:
            results = module.run_live_search(
                [
                    {
                        "product": "SaneVideo",
                        "query": '"SaneVideo" lang:en -is:retweet',
                        "kind": "mention",
                        "website_url": "https://sanevideo.com",
                    }
                ],
                per_query=3,
            )
        finally:
            module.get_secret = original_get_secret
            if old_xdk is None:
                sys.modules.pop("xdk", None)
            else:
                sys.modules["xdk"] = old_xdk
            if old_auth is None:
                sys.modules.pop("xdk.oauth1_auth", None)
            else:
                sys.modules["xdk.oauth1_auth"] = old_auth

        self.assertEqual(captured["max_results"], 10)
        self.assertEqual([item["id"] for item in results], ["100", "101", "102"])

    def test_heartbeat_scout_rejects_keyword_false_positive(self):
        module = self.load_heartbeat_module()
        result = module.classify_candidate(
            "SaneCite",
            "Microsoft locked my Xbox account behind automated phone responses.",
            "Gaming content creator",
            "gamer",
        )
        self.assertIsNone(result)

    def test_heartbeat_scout_qualifies_sanecite_pain(self):
        module = self.load_heartbeat_module()
        result = module.classify_candidate(
            "SaneCite",
            "We answer the same security questionnaire by hand in a spreadsheet every week.",
            "Enterprise sales engineer",
            "seller",
        )
        self.assertEqual(result["kind"], "pain")
        self.assertTrue(result["actionable"])
        self.assertEqual(result["recommended_action"], "quote_repost")
        self.assertIn("Do not send an automated cold reply", result["next_action"])

    def test_seen_actionable_candidate_resurfaces_until_acted_on(self):
        module = self.load_heartbeat_module()
        classification = {"actionable": True}

        self.assertTrue(module.should_surface_candidate("123", classification, {"123"}, set()))
        self.assertFalse(module.should_surface_candidate("123", classification, {"123"}, {"123"}))
        self.assertFalse(module.should_surface_candidate("123", {"actionable": False}, {"123"}, set()))
        self.assertTrue(module.should_surface_candidate("new", classification, {"123"}, set()))

    def test_heartbeat_scout_qualifies_real_dealer_listing_as_a_lead(self):
        module = self.load_heartbeat_module()
        result = module.classify_candidate(
            "SaneLot",
            "New inventory in stock. Financing available and trade-ins welcome.",
            "Independent used car dealer serving Tampa, Florida.",
            "tampaautos",
            "Tampa, Florida",
        )
        self.assertEqual(result["kind"], "beta_review_candidate")
        self.assertEqual(result["region"], "us")
        self.assertTrue(result["actionable"])
        self.assertEqual(result["invite_url"], "https://testflight.apple.com/join/hPv1tGs2")
        self.assertIn("feedback", result["next_action"])
        self.assertIn("VIN to a verified live listing", result["value_hook"])
        self.assertTrue(result["suggested_invite"].startswith("I built SaneLot to get a car"))
        self.assertIn("from one iPhone", result["suggested_invite"])
        self.assertIn("won’t invent facts", result["suggested_invite"])
        self.assertIn("would you test it and give me blunt feedback?", result["suggested_invite"])
        self.assertNotIn("practice", result["suggested_invite"].lower())
        self.assertNotIn("We ", result["suggested_invite"])
        self.assertIn("email or DM", result["preferred_channel"])

    def test_heartbeat_scout_rejects_private_listing_and_classified_platform(self):
        module = self.load_heartbeat_module()
        private_seller = module.classify_candidate(
            "SaneLot",
            "My SUV is available now. DM for details.",
            "Dad, golfer, coffee fan.",
            "privateperson",
        )
        classified_platform = module.classify_candidate(
            "SaneLot",
            "New inventory available now.",
            "Post free classified ads for cars and motorcycles.",
            "adplatform",
        )
        self.assertIsNone(private_seller)
        self.assertIsNone(classified_platform)

    def test_heartbeat_scout_rejects_frazer_name_collision_and_automotive_vendor(self):
        module = self.load_heartbeat_module()
        name_collision = module.classify_candidate(
            "SaneLot",
            "The issue is traffic near Frazer Town hospital.",
            "Local resident.",
            "resident",
        )
        automotive_vendor = module.classify_candidate(
            "SaneLot",
            "Your DMS connects inventory, CRM, accounting and OEM platforms.",
            "Dealership revenue platform with lifecycle management and intent mining.",
            "vendor",
        )
        self.assertIsNone(name_collision)
        self.assertIsNone(automotive_vendor)

    def test_heartbeat_scout_qualifies_dealer_podcaster_as_review_partner(self):
        module = self.load_heartbeat_module()
        result = module.classify_candidate(
            "SaneLot",
            "Mastering dealership inventory means understanding local pricing trends.",
            "A podcast about practical ways to make your dealership better.",
            "dealerpodcast",
        )
        self.assertEqual(result["kind"], "beta_review_partner")
        self.assertTrue(result["actionable"])
        self.assertEqual(result["invite_url"], "https://testflight.apple.com/join/hPv1tGs2")
        self.assertIn("verified live listing", result["suggested_invite"])
        self.assertIn("guides the walkaround", result["suggested_invite"])
        self.assertIn("You understand how cars actually move through a lot", result["suggested_invite"])
        self.assertIn("blunt review", result["suggested_invite"])
        self.assertNotIn("practice", result["suggested_invite"].lower())
        self.assertNotIn("We ", result["suggested_invite"])
        self.assertIn("exact copy approval", result["preferred_channel"])

    def test_heartbeat_scout_keeps_non_us_dealers_as_market_signals(self):
        module = self.load_heartbeat_module()
        result = module.classify_candidate(
            "SaneLot",
            "Fresh inventory in stock at our showroom. KSh 2,000,000.",
            "Trusted used car dealership in Mombasa.",
            "mombasacars",
            "Mombasa, Kenya",
        )
        self.assertEqual(result["kind"], "non_us_dealer_signal")
        self.assertEqual(result["region"], "non_us")
        self.assertFalse(result["actionable"])


if __name__ == "__main__":
    unittest.main()
