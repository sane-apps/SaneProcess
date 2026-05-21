#!/usr/bin/env python3
import importlib.util
import os
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).with_name("ls-sales.py")
SPEC = importlib.util.spec_from_file_location("ls_sales", MODULE_PATH)
LS_SALES = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(LS_SALES)


def make_order(
    status="paid",
    refunded=False,
    total=699,
    created_at="2026-03-26T12:00:00Z",
    order_id="123",
    order_number=111,
    product_name="SaneClip",
    user_name="Test User",
    user_email="user@example.com",
):
    return {
        "id": order_id,
        "attributes": {
            "status": status,
            "refunded": refunded,
            "total": total,
            "subtotal_usd": total,
            "tax_usd": 0,
            "currency": "USD",
            "created_at": created_at,
            "updated_at": created_at,
            "order_number": order_number,
            "user_name": user_name,
            "user_email": user_email,
            "first_order_item": {"product_name": product_name},
        },
    }


class LsSalesTests(unittest.TestCase):
    def test_fetch_orders_follows_lemon_links_next(self):
        calls = []

        def fake_run(cmd, capture_output, text):
            url = cmd[5]
            calls.append(url)
            page_one = {
                "data": [make_order(order_id="1")],
                "links": {"next": "https://api.lemonsqueezy.com/v1/orders?page%5Bnumber%5D=2&page%5Bsize%5D=100"},
            }
            page_two = {
                "data": [make_order(order_id="2")],
                "links": {"next": None},
            }
            stdout = json.dumps(page_one if len(calls) == 1 else page_two)
            return SimpleNamespace(returncode=0, stdout=stdout, stderr="")

        with mock.patch.object(LS_SALES.subprocess, "run", side_effect=fake_run):
            orders = LS_SALES.fetch_orders("api-key")

        self.assertEqual([order["id"] for order in orders], ["1", "2"])
        self.assertIn("page%5Bsize%5D=100", calls[0])
        self.assertEqual(calls[1], "https://api.lemonsqueezy.com/v1/orders?page%5Bnumber%5D=2&page%5Bsize%5D=100")

    def test_fetch_orders_retries_transient_non_json_response(self):
        calls = []

        def fake_run(_cmd, capture_output, text):
            calls.append(1)
            if len(calls) == 1:
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout=json.dumps({"data": [], "links": {}}), stderr="")

        with mock.patch.object(LS_SALES.subprocess, "run", side_effect=fake_run), \
             mock.patch("time.sleep"):
            orders = LS_SALES.fetch_orders("api-key")

        self.assertEqual(orders, [])
        self.assertEqual(len(calls), 2)

    def test_filter_orders_excludes_refunded_by_default(self):
        args = SimpleNamespace(month=False, days=None, json=False, include_refunded=False)
        orders = [
            make_order(status="paid", refunded=False),
            make_order(status="refunded", refunded=True),
        ]
        filtered = LS_SALES.filter_orders(orders, args)
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["attributes"]["status"], "paid")

    def test_filter_orders_includes_refunded_for_json(self):
        args = SimpleNamespace(month=False, days=None, json=True, include_refunded=False)
        orders = [
            make_order(status="paid", refunded=False),
            make_order(status="refunded", refunded=True),
        ]
        filtered = LS_SALES.filter_orders(orders, args)
        self.assertEqual(len(filtered), 2)

    def test_validate_refund_approval_requires_env_and_note(self):
        args = SimpleNamespace(proof_file="/tmp/refund.txt", approval_note=None)
        old = os.environ.pop("SANE_REFUND_APPROVED", None)
        try:
            with self.assertRaises(SystemExit):
                LS_SALES.validate_refund_approval(args)
        finally:
            if old is not None:
                os.environ["SANE_REFUND_APPROVED"] = old

    def test_validate_refund_approval_accepts_note(self):
        with tempfile.TemporaryDirectory() as tmp:
            note = Path(tmp) / "approval.txt"
            note.write_text("User approved refund.\nBug still unresolved after 24 hours.\n", encoding="utf-8")
            args = SimpleNamespace(proof_file=str(Path(tmp) / "refund.txt"), approval_note=str(note))
            old = os.environ.get("SANE_REFUND_APPROVED")
            os.environ["SANE_REFUND_APPROVED"] = "1"
            try:
                note_path, note_text = LS_SALES.validate_refund_approval(args)
            finally:
                if old is None:
                    os.environ.pop("SANE_REFUND_APPROVED", None)
                else:
                    os.environ["SANE_REFUND_APPROVED"] = old
            self.assertEqual(note_path, note)
            self.assertIn("User approved refund", note_text)

    def test_validate_refund_approval_rejects_customer_only_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            note = Path(tmp) / "approval.txt"
            note.write_text("Customer requested a refund because the app was not a fit.\n", encoding="utf-8")
            args = SimpleNamespace(proof_file=str(Path(tmp) / "refund.txt"), approval_note=str(note))
            old = os.environ.get("SANE_REFUND_APPROVED")
            os.environ["SANE_REFUND_APPROVED"] = "1"
            try:
                with self.assertRaises(SystemExit):
                    LS_SALES.validate_refund_approval(args)
            finally:
                if old is None:
                    os.environ.pop("SANE_REFUND_APPROVED", None)
                else:
                    os.environ["SANE_REFUND_APPROVED"] = old

    def test_write_refund_audit_record_persists_proof_and_note(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_dir = LS_SALES.REFUND_AUDIT_DIR
            LS_SALES.REFUND_AUDIT_DIR = Path(tmp) / "refunds"
            proof = Path(tmp) / "proof.txt"
            proof.write_text("Refund proof body\n", encoding="utf-8")
            try:
                summary = {
                    "id": "8188124",
                    "order_number": 270691572,
                    "user_name": "Alan Makota",
                    "user_email": "x61wq1ve@addy.to",
                    "product": "SaneBar",
                    "total_formatted": "$14.99",
                    "refunded_amount_formatted": "$14.99",
                    "refunded": True,
                    "refunded_at": "2026-04-30T07:38:09.000000Z",
                    "receipt_url": "https://example.test/receipt",
                }
                args = SimpleNamespace(
                    proof_file=str(proof),
                    customer_thread="Lemon Squeezy dashboard",
                    approval_source="external provider refund",
                    amount=None,
                )
                audit_path = LS_SALES.write_refund_audit_record(
                    summary,
                    "external",
                    args,
                    approval_note_path="/tmp/note.txt",
                    approval_note_text="Owner approved external audit note.",
                    action="already_refunded_observed",
                )
                text = audit_path.read_text(encoding="utf-8")
                self.assertIn("Order number: 270691572", text)
                self.assertIn("Lemon Squeezy dashboard", text)
                self.assertIn("Refund proof body", text)
            finally:
                LS_SALES.REFUND_AUDIT_DIR = old_dir

    def test_find_customer_order_candidates_surfaces_alt_email_match(self):
        orders = [
            make_order(
                order_id="7980001",
                order_number=270691164,
                product_name="SaneBar",
                user_name="Rene Köcher",
                user_email="heals@saneapps.tag.heals.codes",
            ),
            make_order(
                order_id="7980310",
                order_number=270691527,
                product_name="SaneBar",
                user_name="Syed Raed Al Hashmi",
                user_email="raed-a@outlook.com",
            ),
            make_order(
                order_id="7980352",
                order_number=270691528,
                product_name="SaneBar",
                user_name="Syed Raed Al Hashmi",
                user_email="raed-a@outlook.com",
            ),
        ]
        candidates = LS_SALES.find_customer_order_candidates(
            orders,
            query_email="reed@reed-a.ca",
            query_name="Reed",
            product="SaneBar",
        )
        self.assertEqual(len(candidates), 3)
        self.assertEqual(candidates[0]["order_number"], 270691527)
        self.assertGreater(candidates[0]["match_score"], 0)
        self.assertIn("repeat_product_orders=2", candidates[0]["match_reasons"])
        self.assertEqual(candidates[-1]["order_number"], 270691164)

    def test_refund_duplicate_license_success_writes_proof(self):
        keep_key = "KEEP-KEY"
        refund_key = "REFUND-KEY"
        orders = [
            make_order(
                order_id="7980352",
                order_number=270691528,
                product_name="SaneBar",
                user_name="Syed Raed Al Hashmi",
                user_email="raed-a@outlook.com",
            )
        ]
        keep_summary = {
            "valid": True,
            "license_key_id": 1,
            "license_key": keep_key,
            "license_key_status": "inactive",
            "order_id": "7980310",
            "customer_id": 8245281,
            "customer_name": "Syed Raed Al Hashmi",
            "customer_email": "raed-a@outlook.com",
            "product_id": 778575,
            "product_name": "SaneBar",
            "raw": {},
        }
        refund_summary = {
            "valid": True,
            "license_key_id": 2,
            "license_key": refund_key,
            "license_key_status": "inactive",
            "order_id": "7980352",
            "customer_id": 8245281,
            "customer_name": "Syed Raed Al Hashmi",
            "customer_email": "raed-a@outlook.com",
            "product_id": 778575,
            "product_name": "SaneBar",
            "raw": {},
        }
        refund_summary_final = dict(refund_summary, valid=False, license_key_status="disabled")

        old_validate_refund_approval = LS_SALES.validate_refund_approval
        old_validate_license_key_public = LS_SALES.validate_license_key_public
        old_issue_order_refund = LS_SALES.issue_order_refund
        old_disable_license_key = LS_SALES.disable_license_key
        try:
            with tempfile.TemporaryDirectory() as tmp:
                proof = Path(tmp) / "duplicate_refund.txt"
                note = Path(tmp) / "approval.txt"
                note.write_text("Approved duplicate refund.\n", encoding="utf-8")
                args = SimpleNamespace(
                    proof_file=str(proof),
                    approval_note=str(note),
                    keep_license_key=keep_key,
                    refund_duplicate_license_key=refund_key,
                    refund_order_number="270691528",
                    amount=None,
                    customer_thread="email #542",
                    approval_source="owner approval note",
                )

                calls = []

                LS_SALES.validate_refund_approval = lambda _args, refund_type="discretionary": (note, "User approved duplicate refund.")
                old_dir = LS_SALES.REFUND_AUDIT_DIR
                LS_SALES.REFUND_AUDIT_DIR = Path(tmp) / "audit"

                def fake_validate_license_key_public(key, allow_failure=False):
                    calls.append(("validate", key))
                    if key == keep_key:
                        return dict(keep_summary)
                    if key == refund_key and calls.count(("validate", refund_key)) == 1:
                        return dict(refund_summary)
                    if key == refund_key:
                        return dict(refund_summary_final)
                    raise AssertionError(f"unexpected key {key}")

                LS_SALES.validate_license_key_public = fake_validate_license_key_public
                LS_SALES.issue_order_refund = lambda api_key, order_id, amount=None: make_order(
                    status="refunded",
                    refunded=True,
                    order_id=order_id,
                    order_number=270691528,
                    product_name="SaneBar",
                    user_name="Syed Raed Al Hashmi",
                    user_email="raed-a@outlook.com",
                )
                LS_SALES.disable_license_key = lambda api_key, license_key_id: {
                    "license_key_id": license_key_id,
                    "license_key": refund_key,
                    "status": "disabled",
                    "disabled": True,
                    "order_id": "7980352",
                    "customer_email": "raed-a@outlook.com",
                    "customer_name": "Syed Raed Al Hashmi",
                    "product_id": 778575,
                    "raw": {},
                }

                summary = LS_SALES.refund_duplicate_license("api-key", orders, args)
                self.assertEqual(summary["refunded_order"]["order_number"], 270691528)
                self.assertTrue(summary["disabled_license"]["disabled"])
                self.assertTrue(proof.exists())
                proof_text = proof.read_text(encoding="utf-8")
                self.assertIn("Refunded order number: 270691528", proof_text)
                self.assertIn(f"Kept key: {keep_key}", proof_text)
                self.assertIn(f"Refunded key: {refund_key}", proof_text)
                self.assertEqual(len(list((Path(tmp) / "audit").glob("*.md"))), 1)
        finally:
            LS_SALES.REFUND_AUDIT_DIR = old_dir
            LS_SALES.validate_refund_approval = old_validate_refund_approval
            LS_SALES.validate_license_key_public = old_validate_license_key_public
            LS_SALES.issue_order_refund = old_issue_order_refund
            LS_SALES.disable_license_key = old_disable_license_key

    def test_refund_duplicate_license_rejects_order_mismatch(self):
        keep_key = "KEEP-KEY"
        refund_key = "REFUND-KEY"
        orders = [
            make_order(
                order_id="7989999",
                order_number=270691528,
                product_name="SaneBar",
                user_name="Syed Raed Al Hashmi",
                user_email="raed-a@outlook.com",
            )
        ]
        old_validate_refund_approval = LS_SALES.validate_refund_approval
        old_validate_license_key_public = LS_SALES.validate_license_key_public
        try:
            with tempfile.TemporaryDirectory() as tmp:
                note = Path(tmp) / "approval.txt"
                note.write_text("Approved duplicate refund.\n", encoding="utf-8")
                args = SimpleNamespace(
                    proof_file=str(Path(tmp) / "proof.txt"),
                    approval_note=str(note),
                    keep_license_key=keep_key,
                    refund_duplicate_license_key=refund_key,
                    refund_order_number="270691528",
                    amount=None,
                )
                LS_SALES.validate_refund_approval = lambda _args, refund_type="discretionary": (note, "User approved duplicate refund.")
                LS_SALES.validate_license_key_public = lambda key, allow_failure=False: {
                    "valid": True,
                    "license_key_id": 1 if key == keep_key else 2,
                    "license_key": key,
                    "license_key_status": "inactive",
                    "order_id": "7980352" if key == refund_key else "7980310",
                    "customer_id": 8245281,
                    "customer_name": "Syed Raed Al Hashmi",
                    "customer_email": "raed-a@outlook.com",
                    "product_id": 778575,
                    "product_name": "SaneBar",
                    "raw": {},
                }
                with self.assertRaises(SystemExit):
                    LS_SALES.refund_duplicate_license("api-key", orders, args)
        finally:
            LS_SALES.validate_refund_approval = old_validate_refund_approval
            LS_SALES.validate_license_key_public = old_validate_license_key_public

    def test_refund_duplicate_license_post_validation_failure_is_soft(self):
        keep_key = "KEEP-KEY"
        refund_key = "REFUND-KEY"
        orders = [
            make_order(
                order_id="7980352",
                order_number=270691528,
                product_name="SaneBar",
                user_name="Syed Raed Al Hashmi",
                user_email="raed-a@outlook.com",
            )
        ]
        old_validate_refund_approval = LS_SALES.validate_refund_approval
        old_validate_license_key_public = LS_SALES.validate_license_key_public
        old_issue_order_refund = LS_SALES.issue_order_refund
        old_disable_license_key = LS_SALES.disable_license_key
        try:
            with tempfile.TemporaryDirectory() as tmp:
                proof = Path(tmp) / "duplicate_refund.txt"
                note = Path(tmp) / "approval.txt"
                note.write_text("Approved duplicate refund.\n", encoding="utf-8")
                args = SimpleNamespace(
                    proof_file=str(proof),
                    approval_note=str(note),
                    keep_license_key=keep_key,
                    refund_duplicate_license_key=refund_key,
                    refund_order_number="270691528",
                    amount=None,
                )

                def fake_validate_license_key_public(key, allow_failure=False):
                    if key == keep_key and not allow_failure:
                        return {
                            "valid": True,
                            "license_key_id": 1,
                            "license_key": keep_key,
                            "license_key_status": "inactive",
                            "order_id": "7980310",
                            "customer_id": 8245281,
                            "customer_name": "Syed Raed Al Hashmi",
                            "customer_email": "raed-a@outlook.com",
                            "product_id": 778575,
                            "product_name": "SaneBar",
                            "raw": {},
                            "validation_failed": False,
                        }
                    if key == refund_key and not allow_failure:
                        return {
                            "valid": True,
                            "license_key_id": 2,
                            "license_key": refund_key,
                            "license_key_status": "inactive",
                            "order_id": "7980352",
                            "customer_id": 8245281,
                            "customer_name": "Syed Raed Al Hashmi",
                            "customer_email": "raed-a@outlook.com",
                            "product_id": 778575,
                            "product_name": "SaneBar",
                            "raw": {},
                            "validation_failed": False,
                        }
                    return {
                        "valid": False,
                        "error": "post-action validation timeout",
                        "license_key_id": None,
                        "license_key": key,
                        "license_key_status": "unknown",
                        "activation_limit": None,
                        "activation_usage": None,
                        "order_id": None,
                        "order_item_id": None,
                        "customer_id": None,
                        "customer_name": "",
                        "customer_email": "",
                        "customer_email_raw": "",
                        "product_id": None,
                        "product_name": "",
                        "store_id": None,
                        "raw": None,
                        "disabled": False,
                        "validation_failed": True,
                    }

                LS_SALES.validate_refund_approval = lambda _args, refund_type="discretionary": (note, "User approved duplicate refund.")
                LS_SALES.validate_license_key_public = fake_validate_license_key_public
                LS_SALES.issue_order_refund = lambda api_key, order_id, amount=None: make_order(
                    status="refunded",
                    refunded=True,
                    order_id=order_id,
                    order_number=270691528,
                    product_name="SaneBar",
                    user_name="Syed Raed Al Hashmi",
                    user_email="raed-a@outlook.com",
                )
                LS_SALES.disable_license_key = lambda api_key, license_key_id: {
                    "license_key_id": license_key_id,
                    "license_key": refund_key,
                    "status": "disabled",
                    "disabled": True,
                    "order_id": "7980352",
                    "customer_email": "raed-a@outlook.com",
                    "customer_name": "Syed Raed Al Hashmi",
                    "product_id": 778575,
                    "raw": {},
                }

                summary = LS_SALES.refund_duplicate_license("api-key", orders, args)
                self.assertTrue(summary["kept_license"]["validation_failed"])
                self.assertTrue(summary["refunded_license_final"]["validation_failed"])
                self.assertTrue(proof.exists())
                proof_text = proof.read_text(encoding="utf-8")
                self.assertIn("Kept key post-check warning: post-action validation timeout", proof_text)
                self.assertIn("Refunded key post-check warning: post-action validation timeout", proof_text)
        finally:
            LS_SALES.validate_refund_approval = old_validate_refund_approval
            LS_SALES.validate_license_key_public = old_validate_license_key_public
            LS_SALES.issue_order_refund = old_issue_order_refund
            LS_SALES.disable_license_key = old_disable_license_key


if __name__ == "__main__":
    unittest.main()
