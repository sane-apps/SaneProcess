#!/usr/bin/env python3
# frozen_string_literal: false
"""LemonSqueezy sales & fee report for SaneApps.

Usage:
  ls-sales.py              # Full report (all time)
  ls-sales.py --daily      # Today/yesterday/week/all-time breakdown
  ls-sales.py --month      # Current month only
  ls-sales.py --days 7     # Last 7 days
  ls-sales.py --fees       # Fee breakdown only
  ls-sales.py --products   # Revenue by product
  ls-sales.py --product-variants  # Revenue by product + variant
  ls-sales.py --refund-order 1234 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt
  ls-sales.py --refund-order-number 5678 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt
  ls-sales.py --json       # Raw JSON output (for piping)
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

INFRA_SCRIPTS_DIR = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(INFRA_SCRIPTS_DIR))
from customer_email_corrections import canonical_email

# Store-specific fee configuration.
# Defaults reflect SaneApps Lemon Squeezy pricing update confirmed on 2026-03-03.
PLATFORM_FEE_RATE = float(os.environ.get("LEMONSQUEEZY_PLATFORM_FEE_RATE", "0.05"))
INTERNATIONAL_FEE_RATE = float(os.environ.get("LEMONSQUEEZY_INTERNATIONAL_FEE_RATE", "0.015"))
FLAT_FEE_BEFORE = float(os.environ.get("LEMONSQUEEZY_FLAT_FEE_CENTS_BEFORE", "50")) / 100
FLAT_FEE_AFTER = float(os.environ.get("LEMONSQUEEZY_FLAT_FEE_CENTS_AFTER", "30")) / 100
FLAT_FEE_EFFECTIVE_UTC_RAW = os.environ.get(
    "LEMONSQUEEZY_FLAT_FEE_EFFECTIVE_UTC",
    "2026-03-03T05:47:45Z",
)


def parse_order_timestamp(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


FLAT_FEE_EFFECTIVE_UTC = parse_order_timestamp(FLAT_FEE_EFFECTIVE_UTC_RAW)
ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()


def load_env_cache():
    if not ENV_CACHE_FILE.is_file():
        return
    try:
        for raw_line in ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, raw_value = line.split("=", 1)
            key = key.strip()
            if not key or key in os.environ:
                continue
            parts = shlex.split(raw_value, posix=True)
            value = parts[0] if len(parts) == 1 else raw_value.strip()
            os.environ[key] = os.path.expandvars(value)
    except OSError:
        return


def persist_secret_to_env_cache(value, *env_names):
    if not value or os.environ.get("SANE_ENV_CACHE_WRITE", "1") == "0":
        return
    names = [name for name in env_names if name]
    if not names:
        return
    ENV_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        ENV_CACHE_FILE.parent.chmod(0o700)
    except OSError:
        pass
    lines = []
    if ENV_CACHE_FILE.exists():
        lines = ENV_CACHE_FILE.read_text(encoding="utf-8").splitlines()
    filtered = []
    for line in lines:
        stripped = line.strip()
        if any(stripped.startswith(f"export {name}=") for name in names):
            continue
        filtered.append(line)
    for name in names:
        filtered.append(f"export {name}={shlex.quote(value)}")
    ENV_CACHE_FILE.write_text("\n".join(filtered) + "\n", encoding="utf-8")
    ENV_CACHE_FILE.chmod(0o600)


def get_api_key():
    load_env_cache()
    # Try env var first (headless/LaunchAgent contexts)
    key = os.environ.get("LEMONSQUEEZY_API_KEY", "")
    if key:
        return key
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        print("Error: No LemonSqueezy API key found.", file=sys.stderr)
        print("  Set LEMONSQUEEZY_API_KEY in ~/.config/nv/env or the environment.", file=sys.stderr)
        sys.exit(1)
    # Fall back to keychain (interactive sessions)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "lemonsqueezy", "-a", "api_key", "-w"],
        capture_output=True, text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: No LemonSqueezy API key found.", file=sys.stderr)
        print("  Set LEMONSQUEEZY_API_KEY in ~/.config/nv/env or the environment, or add it to keychain:", file=sys.stderr)
        print("  security add-generic-password -s lemonsqueezy -a api_key -w YOUR_KEY", file=sys.stderr)
        sys.exit(1)
    persist_secret_to_env_cache(key, "LEMONSQUEEZY_API_KEY")
    return key


def fetch_orders(api_key):
    all_orders = []
    page = 1
    while True:
        result = subprocess.run(
            ["curl", "-s", "-g", "--max-time", "15",
             f"https://api.lemonsqueezy.com/v1/orders?page[size]=50&page[number]={page}",
             "-H", f"Authorization: Bearer {api_key}",
             "-H", "Accept: application/vnd.api+json"],
            capture_output=True, text=True,
        )
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            body = (result.stdout or "").lower()
            if "just a moment" in body:
                raise RuntimeError("LemonSqueezy API is returning a Cloudflare challenge. Order lookup is temporarily unavailable.")
            raise RuntimeError(f"Bad API response on page {page}")
        orders = data.get("data", [])
        all_orders.extend(orders)
        if len(orders) < 50:
            break
        page += 1
    return all_orders


def order_to_summary(order):
    attrs = order.get("attributes", {})
    item = attrs.get("first_order_item") or {}
    raw_email = attrs.get("user_email", "")
    return {
        "id": order.get("id"),
        "order_number": attrs.get("order_number"),
        "status": attrs.get("status"),
        "refunded": attrs.get("refunded", False),
        "refunded_amount_formatted": attrs.get("refunded_amount_formatted", "$0.00"),
        "refunded_at": attrs.get("refunded_at"),
        "created_at": attrs.get("created_at"),
        "updated_at": attrs.get("updated_at"),
        "user_name": attrs.get("user_name", ""),
        "user_email": canonical_email(raw_email),
        "user_email_raw": raw_email,
        "product": item.get("product_name", "Unknown"),
        "total_formatted": attrs.get("total_formatted", "$0.00"),
        "receipt_url": (attrs.get("urls") or {}).get("receipt"),
    }


def find_order_by_number(orders, order_number):
    needle = str(order_number).strip()
    for order in orders:
        if str((order.get("attributes") or {}).get("order_number", "")).strip() == needle:
            return order
    return None


def issue_order_refund(api_key, order_id, amount=None):
    payload = {
        "data": {
            "type": "orders",
            "id": str(order_id),
        }
    }
    if amount is not None:
        payload["data"]["attributes"] = {"amount": int(amount)}

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "-X",
            "POST",
            f"https://api.lemonsqueezy.com/v1/orders/{order_id}/refund",
            "-H",
            f"Authorization: Bearer {api_key}",
            "-H",
            "Accept: application/vnd.api+json",
            "-H",
            "Content-Type: application/vnd.api+json",
            "-d",
            json.dumps(payload),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Error: Refund request failed for order {order_id}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    try:
        response = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        body = (result.stdout or "").lower()
        if "just a moment" in body:
            print("Error: LemonSqueezy API is returning a Cloudflare challenge. Refund did not go through.", file=sys.stderr)
        else:
            print(f"Error: Refund response was not valid JSON: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    if "errors" in response:
        print(json.dumps(response["errors"], indent=2), file=sys.stderr)
        sys.exit(1)
    data = response.get("data")
    if not isinstance(data, dict):
        print(f"Error: Refund response missing order payload: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    return data


def validate_refund_approval(args):
    approval_gate = os.environ.get("SANE_REFUND_APPROVED", "").strip()
    if approval_gate != "1":
        print("Error: Refund blocked.", file=sys.stderr)
        print("  Refunds require explicit user approval plus a documented unresolved bug (>24h).", file=sys.stderr)
        print("  Re-run with: SANE_REFUND_APPROVED=1 ...", file=sys.stderr)
        sys.exit(1)

    if not args.proof_file:
        print("Error: Refund blocked. --proof-file is required so refund actions leave an audit trail.", file=sys.stderr)
        sys.exit(1)

    if not args.approval_note:
        print("Error: Refund blocked. --approval-note is required.", file=sys.stderr)
        print("  The note should capture user approval and the documented bug/unresolved status.", file=sys.stderr)
        sys.exit(1)

    note_path = Path(args.approval_note).expanduser()
    if not note_path.is_file():
        print(f"Error: Refund approval note not found: {note_path}", file=sys.stderr)
        sys.exit(1)

    note_text = note_path.read_text(encoding="utf-8").strip()
    if not note_text:
        print(f"Error: Refund approval note is empty: {note_path}", file=sys.stderr)
        sys.exit(1)

    return note_path, note_text


def write_proof_file(path, summary, approval_note_path=None, approval_note_text=None):
    lines = [
        "Lemon Squeezy refund confirmation",
        f"Order ID: {summary.get('id')}",
        f"Order number: {summary.get('order_number')}",
        f"Customer: {summary.get('user_name') or '?'} <{summary.get('user_email') or '?'}>",
        f"Product: {summary.get('product')}",
        f"Order total: {summary.get('total_formatted')}",
        f"Refunded amount: {summary.get('refunded_amount_formatted')}",
        f"Refunded flag: {summary.get('refunded')}",
        f"Refunded at: {summary.get('refunded_at') or 'partial/not-finalized timestamp unavailable'}",
        f"Receipt: {summary.get('receipt_url') or 'n/a'}",
        f"Updated at: {summary.get('updated_at') or 'n/a'}",
    ]
    if approval_note_path:
        lines.append(f"Approval note: {approval_note_path}")
    if approval_note_text:
        lines.extend([
            "",
            "Approval note contents:",
            approval_note_text,
        ])
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def print_refund_summary(summary):
    print("Refund issued")
    print(f"  Order ID: {summary.get('id')}")
    print(f"  Order number: {summary.get('order_number')}")
    print(f"  Customer: {summary.get('user_name') or '?'} <{summary.get('user_email') or '?'}>")
    print(f"  Product: {summary.get('product')}")
    print(f"  Order total: {summary.get('total_formatted')}")
    print(f"  Refunded amount: {summary.get('refunded_amount_formatted')}")
    print(f"  Refunded flag: {summary.get('refunded')}")
    print(f"  Refunded at: {summary.get('refunded_at') or 'partial/not-finalized timestamp unavailable'}")
    if summary.get("receipt_url"):
        print(f"  Receipt: {summary['receipt_url']}")


def flat_fee_for_order(created_at):
    if not FLAT_FEE_EFFECTIVE_UTC:
        return FLAT_FEE_AFTER
    if created_at and created_at >= FLAT_FEE_EFFECTIVE_UTC:
        return FLAT_FEE_AFTER
    return FLAT_FEE_BEFORE


def calc_fee(subtotal, currency, created_at=None):
    """Calculate estimated LS fee for an order."""
    flat = flat_fee_for_order(created_at)
    base = (subtotal * PLATFORM_FEE_RATE) + flat
    intl = subtotal * INTERNATIONAL_FEE_RATE if currency != "USD" else 0
    return base + intl, intl, flat


def filter_orders(orders, args):
    """Filter orders by date range."""
    now = datetime.now(timezone.utc)
    cutoff = None
    include_refunded = bool(getattr(args, "include_refunded", False) or args.json)

    if args.month:
        cutoff = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    elif args.days:
        cutoff = now - timedelta(days=args.days)

    filtered = []
    for o in orders:
        a = o["attributes"]
        status = str(a.get("status") or "").strip().lower()
        refunded = bool(a.get("refunded", False))
        if include_refunded:
            if status not in {"paid", "refunded"} and not refunded:
                continue
        else:
            if status != "paid":
                continue
        if a.get("total", 0) == 0:
            continue
        if cutoff:
            created = parse_order_timestamp(a.get("created_at"))
            if created is None:
                continue
            if created < cutoff:
                continue
        filtered.append(o)
    return filtered


def print_monthly(orders):
    """Monthly breakdown with fees."""
    monthly = defaultdict(lambda: {"revenue": 0, "orders": 0, "fees": 0, "tax": 0, "net": 0})

    for o in orders:
        a = o["attributes"]
        subtotal = a.get("subtotal_usd", 0) / 100
        tax = a.get("tax_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        fee, _, _ = calc_fee(subtotal, a.get("currency", "USD"), created)
        month = a["created_at"][:7]
        monthly[month]["revenue"] += subtotal
        monthly[month]["orders"] += 1
        monthly[month]["fees"] += fee
        monthly[month]["tax"] += tax
        monthly[month]["net"] += subtotal - fee

    print(f"{'Month':<10} {'Orders':>7} {'Revenue':>10} {'LS Fees':>10} {'Tax':>10} {'You Keep':>10} {'Fee %':>7}")
    print("-" * 82)
    for month in sorted(monthly.keys()):
        m = monthly[month]
        pct = (m["fees"] / m["revenue"] * 100) if m["revenue"] > 0 else 0
        print(f"{month:<10} {m['orders']:>7} ${m['revenue']:>9.2f} ${m['fees']:>9.2f} ${m['tax']:>9.2f} ${m['net']:>9.2f} {pct:>6.1f}%")
    print("-" * 82)

    totals = {k: sum(m[k] for m in monthly.values()) for k in ["revenue", "orders", "fees", "tax", "net"]}
    pct = (totals["fees"] / totals["revenue"] * 100) if totals["revenue"] > 0 else 0
    print(f"{'TOTAL':<10} {int(totals['orders']):>7} ${totals['revenue']:>9.2f} ${totals['fees']:>9.2f} ${totals['tax']:>9.2f} ${totals['net']:>9.2f} {pct:>6.1f}%")
    return totals


def print_fees(orders):
    """Detailed fee breakdown."""
    total_revenue = 0
    total_intl = 0
    total_flat = 0
    pre_change_flat = 0
    post_change_flat = 0
    pre_change_count = 0
    post_change_count = 0
    paid_count = 0

    for o in orders:
        a = o["attributes"]
        subtotal = a.get("subtotal_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        _, intl, flat = calc_fee(subtotal, a.get("currency", "USD"), created)
        total_revenue += subtotal
        total_intl += intl
        total_flat += flat
        paid_count += 1
        if FLAT_FEE_EFFECTIVE_UTC and created and created >= FLAT_FEE_EFFECTIVE_UTC:
            post_change_count += 1
            post_change_flat += flat
        else:
            pre_change_count += 1
            pre_change_flat += flat

    platform_pct = total_revenue * PLATFORM_FEE_RATE
    total_fees = platform_pct + total_flat + total_intl
    eff = (total_fees / total_revenue * 100) if total_revenue > 0 else 0

    print()
    print("Fee Breakdown")
    print(f"  Platform cut ({PLATFORM_FEE_RATE * 100:.1f}%):            ${platform_pct:>8.2f}")
    if pre_change_count > 0 and post_change_count > 0:
        print(f"  Per-txn flat (variable):      ${total_flat:>8.2f}")
        print(f"    Pre-change (${FLAT_FEE_BEFORE:.2f} x {pre_change_count:<4}):    ${pre_change_flat:>8.2f}")
        print(f"    Post-change (${FLAT_FEE_AFTER:.2f} x {post_change_count:<4}):   ${post_change_flat:>8.2f}")
    elif post_change_count > 0:
        print(f"  Per-txn flat (${FLAT_FEE_AFTER:.2f} x {post_change_count:<4}):   ${post_change_flat:>8.2f}")
    else:
        print(f"  Per-txn flat (${FLAT_FEE_BEFORE:.2f} x {pre_change_count:<4}):   ${pre_change_flat:>8.2f}")
    print(f"  International (+{INTERNATIONAL_FEE_RATE * 100:.1f}%):        ${total_intl:>8.2f}")
    print(f"                                ---------")
    print(f"  Total fees to LS:             ${total_fees:>8.2f}")
    print(f"  Effective rate:               {eff:>7.1f}%")
    print()
    print(f"  Gross revenue:                ${total_revenue:>8.2f}")
    print(f"  You keep:                     ${total_revenue - total_fees:>8.2f}")

    # Show what rate would be at different price points
    if paid_count > 0:
        avg = total_revenue / paid_count
        current_rate = ((avg * PLATFORM_FEE_RATE + FLAT_FEE_AFTER) / avg * 100)
        print()
        print(f"  Avg order: ${avg:.2f} -> {current_rate:.1f}% effective rate (current)")
        print()
        print("  Rate at different price points:")
        for price in [5, 10, 15, 20, 30, 50]:
            current = ((price * PLATFORM_FEE_RATE + FLAT_FEE_AFTER) / price * 100)
            if FLAT_FEE_BEFORE != FLAT_FEE_AFTER:
                legacy = ((price * PLATFORM_FEE_RATE + FLAT_FEE_BEFORE) / price * 100)
                print(f"    ${price:>3} -> {current:.1f}% current ({legacy:.1f}% legacy)")
            else:
                print(f"    ${price:>3} -> {current:.1f}%")


def print_products(orders):
    """Revenue by product."""
    products = defaultdict(lambda: {"revenue": 0, "orders": 0, "fees": 0})

    for o in orders:
        a = o["attributes"]
        item = a.get("first_order_item") or {}
        name = item.get("product_name", "Unknown")
        subtotal = a.get("subtotal_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        fee, _, _ = calc_fee(subtotal, a.get("currency", "USD"), created)
        products[name]["revenue"] += subtotal
        products[name]["orders"] += 1
        products[name]["fees"] += fee

    print()
    print(f"{'Product':<30} {'Orders':>7} {'Revenue':>10} {'LS Fees':>10} {'You Keep':>10}")
    print("-" * 72)
    for name in sorted(products, key=lambda n: products[n]["revenue"], reverse=True):
        p = products[name]
        net = p["revenue"] - p["fees"]
        print(f"{name[:29]:<30} {p['orders']:>7} ${p['revenue']:>9.2f} ${p['fees']:>9.2f} ${net:>9.2f}")


def print_product_variants(orders):
    """Revenue by product + variant."""
    products = defaultdict(lambda: {"revenue": 0, "orders": 0, "fees": 0})

    for o in orders:
        a = o["attributes"]
        item = a.get("first_order_item") or {}
        product = item.get("product_name", "Unknown")
        variant = item.get("variant_name") or "Default"
        key = f"{product} | {variant}"
        subtotal = a.get("subtotal_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        fee, _, _ = calc_fee(subtotal, a.get("currency", "USD"), created)
        products[key]["revenue"] += subtotal
        products[key]["orders"] += 1
        products[key]["fees"] += fee

    print()
    print(f"{'Product + Variant':<34} {'Orders':>7} {'Revenue':>10} {'LS Fees':>10} {'You Keep':>10}")
    print("-" * 76)
    for key in sorted(products, key=lambda k: products[k]["revenue"], reverse=True):
        p = products[key]
        net = p["revenue"] - p["fees"]
        print(f"{key[:34]:<34} {p['orders']:>7} ${p['revenue']:>9.2f} ${p['fees']:>9.2f} ${net:>9.2f}")


def print_daily(all_orders):
    """Today / Yesterday / This Week / All-time breakdown."""
    # Use local time so "today" matches the user's actual day
    now = datetime.now().astimezone()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    yesterday_start = today_start - timedelta(days=1)
    week_start = today_start - timedelta(days=7)

    buckets = {
        "Today": {"orders": 0, "revenue": 0, "fees": 0},
        "Yesterday": {"orders": 0, "revenue": 0, "fees": 0},
        "This Week": {"orders": 0, "revenue": 0, "fees": 0},
        "All Time": {"orders": 0, "revenue": 0, "fees": 0},
    }

    redemptions = {"Today": 0, "Yesterday": 0, "This Week": 0, "All Time": 0}

    for o in all_orders:
        a = o["attributes"]
        if a.get("status") != "paid":
            continue
        subtotal = a.get("subtotal_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        if created is None:
            continue

        # Track $0 discount redemptions separately (check total, not subtotal —
        # LS keeps subtotal_usd at full price and applies discount_total separately)
        if a.get("total", 0) == 0:
            redemptions["All Time"] += 1
            if created >= week_start:
                redemptions["This Week"] += 1
            if created >= today_start:
                redemptions["Today"] += 1
            elif created >= yesterday_start:
                redemptions["Yesterday"] += 1
            continue

        fee, _, _ = calc_fee(subtotal, a.get("currency", "USD"), created)

        buckets["All Time"]["orders"] += 1
        buckets["All Time"]["revenue"] += subtotal
        buckets["All Time"]["fees"] += fee

        if created >= week_start:
            buckets["This Week"]["orders"] += 1
            buckets["This Week"]["revenue"] += subtotal
            buckets["This Week"]["fees"] += fee

        if created >= today_start:
            buckets["Today"]["orders"] += 1
            buckets["Today"]["revenue"] += subtotal
            buckets["Today"]["fees"] += fee
        elif created >= yesterday_start:
            buckets["Yesterday"]["orders"] += 1
            buckets["Yesterday"]["revenue"] += subtotal
            buckets["Yesterday"]["fees"] += fee

    print(f"{'Period':<15} {'Orders':>7} {'Revenue':>10} {'LS Fees':>10} {'You Keep':>10}")
    print("-" * 55)
    for name in ["Today", "Yesterday", "This Week", "All Time"]:
        b = buckets[name]
        net = b["revenue"] - b["fees"]
        print(f"{name:<15} {b['orders']:>7} ${b['revenue']:>9.2f} ${b['fees']:>9.2f} ${net:>9.2f}")

    total_redemptions = sum(redemptions.values())
    if total_redemptions > 0:
        print()
        parts = []
        for name in ["Today", "Yesterday", "This Week", "All Time"]:
            if redemptions[name] > 0:
                parts.append(f"{name}: {redemptions[name]}")
        print(f"Discount redemptions ($0): {', '.join(parts)}")

    # Recent orders (last 5)
    recent = sorted(
        [o for o in all_orders if o["attributes"].get("status") == "paid"],
        key=lambda o: o["attributes"]["created_at"],
        reverse=True,
    )[:5]
    if recent:
        print()
        print("Recent Orders:")
        for o in recent:
            a = o["attributes"]
            item = a.get("first_order_item") or {}
            name = item.get("product_name", "Unknown")
            subtotal = a.get("subtotal_usd", 0) / 100
            date = a["created_at"][:10]
            print(f"  {date}  ${subtotal:.2f}  {name}")


def print_json(orders):
    """Raw JSON output for piping."""
    result = []
    for o in orders:
        a = o["attributes"]
        subtotal = a.get("subtotal_usd", 0) / 100
        created = parse_order_timestamp(a.get("created_at"))
        fee, intl, flat = calc_fee(subtotal, a.get("currency", "USD"), created)
        item = a.get("first_order_item") or {}
        result.append({
            "id": o.get("id"),
            "order_number": a.get("order_number"),
            "status": a.get("status"),
            "created_at": a.get("created_at"),
            "updated_at": a.get("updated_at"),
            "date": a["created_at"][:10],
            "product": item.get("product_name", "Unknown"),
            "subtotal": subtotal,
            "tax": a.get("tax_usd", 0) / 100,
            "fee": round(fee, 2),
            "flat_fee": round(flat, 2),
            "net": round(subtotal - fee, 2),
            "currency": a.get("currency", "USD"),
            "refunded": a.get("refunded", False),
            "refunded_at": a.get("refunded_at"),
            "refunded_amount_formatted": a.get("refunded_amount_formatted", "$0.00"),
        })
    json.dump(result, sys.stdout, indent=2)
    print()


def main():
    parser = argparse.ArgumentParser(description="LemonSqueezy sales & fee report")
    parser.add_argument("--month", action="store_true", help="Current month only")
    parser.add_argument("--daily", action="store_true", help="Today/yesterday/week/all-time breakdown")
    parser.add_argument("--days", type=int, help="Last N days")
    parser.add_argument("--fees", action="store_true", help="Fee breakdown only")
    parser.add_argument("--products", action="store_true", help="Revenue by product")
    parser.add_argument("--product-variants", action="store_true", help="Revenue by product + variant")
    parser.add_argument("--refund-order", type=str, help="Issue a refund for Lemon Squeezy order ID")
    parser.add_argument("--refund-order-number", type=str, help="Issue a refund for Lemon Squeezy order number")
    parser.add_argument("--amount", type=int, help="Refund amount in cents (omit for full refund)")
    parser.add_argument("--proof-file", type=str, help="Write a human-readable refund proof file")
    parser.add_argument("--approval-note", type=str, help="Path to the explicit refund approval note")
    parser.add_argument("--include-refunded", action="store_true", help="Include refunded orders in report/json output")
    parser.add_argument("--json", action="store_true", help="Raw JSON output")
    args = parser.parse_args()

    api_key = get_api_key()
    try:
        all_orders = fetch_orders(api_key)
    except RuntimeError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)

    if args.refund_order and args.refund_order_number:
        print("Error: use either --refund-order or --refund-order-number, not both.", file=sys.stderr)
        sys.exit(1)

    if args.refund_order or args.refund_order_number:
        target_order = None
        if args.refund_order:
            target_id = str(args.refund_order).strip()
            for order in all_orders:
                if str(order.get("id", "")).strip() == target_id:
                    target_order = order
                    break
            if target_order is None:
                print(f"Error: order id {target_id} not found.", file=sys.stderr)
                sys.exit(1)
        else:
            target_order = find_order_by_number(all_orders, args.refund_order_number)
            if target_order is None:
                print(f"Error: order number {args.refund_order_number} not found.", file=sys.stderr)
                sys.exit(1)
            target_id = str(target_order.get("id", "")).strip()

        target_attrs = target_order.get("attributes", {})
        if target_attrs.get("refunded"):
            summary = order_to_summary(target_order)
            if args.json:
                json.dump(summary, sys.stdout, indent=2)
                print()
            else:
                print_refund_summary(summary)
            if args.proof_file:
                write_proof_file(args.proof_file, summary)
            return

        approval_note_path, approval_note_text = validate_refund_approval(args)
        refunded_order = issue_order_refund(api_key, target_id, amount=args.amount)
        summary = order_to_summary(refunded_order)
        if args.proof_file:
            write_proof_file(args.proof_file, summary, str(approval_note_path), approval_note_text)
        if args.json:
            json.dump(summary, sys.stdout, indent=2)
            print()
        else:
            print_refund_summary(summary)
        return

    # --daily uses all orders (does its own bucketing)
    if args.daily:
        if not all_orders:
            print("No orders found.")
            sys.exit(0)
        print(f"LemonSqueezy Sales — {datetime.now().strftime('%Y-%m-%d')}")
        print()
        print_daily(all_orders)
        return

    orders = filter_orders(all_orders, args)

    if not orders:
        print("No orders found for the selected period.")
        sys.exit(0)

    if args.json:
        print_json(orders)
        return

    # Header
    label = "all time"
    if args.month:
        label = datetime.now().strftime("%B %Y")
    elif args.days:
        label = f"last {args.days} days"
    print(f"LemonSqueezy Report — {label} ({len(orders)} orders)")
    print()

    if args.fees:
        print_fees(orders)
    elif args.products:
        print_products(orders)
    elif args.product_variants:
        print_product_variants(orders)
    else:
        print_monthly(orders)
        print_fees(orders)
        print()
        print_products(orders)


if __name__ == "__main__":
    main()
