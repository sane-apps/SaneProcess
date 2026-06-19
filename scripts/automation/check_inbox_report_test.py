#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK_INBOX = REPO_ROOT.parent / "scripts" / "check-inbox.sh"


def email_row(
    email_id,
    *,
    from_email,
    subject,
    status,
    category="other",
    created_at="2026-06-17 14:11:00",
    body_text="",
):
    return {
        "id": email_id,
        "from_email": from_email,
        "from_name": from_email.split("@", 1)[0],
        "subject": subject,
        "status": status,
        "category": category,
        "priority": "normal",
        "created_at": created_at,
        "body_text": body_text,
        "body_html": "",
        "summary": "",
    }


class CheckInboxReportTests(unittest.TestCase):
    def run_command(self, args, emails, resend=None, *, reviewed_ids=None):
        with tempfile.TemporaryDirectory(prefix="check-inbox-report-") as tmpdir:
            tmp = Path(tmpdir)
            email_path = tmp / "emails.json"
            resend_path = tmp / "resend.json"
            home = tmp / "home"
            review_dir = home / ".sane" / "email-review"
            review_dir.mkdir(parents=True)
            email_path.write_text(json.dumps({"results": emails}), encoding="utf-8")
            resend_path.write_text(json.dumps(resend or {"data": []}), encoding="utf-8")
            for email_id in reviewed_ids or []:
                (review_dir / f"{email_id}.reviewed").write_text(
                    f"{datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')}\t"
                    "attachments=0\tmedia_expected=0\tmedia_opened=0\tlog_like=0\tlog_reviewed=0\n",
                    encoding="utf-8",
                )

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "CHECK_INBOX_FIXTURE_EMAILS": str(email_path),
                    "CHECK_INBOX_FIXTURE_RESEND": str(resend_path),
                    "CHECK_INBOX_SKIP_GITHUB": "1",
                    "CHECK_INBOX_SKIP_ACTIONS": "1",
                    "CHECK_INBOX_SKIP_POSITIVE_FEEDBACK": "1",
                    "SANE_NO_KEYCHAIN": "1",
                    "INBOX_FETCH_LIMIT": "50",
                }
            )

            result = subprocess.run(
                ["bash", str(CHECK_INBOX), *args],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            return result

    def run_report(self, emails, resend=None):
        result = self.run_command([], emails, resend)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_replied_external_partner_mail_requires_review_without_latest_reply(self):
        output = self.run_report(
            [
                email_row(
                    886,
                    from_email="dasha.fisun@macpaw.com",
                    subject="Re: Setapp partnership inquiry for SaneBar and SaneClip",
                    status="replied_external",
                    body_text=(
                        "Thank you! While it's not a blocker for the release, "
                        "please update the icon for both apps according to our guidelines."
                    ),
                )
            ]
        )

        self.assertIn("NEEDS REVIEW BEFORE RESOLVE", output)
        self.assertIn("#886", output)
        self.assertIn("platform/business review mail", output)
        self.assertNotIn("resolve-batch 886", output)
        self.assertIn("check-inbox.sh review 886", output)

    def test_partner_thread_with_reply_evidence_stays_pending_confirmation(self):
        output = self.run_report(
            [
                email_row(
                    886,
                    from_email="dasha.fisun@macpaw.com",
                    subject="Re: Setapp partnership inquiry for SaneBar and SaneClip",
                    status="pending",
                    body_text="Please update the icon for both apps according to our guidelines.",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "reply-886",
                        "to": ["dasha.fisun@macpaw.com"],
                        "subject": "Re: Setapp partnership inquiry for SaneBar and SaneClip",
                        "created_at": "2026-06-17 16:16:04+00",
                        "last_event": "delivered",
                    }
                ]
            },
        )

        self.assertIn("REPLIED — PENDING CONFIRMATION / REVIEW BEFORE RESOLVE", output)
        self.assertIn("#886", output)
        self.assertNotIn("resolve-batch 886", output)

    def test_low_risk_replied_thread_is_cleanup_candidate_but_not_batch_command(self):
        output = self.run_report(
            [
                email_row(
                    901,
                    from_email="bot@example.com",
                    subject="Routine notification",
                    status="pending",
                    category="other",
                    body_text="Routine notification acknowledged.",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "reply-901",
                        "to": ["bot@example.com"],
                        "subject": "Re: Routine notification",
                        "created_at": "2026-06-17 16:00:00+00",
                        "last_event": "delivered",
                    }
                ]
            },
        )

        self.assertIn("LOW-RISK DELIVERED REPLY FOUND AFTER LATEST INBOUND", output)
        self.assertIn("check-inbox.sh review 901", output)
        self.assertNotIn("resolve-batch 901", output)

    def test_resolved_setapp_review_blocker_is_not_silently_skipped(self):
        output = self.run_report(
            [
                email_row(
                    874,
                    from_email="no-reply@setapp.com",
                    subject="[Setapp] SaneClip Needs Revision",
                    status="resolved",
                    category="other",
                    body_text=(
                        "Comment from reviewer: The build cannot be opened. "
                        "Please fix this and reapply."
                    ),
                )
            ]
        )

        self.assertIn("RESOLVED HIGH-VALUE HISTORY", output)
        self.assertIn("#874", output)
        self.assertIn("Reviewer blocker", output)

    def test_classification_audit_accepts_platform_review_without_support_priority(self):
        result = self.run_command(
            ["classification-audit", "50"],
            [
                email_row(
                    886,
                    from_email="dasha.fisun@macpaw.com",
                    subject="Re: Setapp partnership inquiry for SaneBar and SaneClip",
                    status="pending",
                    category="other",
                    body_text=(
                        "Thank you! While it's not a blocker for the release, "
                        "please update the icon for both apps according to our guidelines."
                    ),
                )
            ],
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Platform review blocker surfaced", result.stdout)
        self.assertIn("weaknesses=0", result.stdout)
        self.assertNotIn("not high-priority support", result.stdout)

    def test_resolved_support_thread_with_latest_bounce_stays_visible(self):
        output = self.run_report(
            [
                email_row(
                    501,
                    from_email="customer@example.com",
                    subject="SaneBar license issue",
                    status="resolved",
                    category="support",
                    body_text="My license key is not working.",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "bounce-501",
                        "to": ["customer@example.com"],
                        "subject": "Re: SaneBar license issue",
                        "created_at": "2026-06-17 16:00:00+00",
                        "last_event": "bounced",
                    }
                ]
            },
        )

        self.assertIn("BOUNCED OUTBOUND", output)
        self.assertIn("#501", output)
        self.assertNotIn("All emails handled", output)

    def test_broad_subject_overlap_does_not_create_cleanup_candidate(self):
        output = self.run_report(
            [
                email_row(
                    601,
                    from_email="customer@example.com",
                    subject="Question",
                    status="pending",
                    category="other",
                    body_text="Question",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "unrelated-601",
                        "to": ["customer@example.com"],
                        "subject": "Re: Question about sponsorship",
                        "created_at": "2026-06-17 16:00:00+00",
                        "last_event": "delivered",
                    }
                ]
            },
        )

        self.assertIn("NEEDS REPLY TO LATEST MESSAGE", output)
        self.assertIn("#601", output)
        self.assertNotIn("LOW-RISK DELIVERED REPLY FOUND", output)

    def test_needs_reply_lists_latest_open_row_once_per_thread(self):
        output = self.run_report(
            [
                email_row(
                    610,
                    from_email="partner@example.com",
                    subject="Setapp review",
                    status="pending",
                    created_at="2026-06-17 12:00:00",
                    body_text="Older message.",
                ),
                email_row(
                    611,
                    from_email="partner@example.com",
                    subject="Re: Setapp review",
                    status="needs_human",
                    created_at="2026-06-17 14:00:00",
                    body_text="Newest message.",
                ),
            ]
        )

        self.assertIn("NEEDS REPLY TO LATEST MESSAGE", output)
        self.assertIn("#611", output)
        self.assertNotIn("#610", output)

    def test_resolve_blocks_stale_replied_external_without_latest_reply(self):
        result = self.run_command(
            ["resolve", "886"],
            [
                email_row(
                    886,
                    from_email="dasha.fisun@macpaw.com",
                    subject="Re: Setapp partnership inquiry for SaneBar and SaneClip",
                    status="replied_external",
                    body_text="Please update the icon for both apps according to our guidelines.",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "old-886",
                        "to": ["dasha.fisun@macpaw.com"],
                        "subject": "Re: Setapp partnership inquiry for SaneBar and SaneClip",
                        "created_at": "2026-06-17 13:00:00+00",
                        "last_event": "delivered",
                    }
                ]
            },
            reviewed_ids=[886],
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BLOCKED", result.stdout)
        self.assertIn("latest inbound", result.stdout)

    def test_resolve_blocks_older_row_when_newer_same_thread_auto_reply_is_unanswered(self):
        result = self.run_command(
            ["resolve", "700"],
            [
                email_row(
                    700,
                    from_email="customer@example.com",
                    subject="License problem",
                    status="replied_external",
                    category="support",
                    created_at="2026-06-17 12:00:00",
                    body_text="I have a license problem.",
                ),
                email_row(
                    701,
                    from_email="customer@example.com",
                    subject="Re: License problem",
                    status="auto_replied",
                    category="support",
                    created_at="2026-06-17 14:00:00",
                    body_text="This still is not fixed.",
                ),
            ],
            resend={
                "data": [
                    {
                        "id": "old-700",
                        "to": ["customer@example.com"],
                        "subject": "Re: License problem",
                        "created_at": "2026-06-17 13:00:00+00",
                        "last_event": "delivered",
                    }
                ]
            },
            reviewed_ids=[700],
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BLOCKED", result.stdout)

    def test_check_reply_separates_strict_thread_proof_from_address_history(self):
        result = self.run_command(
            ["check-reply", "601"],
            [
                email_row(
                    601,
                    from_email="customer@example.com",
                    subject="Question",
                    status="pending",
                    category="other",
                    body_text="Question",
                )
            ],
            resend={
                "data": [
                    {
                        "id": "unrelated-601",
                        "to": ["customer@example.com"],
                        "subject": "Re: Question about sponsorship",
                        "created_at": "2026-06-17 16:00:00+00",
                        "last_event": "delivered",
                    }
                ]
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No strict thread-matched Resend evidence", result.stdout)
        self.assertIn("address history, not proof", result.stdout)


if __name__ == "__main__":
    unittest.main()
