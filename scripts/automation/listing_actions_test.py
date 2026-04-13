#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("listing-actions.py")
SCRIPT_SPEC = importlib.util.spec_from_file_location("listing_actions", SCRIPT_PATH)
LISTING_ACTIONS = importlib.util.module_from_spec(SCRIPT_SPEC)
assert SCRIPT_SPEC.loader is not None
SCRIPT_SPEC.loader.exec_module(LISTING_ACTIONS)

RULES_PATH = Path(__file__).with_name("listing_actions_rules.py")
RULES_SPEC = importlib.util.spec_from_file_location("listing_actions_rules", RULES_PATH)
LISTING_RULES = importlib.util.module_from_spec(RULES_SPEC)
assert RULES_SPEC.loader is not None
RULES_SPEC.loader.exec_module(LISTING_RULES)


def make_email(
    *,
    email_id=1,
    from_email="team@saasworthy.com",
    subject="Welcome to SaaSworthy!",
    body_text="Verify here https://links.example/verify and manage https://saasworthy.com/",
    created_at="2026-04-08 12:00:00",
    status="needs_human",
    category="other",
):
    return {
        "id": email_id,
        "from_email": from_email,
        "subject": subject,
        "body_text": body_text,
        "body_html": "",
        "created_at": created_at,
        "status": status,
        "category": category,
    }


class ListingActionTests(unittest.TestCase):
    def test_classify_sourceforge_claim_email(self):
        row = make_email(
            from_email="software@slashdotmedia.com",
            subject="SaneBar on SourceForge",
            body_text=(
                "Live page https://sourceforge.net/software/product/SaneBar/ "
                "Claim https://sourceforge.net/software/product/SaneBar/claim"
            ),
        )
        classified = LISTING_RULES.classify_email(row)
        self.assertEqual(classified["site"], "SourceForge")
        self.assertEqual(classified["workflow"], "Claim the SaneBar page")
        self.assertEqual(
            classified["primary_link"],
            "https://sourceforge.net/software/product/SaneBar/claim",
        )

    def test_extract_urls_trims_markdown_closer(self):
        urls = LISTING_RULES.extract_urls("[https://selldigitals.com/orders/123/details]")
        self.assertEqual(urls, ["https://selldigitals.com/orders/123/details"])

    def test_build_current_actions_uses_action_status_not_thread_status(self):
        history = [
            {
                "site": "SaaSworthy",
                "workflow": "Complete vendor portal profile",
                "required": "Required",
                "action": "Finish the profile",
                "instructions": "Log in and fill it out.",
                "primary_link": "https://example.com/vendor",
                "secondary_link": "",
                "note": "Current setup step.",
                "email_id": 531,
                "status": "resolved",
                "category": "other",
                "from_email": "team@saasworthy.com",
                "subject": "Portal active",
                "created_at": "2026-04-08 12:00:00",
                "all_urls": "",
            }
        ]
        current = LISTING_RULES.build_current_actions(history)
        self.assertEqual(len(current), 1)
        self.assertEqual(current[0]["action_status"], "Needs action")
        self.assertEqual(current[0]["latest_thread_status"], "resolved")

    def test_build_email_history_collects_classified_rows(self):
        rows = [
            make_email(
                email_id=508,
                from_email="team@saasworthy.com",
                subject="Welcome to SaaSworthy!",
                body_text="Verify https://sendgrid.net/ls/click/abc",
            ),
            make_email(
                email_id=999,
                from_email="noreply@example.com",
                subject="Unrelated",
                body_text="hello",
            ),
        ]
        history = LISTING_RULES.build_email_history(rows)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["email_id"], 508)
        self.assertEqual(history[0]["primary_link"], "https://sendgrid.net/ls/click/abc")

    def test_build_current_actions_suppresses_superseded_saasworthy_invite(self):
        history = [
            {
                "site": "SaaSworthy",
                "workflow": "Verify vendor portal invite",
                "required": "Required",
                "action": "Verify the invite",
                "instructions": "Click the invite link.",
                "primary_link": "https://example.com/verify",
                "secondary_link": "",
                "note": "Initial step.",
                "email_id": 508,
                "status": "resolved",
                "category": "other",
                "from_email": "team@saasworthy.com",
                "subject": "Welcome to SaaSworthy!",
                "created_at": "2026-04-03 09:27:11",
                "all_urls": "",
            },
            {
                "site": "SaaSworthy",
                "workflow": "Complete vendor portal profile",
                "required": "Required",
                "action": "Finish the profile",
                "instructions": "Log in and fill it out.",
                "primary_link": "https://example.com/vendor",
                "secondary_link": "",
                "note": "Current setup step.",
                "email_id": 531,
                "status": "resolved",
                "category": "other",
                "from_email": "team@saasworthy.com",
                "subject": "Portal active",
                "created_at": "2026-04-04 02:32:12",
                "all_urls": "",
            },
        ]
        current = LISTING_RULES.build_current_actions(history)
        workflows = {(item["site"], item["workflow"]) for item in current}
        self.assertIn(("SaaSworthy", "Complete vendor portal profile"), workflows)
        self.assertNotIn(("SaaSworthy", "Verify vendor portal invite"), workflows)

    def test_build_current_actions_suppresses_superseded_startupsubmit_review(self):
        history = [
            {
                "site": "StartupSubmit",
                "workflow": "Review master sheet deliverables",
                "required": "Required",
                "action": "Review the Airtable sheet",
                "instructions": "Open the master sheet.",
                "primary_link": "https://airtable.com/example",
                "secondary_link": "",
                "note": "Initial deliverable.",
                "email_id": 527,
                "status": "resolved",
                "category": "other",
                "from_email": "ops@startupsubmit.app",
                "subject": "Your Submission Report is Ready!",
                "created_at": "2026-04-03 18:00:03",
                "all_urls": "",
            },
            {
                "site": "StartupSubmit",
                "workflow": "Decide whether vendor must redo manual setups",
                "required": "Required",
                "action": "Decide whether to require cleanup.",
                "instructions": "Use the transcript to decide.",
                "primary_link": "https://startupsubmit.app",
                "secondary_link": "",
                "note": "Later transcript supersedes review.",
                "email_id": 552,
                "status": "resolved",
                "category": "support",
                "from_email": "transcripts@startupsubmit.on.crisp.email",
                "subject": "Chat transcript (#b55)",
                "created_at": "2026-04-07 18:50:58",
                "all_urls": "",
            },
        ]
        current = LISTING_RULES.build_current_actions(history)
        workflows = {(item["site"], item["workflow"]) for item in current}
        self.assertIn(("StartupSubmit", "Decide whether vendor must redo manual setups"), workflows)
        self.assertNotIn(("StartupSubmit", "Review master sheet deliverables"), workflows)

    def test_generic_listing_email_is_captured(self):
        rows = [
            make_email(
                email_id=777,
                from_email="ops@app-listing-hub.com",
                subject="Activate your listing profile",
                body_text="Please activate your listing profile at https://app-listing-hub.com/vendors/activate",
            )
        ]
        history = LISTING_RULES.build_email_history(rows)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["site"], "App Listing Hub")
        self.assertEqual(history[0]["workflow"], "Review new listing/setup email")
        self.assertEqual(history[0]["required"], "Required")
        self.assertIn("Generic heuristic match", history[0]["note"])

    def test_non_listing_customer_email_is_not_captured(self):
        rows = [
            make_email(
                email_id=13,
                from_email="tony.dessablons@rankup.eu",
                subject="SaneClip & Paste Stacking",
                body_text=(
                    "I love SaneBar and have a question about SaneClip. "
                    "Is the stack window positioned near the cursor? "
                    "Website https://rankup.fr/"
                ),
            )
        ]
        history = LISTING_RULES.build_email_history(rows)
        self.assertEqual(history, [])

    def test_rows_for_sheet_uses_action_status_column(self):
        rows = LISTING_ACTIONS.rows_for_sheet(
            LISTING_ACTIONS.CURRENT_COLUMNS,
            [
                {
                    "site": "SourceForge",
                    "workflow": "Claim the SaneBar page",
                    "action_status": "Needs action",
                    "required": "Required",
                    "latest_date": "2026-04-08 12:00:00",
                    "latest_email_id": 528,
                    "latest_thread_status": "resolved",
                    "latest_subject": "SaneBar on SourceForge",
                    "action": "Claim the page",
                    "instructions": "Click claim.",
                    "primary_link": "https://sourceforge.net/software/product/SaneBar/claim",
                    "secondary_link": "",
                    "source_email_ids": "528",
                    "note": "Live page exists.",
                }
            ],
        )
        self.assertIn("Needs action", rows[0])

    def test_write_xlsx_creates_expected_sheet_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            output_path = Path(tmp) / "listing_actions.xlsx"
            LISTING_ACTIONS.write_xlsx(
                output_path,
                [
                    (
                        ["site", "action_status"],
                        [["SourceForge", "Needs action"]],
                    ),
                    (
                        ["site", "subject"],
                        [["SourceForge", "SaneBar on SourceForge"]],
                    ),
                ],
            )
            self.assertTrue(output_path.exists())
            with zipfile.ZipFile(output_path) as zf:
                workbook_xml = zf.read("xl/workbook.xml").decode("utf-8")
                sheet_xml = zf.read("xl/worksheets/sheet1.xml").decode("utf-8")
            self.assertIn('sheet name="Current Actions"', workbook_xml)
            self.assertIn("SourceForge", sheet_xml)
            self.assertIn("Needs action", sheet_xml)

    def test_main_writes_json_out_and_xlsx(self):
        sample_payload = [make_email(email_id=508, body_text="Verify https://sendgrid.net/ls/click/abc")]
        with tempfile.TemporaryDirectory() as tmp:
            output_path = Path(tmp) / "listing_actions.xlsx"
            json_path = Path(tmp) / "listing_actions.json"
            with mock.patch.object(LISTING_ACTIONS, "get_email_api_key", return_value="test-key"), \
                mock.patch.object(LISTING_ACTIONS, "fetch_emails", return_value=sample_payload), \
                mock.patch.object(LISTING_ACTIONS.sys, "argv", [
                    "listing-actions.py",
                    "--xlsx",
                    str(output_path),
                    "--json-out",
                    str(json_path),
                ]):
                LISTING_ACTIONS.main()
            self.assertTrue(output_path.exists())
            self.assertTrue(json_path.exists())
            self.assertIn("current_actions", json_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
