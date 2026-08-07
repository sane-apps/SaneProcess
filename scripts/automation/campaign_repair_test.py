#!/usr/bin/env python3
import csv
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
import datetime as dt
import urllib.error
from unittest import mock
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

HELPER = Path(__file__).resolve().parents[3] / "scripts" / "campaign_repair.py"
EMAIL_GUARD = HELPER.parent.parent / "SaneProcess/scripts/hooks/sane_email_guard.rb"
SPEC = importlib.util.spec_from_file_location("campaign_repair", HELPER)
repair = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(repair)
AUDIT_SPEC = importlib.util.spec_from_file_location("campaign_audit", HELPER.parent / "campaign_audit.py")
audit = importlib.util.module_from_spec(AUDIT_SPEC)
assert AUDIT_SPEC.loader
AUDIT_SPEC.loader.exec_module(audit)


class Args:
    pass


class CampaignRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="campaign-repair-test-")
        self.root = Path(self.temp.name)
        self.all_emails = {f"person{i:03d}@company{i:03d}.test" for i in range(533)}
        self.missing = set(sorted(self.all_emails)[288:])
        self.prior_covered = set(sorted(self.missing)[:19])
        self.repair_subset = self.missing - self.prior_covered
        repair.EXPECTED_ROSTER_HASH = repair.recipient_set_hash(self.all_emails)
        repair.EXPECTED_MISSING_HASH = repair.recipient_set_hash(self.missing)
        repair.EXPECTED_PRIOR_COVERED_HASH = repair.recipient_set_hash(self.prior_covered)
        repair.EXPECTED_REPAIR_HASH = repair.recipient_set_hash(self.repair_subset)
        self.roster = self.root / "roster.csv"
        with self.roster.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=["email", "first_name", "company", "arm", "subject"])
            writer.writeheader()
            for index, email in enumerate(sorted(self.all_emails)):
                writer.writerow({"email": email, "first_name": f"Person{index}", "company": f"Company{index}", "arm": "named-sales", "subject": repair.SUBJECT})
        repair.EXPECTED_ROSTER_FILE_HASHES = {self.roster.name: hashlib.sha256(self.roster.read_bytes()).hexdigest()}
        self.text = self.root / "template.txt"
        self.html = self.root / "template.html"
        self.text.write_text("Hi {{FIRST_NAME}} at {{COMPANY}}\n\nBest,\nStephan Joseph\nFounder, SaneApps / SaneCite\n727-758-9785\nhi@saneapps.com\nhttps://sanecite.com\n\n--\nSaneApps LLC, 3270 Auraria Rd, Dahlonega, GA 30533\nReply unsubscribe.", encoding="utf-8")
        self.html.write_text("<p>Hi {{FIRST_NAME}} at {{COMPANY}}</p><p>Best,<br>Stephan Joseph<br>Founder, SaneApps / SaneCite<br>727-758-9785<br>hi@saneapps.com<br>https://sanecite.com</p><p>SaneApps LLC &middot; 3270 Auraria Rd, Dahlonega, GA 30533<br>Unsubscribe</p>", encoding="utf-8")
        repair.EXPECTED_TEMPLATE_HASHES = {self.text.name: hashlib.sha256(self.text.read_bytes()).hexdigest(), self.html.name: hashlib.sha256(self.html.read_bytes()).hexdigest()}
        self.history = self.root / "history.json"
        active = sorted(self.all_emails - self.missing)
        rows = [self.provider_row(email, "2026-07-28T13:00:00Z", "delivered", f"old-{index}") for index, email in enumerate(active)]
        rows.extend(self.provider_row(email, "2026-07-31T13:00:00Z", "delivered", f"prior-{index}", subject="Cited answers for security questionnaires, never guessed") for index, email in enumerate(sorted(self.prior_covered)))
        rows.extend(self.provider_row(email, "2026-08-06T13:00:00Z", "scheduled", f"followup-{index}", subject="Quick test on your security questionnaire workflow") for index, email in enumerate(sorted(self.prior_covered)[:9]))
        self.history.write_text(json.dumps({"data": rows, "meta": {"truncated": False}}), encoding="utf-8")
        self.opt_outs = self.root / "opt-outs.json"
        self.suppressions = self.root / "suppressions.json"
        self.opt_outs.write_text("[]", encoding="utf-8")
        self.suppressions.write_text("[]", encoding="utf-8")
        self.dne = self.root / "DO_NOT_EMAIL.csv"
        self.dne.write_text("email,reason\n", encoding="utf-8")
        self.manifest = self.root / "manifest.csv"

    def tearDown(self):
        self.temp.cleanup()

    def provider_row(self, email, scheduled_at, status="scheduled", provider_id="provider-id", subject=None, sender=None):
        return {"id": provider_id, "from": sender or repair.SENDER, "to": [email], "subject": subject or repair.SUBJECT, "scheduled_at": scheduled_at, "last_event": status, "tags": [{"name": "campaign", "value": repair.CAMPAIGN_TAG}, {"name": "arm", "value": repair.ARM_TAG}]}

    def preflight_args(self):
        args = Args()
        args.roster = [str(self.roster)]
        args.history_json = str(self.history)
        args.opt_outs_json = str(self.opt_outs)
        args.suppressions_json = str(self.suppressions)
        args.do_not_email = str(self.dne)
        args.text_template = str(self.text)
        args.html_template = str(self.html)
        args.manifest_out = str(self.manifest)
        args._fixture_authorized = True
        return args

    def make_manifest(self):
        result = repair.preflight(self.preflight_args())
        self.assertEqual(result["repair_count"], 226)
        return result

    def approval(self, created_at=990, manifest_hash=None):
        path = self.root / "approval.json"
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        remaining = [{"to": row["to"], "subject": row["subject"], "body_hash": hashlib.sha256(Path(row["body_file"]).read_text(encoding="utf-8").strip().encode()).hexdigest()} for row in rows]
        path.write_text(json.dumps({
            "created_at": created_at,
            "manifest": str(self.manifest),
            "manifest_sha256": manifest_hash or repair.manifest_hash(self.manifest),
            "total": repair.EXPECTED_REPAIR_COUNT,
            "used": 0,
            "remaining": remaining,
            "user_approval": "send the approved repair batch",
        }), encoding="utf-8")
        path.chmod(0o600)
        return path

    def schedule_args(self, journal=None):
        args = Args()
        args.manifest = str(self.manifest)
        args.approval_file = str(self.approval())
        args.journal = str(journal or self.root / "journal.json")
        args.token = "fixture-token"
        args.now = 1000
        args._fixture_authorized = True
        return args

    def test_preflight_builds_exact_226_and_rejects_fresh_suppression_overlap(self):
        result = self.make_manifest()
        self.assertEqual(result["daily_counts"], {"2026-08-04": 113, "2026-08-05": 113})
        self.assertEqual(result["checks"]["prior_covered_recipients"], 19)
        self.assertEqual(os.stat(self.manifest).st_mode & 0o777, 0o600)
        blocked = next(iter(self.repair_subset))
        self.suppressions.write_text(json.dumps([{"name": f"suppressed:{blocked}"}]), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "prohibited overlap"):
            repair.preflight(self.preflight_args())

    def test_preflight_keeps_repair_window_out_of_historical_set_and_blocks_live_duplicate(self):
        duplicate = next(iter(self.repair_subset))
        payload = json.loads(self.history.read_text(encoding="utf-8"))
        payload["data"].append(self.provider_row(duplicate, "2026-08-04T13:00:00Z", "scheduled", "outside-window"))
        self.history.write_text(json.dumps(payload), encoding="utf-8")
        _arm_a, historical, _blocked = repair.historical_sets(payload["data"])
        self.assertEqual(len(historical), 288)
        with self.assertRaisesRegex(repair.RepairError, "prohibited overlap"):
            repair.preflight(self.preflight_args())

    def reconciliation_fixture(self):
        payload = json.loads(self.history.read_text(encoding="utf-8"))
        historical_emails = sorted(self.all_emails - self.missing)[:19]
        missing_email = next(iter(self.missing))
        target_rows = [self.provider_row(email, "2026-08-04T13:00:00Z", "scheduled", f"historical-duplicate-{index}") for index, email in enumerate(historical_emails)]
        target_rows.append(self.provider_row(missing_email, "2026-08-05T13:00:00Z", "scheduled", "missing-cohort"))
        outside_row = self.provider_row("outside@unrelated.test", "2026-08-05T14:00:00Z", "scheduled", "outside-roster")
        payload["data"].extend(target_rows + [outside_row])
        self.history.write_text(json.dumps(payload), encoding="utf-8")
        details = self.root / "details.json"
        details.write_text(json.dumps({"schema": 1, "purpose": "aug04_05_reconciliation_cancel", "roster_sha256": repair.EXPECTED_ROSTER_HASH, "roster_files_sha256": repair.roster_files_hash(), "data": []}), encoding="utf-8"); details.chmod(0o600)
        args = Args(); args.history_json = str(self.history); args.details_json = str(details); args.roster = [str(self.roster)]
        args.text_template = str(self.text); args.html_template = str(self.html); args.journal_out = str(self.root / "reconcile.json")
        args.now = 1785686400.0; args._fixture_authorized = True
        return args, details, target_rows

    def test_reconciliation_requires_exact_20_foreign_contract_candidates(self):
        args, details, target_rows = self.reconciliation_fixture()
        blocked = repair.reconciliation_preflight(args)
        self.assertEqual(blocked["unresolved"], 20)
        self.assertEqual(blocked["counts"]["outside_roster"], 1)
        self.assertEqual(blocked["counts"]["ignore"], 1)
        self.assertFalse(Path(args.journal_out).exists())
        for detail in target_rows:
            detail["tags"] = [{"name": "campaign", "value": "sanecite-wave2-fixed-2026-08"}, {"name": "arm", "value": "privacy"}]
            detail.update({"reply_to": "hi@saneapps.com", "headers": {"List-Unsubscribe": "<mailto:hi@saneapps.com?subject=unsubscribe>"}})
        detail_payload = json.loads(details.read_text()); detail_payload["data"] = target_rows
        details.write_text(json.dumps(detail_payload), encoding="utf-8"); details.chmod(0o600)
        ready = repair.reconciliation_preflight(args)
        self.assertEqual(ready["status"], "ready_for_scoped_approval")
        self.assertEqual(ready["counts"]["cancel_candidate"], 20)
        journal = json.loads(Path(args.journal_out).read_text())
        self.assertEqual({item["state"] for item in journal["records"]}, {"pending"})
        self.assertEqual({item["cohort"] for item in journal["records"]}, {"historical_duplicate", "missing_cohort"})
        self.assertEqual(journal["purpose"], "aug04_05_reconciliation_cancel")
        self.assertEqual(os.stat(args.journal_out).st_mode & 0o777, 0o600)

    def test_reconciliation_cancel_revalidates_twice_journals_and_resumes(self):
        args, details, target_rows = self.reconciliation_fixture()
        for detail in target_rows:
            detail["tags"] = [{"name": "campaign", "value": "sanecite-wave2-fixed-2026-08"}, {"name": "arm", "value": "privacy"}]
            detail.update({"reply_to": "hi@saneapps.com", "headers": {"List-Unsubscribe": "<mailto:hi@saneapps.com?subject=unsubscribe>"}})
        detail_payload = json.loads(details.read_text()); detail_payload["data"] = target_rows
        details.write_text(json.dumps(detail_payload), encoding="utf-8"); details.chmod(0o600)
        repair.reconciliation_preflight(args)
        journal_path = Path(args.journal_out)
        journal = json.loads(journal_path.read_text())
        approval = self.root / "reconciliation-approval.json"
        approval.write_text(json.dumps({"created_at": args.now - 10, "purpose": journal["purpose"], "scope_sha256": journal["scope_sha256"], "user_approval": "cancel the reconciliation candidates"}), encoding="utf-8"); approval.chmod(0o600)
        live = {row["id"]: dict(row) for row in target_rows}
        fetches = []
        def fetcher(_token):
            fetches.append(True)
            return list(live.values())
        def poster(url, _token, *_rest):
            target = url.split("/")[-2]
            live[target]["last_event"] = "canceled"
            return {"id": target}
        cancel_args = Args(); cancel_args.journal = str(journal_path); cancel_args.approval_file = str(approval)
        cancel_args.token = "fixture-token"; cancel_args.now = args.now; cancel_args._fixture_authorized = True
        result = repair.reconciliation_cancel(cancel_args, fetcher=fetcher, poster=poster)
        self.assertEqual(result["verified_canceled"], 20)
        self.assertEqual(result["cancel_requested_this_run"], 20)
        self.assertEqual(len(fetches), 2)
        self.assertEqual({row["state"] for row in json.loads(journal_path.read_text())["records"]}, {"canceled"})
        fetches.clear()
        resumed = repair.reconciliation_cancel(cancel_args, fetcher=fetcher, poster=poster)
        self.assertEqual(resumed["cancel_requested_this_run"], 0)
        self.assertEqual(len(fetches), 2)

    def test_canonical_wrapper_parser_binds_reconcile_preflight_journal_out(self):
        args, details, target_rows = self.reconciliation_fixture()
        for detail in target_rows:
            detail["tags"] = [{"name": "campaign", "value": "sanecite-wave2-fixed-2026-08"}, {"name": "arm", "value": "privacy"}]
            detail.update({"reply_to": "hi@saneapps.com", "headers": {"List-Unsubscribe": "<mailto:hi@saneapps.com?subject=unsubscribe>"}})
        detail_payload = json.loads(details.read_text()); detail_payload["data"] = target_rows
        details.write_text(json.dumps(detail_payload), encoding="utf-8"); details.chmod(0o600)
        argv = [
            "reconcile-preflight", "--history-json", str(self.history), "--details-json", str(details),
            "--journal-out", args.journal_out, "--roster", str(self.roster),
            "--text-template", str(self.text), "--html-template", str(self.html), "--now", str(args.now),
        ]
        environment = {
            "SANE_CAMPAIGN_REPAIR_WRAPPER": "1",
            "SANE_CAMPAIGN_REPAIR_WRAPPER_PATH": str(HELPER.with_name("check-inbox.sh")),
            "CAMPAIGN_RECONCILIATION_DETAILS": str(details),
            "CAMPAIGN_RECONCILIATION_JOURNAL": args.journal_out,
        }
        stdout = StringIO()
        with mock.patch.dict(os.environ, environment, clear=False), redirect_stdout(stdout):
            status = repair.main(argv)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(stdout.getvalue())["status"], "ready_for_scoped_approval")
        wrapper = HELPER.with_name("check-inbox.sh").read_text(encoding="utf-8")
        self.assertIn('CAMPAIGN_RECONCILIATION_JOURNAL="$RECONCILIATION_JOURNAL"', wrapper)
        self.assertIn('--journal-out "$RECONCILIATION_JOURNAL"', wrapper)

    def test_hypothetical_history_changes_only_20_journaled_states(self):
        args, details, target_rows = self.reconciliation_fixture()
        for detail in target_rows:
            detail["tags"] = [{"name": "campaign", "value": "sanecite-wave2-fixed-2026-08"}, {"name": "arm", "value": "privacy"}]
            detail.update({"reply_to": "hi@saneapps.com", "headers": {"List-Unsubscribe": "<mailto:hi@saneapps.com?subject=unsubscribe>"}})
        detail_payload = json.loads(details.read_text()); detail_payload["data"] = target_rows
        details.write_text(json.dumps(detail_payload), encoding="utf-8"); details.chmod(0o600)
        repair.reconciliation_preflight(args)
        live = json.loads(self.history.read_text())["data"]
        output = self.root / "hypothetical.json"
        simulate_args = Args(); simulate_args.journal = args.journal_out; simulate_args.output = str(output)
        simulate_args.token = "fixture-token"; simulate_args._fixture_authorized = True
        result = repair.reconciliation_simulate(simulate_args, fetcher=lambda _token: live)
        self.assertEqual(result["changed_records"], 20)
        hypothetical = json.loads(output.read_text())
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
        journal_ids = {row["provider_id"] for row in json.loads(Path(args.journal_out).read_text())["records"]}
        before = {row["id"]: row for row in live}; after = {row["id"]: row for row in hypothetical["data"]}
        self.assertEqual(set(before), set(after))
        for provider_id in before:
            expected = dict(before[provider_id])
            if provider_id in journal_ids:
                expected["last_event"] = "canceled"
            self.assertEqual(after[provider_id], expected)

    def test_wrapper_never_allows_schedule_to_consume_hypothetical_fixture(self):
        import subprocess
        wrapper = HELPER.with_name("check-inbox.sh")
        fixture = self.root / "hypothetical.json"; fixture.write_text('{"data":[]}', encoding="utf-8")
        environment = dict(os.environ, EMAIL_API_KEY="fixture-key", CAMPAIGN_REPAIR_HISTORY_JSON=str(fixture), CAMPAIGN_REPAIR_TEST_MODE="0")
        result = subprocess.run(["bash", str(wrapper), "campaign-repair", "schedule"], env=environment, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixtures require explicit non-mutating test mode", result.stderr)
        environment["CAMPAIGN_REPAIR_TEST_MODE"] = "1"
        result = subprocess.run(["bash", str(wrapper), "campaign-repair", "schedule"], env=environment, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test mode cannot mutate provider state", result.stderr)

    def test_approval_hash_mismatch_and_expiry_fail_closed(self):
        self.make_manifest()
        with self.assertRaisesRegex(repair.RepairError, "does not match"):
            repair.verify_approval(self.manifest, self.approval(manifest_hash="0" * 64), now=1000)
        with self.assertRaisesRegex(repair.RepairError, "does not match"):
            repair.verify_approval(self.manifest, self.approval(manifest_hash=repair.LEGACY_245_MANIFEST_HASH), now=1000)
        with self.assertRaisesRegex(repair.RepairError, "expired"):
            repair.verify_approval(self.manifest, self.approval(created_at=1), now=50_000)
        approval = self.approval()
        payload = json.loads(approval.read_text())
        payload["remaining"][0]["body_hash"] = "0" * 64
        approval.write_text(json.dumps(payload), encoding="utf-8")
        approval.chmod(0o600)
        with self.assertRaisesRegex(repair.RepairError, "entries/body hashes"):
            repair.verify_approval(self.manifest, approval, now=1000)

    def test_full_roster_file_hash_binds_render_inputs(self):
        original = self.roster.read_text(encoding="utf-8")
        self.roster.write_text(original.replace("Person0", "ChangedName", 1), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "roster file hashes"):
            repair.preflight(self.preflight_args())

    def test_template_hash_drift_blocks_preflight(self):
        self.text.write_text("changed campaign copy", encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "template hashes"):
            repair.preflight(self.preflight_args())

    def test_template_fixtures_use_founder_sales_identity_and_keep_compliance_footer(self):
        for content in (self.text.read_text(encoding="utf-8"), self.html.read_text(encoding="utf-8")):
            self.assertIn("Stephan Joseph", content)
            self.assertIn("Founder, SaneApps / SaneCite", content)
            self.assertIn("727-758-9785", content)
            self.assertIn("hi@saneapps.com", content)
            self.assertIn("https://sanecite.com", content)
            self.assertIn("SaneApps LLC", content)
            self.assertIn("3270 Auraria Rd", content)
            self.assertRegex(content.lower(), "unsubscribe")
            self.assertNotIn("Mr. Sane", content)

    def test_sender_correction_preflight_and_manifest_migration_are_strict(self):
        self.make_manifest()
        with self.manifest.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        provider_journal = self.root / "provider-journal.json"
        live = []
        records = []
        for index, row in enumerate(rows[:27]):
            provider_id = f"legacy-sender-{index}"
            records.append({"provider_id": provider_id, "recipient_sha256": hashlib.sha256(row["to"].encode()).hexdigest(), "scheduled_at": row["scheduled_at"], "state": "created"})
            live.append(self.provider_row(row["to"], row["scheduled_at"], "scheduled", provider_id, sender=repair.LEGACY_SENDER))
        repair.atomic_json(provider_journal, {"schema": 1, "repair_label": repair.LABEL, "manifest_sha256": repair.LEGACY_245_MANIFEST_HASH, "records": records})
        history = self.root / "correction-history.json"; history.write_text(json.dumps({"data": live, "meta": {"truncated": False}}), encoding="utf-8")
        args = Args(); args.manifest = str(self.manifest); args.provider_journal = str(provider_journal)
        args.history_json = str(history); args.journal_out = str(self.root / "correction-journal.json")
        result = repair.correction_preflight(args)
        self.assertEqual(result["correction_candidates"], 27)
        provider = json.loads(provider_journal.read_text())
        for record in provider["records"]: record["state"] = "correction_canceled"
        repair.atomic_json(provider_journal, provider)
        for row in live: row["last_event"] = "canceled"
        import campaign_correction
        campaign_correction.migrate_provider_journal(provider_journal, self.manifest, rows, live, vars(repair))
        self.assertEqual(json.loads(provider_journal.read_text())["manifest_sha256"], repair.manifest_hash(self.manifest))
        provider = json.loads(provider_journal.read_text()); provider["manifest_sha256"] = repair.LEGACY_245_MANIFEST_HASH
        provider["records"][0]["scheduled_at"] = "2026-08-05T00:00:00Z"; repair.atomic_json(provider_journal, provider)
        with self.assertRaisesRegex(repair.RepairError, "unchanged canceled live proof"):
            campaign_correction.migrate_provider_journal(provider_journal, self.manifest, rows, live, vars(repair))

    def test_contextual_approved_response_is_valid_correction_approval(self):
        import campaign_correction
        journal = {
            "schema": 1,
            "purpose": campaign_correction.PURPOSE,
            "repair_label": repair.LABEL,
            "old_manifest_sha256": repair.LEGACY_245_MANIFEST_HASH,
            "new_manifest_sha256": "new-manifest",
            "records": [],
        }
        journal["scope_sha256"] = campaign_correction._scope_hash(journal)
        journal_path = self.root / "approval-journal.json"
        approval_path = self.root / "correction-approval.json"
        repair.atomic_json(journal_path, journal)
        repair.atomic_json(approval_path, {
            "created_at": 990,
            "purpose": campaign_correction.PURPOSE,
            "scope_sha256": journal["scope_sha256"],
            "user_approval": "approved",
        })
        args = Args(); args.approval_file = str(approval_path); args.now = 1000
        self.assertEqual(campaign_correction._approval(args, journal, vars(repair)), 1290)

    def test_provider_contract_requires_private_sender_identity(self):
        self.make_manifest()
        with self.manifest.open(newline="", encoding="utf-8") as handle: row = next(csv.DictReader(handle))
        live = self.provider_row(row["to"], row["scheduled_at"], "scheduled", "sender-check")
        self.assertTrue(repair.provider_record_matches(live, row, "sender-check"))
        live["from"] = repair.SUPPORT_SENDER
        self.assertFalse(repair.provider_record_matches(live, row, "sender-check"))

    def test_idempotent_resume_skips_private_journal_entries(self):
        self.make_manifest()
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            first = next(csv.DictReader(handle))
        recipient_sha = hashlib.sha256(first["to"].encode()).hexdigest()
        journal = self.root / "journal.json"
        repair.atomic_json(journal, {"schema": 1, "repair_label": repair.LABEL, "manifest_sha256": repair.manifest_hash(self.manifest), "records": [{"provider_id": "existing-private-id", "recipient_sha256": recipient_sha, "scheduled_at": first["scheduled_at"], "idempotency_key": "private-key", "state": "created"}]})
        posts = []
        existing = self.provider_row(first["to"], first["scheduled_at"], "scheduled", "existing-private-id")
        fetches = []
        result = repair.schedule(self.schedule_args(journal), fetcher=lambda _token: fetches.append(True) or [existing], poster=lambda *items: posts.append(items) or {"id": f"new-{len(posts)}"})
        self.assertEqual(result["created_this_run"], 225)
        self.assertEqual(len(posts), 225)
        self.assertEqual(len(fetches), 1)
        self.assertEqual(os.stat(journal).st_mode & 0o777, 0o600)
        public = json.dumps(result)
        self.assertNotIn(first["to"], public)
        self.assertNotIn("existing-private-id", public)

    def test_resume_rejects_journal_without_exact_provider_tags(self):
        self.make_manifest()
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            first = next(csv.DictReader(handle))
        journal = self.root / "journal.json"
        repair.atomic_json(journal, {"schema": 1, "repair_label": repair.LABEL, "manifest_sha256": repair.manifest_hash(self.manifest), "records": [{"provider_id": "existing-private-id", "recipient_sha256": hashlib.sha256(first["to"].encode()).hexdigest(), "scheduled_at": first["scheduled_at"], "state": "created"}]})
        live = self.provider_row(first["to"], first["scheduled_at"], "scheduled", "existing-private-id")
        live["tags"][0]["value"] = "wrong-campaign"
        with self.assertRaisesRegex(repair.RepairError, "exact live provider proof"):
            repair.schedule(self.schedule_args(journal), fetcher=lambda _token: [live], poster=lambda *_items: {"id": "unused"})

    def test_partial_failure_stops_and_journals_only_confirmed_create(self):
        self.make_manifest()
        attempts = 0
        def poster(*_items):
            nonlocal attempts
            attempts += 1
            if attempts == 2:
                raise repair.RepairError("fixture create failed")
            return {"id": "private-provider-id"}
        args = self.schedule_args()
        with self.assertRaisesRegex(repair.RepairError, "fixture create failed"):
            repair.schedule(args, fetcher=lambda _token: [], poster=poster)
        journal = json.loads(Path(args.journal).read_text())
        self.assertEqual(attempts, 2)
        self.assertEqual(len(journal["records"]), 1)

    def test_direct_helper_mutation_is_blocked_without_wrapper_marker(self):
        self.make_manifest()
        args = self.schedule_args()
        args._fixture_authorized = False
        with self.assertRaisesRegex(repair.RepairError, "canonical check-inbox wrapper"):
                repair.schedule(args, fetcher=lambda _token: [], poster=lambda *_items: {"id": "should-not-run"})

    def test_shell_guard_blocks_direct_helper_but_allows_wrapper(self):
        import subprocess
        blocked_commands = [
            "python3 /tmp/campaign_repair.py schedule --manifest /tmp/private.csv",
            "env SANE_CAMPAIGN_REPAIR_WRAPPER=1 CAMPAIGN_REPAIR_MANIFEST=/tmp/private.csv python3 /tmp/campaign_repair.py schedule --manifest /tmp/private.csv",
            "ssh mini 'python3 ~/SaneApps/infra/scripts/campaign_repair.py rollback --journal /tmp/private.json'",
            "ssh mini \"env SANE_CAMPAIGN_REPAIR_WRAPPER=1 python3 ~/SaneApps/infra/scripts/campaign_repair.py rollback --journal /tmp/private.json\"",
            "bash -lc 'python3 /tmp/campaign_repair.py schedule --manifest /tmp/private.csv'",
            "python3 /tmp/campaign_repair.py reconcile-cancel --journal /tmp/reconcile.json --approval-file /tmp/approval.json",
            "env SANE_CAMPAIGN_REPAIR_WRAPPER=1 python3 /tmp/campaign_repair.py reconcile-cancel --journal /tmp/reconcile.json --approval-file /tmp/approval.json",
            "ssh mini 'bash -lc \"python3 ~/SaneApps/infra/scripts/campaign_repair.py reconcile-cancel --journal /tmp/reconcile.json --approval-file /tmp/approval.json\"'",
        ]
        for command in blocked_commands:
            direct = {"tool_name": "Bash", "tool_input": {"command": command}}
            blocked = subprocess.run(["ruby", str(EMAIL_GUARD)], input=json.dumps(direct), text=True, capture_output=True, check=False)
            self.assertEqual(blocked.returncode, 2, command)
            self.assertIn("Direct campaign repair mutation helper", blocked.stderr)
        wrapper = {"tool_name": "Bash", "tool_input": {"command": "/Users/sj/SaneApps/infra/scripts/check-inbox.sh campaign-repair schedule"}}
        allowed = subprocess.run(["ruby", str(EMAIL_GUARD)], input=json.dumps(wrapper), text=True, capture_output=True, check=False)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def test_fixture_mode_is_mechanically_non_mutating(self):
        self.make_manifest()
        args = ["schedule", "--manifest", str(self.manifest), "--approval-file", str(self.approval()), "--journal", str(self.root / "journal.json"), "--token", "fixture"]
        stderr = StringIO()
        with mock.patch.dict(os.environ, {"CAMPAIGN_REPAIR_TEST_MODE": "1"}), redirect_stderr(stderr):
            status = repair.main(args)
        self.assertEqual(status, 1)
        self.assertIn("cannot mutate provider state", stderr.getvalue())
        stderr = StringIO()
        with mock.patch.dict(os.environ, {"CAMPAIGN_REPAIR_TEST_MODE": "1"}), redirect_stderr(stderr):
            status = repair.main(["reconcile-cancel", "--journal", str(self.root / "private.json"), "--approval-file", str(self.root / "approval.json"), "--token", "fixture"])
        self.assertEqual(status, 1)
        self.assertIn("cannot mutate provider state", stderr.getvalue())

    def test_http_failure_is_redacted(self):
        secret = "provider-secret-id-person@example.test"
        failure = urllib.error.URLError(secret)
        with mock.patch.object(repair.urllib.request, "urlopen", side_effect=failure):
            with self.assertRaises(repair.RepairError) as caught:
                repair.provider_post(f"https://api.resend.com/emails/{secret}/cancel", "secret-token")
        self.assertNotIn(secret, str(caught.exception))
        self.assertNotIn("secret-token", str(caught.exception))

    def test_resend_client_paces_sequential_requests_at_four_per_second(self):
        now = [0.0]; sleeps = []
        def sleeper(delay):
            sleeps.append(delay); now[0] += delay
        client = repair.SequentialResendClient(opener=lambda *_args, **_kwargs: object(), clock=lambda: now[0], wall_clock=lambda: 1000 + now[0], sleeper=sleeper)
        request = repair.urllib.request.Request(repair.RESEND_URL)
        client.open(request); client.open(request); client.open(request)
        self.assertEqual(sleeps, [0.25, 0.25])

    def test_resend_client_honors_429_retry_after_with_bounded_retry(self):
        now = [0.0]; sleeps = []; attempts = []
        def sleeper(delay):
            sleeps.append(delay); now[0] += delay
        def opener(request, **_kwargs):
            attempts.append(request)
            if len(attempts) == 1:
                raise urllib.error.HTTPError(request.full_url, 429, "rate limited", {"Retry-After": "2"}, None)
            return object()
        client = repair.SequentialResendClient(opener=opener, clock=lambda: now[0], wall_clock=lambda: 1000 + now[0], sleeper=sleeper)
        client.open(repair.urllib.request.Request(repair.RESEND_URL))
        self.assertEqual(len(attempts), 2)
        self.assertEqual(sleeps, [2.0])

    def test_resend_client_never_retries_non_429(self):
        attempts = []
        def opener(request, **_kwargs):
            attempts.append(request)
            raise urllib.error.HTTPError(request.full_url, 403, "forbidden", {}, None)
        client = repair.SequentialResendClient(opener=opener, clock=lambda: 0.0, wall_clock=lambda: 1000.0, sleeper=lambda _delay: None)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            client.open(repair.urllib.request.Request(repair.RESEND_URL))
        caught.exception.close()
        self.assertEqual(len(attempts), 1)

    def test_provider_post_429_retry_reuses_one_idempotency_key(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def read(self): return b'{"id":"confirmed-once"}'
        now = [0.0]; attempts = []
        def sleeper(delay): now[0] += delay
        def opener(request, **_kwargs):
            attempts.append(request)
            if len(attempts) == 1:
                raise urllib.error.HTTPError(request.full_url, 429, "rate limited", {"ratelimit-reset": "1"}, None)
            return Response()
        client = repair.SequentialResendClient(opener=opener, clock=lambda: now[0], wall_clock=lambda: 1000 + now[0], sleeper=sleeper)
        with mock.patch.object(repair, "RESEND_CLIENT", client):
            result = repair.provider_post(f"{repair.RESEND_URL}/private/cancel", "token", idempotency_key="stable-key", deadline=1300)
        self.assertEqual(result, {"id": "confirmed-once"})
        self.assertEqual(len(attempts), 2)
        self.assertEqual([request.get_header("Idempotency-key") for request in attempts], ["stable-key", "stable-key"])
        self.assertEqual([request.get_header("User-agent") for request in attempts], [repair.RESEND_USER_AGENT, repair.RESEND_USER_AGENT])

    def test_bounded_rollback_cancels_only_future_scheduled_journal_ids(self):
        journal = self.root / "journal.json"
        self.make_manifest()
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            manifest_rows = list(csv.DictReader(handle))
        future = manifest_rows[0]
        past = manifest_rows[1]
        past["scheduled_at"] = "2026-08-03T13:00:00Z"
        repair.atomic_json(journal, {"schema": 1, "repair_label": repair.LABEL, "manifest_sha256": repair.manifest_hash(self.manifest), "records": [
            {"provider_id": "repair-future", "recipient_sha256": hashlib.sha256(future["to"].encode()).hexdigest(), "scheduled_at": future["scheduled_at"], "state": "created"},
        ]})
        live_rows = {"repair-future": self.provider_row(future["to"], future["scheduled_at"], "scheduled", "repair-future"), "unrelated": self.provider_row(past["to"], past["scheduled_at"], "scheduled", "unrelated")}
        def getter(_token):
            return list(live_rows.values())
        def poster(url, _token, *_rest):
            target = url.split("/")[-2]
            live_rows[target]["last_event"] = "canceled"
            return {"id": target}
        args = Args()
        args.confirm_label = repair.LABEL
        args.token = "fixture-token"
        args.journal = str(journal)
        args.manifest = str(self.manifest)
        args.now = 1785762000.0
        rollback_approval = self.root / "rollback-approval.json"
        rollback_approval.write_text(json.dumps({"created_at": args.now - 10, "repair_label": repair.LABEL, "manifest_sha256": repair.manifest_hash(self.manifest), "journal_sha256": hashlib.sha256(journal.read_bytes()).hexdigest(), "user_approval": "rollback the repair"}), encoding="utf-8")
        rollback_approval.chmod(0o600)
        args.rollback_approval_file = str(rollback_approval)
        args._fixture_authorized = True
        result = repair.rollback(args, getter=getter, poster=poster, detail_getter=lambda _token, provider_id: live_rows[provider_id])
        self.assertEqual(result["canceled"], 1)
        self.assertEqual(live_rows["repair-future"]["last_event"], "canceled")
        self.assertEqual(live_rows["unrelated"]["last_event"], "scheduled")

    def test_redacted_cli_error_never_prints_recipient_or_provider_id(self):
        secret_email = next(iter(self.repair_subset))
        self.suppressions.write_text(json.dumps([{"name": f"suppressed:{secret_email}"}, {"id": "provider-secret-id"}]), encoding="utf-8")
        stderr = StringIO()
        with redirect_stderr(stderr), redirect_stdout(StringIO()):
            status = repair.main(["preflight", "--roster", str(self.roster), "--history-json", str(self.history), "--opt-outs-json", str(self.opt_outs), "--suppressions-json", str(self.suppressions), "--do-not-email", str(self.dne), "--text-template", str(self.text), "--html-template", str(self.html), "--manifest-out", str(self.manifest)])
        self.assertEqual(status, 1)
        self.assertNotIn(secret_email, stderr.getvalue())
        self.assertNotIn("provider-secret-id", stderr.getvalue())

    def test_combined_verify_requires_exact_533_union(self):
        self.make_manifest()
        historical = history_rows = json.loads(self.history.read_text())["data"]
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            manifest_rows = list(csv.DictReader(handle))
        repairs = [self.provider_row(row["to"], row["scheduled_at"], "scheduled", f"repair-{index}") for index, row in enumerate(manifest_rows)]
        combined_history = self.root / "combined.json"
        combined_history.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        args = Args()
        args.manifest = str(self.manifest)
        args.history_json = str(combined_history)
        args.roster = [str(self.roster)]
        args.opt_outs_json = str(self.opt_outs)
        args.suppressions_json = str(self.suppressions)
        args.do_not_email = str(self.dne)
        args.now = 1785686400.0
        result = repair.verify(args)
        self.assertEqual(result["checks"]["combined_unique_recipients"], 533)
        repairs.pop()
        combined_history.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "combined 533"):
            repair.verify(args)

    def test_verify_blocks_bad_provider_state_and_fresh_suppression(self):
        self.make_manifest()
        historical = json.loads(self.history.read_text())["data"]
        with self.manifest.open(encoding="utf-8", newline="") as handle:
            manifest_rows = list(csv.DictReader(handle))
        repairs = [self.provider_row(row["to"], row["scheduled_at"], "scheduled", f"repair-{index}") for index, row in enumerate(manifest_rows)]
        combined = self.root / "verify.json"
        combined.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        args = Args(); args.manifest = str(self.manifest); args.history_json = str(combined); args.roster = [str(self.roster)]
        args.opt_outs_json = str(self.opt_outs); args.suppressions_json = str(self.suppressions); args.do_not_email = str(self.dne); args.now = 1785686400.0
        repairs[0]["last_event"] = "bounced"
        combined.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "suppression overlap"):
            repair.verify(args)
        repairs[0]["last_event"] = "unknown"
        combined.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "schedule phase"):
            repair.verify(args)
        repairs[0]["last_event"] = "scheduled"
        self.suppressions.write_text(json.dumps([{"name": f"suppressed:{repairs[0]['to'][0]}"}]), encoding="utf-8")
        combined.write_text(json.dumps({"data": historical + repairs}), encoding="utf-8")
        with self.assertRaisesRegex(repair.RepairError, "suppression overlap"):
            repair.verify(args)

    def test_read_only_audit_combines_historical_and_repair_union(self):
        old = [self.provider_row(email, "2026-07-28T13:00:00Z", "delivered", f"old-{index}") for index, email in enumerate(sorted(self.all_emails)[:288])]
        new = [self.provider_row(email, "2026-08-04T13:00:00Z", "scheduled", f"new-{index}") for index, email in enumerate(sorted(self.all_emails)[288:])]
        report = audit.build_arm_window_report(
            old + new, [],
            {"historical": repair.SUBJECT, "repair": repair.SUBJECT},
            {"historical": (dt.date(2026, 7, 28), dt.date(2026, 7, 31)), "repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
            dt.datetime(2026, 7, 1, tzinfo=dt.timezone.utc), repair.TIMEZONE, {},
            as_of=dt.datetime(2026, 8, 3, tzinfo=dt.timezone.utc),
            combined_groups={"B_named_sales": ["historical", "repair"]},
            combined_expected={"B_named_sales": 533},
        )
        self.assertEqual(report["combined_arms"]["B_named_sales"]["unique_recipients"], 533)
        self.assertEqual(report["combined_arms"]["B_named_sales"]["blockers"], [])

    def test_read_only_audit_exact_tags_exclude_46_same_subject_window_rows(self):
        target = [
            self.provider_row(
                email,
                "2026-08-04T13:00:00Z" if index < 113 else "2026-08-05T13:00:00Z",
                "scheduled",
                f"target-{index}",
            )
            for index, email in enumerate(sorted(self.repair_subset))
        ]
        unrelated = [
            self.provider_row(
                f"unrelated{index:03d}@outside.test",
                "2026-08-04T14:00:00Z",
                "scheduled",
                f"unrelated-{index}",
            )
            for index in range(46)
        ]
        for index, row in enumerate(unrelated):
            if index < 23:
                row["tags"] = [{"name": "arm", "value": repair.ARM_TAG}]
            else:
                row["tags"] = [{"name": "campaign", "value": "wrong-campaign"}, {"name": "arm", "value": repair.ARM_TAG}]
        list_rows = [{key: value for key, value in row.items() if key != "tags"} for row in target + unrelated]
        details = {
            row["id"]: {
                **row,
                "tags": {item["name"]: item["value"] for item in row["tags"]},
            }
            for row in target + unrelated
        }
        request_times = []

        class FakeClock:
            now = 0.0

            @classmethod
            def clock(cls):
                return cls.now

            @classmethod
            def sleep(cls, seconds):
                cls.now += seconds

        def fetch_detail(url, _headers):
            request_times.append(FakeClock.now)
            return details[url.rsplit("/", 1)[-1]]

        enriched = audit.enrich_tagged_arm_candidates(
            list_rows,
            {"repair": repair.SUBJECT},
            {"repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
            {"repair": {"campaign": repair.CAMPAIGN_TAG, "arm": repair.ARM_TAG}},
            dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc),
            repair.TIMEZONE,
            "fixture-token",
            audit.try_parse_time,
            fetch=fetch_detail,
            sleep_fn=FakeClock.sleep,
            clock_fn=FakeClock.clock,
        )
        self.assertEqual(len(request_times), 272)
        self.assertTrue(all(second - first >= 0.25 for first, second in zip(request_times, request_times[1:])))
        report = audit.build_arm_window_report(
            enriched,
            [],
            {"repair": repair.SUBJECT},
            {"repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
            dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc),
            repair.TIMEZONE,
            {},
            as_of=dt.datetime(2026, 8, 3, tzinfo=dt.timezone.utc),
            expected_counts={"repair": 226},
            arm_tags={"repair": {"campaign": repair.CAMPAIGN_TAG, "arm": repair.ARM_TAG}},
        )
        self.assertEqual(report["arms"]["repair"]["matching_records"], 226)
        self.assertEqual(report["arms"]["repair"]["active_records"], 226)
        self.assertEqual(report["arms"]["repair"]["unique_recipients"], 226)
        self.assertEqual(report["arms"]["repair"]["blockers"], [])

        for row in target:
            row["tags"] = {item["name"]: item["value"] for item in row["tags"]}
        dict_tag_report = audit.build_arm_window_report(
            target + unrelated,
            [],
            {"repair": repair.SUBJECT},
            {"repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
            dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc),
            repair.TIMEZONE,
            {},
            as_of=dt.datetime(2026, 8, 3, tzinfo=dt.timezone.utc),
            expected_counts={"repair": 226},
            arm_tags={"repair": {"campaign": repair.CAMPAIGN_TAG, "arm": repair.ARM_TAG}},
        )
        self.assertEqual(dict_tag_report["arms"]["repair"]["active_records"], 226)
        self.assertEqual(dict_tag_report["arms"]["repair"]["blockers"], [])

    def test_read_only_audit_untagged_arms_make_zero_detail_requests(self):
        rows = [{"id": "list-only", "subject": repair.SUBJECT, "scheduled_at": "2026-07-28T13:00:00Z"}]
        result = audit.enrich_tagged_arm_candidates(
            rows,
            {"historical": repair.SUBJECT},
            {"historical": (dt.date(2026, 7, 28), dt.date(2026, 7, 31))},
            {},
            dt.datetime(2026, 7, 1, tzinfo=dt.timezone.utc),
            repair.TIMEZONE,
            "fixture-token",
            audit.try_parse_time,
            fetch=lambda *_args: self.fail("untagged arm must not fetch details"),
        )
        self.assertIs(result, rows)

    def test_read_only_audit_detail_fetch_honors_429_and_fails_closed(self):
        class FakeClock:
            now = 0.0

            @classmethod
            def clock(cls):
                return cls.now

            @classmethod
            def sleep(cls, seconds):
                cls.now += seconds

        attempts = []

        def retry_once(_url, _headers):
            attempts.append(FakeClock.now)
            if len(attempts) == 1:
                raise urllib.error.HTTPError("fixture", 429, "limited", {"Retry-After": "1"}, None)
            return {"id": "provider-id", "tags": [{"name": "campaign", "value": repair.CAMPAIGN_TAG}]}

        client = audit.ResendReadClient(
            "fixture-token", fetch=retry_once,
            sleep_fn=FakeClock.sleep, clock_fn=FakeClock.clock,
        )
        detail = audit.fetch_resend_detail(client, "provider-id")
        self.assertEqual(detail["id"], "provider-id")
        self.assertEqual(attempts, [0.0, 1.0])
        with self.assertRaisesRegex(RuntimeError, "tags are missing or malformed"):
            audit.fetch_resend_detail(
                audit.ResendReadClient(
                    "fixture-token",
                    fetch=lambda *_args: {"id": "missing-tags"},
                    sleep_fn=FakeClock.sleep,
                    clock_fn=FakeClock.clock,
                ),
                "missing-tags",
            )

    def test_read_only_audit_shared_client_paces_list_429_and_detail(self):
        class FakeClock:
            now = 0.0

            @classmethod
            def clock(cls):
                return cls.now

            @classmethod
            def sleep(cls, seconds):
                cls.now += seconds

        calls = []

        def fetch(url, _headers):
            kind = "list" if "?" in url else "detail"
            calls.append((kind, FakeClock.now))
            if len(calls) == 1:
                raise urllib.error.HTTPError("redacted", 429, "limited", {"Retry-After": "0.5"}, None)
            if kind == "list":
                return {"data": [{
                    "id": "row-1", "subject": repair.SUBJECT,
                    "scheduled_at": "2026-08-04T13:00:00Z", "last_event": "scheduled",
                    "to": ["fixture@example.test"],
                }], "has_more": False}
            return {"id": "row-1", "tags": {"campaign": repair.CAMPAIGN_TAG, "arm": repair.ARM_TAG}}

        client = audit.ResendReadClient(
            "fixture-token", fetch=fetch,
            sleep_fn=FakeClock.sleep, clock_fn=FakeClock.clock,
        )
        rows = audit.fetch_resend_pages(client)
        enriched = audit.enrich_tagged_arm_candidates(
            rows,
            {"repair": repair.SUBJECT},
            {"repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
            {"repair": {"campaign": repair.CAMPAIGN_TAG, "arm": repair.ARM_TAG}},
            dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc),
            repair.TIMEZONE,
            "fixture-token",
            audit.try_parse_time,
            client=client,
        )
        self.assertEqual(enriched[0]["tags"]["campaign"], repair.CAMPAIGN_TAG)
        self.assertEqual(calls, [("list", 0.0), ("list", 0.5), ("detail", 0.75)])

    def test_read_only_audit_exhausted_list_retry_error_is_redacted(self):
        secret_fragments = ["person@example.test", "provider-sensitive-id", "secret-token", "response-body"]

        def always_limited(_url, _headers):
            raise urllib.error.HTTPError(
                "https://api.resend.com/emails?after=provider-sensitive-id",
                429,
                "person@example.test response-body secret-token",
                {"Retry-After": "0"},
                None,
            )

        client = audit.ResendReadClient(
            "secret-token", fetch=always_limited,
            sleep_fn=lambda _seconds: None, clock_fn=lambda: 0.0,
        )
        with self.assertRaises(RuntimeError) as raised:
            audit.fetch_resend_pages(client)
        self.assertEqual(str(raised.exception), "Resend read request exhausted rate-limit retries")
        self.assertTrue(all(fragment not in str(raised.exception) for fragment in secret_fragments))

    def test_read_only_audit_arm_tag_validation_fails_closed(self):
        self.assertEqual(
            audit.parse_arm_tags(["repair=campaign:wave3", "repair=arm:named-sales"]),
            {"repair": {"campaign": "wave3", "arm": "named-sales"}},
        )
        for invalid in ("repair", "repair=campaign", "bad label=campaign:wave3", "repair=:wave3", "repair=campaign:"):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                audit.parse_arm_tags([invalid])
        with self.assertRaisesRegex(RuntimeError, "Duplicate --arm-tag"):
            audit.parse_arm_tags(["repair=campaign:wave3", "repair=campaign:wave3"])
        with self.assertRaisesRegex(RuntimeError, "Arm-tag labels"):
            audit.build_arm_window_report(
                [], [], {"repair": repair.SUBJECT},
                {"repair": (dt.date(2026, 8, 4), dt.date(2026, 8, 5))},
                dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc), repair.TIMEZONE, {},
                arm_tags={"other": {"campaign": "wave3"}},
            )

    def test_wrapper_repair_history_forces_100_pages_without_changing_default(self):
        check_inbox = HELPER.parent / "check-inbox.sh"
        source = check_inbox.read_text(encoding="utf-8")
        start = source.index("  repair_history_snapshot() {")
        end = source.index("\n\n  repair_kv_snapshot()", start)
        function_source = source[start:end].strip()
        target = self.root / "history-pages.txt"
        script = f'''set -euo pipefail
RESEND_FETCH_MAX_PAGES=25
reset_resend_sent_cache() {{ :; }}
get_resend_sent_json() {{ printf "%s" "$RESEND_FETCH_MAX_PAGES"; }}
{function_source}
repair_history_snapshot "{target}"
printf "|%s" "$RESEND_FETCH_MAX_PAGES"
'''
        result = __import__("subprocess").run(["bash", "-c", script], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "100")
        self.assertEqual(result.stdout, "|25")

    def test_campaign_repair_mktemp_templates_are_terminal_and_repeat_safe(self):
        import re
        import subprocess
        source = (HELPER.parent / "check-inbox.sh").read_text(encoding="utf-8")
        templates = re.findall(r'mktemp "\$REPAIR_RUNTIME/([^"]+)"', source)
        self.assertGreaterEqual(len(templates), 8)
        self.assertTrue(all(re.search(r"X{6}$", template) for template in templates), templates)
        created = []
        for template in sorted(set(templates)):
            first = subprocess.run(["mktemp", str(self.root / template)], text=True, capture_output=True, check=False)
            second = subprocess.run(["mktemp", str(self.root / template)], text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertNotEqual(first.stdout.strip(), second.stdout.strip())
            created.extend([first.stdout.strip(), second.stdout.strip()])
        self.assertFalse(any(Path(path).name in {"history.XXXXXX.json", "opt-outs.XXXXXX.json", "suppressions.XXXXXX.json"} for path in created))


if __name__ == "__main__":
    unittest.main()
