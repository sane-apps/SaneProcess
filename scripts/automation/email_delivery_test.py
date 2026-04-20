#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("email_delivery.py")
SCRIPT_SPEC = importlib.util.spec_from_file_location("email_delivery", SCRIPT_PATH)
EMAIL_DELIVERY = importlib.util.module_from_spec(SCRIPT_SPEC)
assert SCRIPT_SPEC.loader is not None
SCRIPT_SPEC.loader.exec_module(EMAIL_DELIVERY)


class EmailDeliveryTests(unittest.TestCase):
    def test_summary_counts_related_delivered_and_bounced_events(self):
        payload = {
            "data": [
                {
                    "id": "old-unrelated",
                    "to": ["customer@example.com"],
                    "subject": "Re: Something else",
                    "created_at": "2026-04-10 09:00:00+00",
                    "last_event": "delivered",
                },
                {
                    "id": "bounce-1",
                    "to": ["Customer <customer@example.com>"],
                    "subject": "Re: Startup submit issue",
                    "created_at": "2026-04-10 19:01:50+00",
                    "last_event": "bounced",
                },
                {
                    "id": "deliver-1",
                    "to": ["customer@example.com"],
                    "subject": "Fwd: Re: Startup submit issue",
                    "created_at": "2026-04-10 19:05:00+00",
                    "last_event": "delivered",
                },
                {
                    "id": "pending-1",
                    "to": ["customer@example.com"],
                    "subject": "Re: Startup submit issue",
                    "created_at": "2026-04-10 19:06:00+00",
                    "last_event": "queued",
                },
            ]
        }

        summary = EMAIL_DELIVERY.summarize_related_events(
            "customer@example.com",
            "Startup submit issue",
            "2026-04-10 19:00:00+00",
            payload,
        )
        indexed_summary = EMAIL_DELIVERY.summarize_related_events(
            "customer@example.com",
            "Startup submit issue",
            "2026-04-10 19:00:00+00",
            payload,
            EMAIL_DELIVERY.build_recipient_index(payload),
        )

        self.assertEqual(summary["bounced"], 1)
        self.assertEqual(summary["delivered"], 1)
        self.assertEqual(summary["pending"], 1)
        self.assertEqual([row["id"] for row in summary["rows"]], ["bounce-1", "deliver-1", "pending-1"])
        self.assertEqual(indexed_summary, summary)

    def test_bounced_only_thread_has_no_delivery_evidence(self):
        payload = {
            "data": [
                {
                    "id": "bounce-1",
                    "to": ["customer@example.com"],
                    "subject": "Re: Requesting Refund of Sanebar",
                    "created_at": "2026-01-30 03:43:24+00",
                    "last_event": "bounced",
                }
            ]
        }

        summary = EMAIL_DELIVERY.summarize_related_events(
            "customer@example.com",
            "Requesting Refund of Sanebar",
            "2026-01-30 03:40:00+00",
            payload,
        )

        self.assertEqual(summary["delivered"], 0)
        self.assertEqual(summary["bounced"], 1)
        self.assertEqual(summary["pending"], 0)

    def test_open_thread_delivery_evidence_counts_only_open_non_spam_threads(self):
        rows = [
            {
                "id": 101,
                "status": "needs_human",
                "category": "support",
                "from_email": "customer@example.com",
                "subject": "Startup submit issue",
                "created_at": "2026-04-10 19:00:00+00",
            },
            {
                "id": 102,
                "status": "resolved",
                "category": "support",
                "from_email": "resolved@example.com",
                "subject": "Already handled",
                "created_at": "2026-04-10 19:00:00+00",
            },
            {
                "id": 103,
                "status": "new",
                "category": "spam",
                "from_email": "spam@example.com",
                "subject": "Buy now",
                "created_at": "2026-04-10 19:00:00+00",
            },
            {
                "id": 104,
                "status": "pending",
                "category": "support",
                "from_email": "other@example.com",
                "subject": "Another thread",
                "created_at": "2026-04-10 21:00:00+00",
            },
        ]
        payload = {
            "data": [
                {
                    "id": "deliver-1",
                    "to": ["customer@example.com"],
                    "subject": "Re: Startup submit issue",
                    "created_at": "2026-04-10 19:05:00+00",
                    "last_event": "delivered",
                },
                {
                    "id": "deliver-2",
                    "to": ["other@example.com"],
                    "subject": "Re: Another thread",
                    "created_at": "2026-04-10 21:05:00+00",
                    "last_event": "delivered",
                },
                {
                    "id": "pending-1",
                    "to": ["other@example.com"],
                    "subject": "Re: Another thread",
                    "created_at": "2026-04-10 21:06:00+00",
                    "last_event": "queued",
                },
            ]
        }

        recipient_index = EMAIL_DELIVERY.build_recipient_index(payload)
        evidence = EMAIL_DELIVERY.open_thread_delivery_evidence(rows, payload, recipient_index)

        self.assertEqual(evidence, {101: 1, 104: 1})


if __name__ == "__main__":
    unittest.main()
