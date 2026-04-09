#!/usr/bin/env python3
"""Summarize Mini training state and notify locally once per day."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path


REMOTE_SNAPSHOT_SCRIPT = r"""
import csv
import json
import re
from datetime import datetime
from pathlib import Path

BASE = Path.home() / "SaneApps" / "outputs"


def read_last_tsv(path_str):
    path = Path(path_str)
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    return rows[-1] if rows else None


def read_last_metrics(app_name):
    history_dir = BASE / "history" / app_name
    for filename in ("training_metrics_workflow_v1.tsv", "training_metrics.tsv"):
        row = read_last_tsv(history_dir / filename)
        if row:
            return row
    return None


def parse_report(path_str):
    if not path_str:
        return {}
    path = Path(path_str)
    if not path.exists():
        return {"report_exists": False, "report_path": path_str}

    text = path.read_text(encoding="utf-8", errors="ignore")
    result = {"report_exists": True, "report_path": str(path)}
    patterns = {
        "workflow_gate": r"\*\*Workflow gate:\*\*\s*(.+)",
        "workflow_score": r"\*\*Workflow-first score:\*\*\s*(.+)",
        "raw_score": r"\*\*Raw score:\*\*\s*(.+)",
        "result": r"\*\*Result:\*\*\s*(.+)",
        "challenger_result": r"\*\*CHALLENGER RESULT:\s*(.+?)\*\*",
        "decision_hint": r"- Decision hint:\s*(.+)",
        "target_mode": r"- Target baseline mode:\s*(.+)",
        "readiness_status": r"- Status:\s*(.+)",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            result[key] = match.group(1).strip()
    return result


def read_current_alerts():
    alerts = []
    alert_dir = BASE / "alerts" / "training" / "current"
    if not alert_dir.exists():
        return alerts

    for path in sorted(alert_dir.glob("*.md")):
        lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()]
        alerts.append(
            {
                "path": str(path),
                "preview": " | ".join(lines[1:5]),
            }
        )
    return alerts


latest_ai = read_last_metrics("SaneAI")
latest_sync = read_last_metrics("SaneSync")
latest_readiness = read_last_tsv(BASE / "history" / "SaneAI" / "readiness_vs_SaneSync_workflow_v1.tsv")

payload = {
    "generated_at": datetime.now().isoformat(timespec="seconds"),
    "latest_saneai": latest_ai,
    "latest_sanesync": latest_sync,
    "latest_readiness": latest_readiness,
    "latest_saneai_report": parse_report(latest_ai.get("report_archive") if latest_ai else ""),
    "latest_sanesync_report": parse_report(latest_sync.get("report_archive") if latest_sync else ""),
    "current_alerts": read_current_alerts(),
}

print(json.dumps(payload))
"""


def fetch_remote_snapshot(host: str) -> dict:
    ssh_opts = os.environ.get("TRAIN_DAILY_CHECK_SSH_OPTS") or os.environ.get("MINI_SSH_OPTS") or ""
    ssh_cmd = ["ssh"]
    if ssh_opts:
        ssh_cmd.extend(shlex.split(ssh_opts))
    ssh_cmd.extend(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "python3", "-"])

    result = subprocess.run(
        ssh_cmd,
        input=REMOTE_SNAPSHOT_SCRIPT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"ssh exited {result.returncode}")
    return json.loads(result.stdout)


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")


def age_hours(timestamp: str | None) -> int | None:
    dt = parse_timestamp(timestamp)
    if dt is None:
        return None
    return int((datetime.now() - dt).total_seconds() // 3600)


def write_report(report_path: Path, snapshot: dict, summary: str) -> None:
    latest_ai = snapshot.get("latest_saneai") or {}
    latest_sync = snapshot.get("latest_sanesync") or {}
    latest_readiness = snapshot.get("latest_readiness") or {}
    ai_report = snapshot.get("latest_saneai_report") or {}
    sync_report = snapshot.get("latest_sanesync_report") or {}
    alerts = snapshot.get("current_alerts") or []

    lines = [
        "# Training Daily Check",
        "",
        f"Generated at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "",
        "## Summary",
        "",
        summary,
        "",
        "## SaneAI",
        "",
        f"- Timestamp: {latest_ai.get('timestamp', 'missing')}",
        f"- Model: {latest_ai.get('model', 'missing')}",
        f"- Train/valid: {latest_ai.get('train_examples', 'missing')} / {latest_ai.get('valid_examples', 'missing')}",
        f"- Best workflow-first score: {latest_ai.get('best_accuracy', 'missing')}%",
        f"- Workflow gate: {ai_report.get('workflow_gate', 'missing')}",
        f"- Result: {ai_report.get('result', 'missing')}",
        f"- Report: {ai_report.get('report_path', latest_ai.get('report_archive', 'missing'))}",
        "",
        "## SaneSync",
        "",
        f"- Timestamp: {latest_sync.get('timestamp', 'missing')}",
        f"- Mode: {latest_sync.get('mode', 'missing')}",
        f"- Model: {latest_sync.get('model', 'missing')}",
        f"- Best score: {latest_sync.get('best_accuracy', 'missing')}%",
        f"- Report: {sync_report.get('report_path', latest_sync.get('report_archive', 'missing'))}",
        "",
        "## Readiness",
        "",
        f"- Timestamp: {latest_readiness.get('timestamp', 'missing')}",
        f"- Status: {latest_readiness.get('status', 'missing')}",
        f"- Delta: {latest_readiness.get('delta', 'missing')}",
        f"- Source report: {latest_readiness.get('source_report', 'missing')}",
        f"- Target report: {latest_readiness.get('target_report', 'missing') or 'missing'}",
        "",
        "## Active Alerts",
        "",
    ]

    if alerts:
        for alert in alerts:
            lines.append(f"- {alert['path']}: {alert['preview']}")
    else:
        lines.append("- None")

    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_summary(snapshot: dict) -> tuple[str, str]:
    latest_ai = snapshot.get("latest_saneai") or {}
    latest_readiness = snapshot.get("latest_readiness") or {}
    ai_report = snapshot.get("latest_saneai_report") or {}
    alerts = snapshot.get("current_alerts") or []

    ai_score = latest_ai.get("best_accuracy", "?")
    ai_timestamp = latest_ai.get("timestamp")
    ai_age = age_hours(ai_timestamp)
    readiness_status = latest_readiness.get("status", "missing")
    workflow_gate = ai_report.get("workflow_gate", "missing")

    if alerts:
        title = "SaneAI training alert"
        message = f"{len(alerts)} active alert(s). Latest SaneAI score {ai_score}%."
    elif not latest_ai:
        title = "SaneAI training missing"
        message = "No SaneAI training metrics found on the Mini."
    elif ai_age is not None and ai_age > 36:
        title = "SaneAI training stale"
        message = f"Latest SaneAI metric is {ai_age}h old. Check the Mini run."
    elif readiness_status in {"missing_target_baseline", "missing_target_production_baseline"}:
        title = "SaneAI needs baseline"
        message = f"SaneAI {ai_score}% and readiness is blocked: {readiness_status}."
    elif "FAIL" in workflow_gate or ai_report.get("result") == "NEEDS WORK":
        title = "SaneAI needs work"
        message = f"SaneAI is still at {ai_score}% with workflow gate failing."
    else:
        title = "SaneAI daily check"
        message = f"SaneAI latest score {ai_score}%. Readiness: {readiness_status}."

    return title, message


def notify(title: str, message: str) -> None:
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(
        [
            "osascript",
            "-e",
            f'display notification "{safe_message}" with title "{safe_title}" sound name "Sosumi"',
        ],
        check=False,
    )


def main() -> int:
    default_host = os.environ.get("TRAIN_DAILY_CHECK_HOST") or os.environ.get("MINI_HOST") or "mini"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=default_host, help="SSH host for the Mini")
    parser.add_argument("--no-notify", action="store_true", help="Skip the local macOS notification")
    parser.add_argument("--print", action="store_true", dest="print_summary", help="Print the summary after writing the report")
    args = parser.parse_args()

    output_dir = Path.home() / "SaneApps" / "infra" / "SaneProcess" / "outputs"
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "training_daily_check.md"

    try:
      snapshot = fetch_remote_snapshot(args.host)
    except Exception as exc:  # noqa: BLE001
        title = "SaneAI daily check failed"
        message = f"Could not read Mini training state: {exc}"
        report_path.write_text(f"# Training Daily Check\n\n{message}\n", encoding="utf-8")
        if not args.no_notify:
            notify(title, message)
        if args.print_summary:
            print(message)
        return 1

    title, message = build_summary(snapshot)
    write_report(report_path, snapshot, message)

    if not args.no_notify:
        notify(title, message)

    if args.print_summary:
        print(message)
        print(f"Report: {report_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
