#!/usr/bin/env python3
import json
import http.server
import importlib.util
import os
import socketserver
import subprocess
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path


from saneapps_paths import check_inbox_script

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK_INBOX = check_inbox_script()
CAMPAIGN_AUDIT_PATH = check_inbox_script().parent / "campaign_audit.py"
CAMPAIGN_AUDIT_SPEC = importlib.util.spec_from_file_location("campaign_audit", CAMPAIGN_AUDIT_PATH)
campaign_audit = importlib.util.module_from_spec(CAMPAIGN_AUDIT_SPEC)
assert CAMPAIGN_AUDIT_SPEC and CAMPAIGN_AUDIT_SPEC.loader
CAMPAIGN_AUDIT_SPEC.loader.exec_module(campaign_audit)


def email_row(
    email_id,
    *,
    from_email,
    subject,
    status,
    category="other",
    created_at="2026-06-17 14:11:00",
    body_text="",
    body_html="",
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
        "body_html": body_html,
        "summary": "",
    }


class CheckInboxReportTests(unittest.TestCase):
    def test_campaign_audit_paginates_and_matches_replies_without_counting_canceled_rows(self):
        calls = []

        def fetch(url, _headers):
            calls.append(url)
            if "api.resend.com" in url:
                if "after=send-1" in url:
                    return {"data": [{"id": "send-2", "subject": "A", "created_at": "2026-07-16T12:00:00Z", "last_event": "canceled", "to": ["canceled@example.com"]}], "has_more": False}
                return {"data": [{"id": "send-1", "subject": "A", "created_at": "2026-07-16T12:00:00Z", "last_event": "delivered", "to": ["reply@example.com"]}], "has_more": True}
            return {"results": [{"from_email": "reply@example.com", "subject": "Re: A", "body_text": "Please unsubscribe me"}]}

        report = campaign_audit.build_report(
            campaign_audit.fetch_resend_pages(fetch, "resend-key"),
            campaign_audit.fetch_inbox_pages(fetch, "https://email.example.test", "inbox-key"),
            {"A"},
            campaign_audit.parse_time("2026-07-16"),
        )

        self.assertEqual(report["matching_records"], 2)
        self.assertEqual(report["recipient_count"], 1)
        self.assertEqual(report["inbound_sender_count"], 1)
        self.assertEqual(report["unsubscribe_count"], 1)
        self.assertEqual(report["unsubscribe_email_ids"], [])
        self.assertEqual(report["unsubscribe_recipients"], ["reply@example.com"])
        self.assertEqual(report["last_event_counts"], {"canceled": 1, "delivered": 1})
        self.assertEqual(sum("api.resend.com" in url for url in calls), 2)

    def test_campaign_audit_filters_named_arm_windows_and_counts_safe_overlaps(self):
        def resend_row(email_id, subject, scheduled_at, last_event, recipient):
            return {
                "id": email_id,
                "subject": subject,
                "created_at": "2026-07-26T12:00:00Z",
                "scheduled_at": scheduled_at,
                "last_event": last_event,
                "to": [recipient],
            }

        with tempfile.TemporaryDirectory(prefix="campaign-suppression-") as tmpdir:
            campaign_opt_outs = Path(tmpdir) / "campaign-opt-outs.json"
            bounce_complaints = Path(tmpdir) / "bounce-complaints.txt"
            campaign_opt_outs.write_text('[{"name":"campaign-opt-out:blocked@example.net"}]', encoding="utf-8")
            bounce_complaints.write_text("suppressed:duplicate@example.com\n", encoding="utf-8")
            suppression_sets = campaign_audit.load_suppression_files(
                [
                    f"campaign_opt_out={campaign_opt_outs}",
                    f"bounce_complaint={bounce_complaints}",
                ]
            )

        report = campaign_audit.build_arm_window_report(
            [
                resend_row("a-1", "Subject A", "2026-07-27T14:00:00Z", "scheduled", "duplicate@example.com"),
                resend_row("a-2", "Subject A", "2026-07-27T15:00:00Z", "scheduled", "duplicate@example.com"),
                resend_row("a-3", "Subject A", "2026-07-27T16:00:00Z", "canceled", "canceled@example.com"),
                resend_row("a-4", "Subject A", "2026-07-28T01:00:00Z", "scheduled", "edge@example.net"),
                resend_row("a-5", "Subject A", "2026-07-28T14:00:00Z", "scheduled", "outside@example.org"),
                resend_row("b-1", "Subject B", "2026-07-28T14:00:00Z", "delivered", "shared@example.org"),
                resend_row("b-2", "Subject B", "2026-07-29T14:00:00Z", "bounced", "blocked@example.net"),
                resend_row("b-3", "Subject B", "2026-07-30T14:00:00Z", "scheduled", "duplicate@example.com"),
            ],
            [
                {"from_email": "duplicate@example.com", "subject": "Re: A", "body_text": "Please unsubscribe me"},
                {"from_email": "duplicate@example.com", "subject": "Re: A", "body_text": "Following up"},
                {"from_email": "shared@example.org", "subject": "Re: B", "body_text": "Thanks"},
            ],
            {"A_generic_sales": "Subject A", "B_named_sales": "Subject B"},
            campaign_audit.parse_arm_windows(
                [
                    "A_generic_sales=2026-07-27",
                    "B_named_sales=2026-07-28..2026-07-31",
                ]
            ),
            campaign_audit.parse_time("2026-07-26"),
            "America/New_York",
            suppression_sets,
        )

        arm_a = report["arms"]["A_generic_sales"]
        self.assertEqual(arm_a["matching_records"], 4)
        self.assertEqual(arm_a["excluded_canceled_records"], 1)
        self.assertEqual(arm_a["active_records"], 3)
        self.assertEqual(arm_a["unique_recipients"], 2)
        self.assertEqual(arm_a["duplicate_recipients"], 1)
        self.assertEqual(arm_a["duplicate_records"], 1)
        self.assertEqual(arm_a["last_event_counts"], {"scheduled": 3})
        self.assertEqual(arm_a["suppression_overlap_counts"], {"bounce_complaint": 1, "campaign_opt_out": 0})
        self.assertEqual(arm_a["inbox_sender_overlap"], 1)
        self.assertEqual(arm_a["inbox_message_overlap"], 2)
        self.assertEqual(arm_a["unsubscribe_sender_overlap"], 1)

        totals = report["totals"]
        self.assertEqual(totals["active_records"], 6)
        self.assertEqual(totals["unique_recipients"], 4)
        self.assertEqual(totals["duplicate_recipients"], 1)
        self.assertEqual(totals["duplicate_records"], 2)
        self.assertEqual(totals["cross_arm_recipient_overlap"], 1)
        self.assertEqual(totals["cross_arm_domain_overlap"], 2)
        self.assertEqual(totals["suppression_overlap_counts"], {"bounce_complaint": 1, "campaign_opt_out": 1})
        self.assertEqual(totals["inbox_sender_overlap"], 2)
        self.assertEqual(totals["inbox_message_overlap"], 3)
        self.assertEqual(totals["unsubscribe_sender_overlap"], 1)

    def run_validate_email_format(self, body, email):
        source = CHECK_INBOX.read_text(encoding="utf-8")
        start = source.index("validate_email_format() {")
        end = source.index("\nemail_body_sha256() {", start)
        function_source = source[start:end]

        with tempfile.TemporaryDirectory(prefix="check-inbox-signature-") as tmpdir:
            tmp = Path(tmpdir)
            body_file = tmp / "body.txt"
            body_file.write_text(body, encoding="utf-8")
            script = f"""
curl() {{ printf '%s' "$SANE_TEST_EMAIL_META"; }}
AUTH=test
API_BASE=https://email.example.invalid
EMAIL_FORMAT_OVERRIDE={tmp / 'no-format-override'}
{function_source}
validate_email_format {body_file} {email['id']}
"""
            env = os.environ.copy()
            env["SANE_TEST_EMAIL_META"] = json.dumps(email)
            return subprocess.run(
                ["bash", "-c", script],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def test_business_correspondence_rejects_customer_alias_signature(self):
        body = """Thanks for following up.\n\nHere are the requested details.\n\nMr. Sane\nhttps://saneapps.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1115,
                from_email="verifymyaccount@twilio.zendesk.com",
                subject="Twilio Account Verification - Action Required",
                status="needs_human",
            ),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Business/vendor correspondence", result.stdout)

    def test_business_correspondence_accepts_complete_real_name_signature(self):
        body = """Thanks for following up.\n\nHere are the requested details.\n\nStephan Joseph\nFounder, SaneApps / SaneLot\n727-758-9785\nhi@saneapps.com\nhttps://sanelot.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1124,
                from_email="support@vinaudit.com",
                subject="Following up on my SaneLot API inquiry",
                status="needs_human",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_twilio_compliance_support_category_accepts_business_signature(self):
        body = """Thanks for following up.\n\nHere are the requested details.\n\nStephan Joseph\nFounder, SaneApps / SaneLot\n727-758-9785\nhi@saneapps.com\nhttps://sanelot.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1158,
                from_email="verifymyaccount@twilio.zendesk.com",
                subject="Twilio Account Verification - Action Required",
                status="needs_human",
                category="support",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_generic_support_category_keeps_customer_signature_lane(self):
        body = """Thanks for the report.\n\nI am reviewing it. Thanks again.\n\nMr. Sane\nhttps://saneapps.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1159,
                from_email="support@customer-company.example",
                subject="SaneClip issue",
                status="needs_human",
                category="support",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_business_correspondence_accepts_any_product_lane_signature(self):
        # Owner ruling 2026-07-15: ONE business signature template that works
        # for every product lane, not just SaneLot/SaneCite.
        body = """Thanks for following up.\n\nHere are the requested partnership details.\n\nStephan Joseph\nFounder, SaneApps / SaneClip\n727-758-9785\nhi@saneapps.com\nhttps://saneclip.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1125,
                from_email="partnerships@setapp.com",
                subject="SaneClip partnership question",
                status="needs_human",
                category="sales",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_business_correspondence_rejects_retired_sanecite_founder_variant(self):
        # Retired 2026-07-15: "SaneCite Founder" role line, "(727) 758-9785"
        # phone format, and the missing email line must keep failing.
        body = """Thanks for following up.\n\nHere are the requested details.\n\nStephan Joseph\nSaneCite Founder\n(727) 758-9785\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1126,
                from_email="partnerships@setapp.com",
                subject="SaneCite partnership question",
                status="needs_human",
                category="sales",
            ),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Business/vendor correspondence", result.stdout)

    def test_business_correspondence_rejects_retired_paren_phone_format(self):
        body = """Thanks for following up.\n\nHere are the requested details.\n\nStephan Joseph\nFounder, SaneApps / SaneCite\n(727) 758-9785\nhi@saneapps.com\nhttps://sanecite.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1127,
                from_email="partnerships@setapp.com",
                subject="SaneCite partnership question",
                status="needs_human",
                category="sales",
            ),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Business/vendor correspondence", result.stdout)

    def test_customer_support_rejects_real_name_business_signature(self):
        body = """Thanks for the detailed report.\n\nPlease test the update. Thanks again.\n\nStephan Joseph\nFounder, SaneApps / SaneLot\n727-758-9785\nhi@saneapps.com\nhttps://sanelot.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1083,
                from_email="customer@outlook.com",
                subject="SaneClip issue",
                status="needs_human",
                category="bug",
            ),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("customer/support correspondence", result.stdout)

    def test_customer_support_accepts_mr_sane_signature(self):
        body = """Thanks for the detailed report.\n\nPlease test the update. Thanks again.\n\nMr. Sane\nhttps://saneapps.com\n"""
        result = self.run_validate_email_format(
            body,
            email_row(
                1083,
                from_email="customer@outlook.com",
                subject="SaneClip issue",
                status="needs_human",
                category="bug",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_open_review_media(self, opener_exit, *, explicit_host=True, local_hostname=None):
        source = CHECK_INBOX.read_text(encoding="utf-8")
        start = source.index("default_review_media_host() {")
        end = source.index("\n}\n\nrequire_spam_safe_to_mark", start) + 2
        function_source = source[start:end]

        with tempfile.TemporaryDirectory(prefix="check-inbox-open-media-") as tmpdir:
            tmp = Path(tmpdir)
            media = tmp / "evidence.mp4"
            media.write_bytes(b"synthetic-media")
            opener = tmp / "open-stub"
            opener.write_text(
                f"#!/bin/sh\nprintf 'OPEN_ARGS:%s\\n' \"$*\"\nexit {opener_exit}\n",
                encoding="utf-8",
            )
            opener.chmod(0o755)
            script = f"{function_source}\nopen_review_media MEDIA {media!s}\n"
            env = {
                **os.environ,
                "SANE_OPEN_COMMAND": str(opener),
            }
            if explicit_host:
                env["SANE_REVIEW_MEDIA_HOST"] = "local"
            else:
                env.pop("SANE_REVIEW_MEDIA_HOST", None)
            if local_hostname is not None:
                env["SANE_LOCAL_HOSTNAME"] = local_hostname
            return subprocess.run(
                ["bash", "-c", script],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def test_failed_local_media_open_fails_closed(self):
        result = self.run_open_review_media(7)
        self.assertEqual(result.returncode, 1)
        self.assertIn("MEDIA OPEN FAILED", result.stdout)
        self.assertNotIn("OPENED LOCALLY", result.stdout)

    def test_successful_local_media_open_is_recorded(self):
        result = self.run_open_review_media(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OPEN_ARGS:-a QuickTime Player", result.stdout)
        self.assertIn("MEDIA OPENED LOCALLY: 1 file(s)", result.stdout)

    def test_mini_defaults_to_local_media_open_without_ssh_loopback(self):
        result = self.run_open_review_media(
            0,
            explicit_host=False,
            local_hostname="Stephans-Mac-mini",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MEDIA OPENED LOCALLY: 1 file(s)", result.stdout)

    def run_linked_media_extractor(self, email):
        source = CHECK_INBOX.read_text(encoding="utf-8")
        marker = 'LINK_MEDIA_OUTPUT=$(EMAIL_ID="$EMAIL_ID" DEST="$LINK_DEST" python3 - "$EMAIL_JSON_FILE" <<\'PYEOF\'\n'
        start = source.index(marker) + len(marker)
        end = source.index("\nPYEOF\n)", start)
        extractor = source[start:end]

        with tempfile.TemporaryDirectory(prefix="check-inbox-linked-media-") as tmpdir:
            tmp = Path(tmpdir)
            email_path = tmp / "email.json"
            dest = tmp / "linked-media"
            email_path.write_text(json.dumps({"email": email}), encoding="utf-8")
            env = os.environ.copy()
            env.update({"EMAIL_ID": str(email["id"]), "DEST": str(dest)})
            result = subprocess.run(
                ["python3", "-", str(email_path)],
                input=extractor,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            files = {path.name: path.read_bytes() for path in dest.glob("*")} if dest.exists() else {}
            return result, files

    def test_review_does_not_treat_remote_html_decorations_as_customer_evidence(self):
        html_assets = """\
        <a href="https://app.intercom.com/ratings?rating_index=1">
          <img src="https://apollo.example/rating-1-60x60.png">
        </a>
        <img src="https://twilio.example/default-avatar-80.png">
        <img src="https://images.macpaw.example/macpaw-logo-grey.png">
        <img src="https://vendor.example/signature-emoji.gif">
        <img src="https://vendor.example/tracking-pixel.gif">
        """
        result, files = self.run_linked_media_extractor(
            email_row(
                1200,
                from_email="vendor@example.com",
                subject="Routine vendor reply",
                status="needs_human",
                body_text="Thanks for the update.",
                body_html=html_assets,
            )
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(files, {})

    def test_review_downloads_media_link_explicitly_present_in_plain_text(self):
        payload = b"customer-video-evidence"

        class EvidenceHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, _format, *_args):
                return

        with socketserver.TCPServer(("127.0.0.1", 0), EvidenceHandler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            port = server.server_address[1]
            result, files = self.run_linked_media_extractor(
                email_row(
                    1201,
                    from_email="customer@example.com",
                    subject="Video of the problem",
                    status="needs_human",
                    body_text=f"Here is the requested evidence: http://127.0.0.1:{port}/customer-evidence.mp4",
                    body_html='<img src="https://vendor.example/logo.png">',
                )
            )
            server.shutdown()
            thread.join(timeout=2)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LINKED_MEDIA_SAVED", result.stdout)
        self.assertEqual(list(files.values()), [payload])

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
                    "SANE_RUNTIME_DIR": str(home / ".sane"),
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
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result.stdout

    def test_active_summary_surfaces_apollo_api_thread_as_business_blocker(self):
        result = self.run_command(
            ["active-summary"],
            [
                email_row(
                    990001,
                    from_email="support@apollo.example.invalid",
                    subject="Synthetic Apollo API access fixture",
                    status="needs_human",
                    created_at="2099-01-03 15:52:07",
                    body_text=(
                        "This synthetic Apollo account has no API keys associated with it. "
                        "Are you using MCP? Which test API key are you using?"
                    ),
                ),
                email_row(
                    990002,
                    from_email="support@apollo.example.invalid",
                    subject="Synthetic prospecting newsletter fixture",
                    status="needs_human",
                    created_at="2099-01-03 10:00:00",
                    body_text="Synthetic prospecting newsletter. Unsubscribe from Apollo tips.",
                ),
                email_row(
                    990003,
                    from_email="customer@example.invalid",
                    subject="Synthetic SaneClip issue fixture",
                    status="needs_human",
                    created_at="2099-01-03 02:55:13",
                    body_text="Synthetic report: the fixed window still has a subsequent-paste problem.",
                ),
            ],
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Business/API threads:", result.stdout)
        self.assertIn("#990001 [REVIEW REQUIRED]", result.stdout)
        self.assertIn("Apollo", result.stdout)
        business_section = result.stdout.split("Support/product bugs:", 1)[0]
        self.assertNotIn("#990002", business_section)
        self.assertIn("Never classify open business/vendor/API threads as noise before review.", result.stdout)
        self.assertIn("Support/product bugs:", result.stdout)
        support_section = result.stdout.split("Support/product bugs:", 1)[1].split("Other open threads:", 1)[0]
        self.assertNotIn("#990002", support_section)
        self.assertIn("#990003 [REVIEW REQUIRED]", result.stdout)
        self.assertIn("Other open threads:", result.stdout)
        self.assertIn("#990002 [REVIEW REQUIRED]", result.stdout)

    def test_verify_facts_detects_api_and_receipt_claims(self):
        with tempfile.TemporaryDirectory(prefix="check-inbox-facts-") as tmpdir:
            tmp = Path(tmpdir)
            body_file = tmp / "apollo_reply.txt"
            evidence_file = tmp / "evidence.txt"
            body_file.write_text(
                "\n".join(
                    [
                        "Hi Example Support,",
                        "",
                        "Synthetic usage stats returns HTTP 200.",
                        "Synthetic People Search returns HTTP 403 API_INACCESSIBLE and says the test key is on a free plan.",
                        "I paid for a synthetic Professional fixture on January 2, 2099: test receipt #TEST-0000.",
                        "",
                        "Mr. Sane",
                        "https://saneapps.com",
                    ]
                ),
                encoding="utf-8",
            )
            evidence_file.write_text("NO_FACTUAL_CLAIMS\n", encoding="utf-8")

            result = self.run_command(
                ["verify-facts", "990001", str(body_file), str(evidence_file)],
                [
                    email_row(
                        990001,
                        from_email="support@apollo.example.invalid",
                        subject="Synthetic Apollo API key fixture",
                        status="needs_human",
                        body_text="Which synthetic API key are you using?",
                    )
                ],
                reviewed_ids=[990001],
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Factual claim signal in draft: yes", result.stdout)
        self.assertIn("Draft has factual claims but evidence file says NO_FACTUAL_CLAIMS", result.stdout)

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

    def test_low_risk_replied_thread_is_suppressed_and_auto_resolve_candidate(self):
        # NEW CONTRACT (deliberate owner-requested suppression): a low-risk routine
        # thread we already replied to, with the customer silent, is no longer surfaced
        # under "LOW-RISK DELIVERED REPLY FOUND". Instead it is SUPPRESSED under
        # "WE RESPONDED LAST" and, once our reply is aged >= AUTO_RESOLVE_DAYS (5d) with
        # no customer response, it appears as an AUTO-RESOLVE [DRY-RUN] candidate.
        # Default remains dry-run: nothing is resolved here (no APPLY env set).
        output = self.run_report(
            [
                email_row(
                    901,
                    from_email="bot@example.com",
                    subject="Routine notification",
                    status="pending",
                    category="other",
                    created_at="2026-06-17 14:11:00",
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

        # Suppressed under the quiet "we responded last" line, not the cleanup bucket.
        self.assertIn("WE RESPONDED LAST", output)
        self.assertNotIn("LOW-RISK DELIVERED REPLY FOUND AFTER LATEST INBOUND", output)
        # Aged >= 5d (reply 2026-06-17) => dry-run auto-resolve candidate, not an apply.
        self.assertIn("AUTO-RESOLVE [DRY-RUN", output)
        self.assertIn("#901", output)
        self.assertNotIn("AUTO-RESOLVED: #901", output)
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

    def test_classification_audit_flags_trusted_account_actions_hidden_as_spam(self):
        rows = [
            email_row(
                1116,
                from_email="support@globaldomaingroup.com",
                subject="WHOIS Contact Record Verification for getsaneapps.com",
                status="spam",
                category="spam",
            ),
            email_row(
                1118,
                from_email="support@globaldomaingroup.com",
                subject="Registration confirmation for getsaneapps.com",
                status="spam",
                category="spam",
            ),
            email_row(
                1120,
                from_email="gmail-noreply@google.com",
                subject="Gmail Confirmation - Send Mail as hi@saneapps.com",
                status="spam",
                category="spam",
            ),
        ]
        result = self.run_command(["classification-audit", "50"], rows)

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Trusted account/domain workflow hidden as spam/system", result.stdout)
        self.assertIn("#1116", result.stdout)
        self.assertIn("#1118", result.stdout)
        self.assertIn("#1120", result.stdout)
        self.assertIn("critical=3", result.stdout)

    def test_normal_report_surfaces_trusted_account_actions_even_when_spammed(self):
        output = self.run_report([
            email_row(
                1116,
                from_email="support@globaldomaingroup.com",
                subject="WHOIS Contact Record Verification for getsaneapps.com",
                status="spam",
                category="spam",
            ),
            email_row(
                1120,
                from_email="gmail-noreply@google.com",
                subject="Gmail Confirmation - Send Mail as hi@saneapps.com",
                status="spam",
                category="spam",
            ),
        ])

        self.assertIn("TRUSTED ACCOUNT ACTIONS HIDDEN BY CLASSIFICATION", output)
        self.assertIn("#1116", output)
        self.assertIn("#1120", output)
        self.assertIn("Review and reopen", output)

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
