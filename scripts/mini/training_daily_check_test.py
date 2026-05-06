#!/usr/bin/env python3
"""Focused tests for training-daily-check.py."""

from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("training-daily-check.py")
spec = importlib.util.spec_from_file_location("training_daily_check", MODULE_PATH)
assert spec is not None
training_daily_check = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(training_daily_check)


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def timestamp_hours_ago(hours):
    return (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")


def snapshot_with_stale_readiness():
    latest_report = "/tmp/current_saneai_report.md"
    old_report = "/tmp/old_saneai_report.md"
    return {
        "latest_saneai": {
            "timestamp": timestamp_hours_ago(4),
            "best_accuracy": "46",
            "report_archive": latest_report,
        },
        "latest_readiness": {
            "timestamp": timestamp_hours_ago(28),
            "status": "missing_target_production_baseline",
            "source_report": old_report,
        },
        "latest_saneai_report": {
            "workflow_gate": "FAIL (mac_operator 4/10, 40%, threshold 50%)",
            "result": "NEEDS WORK",
        },
        "current_alerts": [],
    }


def snapshot_with_current_missing_baseline():
    latest_report = "/tmp/current_saneai_report.md"
    return {
        "latest_saneai": {
            "timestamp": timestamp_hours_ago(4),
            "best_accuracy": "46",
            "report_archive": latest_report,
        },
        "latest_readiness": {
            "timestamp": timestamp_hours_ago(4),
            "status": "missing_target_production_baseline",
            "source_report": latest_report,
        },
        "latest_saneai_report": {
            "workflow_gate": "PASS (mac_operator 6/10, 60%, threshold 50%)",
            "result": "PASS",
        },
        "current_alerts": [],
    }


def test_stale_readiness_does_not_trigger_baseline_alert():
    title, message = training_daily_check.build_summary(snapshot_with_stale_readiness())
    assert_equal(title, "SaneAI needs work", "stale readiness should fall through to current gate state")
    assert "missing_target_production_baseline" not in message


def test_current_readiness_can_trigger_baseline_alert():
    title, message = training_daily_check.build_summary(snapshot_with_current_missing_baseline())
    assert_equal(title, "SaneAI needs baseline", "current readiness should still warn about missing baselines")
    assert "missing_target_production_baseline" in message


def test_missing_readiness_report_is_not_current():
    snapshot = snapshot_with_current_missing_baseline()
    snapshot["latest_readiness"]["source_report"] = ""
    title, message = training_daily_check.build_summary(snapshot)
    assert_equal(title, "SaneAI daily check", "missing readiness source report should not be current")
    assert "missing_target_production_baseline" not in message


if __name__ == "__main__":
    test_stale_readiness_does_not_trigger_baseline_alert()
    test_current_readiness_can_trigger_baseline_alert()
    test_missing_readiness_report_is_not_current()
    print("training_daily_check_test.py: PASS")
