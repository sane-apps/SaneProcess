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
  ls-sales.py --json       # Raw JSON output (for piping)
"""
import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone


def get_api_key():
    # Try env var first (headless/LaunchAgent contexts)
    key = os.environ.get("LEMONSQUEEZY_API_KEY", "")
    if key:
        return key
    # Fall back to keychain (interactive sessions)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "lemonsqueezy", "-a", "api_key", "-w"],
        capture_output=True, text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: No LemonSqueezy API key found.", file=sys.stderr)
        print("  Set LEMONSQUEEZY_API_KEY env var, or add to keychain:", file=sys.stderr)
        print("  security add-generic-password -s lemonsqueezy -a api_key -w YOUR_KEY", file=sys.stderr)
        sys.exit(1)
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
            print(f"Error: Bad API response on page {page}", file=sys.stderr)
            break
        orders = data.get("data", [])
        all_orders.extend(orders)
        if len(orders) < 50:
            break
        page += 1
    return all_orders


def calc_fee(subtotal, currency):
    """Calculate estimated LS fee for an order."""
    base = (subtotal * 0.05) + 0.50
    intl = subtotal * 0.015 if currency != "USD" else 0
    return base + intl, intl


def filter_orders(orders, args):
    """Filter orders by date range."""
    now = datetime.now(timezone.utc)
    cutoff = None

    if args.month:
        cutoff = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    elif args.days:
        cutoff = now - timedelta(days=args.days)

    filtered = []
    for o in orders:
        a = o["attributes"]
        if a.get("status") != "paid":
            continue
        if cutoff:
            created = datetime.fromisoformat(a["created_at"].replace("Z", "+00:00"))
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
        fee, _ = calc_fee(subtotal, a.get("currency", "USD"))
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
    paid_count = 0

    for o in orders:
        a = o["attributes"]
        subtotal = a.get("subtotal_usd", 0) / 100
        _, intl = calc_fee(subtotal, a.get("currency", "USD"))
        total_revenue += subtotal
        total_intl += intl
        paid_count += 1

    platform_pct = total_revenue * 0.05
    flat_fee = paid_count * 0.50
    total_fees = platform_pct + flat_fee + total_intl
    eff = (total_fees / total_revenue * 100) if total_revenue > 0 else 0

    print()
    print("Fee Breakdown")
    print(f"  Platform cut (5%):            ${platform_pct:>8.2f}")
    print(f"  Per-txn flat ($0.50 x {paid_count:<4}):   ${flat_fee:>8.2f}")
    print(f"  International (+1.5%):        ${total_intl:>8.2f}")
    print(f"                                ---------")
    print(f"  Total fees to LS:             ${total_fees:>8.2f}")
    print(f"  Effective rate:               {eff:>7.1f}%")
    print()
    print(f"  Gross revenue:                ${total_revenue:>8.2f}")
    print(f"  You keep:                     ${total_revenue - total_fees:>8.2f}")

    # Show what rate would be at different price points
    if paid_count > 0:
        avg = total_revenue / paid_count
        print()
        print(f"  Avg order: ${avg:.2f} -> {((avg * 0.05 + 0.50) / avg * 100):.1f}% effective rate")
        print()
        print("  Rate at different price points:")
        for price in [5, 10, 15, 20, 30, 50]:
            rate = ((price * 0.05 + 0.50) / price * 100)
            print(f"    ${price:>3} -> {rate:.1f}%")


def print_products(orders):
    """Revenue by product."""
    products = defaultdict(lambda: {"revenue": 0, "orders": 0, "fees": 0})

    for o in orders:
        a = o["attributes"]
        item = a.get("first_order_item") or {}
        name = item.get("product_name", "Unknown")
        subtotal = a.get("subtotal_usd", 0) / 100
        fee, _ = calc_fee(subtotal, a.get("currency", "USD"))
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

    for o in all_orders:
        a = o["attributes"]
        if a.get("status") != "paid":
            continue
        subtotal = a.get("subtotal_usd", 0) / 100
        fee, _ = calc_fee(subtotal, a.get("currency", "USD"))
        created = datetime.fromisoformat(a["created_at"].replace("Z", "+00:00"))

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
        fee, intl = calc_fee(subtotal, a.get("currency", "USD"))
        item = a.get("first_order_item") or {}
        result.append({
            "date": a["created_at"][:10],
            "product": item.get("product_name", "Unknown"),
            "subtotal": subtotal,
            "tax": a.get("tax_usd", 0) / 100,
            "fee": round(fee, 2),
            "net": round(subtotal - fee, 2),
            "currency": a.get("currency", "USD"),
            "refunded": a.get("refunded", False),
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
    parser.add_argument("--json", action="store_true", help="Raw JSON output")
    args = parser.parse_args()

    api_key = get_api_key()
    all_orders = fetch_orders(api_key)

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
    else:
        print_monthly(orders)
        print_fees(orders)
        print()
        print_products(orders)


if __name__ == "__main__":
    main()
