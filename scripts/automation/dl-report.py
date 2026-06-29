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
import re
import shlex
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


API_BASE = "https://dist.saneapps.com/api/stats"
ENV_CACHE_FILE = Path(os.environ.get("SANE_ENV_CACHE_FILE", "~/.config/nv/env")).expanduser()
SANEAPPS_ROOT = Path(__file__).resolve().parents[4]
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
    "upsell_clicked_buy",
    "license_activated",
    "first_value_action",
]


def normalize_version(version):
    match = re.search(r"\d+(?:\.\d+)+", str(version or ""))
    return match.group(0) if match else ""


def version_key(version):
    normalized = normalize_version(version)
    if not normalized:
        return (-1,)
    return tuple(int(part) for part in normalized.split("."))


def row_count(row):
    try:
        return int(row.get("count", 0))
    except (TypeError, ValueError):
        return 0


def latest_versions(rows):
    latest = {}
    for row in rows:
        app = row.get("app")
        version = row.get("version")
        if not app or not version:
            continue
        if app not in latest or version_key(version) > version_key(latest[app]):
            latest[app] = version
    return latest


def project_versions():
    versions = {}
    for project_file in (SANEAPPS_ROOT / "apps").glob("*/project.yml"):
        app = project_file.parent.name.lower()
        try:
            for line in project_file.read_text(encoding="utf-8").splitlines():
                match = re.match(r"\s*MARKETING_VERSION:\s*\"?([^\"\s]+)\"?", line)
                if match:
                    versions[app] = normalize_version(match.group(1))
                    break
        except OSError:
            continue
    return {app: version for app, version in versions.items() if version}


def current_versions(rows):
    versions = project_versions()
    observed = latest_versions(rows)
    for app, version in observed.items():
        versions.setdefault(str(app).lower(), normalize_version(version))
    return versions


def is_qualified_download(row, latest_by_app):
    source = row.get("source")
    if row.get("mode") == "gated":
        return True
    if source in ("sparkle", "homebrew"):
        return True
    app = str(row.get("app") or "").lower()
    return source == "website" and normalize_version(row.get("version")) == latest_by_app.get(app)


def quality_counts(row, latest_by_app):
    count = row_count(row)
    if is_qualified_download(row, latest_by_app):
        return count, 0
    if row.get("source") == "website":
        return 0, count
    return 0, 0


def print_quality_note():
    print("\nQualified = Sparkle/Homebrew/gated + current-version website; not a human count. Old-site = old-version public website hits.")


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
    latest_by_app = current_versions(rows)

    for r in rows:
        count = row_count(r)
        source = r.get("source") or "unknown"
        date = r.get("date")
        qualified, likely_automated = quality_counts(r, latest_by_app)

        buckets[window_label][source] += count
        buckets[window_label]["total"] += count
        buckets[window_label]["qualified"] += qualified
        buckets[window_label]["likely_automated"] += likely_automated

        if date in week_dates:
            buckets["This Week"][source] += count
            buckets["This Week"]["total"] += count
            buckets["This Week"]["qualified"] += qualified
            buckets["This Week"]["likely_automated"] += likely_automated

        if date == today:
            buckets["Today"][source] += count
            buckets["Today"]["total"] += count
            buckets["Today"]["qualified"] += qualified
            buckets["Today"]["likely_automated"] += likely_automated
        elif date == yesterday:
            buckets["Yesterday"][source] += count
            buckets["Yesterday"]["total"] += count
            buckets["Yesterday"]["qualified"] += qualified
            buckets["Yesterday"]["likely_automated"] += likely_automated

    print(f"{'Period':<15} {'Raw':>7} {'Qualified':>10} {'Old-site':>9} {'Sparkle':>9} {'Homebrew':>9} {'Website':>9}")
    print("-" * 75)
    for name in ["Today", "Yesterday", "This Week", window_label]:
        b = buckets[name]
        print(
            f"{name:<15} {b['total']:>7} {b['qualified']:>10} {b['likely_automated']:>9} "
            f"{b.get('sparkle', 0):>9} {b.get('homebrew', 0):>9} {b.get('website', 0):>9}"
        )
    print_quality_note()


def print_by_app(rows):
    """Downloads grouped by app."""
    apps = defaultdict(lambda: defaultdict(int))
    latest_by_app = current_versions(rows)

    for r in rows:
        app = r.get("app") or "unknown"
        qualified, likely_automated = quality_counts(r, latest_by_app)
        count = row_count(r)
        apps[app][r.get("source") or "unknown"] += count
        apps[app]["total"] += count
        apps[app]["qualified"] += qualified
        apps[app]["likely_automated"] += likely_automated

    print(f"\n{'App':<15} {'Raw':>7} {'Qualified':>10} {'Old-site':>9} {'Sparkle':>9} {'Homebrew':>9} {'Website':>9}")
    print("-" * 75)
    for app in sorted(apps, key=lambda a: apps[a]["total"], reverse=True):
        a = apps[app]
        print(
            f"{app:<15} {a['total']:>7} {a['qualified']:>10} {a['likely_automated']:>9} "
            f"{a.get('sparkle', 0):>9} {a.get('homebrew', 0):>9} {a.get('website', 0):>9}"
        )
    print_quality_note()


def print_by_version(rows):
    """Downloads grouped by version."""
    versions = defaultdict(lambda: {"count": 0, "source": defaultdict(int)})

    for r in rows:
        count = row_count(r)
        key = f"{r.get('app') or 'unknown'} {r.get('version') or 'unknown'}"
        versions[key]["count"] += count
        versions[key]["source"][r.get("source") or "unknown"] += count

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


def print_funnel_events(events, window_days=90):
    """Aggregate privacy-safe funnel event breakdown."""
    from datetime import timedelta, timezone
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    week_dates = set((now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7))
    window_label = f"Last {window_days}d"

    totals = {event: defaultdict(int) for event in FUNNEL_EVENT_TYPES}

    for row in events:
        event = row["event"]
        if event not in totals:
            continue
        count = row["count"]
        date = row["date"]
        totals[event][window_label] += count
        if date in week_dates:
            totals[event]["This Week"] += count
        if date == today:
            totals[event]["Today"] += count

    print(f"\nFunnel Events — aggregate only")
    print(f"{'Event':<28} {'Today':>8} {'This Week':>10} {window_label:>12}")
    print("-" * 62)
    for event in FUNNEL_EVENT_TYPES:
        b = totals[event]
        if b[window_label] == 0:
            continue
        print(f"{event:<28} {b['Today']:>8} {b['This Week']:>10} {b[window_label]:>12}")


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

    if args.events:
        if not events:
            print("No event data found for the selected period.")
            sys.exit(0)
        app_label = args.app or "all apps"
        print(f"Event Analytics — {app_label} — {datetime.now().strftime('%Y-%m-%d')}")
        print_events(events, window_days=args.days)
        print_funnel_events(events, window_days=args.days)
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
            print_funnel_events(events, window_days=args.days)
    else:
        print_by_app(rows)
        print_by_version(rows)
        if events:
            print_events(events, window_days=args.days)
            print_funnel_events(events, window_days=args.days)


if __name__ == "__main__":
    main()
