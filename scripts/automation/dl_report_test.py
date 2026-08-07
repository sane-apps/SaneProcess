#!/usr/bin/env python3
"""Behavior tests for dimension-aware direct-app funnel reporting."""

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from datetime import datetime as RealDateTime
from datetime import timezone
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("dl-report.py")
SPEC = importlib.util.spec_from_file_location("dl_report", MODULE_PATH)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class FixedDateTime(RealDateTime):
    @classmethod
    def now(cls, tz=None):
        value = cls(2026, 7, 19, 12, 0, 0, tzinfo=timezone.utc)
        return value if tz is not None else value.replace(tzinfo=None)


EVENTS = [
    {"app": "saneclip", "event": "checkout_clicked", "date": "2026-07-19", "count": 1073},
    {"app": "saneclip", "event": "website_checkout_redirected", "date": "2026-07-19", "count": 7},
    {"app": "saneclip", "event": "license_activated", "date": "2026-07-19", "count": 4},
]

EVENT_DIMENSIONS = [
    {
        "app": "saneclip", "event": "checkout_clicked", "date": "2026-07-19", "count": 1000,
        "platform": "web", "channel": "website",
    },
    {
        "app": "saneclip", "event": "checkout_clicked", "date": "2026-07-19", "count": 3,
        "platform": "macos", "channel": "direct",
    },
    {
        "app": "saneclip", "event": "checkout_clicked", "date": "2026-07-12", "count": 2,
        "platform": "macos", "channel": "direct",
    },
    {
        "app": "saneclip", "event": "checkout_clicked", "date": "2026-07-19", "count": 50,
        "platform": "macos", "channel": "app_store",
    },
    {
        "app": "saneclip", "event": "checkout_clicked", "date": "2026-07-19", "count": 20,
        "platform": "unknown", "channel": "unknown",
    },
    {
        "app": "saneclip", "event": "website_checkout_redirected", "date": "2026-07-19", "count": 7,
        "platform": "web", "channel": "website",
    },
]


class DirectAppFunnelReportTests(unittest.TestCase):
    def setUp(self):
        REPORT.datetime = FixedDateTime

    def render_main(self, data, *arguments):
        output = io.StringIO()
        with mock.patch.object(REPORT, "get_api_key", return_value="test-key"), \
                mock.patch.object(REPORT, "fetch_stats", return_value=data), \
                mock.patch.object(sys, "argv", ["dl-report.py", *arguments]), \
                contextlib.redirect_stdout(output):
            REPORT.main()
        return output.getvalue()

    def test_direct_clicks_use_only_macos_direct_dimensions(self):
        output = self.render_main(
            {"events": EVENTS, "event_dimensions": EVENT_DIMENSIONS},
            "--events", "--days", "7",
        )

        direct_line = next(line for line in output.splitlines() if line.startswith("checkout_clicked"))
        redirect_line = next(
            line for line in output.splitlines() if line.startswith("website_checkout_redirected")
        )

        self.assertEqual(direct_line.split(), ["checkout_clicked", "3", "3", "5"])
        self.assertEqual(redirect_line.split(), ["website_checkout_redirected", "7", "7", "7"])
        self.assertIn("Last 7d", output)
        self.assertIn(
            "excluded 1000 legacy web/website checkout_clicked events from direct checkout totals",
            output,
        )
        self.assertNotIn("1073", direct_line)

    def test_json_output_remains_raw_and_backward_compatible(self):
        data = {
            "days": 7,
            "events": EVENTS,
            "event_dimensions": EVENT_DIMENSIONS,
            "custom_future_field": {"preserved": True},
        }
        output = self.render_main(data, "--json", "--days", "7")
        self.assertEqual(json.loads(output), data)


if __name__ == "__main__":
    unittest.main()
