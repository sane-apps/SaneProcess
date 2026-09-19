#!/usr/bin/env python3
"""Focused tests for the SaneHosts 12-week weekday sender."""
from __future__ import annotations

import csv
import json
import sys
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import sanehosts_email_campaign as camp  # noqa: E402


def write_campaign(tmp: Path, sendable=None, contacts=None, abort=False, e1_receipt_day=None, e1_receipt_count=0):
    sendable = sendable or []
    contacts = contacts or {}
    (tmp / "email-1.subject").write_text("Keep your localhost lines. Block the rest.\n")
    (tmp / "email-1.txt").write_text("Hi {{FIRST_NAME}}\n")
    (tmp / "email-1.html").write_text("<p>Hi {{FIRST_NAME}}</p>\n")
    (tmp / "email-2.subject").write_text("Touch ID, then your Mac hosts file updates\n")
    (tmp / "email-2.txt").write_text("Hi {{FIRST_NAME}}\n")
    (tmp / "email-2.html").write_text("<p>Hi {{FIRST_NAME}}</p>\n")
    (tmp / "email-3.subject").write_text("Last note: Mac hosts-file manager, $14.99 once\n")
    (tmp / "email-3.txt").write_text("Hi {{FIRST_NAME}}\n")
    (tmp / "email-3.html").write_text("<p>Hi {{FIRST_NAME}}</p>\n")
    with (tmp / "sanehosts-sendable.csv").open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["email", "first_name", "company"])
        w.writeheader()
        w.writerows(sendable)
    (tmp / "drip-state.json").write_text(json.dumps({"contacts": contacts, "campaign": camp.CAMPAIGN}))
    abort_path = tmp / "campaign-ABORT"
    if abort:
        abort_path.write_text("")
    elif abort_path.exists():
        abort_path.unlink()
    if e1_receipt_day:
        payload = {
            "ids": [f"id-{i}" for i in range(e1_receipt_count)],
            "emails": [f"sent{i}@school.edu" for i in range(e1_receipt_count)],
            "scheduled": e1_receipt_count,
        }
        (tmp / f"e1-send-receipt-{e1_receipt_day}.json").write_text(json.dumps(payload) + "\n")


class WindowTests(unittest.TestCase):
    def test_business_days_skip_weekend(self):
        self.assertEqual(camp.add_business_days(date(2026, 8, 28), 5), date(2026, 9, 4))
        self.assertEqual(camp.add_business_days("2026-09-01", 8), date(2026, 9, 11))

    def test_twelve_week_bounds(self):
        self.assertEqual(camp.WINDOW_START, date(2026, 9, 1))
        self.assertEqual(camp.WINDOW_END, date(2026, 11, 24))
        self.assertEqual((camp.WINDOW_END - camp.WINDOW_START).days, 84)

    def test_e1_window_misses_lot_block(self):
        first = camp.schedule_at(date(2026, 9, 1), 0)
        eighth = camp.schedule_at(date(2026, 9, 1), 7)
        jumped = camp.schedule_at(date(2026, 9, 1), 13)
        last = camp.schedule_at(date(2026, 9, 1), 49)
        self.assertEqual(first.hour, 9)
        self.assertEqual(first.minute, 0)
        self.assertLess(eighth, datetime(2026, 9, 1, 9, 38, tzinfo=camp.ET))
        self.assertEqual((jumped.hour, jumped.minute), (10, 12))
        self.assertEqual(camp.E1_CAP, 50)
        self.assertGreaterEqual((last - first).total_seconds() / 60, 49 * 3 - 5)


class PlanTests(unittest.TestCase):
    def test_weekday_books_fifty_new(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            people = [
                {"email": f"mac{i}@school.edu", "first_name": "Pat", "company": "School"}
                for i in range(60)
            ]
            write_campaign(tmp, sendable=people)
            plan = camp.plan_day(tmp, date(2026, 9, 1))
            self.assertEqual(len(plan["e1"]), 50)
            self.assertIn("email-1-50", plan["actions"])
            self.assertTrue(plan["need_leads"])

    def test_already_at_cap_prevents_double_book(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            people = [
                {"email": f"mac{i}@school.edu", "first_name": "Pat", "company": "School"}
                for i in range(10)
            ]
            write_campaign(tmp, sendable=people, e1_receipt_day="2026-09-01", e1_receipt_count=50)
            plan = camp.plan_day(tmp, date(2026, 9, 1))
            self.assertEqual(plan["e1"], [])
            self.assertIn("e1-already-booked", plan["actions"])

    def test_receipt_merge_stacks_a_topup(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_campaign(tmp, sendable=[], e1_receipt_day="2026-09-01", e1_receipt_count=8)
            merged = camp.merge_e1_receipt(
                tmp,
                date(2026, 9, 1),
                {"scheduled": 1, "count": 1, "emails": ["mac@school.edu"], "ids": ["id-new"]},
            )
            self.assertEqual(camp.booked_today_count(merged), 9)
            self.assertEqual(len(merged["ids"]), 9)
            self.assertEqual(merged["emails"][-1], "mac@school.edu")

    def test_partial_day_tops_up_to_fifty(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            people = [
                {"email": f"mac{i}@school.edu", "first_name": "Pat", "company": "School"}
                for i in range(60)
            ]
            write_campaign(tmp, sendable=people, e1_receipt_day="2026-09-01", e1_receipt_count=8)
            plan = camp.plan_day(tmp, date(2026, 9, 1))
            self.assertEqual(len(plan["e1"]), 42)
            self.assertIn("email-1-42-topup-from-8", plan["actions"])

    def test_empty_unsent_is_a_hard_fail_action(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_campaign(tmp, sendable=[])
            plan = camp.plan_day(tmp, date(2026, 9, 1))
            self.assertIn("empty-blocked", plan["actions"])
            self.assertTrue(plan["need_leads"])

    def test_weekend_and_abort_and_outside_window(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            people = [{"email": "mac@school.edu", "first_name": "Pat", "company": "School"}]
            write_campaign(tmp, sendable=people, abort=True)
            self.assertIn("abort-file", camp.plan_day(tmp, date(2026, 9, 1))["actions"])
            write_campaign(tmp, sendable=people)
            self.assertIn("weekend-skip", camp.plan_day(tmp, date(2026, 9, 5))["actions"])
            self.assertIn("outside-window", camp.plan_day(tmp, date(2026, 8, 31))["actions"])
            self.assertIn("outside-window", camp.plan_day(tmp, date(2026, 11, 25))["actions"])

    def test_drip_due_after_five_business_days(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_campaign(
                tmp,
                sendable=[],
                contacts={
                    "mac@school.edu": {
                        "first_name": "Pat",
                        "e1_date": "2026-08-28",
                        "e2_date": None,
                        "stop": None,
                    }
                },
            )
            plan = camp.plan_day(tmp, date(2026, 9, 4))
            self.assertEqual(len(plan["e2"]), 1)
            self.assertIn("email-2-1", plan["actions"])


if __name__ == "__main__":
    unittest.main()
