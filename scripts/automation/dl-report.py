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
import shlex
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


API_BASE = "https://dist.saneapps.com/api/stats"
ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
FUNNEL_EVENT_TYPES = [
    "app_launch_free",
    "app_launch_pro",
    "new_free_user",
    "onboarding_started",
    "onboarding_completed",
    "demo_started",
    "provider_connect_started",
    "provider_connect_success",
    "provider_connect_failed",
    "paywall_seen",
    "upsell_shown",
    "checkout_clicked",
    "website_checkout_redirected",
    "upsell_clicked_buy",
    "license_activated",
    "first_value_action",
]


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
    if not value or os.environ.get("SANE_ENV_CACHE_WRITE", "0") == "0":
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
    key = os.environ.get("DIST_ANALYTICS_KEY", "")
    if key:
        return key
    if os.environ.get("SANE_NO_KEYCHAIN") == "1" or os.environ.get("SANE_KEYCHAIN_FALLBACK") == "0":
        print("Error: No dist analytics API key found.", file=sys.stderr)
        print("  Set DIST_ANALYTICS_KEY in ~/.config/nv/env or the environment.", file=sys.stderr)
        sys.exit(1)
    # Fall back to keychain (interactive sessions)
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "dist-analytics", "-a", "api_key", "-w"],
        capture_output=True, text=True,
    )
    key = result.stdout.strip()
    if not key:
        print("Error: No dist analytics API key found.", file=sys.stderr)
        print("  Set DIST_ANALYTICS_KEY in ~/.config/nv/env or the environment, or add it to keychain:", file=sys.stderr)
        print("  security add-generic-password -s dist-analytics -a api_key -w YOUR_KEY", file=sys.stderr)
        sys.exit(1)
    persist_secret_to_env_cache(key, "DIST_ANALYTICS_KEY")
    return key


def fetch_stats(api_key, days=90, app=None):
    from urllib.parse import urlencode
    params = {"days": days}
    if app:
        params["app"] = app.lower()
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


def print_events(events, window_days=90):
    """User-type event breakdown: Today / Yesterday / This Week / Window."""
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

    for r in events:
        count = r["count"]
        event = r["event"]
        date = r["date"]

        buckets[window_label][event] += count
        if date in week_dates:
            buckets["This Week"][event] += count
        if date == today:
            buckets["Today"][event] += count
        elif date == yesterday:
            buckets["Yesterday"][event] += count

    print(f"\nUser Events — {today}")
    print(f"{'Period':<15} {'New Free':>10} {'Early Adopter':>15} {'Activated':>11}")
    print("-" * 55)
    for name in ["Today", "Yesterday", "This Week", window_label]:
        b = buckets[name]
        print(f"{name:<15} {b.get('new_free_user', 0):>10} {b.get('early_adopter_grant', 0):>15} {b.get('license_activated', 0):>11}")


def print_funnel_events(events, event_dimensions, window_days=90):
    """Aggregate privacy-safe funnel event breakdown."""
    from datetime import timedelta, timezone
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    week_dates = set((now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7))
    window_label = f"Last {window_days}d"

    totals = {event: defaultdict(int) for event in FUNNEL_EVENT_TYPES}

    dimension_events = {"checkout_clicked", "website_checkout_redirected"}
    for row in events:
        event = row["event"]
        if event not in totals or event in dimension_events:
            continue
        count = row["count"]
        date = row["date"]
        totals[event][window_label] += count
        if date in week_dates:
            totals[event]["This Week"] += count
        if date == today:
            totals[event]["Today"] += count

    excluded_legacy_checkout_clicks = 0
    for row in event_dimensions:
        event = row["event"]
        platform = row.get("platform", "unknown")
        channel = row.get("channel", "unknown")
        if event == "checkout_clicked" and platform == "web" and channel == "website":
            excluded_legacy_checkout_clicks += row["count"]
            continue
        if event == "checkout_clicked" and platform == "macos" and channel == "direct":
            display_event = "checkout_clicked"
        elif event == "website_checkout_redirected" and platform == "web" and channel == "website":
            display_event = "website_checkout_redirected"
        else:
            continue

        count = row["count"]
        date = row["date"]
        totals[display_event][window_label] += count
        if date in week_dates:
            totals[display_event]["This Week"] += count
        if date == today:
            totals[display_event]["Today"] += count

    print(f"\nFunnel Events — aggregate only")
    print(f"{'Event':<28} {'Today':>8} {'This Week':>10} {window_label:>12}")
    print("-" * 62)
    for event in FUNNEL_EVENT_TYPES:
        b = totals[event]
        if b[window_label] == 0:
            continue
        print(f"{event:<28} {b['Today']:>8} {b['This Week']:>10} {b[window_label]:>12}")

    if excluded_legacy_checkout_clicks:
        print(
            f"Note: excluded {excluded_legacy_checkout_clicks} legacy web/website "
            "checkout_clicked events from direct checkout totals."
        )


def main():
    parser = argparse.ArgumentParser(description="SaneApps download analytics report")
    parser.add_argument("--daily", action="store_true", help="Today/yesterday/week/all-time breakdown")
    parser.add_argument("--days", type=int, default=90, help="Look back N days (default: 90)")
    parser.add_argument("--app", type=str, help="Filter by app name (e.g. sanebar)")
    parser.add_argument("--json", action="store_true", help="Raw JSON output")
    parser.add_argument("--events", action="store_true", help="Show user-type events only")
    args = parser.parse_args()

    api_key = get_api_key()
    data = fetch_stats(api_key, days=args.days, app=args.app)

    if args.json:
        json.dump(data, sys.stdout, indent=2)
        print()
        return

    events = data.get("events", [])
    event_dimensions = data.get("event_dimensions", [])

    if args.events:
        if not events and not event_dimensions:
            print("No event data found for the selected period.")
            sys.exit(0)
        app_label = args.app or "all apps"
        print(f"Event Analytics — {app_label} — {datetime.now().strftime('%Y-%m-%d')}")
        print_events(events, window_days=args.days)
        print_funnel_events(events, event_dimensions, window_days=args.days)
        return

    rows = data.get("rows", [])
    if not rows:
        print("No download data found for the selected period.")
        sys.exit(0)

    # Header
    app_label = args.app or "all apps"
    print(f"Download Analytics — {app_label} — {datetime.now().strftime('%Y-%m-%d')}")
    print()

    if args.daily:
        print_daily(rows, window_days=args.days)
        if events:
            print_events(events, window_days=args.days)
            print_funnel_events(events, event_dimensions, window_days=args.days)
    else:
        print_by_app(rows)
        print_by_version(rows)
        if events:
            print_events(events, window_days=args.days)
            print_funnel_events(events, event_dimensions, window_days=args.days)


if __name__ == "__main__":
    main()
