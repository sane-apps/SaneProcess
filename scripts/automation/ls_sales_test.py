#!/usr/bin/env python3
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


MODULE_PATH = Path(__file__).with_name("ls-sales.py")
SPEC = importlib.util.spec_from_file_location("ls_sales", MODULE_PATH)
LS_SALES = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(LS_SALES)


def make_order(status="paid", refunded=False, total=699, created_at="2026-03-26T12:00:00Z"):
    return {
        "id": "123",
        "attributes": {
            "status": status,
            "refunded": refunded,
            "total": total,
            "subtotal_usd": total,
            "tax_usd": 0,
            "currency": "USD",
            "created_at": created_at,
            "updated_at": created_at,
            "order_number": 111,
            "first_order_item": {"product_name": "SaneClip"},
        },
    }


class LsSalesTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
