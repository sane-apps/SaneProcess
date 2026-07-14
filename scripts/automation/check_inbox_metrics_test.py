#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


from saneapps_paths import check_inbox_script

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK_INBOX = check_inbox_script()


class CheckInboxMetricsTests(unittest.TestCase):
    def test_support_send_metric_is_written_without_recipient_pii(self):
        with tempfile.TemporaryDirectory(prefix="check-inbox-metrics-") as tmpdir:
            metrics_path = Path(tmpdir) / "process_metrics.jsonl"
            env = os.environ.copy()
            env["SANEMASTER_PROCESS_METRICS_PATH"] = str(metrics_path)

            result = subprocess.run(
                ["bash", str(CHECK_INBOX), "__record-metric-test"],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            rows = metrics_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(rows), 1)

            event = json.loads(rows[0])
            self.assertEqual(event["type"], "support_send")
            self.assertEqual(event["project"], "check-inbox")
            self.assertEqual(event["channel"], "compose")
            self.assertEqual(event["success"], True)
            self.assertEqual(event["recipient_present"], True)
            self.assertNotIn("to", event)
            self.assertNotIn("subject", event)


if __name__ == "__main__":
    unittest.main()
