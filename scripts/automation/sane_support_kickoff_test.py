#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


from saneapps_paths import check_inbox_script

REPO_ROOT = Path(__file__).resolve().parents[2]
KICKOFF = REPO_ROOT / "scripts" / "automation" / "sane-support-kickoff.sh"
CHECK_INBOX = check_inbox_script()


def email_row(email_id, *, from_email, subject, status, category="other", body_text=""):
    return {
        "id": email_id,
        "from_email": from_email,
        "from_name": from_email.split("@", 1)[0],
        "subject": subject,
        "status": status,
        "category": category,
        "priority": "normal",
        "created_at": "2026-06-17 14:11:00",
        "body_text": body_text,
        "body_html": "",
        "summary": "",
    }


class SaneSupportKickoffTests(unittest.TestCase):
    def test_high_signal_summary_includes_more_than_needs_reply(self):
        with tempfile.TemporaryDirectory(prefix="sane-support-kickoff-") as tmpdir:
            tmp = Path(tmpdir)
            email_path = tmp / "emails.json"
            resend_path = tmp / "resend.json"
            email_path.write_text(
                json.dumps(
                    {
                        "results": [
                            email_row(
                                886,
                                from_email="dasha.fisun@macpaw.com",
                                subject="Re: Setapp partnership inquiry for SaneBar and SaneClip",
                                status="replied_external",
                                body_text="Please update the icon for both apps according to our guidelines.",
                            ),
                            email_row(
                                874,
                                from_email="no-reply@setapp.com",
                                subject="[Setapp] SaneClip Needs Revision",
                                status="resolved",
                                body_text="Comment from reviewer: The build cannot be opened.",
                            ),
                            email_row(
                                501,
                                from_email="customer@example.com",
                                subject="SaneBar license issue",
                                status="resolved",
                                category="support",
                                body_text="My license key is not working.",
                            ),
                        ]
                    }
                ),
                encoding="utf-8",
            )
            resend_path.write_text(
                json.dumps(
                    {
                        "data": [
                            {
                                "id": "bounce-501",
                                "to": ["customer@example.com"],
                                "subject": "Re: SaneBar license issue",
                                "created_at": "2026-06-17 16:00:00+00",
                                "last_event": "bounced",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(tmp / "home"),
                    "CHECK_INBOX": str(CHECK_INBOX),
                    "CHECK_INBOX_FIXTURE_EMAILS": str(email_path),
                    "CHECK_INBOX_FIXTURE_RESEND": str(resend_path),
                    "CHECK_INBOX_SKIP_GITHUB": "1",
                    "CHECK_INBOX_SKIP_POSITIVE_FEEDBACK": "1",
                    "SANE_NO_KEYCHAIN": "1",
                }
            )

            result = subprocess.run(
                ["bash", str(KICKOFF)],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = result.stdout.split("High-signal support items:", 1)[1]
            self.assertIn("NEEDS REVIEW BEFORE RESOLVE", summary)
            self.assertIn("RESOLVED HIGH-VALUE HISTORY", summary)
            self.assertIn("BOUNCED OUTBOUND", summary)


if __name__ == "__main__":
    unittest.main()
