#!/usr/bin/env python3
"""Download analytics report for SaneApps distribution.

Reads from the sane-dist Worker's /api/stats endpoint (backed by D1).

Usage:
  dl-report.py              # Full report (default: daily breakdown)
  dl-report.py --daily      # Today/yesterday/week/all-time
  dl-report.py --days 7     # Last 7 days
  dl-report.py --app sanebar # Filter by app
  dl-report.py --json       # Raw JSON output (for piping)
"""
import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime


API_BASE = "https://dist.saneapps.com/api/stats"


def get_api_key():
    # Try env var first (headless/LaunchAgent contexts)
    key = os.environ.get("DIST_ANALYTICS_KEY", "")
    if key:
        return key
    # Fall back to keychain (interactive sessions)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "dist-analytics", "-a", "api_key", "-w"],
        capture_output=True, text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: No dist analytics API key found.", file=sys.stderr)
        print("  Set DIST_ANALYTICS_KEY env var, or add to keychain:", file=sys.stderr)
        print("  security add-generic-password -s dist-analytics -a api_key -w YOUR_KEY", file=sys.stderr)
        sys.exit(1)
    return key


def fetch_stats(api_key, days=90, app=None):
    from urllib.parse import urlencode
    params = {"days": days}
    if app:
        params["app"] = app
    url = f"{API_BASE}?{urlencode(params)}"
    result = subprocess.run(
        ["curl", "-s", "--max-time", "15", url,
         "-H", f"Authorization: Bearer {api_key}"],
        capture_output=True, text=True,
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"Error: Bad API response: {result.stdout[:200]}", file=sys.stderr)
        sys.exit(1)


def print_daily(rows, window_days=90):
    """Today / Yesterday / This Week / Window breakdown."""
    # Worker stores dates in UTC, so bucket using UTC to match
    from datetime import timedelta, timezone
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    yesterday = (now - timedelta(days=1)).strftime("%Y-%m-%d")
    week_dates = set((now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7))
    window_label = f"Last {window_days}d"

    buckets = {
        "Today": defaultdict(int),
        "Yesterday": defaultdict(int),
        "This Week": defaultdict(int),
        window_label: defaultdict(int),
    }

    for r in rows:
        count = r["count"]
        source = r["source"]
        date = r["date"]

        buckets[window_label][source] += count
        buckets[window_label]["total"] += count

        if date in week_dates:
            buckets["This Week"][source] += count
            buckets["This Week"]["total"] += count

        if date == today:
            buckets["Today"][source] += count
            buckets["Today"]["total"] += count
        elif date == yesterday:
            buckets["Yesterday"][source] += count
            buckets["Yesterday"]["total"] += count

    print(f"{'Period':<15} {'Total':>7} {'Sparkle':>9} {'Homebrew':>9} {'Website':>9} {'Unknown':>9}")
    print("-" * 60)
    for name in ["Today", "Yesterday", "This Week", window_label]:
        b = buckets[name]
        print(f"{name:<15} {b['total']:>7} {b.get('sparkle', 0):>9} {b.get('homebrew', 0):>9} {b.get('website', 0):>9} {b.get('unknown', 0):>9}")


def print_by_app(rows):
    """Downloads grouped by app."""
    apps = defaultdict(lambda: defaultdict(int))

    for r in rows:
        app = r["app"]
        apps[app][r["source"]] += r["count"]
        apps[app]["total"] += r["count"]

    print(f"\n{'App':<15} {'Total':>7} {'Sparkle':>9} {'Homebrew':>9} {'Website':>9} {'Unknown':>9}")
    print("-" * 60)
    for app in sorted(apps, key=lambda a: apps[a]["total"], reverse=True):
        a = apps[app]
        print(f"{app:<15} {a['total']:>7} {a.get('sparkle', 0):>9} {a.get('homebrew', 0):>9} {a.get('website', 0):>9} {a.get('unknown', 0):>9}")


def print_by_version(rows):
    """Downloads grouped by version."""
    versions = defaultdict(lambda: {"count": 0, "source": defaultdict(int)})

    for r in rows:
        key = f"{r['app']} {r['version']}"
        versions[key]["count"] += r["count"]
        versions[key]["source"][r["source"]] += r["count"]

    print(f"\n{'App Version':<25} {'Total':>7} {'Sparkle':>9} {'Website':>9}")
    print("-" * 50)
    for key in sorted(versions, key=lambda k: versions[k]["count"], reverse=True)[:20]:
        v = versions[key]
        print(f"{key:<25} {v['count']:>7} {v['source'].get('sparkle', 0):>9} {v['source'].get('website', 0):>9}")


def main():
    parser = argparse.ArgumentParser(description="SaneApps download analytics report")
    parser.add_argument("--daily", action="store_true", help="Today/yesterday/week/all-time breakdown")
    parser.add_argument("--days", type=int, default=90, help="Look back N days (default: 90)")
    parser.add_argument("--app", type=str, help="Filter by app name (e.g. sanebar)")
    parser.add_argument("--json", action="store_true", help="Raw JSON output")
    args = parser.parse_args()

    api_key = get_api_key()
    data = fetch_stats(api_key, days=args.days, app=args.app)

    rows = data.get("rows", [])
    if not rows:
        print("No download data found for the selected period.")
        sys.exit(0)

    if args.json:
        json.dump(data, sys.stdout, indent=2)
        print()
        return

    # Header
    app_label = args.app or "all apps"
    print(f"Download Analytics — {app_label} — {datetime.now().strftime('%Y-%m-%d')}")
    print()

    if args.daily:
        print_daily(rows, window_days=args.days)
    else:
        print_by_app(rows)
        print_by_version(rows)


if __name__ == "__main__":
    main()
