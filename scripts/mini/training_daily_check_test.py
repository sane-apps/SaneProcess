#!/usr/bin/env python3
"""Focused tests for training-daily-check.py."""

from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory


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


def snapshot_with_watchdog_reset_and_stale_lock():
    snapshot = snapshot_with_current_missing_baseline()
    snapshot["latest_readiness"]["status"] = "ready"
    snapshot["latest_saneai_report"]["workflow_gate"] = "PASS (mac_operator 8/10, 80%, threshold 50%)"
    snapshot["latest_saneai_report"]["result"] = "PASS"
    snapshot["training_lock"] = {
        "exists": True,
        "path": "/tmp/.training_mlx.lock",
        "stale": True,
        "active_training_process": False,
    }
    snapshot["recent_system_reset"] = {
        "watchdog_reset": True,
        "panic_string": "panic(cpu 1 caller ...): watchdog timeout",
        "panic_log_path": "/Library/Logs/DiagnosticReports/panic-full-test.panic",
        "latest_reset_path": "/Library/Logs/DiagnosticReports/ResetCounter-test.diag",
    }
    return snapshot


def test_stale_readiness_does_not_trigger_baseline_alert():
    title, message = training_daily_check.build_summary(snapshot_with_stale_readiness())
    assert_equal(title, "SaneAI needs work", "stale readiness should fall through to current gate state")
    assert "missing_target_production_baseline" not in message
    action = training_daily_check.build_action(snapshot_with_stale_readiness())
    assert "Do not promote" in action


def test_current_readiness_can_trigger_baseline_alert():
    title, message = training_daily_check.build_summary(snapshot_with_current_missing_baseline())
    assert_equal(title, "SaneAI needs baseline", "current readiness should still warn about missing baselines")
    assert "missing_target_production_baseline" in message
    action = training_daily_check.build_action(snapshot_with_current_missing_baseline())
    assert "Record the missing target baseline" in action


def test_missing_readiness_report_is_not_current():
    snapshot = snapshot_with_current_missing_baseline()
    snapshot["latest_readiness"]["source_report"] = ""
    title, message = training_daily_check.build_summary(snapshot)
    assert_equal(title, "SaneAI daily check", "missing readiness source report should not be current")
    assert "missing_target_production_baseline" not in message


def test_active_alert_overrides_green_gate():
    snapshot = snapshot_with_current_missing_baseline()
    snapshot["latest_readiness"]["status"] = "ready"
    snapshot["latest_saneai_report"]["workflow_gate"] = "PASS (mac_operator 8/10, 80%, threshold 50%)"
    snapshot["latest_saneai_report"]["result"] = "PASS"
    snapshot["current_alerts"] = [{"path": "/tmp/alert.md", "preview": "adapter regression"}]

    title, message = training_daily_check.build_summary(snapshot)
    action = training_daily_check.build_action(snapshot)

    assert_equal(title, "SaneAI training alert", "active alert should win over green score")
    assert "1 active alert" in message
    assert "active training alerts first" in action


def test_watchdog_reset_and_stale_lock_override_green_gate():
    title, message = training_daily_check.build_summary(snapshot_with_watchdog_reset_and_stale_lock())
    action = training_daily_check.build_action(snapshot_with_watchdog_reset_and_stale_lock())

    assert_equal(title, "SaneAI training interrupted", "watchdog reset should override a green score")
    assert "watchdog reset" in message.lower()
    assert "lower-pressure staged SaneAI lane" in action


def test_write_report_records_current_readiness_and_alerts():
    snapshot = snapshot_with_current_missing_baseline()
    snapshot["current_alerts"] = [{"path": "/tmp/alert.md", "preview": "adapter regression"}]

    with TemporaryDirectory() as tmpdir:
        report_path = Path(tmpdir) / "training_daily_check.md"
        training_daily_check.write_report(report_path, snapshot, "summary text", "action text")
        report = report_path.read_text(encoding="utf-8")

    assert "summary text" in report
    assert "action text" in report
    assert "- Applies to latest SaneAI run: True" in report
    assert "## Mini System" in report
    assert "/tmp/alert.md: adapter regression" in report


if __name__ == "__main__":
    test_stale_readiness_does_not_trigger_baseline_alert()
    test_current_readiness_can_trigger_baseline_alert()
    test_missing_readiness_report_is_not_current()
    test_active_alert_overrides_green_gate()
    test_watchdog_reset_and_stale_lock_override_green_gate()
    test_write_report_records_current_readiness_and_alerts()
    print("training_daily_check_test.py: PASS")
