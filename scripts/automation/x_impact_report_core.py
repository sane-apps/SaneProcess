#!/usr/bin/env python3
"""Core model and reporting logic for X outreach impact reports."""

from __future__ import annotations

import json
import os
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from zoneinfo import ZoneInfo


LOCAL_TZ = ZoneInfo(os.environ.get("SANE_X_IMPACT_TZ", "America/New_York"))
PRODUCT_DOMAINS = {
    "sanebar": ["sanebar.com"],
    "saneclick": ["saneclick.com"],
    "saneclip": ["saneclip.com"],
    "sanehosts": ["sanehosts.com"],
    "sanesales": ["sanesales.com"],
    "sanescan": ["sanescan.saneapps.com"],
    "sanevideo": ["sanevideo.com"],
    "bundle": ["saneapps.com/bundle", "go.saneapps.com/buy/bundle", "go.saneapps.com/buy/sane-bundle"],
    "saneapps": ["saneapps.com"],
}
PRODUCT_LABELS = {
    "sanebar": "SaneBar",
    "saneclick": "SaneClick",
    "saneclip": "SaneClip",
    "sanehosts": "SaneHosts",
    "sanesales": "SaneSales",
    "sanescan": "SaneScan",
    "sanevideo": "SaneVideo",
    "bundle": "SaneApps Bundle",
    "saneapps": "SaneApps",
}


@dataclass
class Post:
    id: str
    created_at: datetime
    product: str
    text: str
    url: str
    kind: str
    source_url: str
    metrics: dict[str, int]
    metrics_snapshot_at: str


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed

def local_date(ts: datetime) -> date:
    return ts.astimezone(LOCAL_TZ).date()

def normalize_product(value: str | None) -> str:
    text = (value or "").lower()
    text = text.replace(" ", "").replace("-", "")
    if "bundle" in text:
        return "bundle"
    for key in PRODUCT_LABELS:
        if key != "bundle" and key.replace(" ", "") in text:
            return key
    return ""

def product_from_url(url: str) -> str:
    if not url:
        return ""
    lowered = url.lower()
    parsed = urlparse(lowered)
    host_path = f"{parsed.netloc}{parsed.path}"
    for product, domains in PRODUCT_DOMAINS.items():
        if any(domain in lowered or domain in host_path for domain in domains):
            return product
    return ""

def product_from_tweet(tweet: dict[str, Any]) -> str:
    text = tweet.get("text") or ""
    urls = []
    entities = tweet.get("entities") or {}
    for item in entities.get("urls") or []:
        for key in ("expanded_url", "unwound_url", "display_url", "url"):
            if item.get(key):
                urls.append(str(item[key]))
    for url in urls:
        product = product_from_url(url)
        if product:
            return product
    return normalize_product(text) or "saneapps"

def extract_tweet_id(response_text: str) -> str:
    if not response_text:
        return ""
    for pattern in (
        r"['\"]id['\"]\s*:\s*['\"]([0-9]{5,})['\"]",
        r"https://x\.com/i/web/status/([0-9]{5,})",
    ):
        match = re.search(pattern, response_text)
        if match:
            return match.group(1)
    return ""

def normalize_metrics(raw: dict[str, Any] | None) -> dict[str, int]:
    metrics = raw or {}
    keys = ["impression_count", "like_count", "reply_count", "retweet_count", "quote_count", "bookmark_count"]
    return {key: int(metrics.get(key) or 0) for key in keys}

def engagement_score(metrics: dict[str, int]) -> int:
    return (
        metrics.get("like_count", 0)
        + metrics.get("reply_count", 0) * 3
        + metrics.get("retweet_count", 0) * 2
        + metrics.get("quote_count", 0) * 2
        + metrics.get("bookmark_count", 0)
    )

def post_url(post_id: str) -> str:
    return f"https://x.com/i/web/status/{post_id}" if post_id else ""

def posts_from_snapshot(snapshot: dict[str, Any], snapshot_path: Path) -> dict[str, Post]:
    snapshot_at = snapshot.get("fetched_at") or snapshot.get("searched_at") or snapshot_path.stem
    posts: dict[str, Post] = {}
    for tweet in snapshot.get("tweets") or snapshot.get("data") or []:
        post_id = str(tweet.get("id") or "")
        created = parse_dt(tweet.get("created_at"))
        if not post_id or not created:
            continue
        product = product_from_tweet(tweet)
        posts[post_id] = Post(
            id=post_id,
            created_at=created,
            product=product,
            text=(tweet.get("text") or "").strip(),
            url=post_url(post_id),
            kind="post",
            source_url="",
            metrics=normalize_metrics(tweet.get("public_metrics")),
            metrics_snapshot_at=str(snapshot_at),
        )
    return posts

def posts_from_log(rows: list[dict[str, Any]]) -> dict[str, Post]:
    posts: dict[str, Post] = {}
    for row in rows:
        if row.get("ok") is not True:
            continue
        post_id = extract_tweet_id(str(row.get("response") or "")) or str(row.get("id") or "")
        created = parse_dt(row.get("posted_at"))
        if not post_id or not created:
            continue
        product = normalize_product(row.get("product")) or product_from_url(row.get("source_url") or "") or "saneapps"
        posts[post_id] = Post(
            id=post_id,
            created_at=created,
            product=product,
            text=(row.get("text") or "").strip(),
            url=post_url(post_id),
            kind=row.get("kind") or ("reply" if row.get("reply_to") else "post"),
            source_url=row.get("source_url") or "",
            metrics=normalize_metrics({}),
            metrics_snapshot_at="post-log",
        )
    return posts

def merge_posts(log_posts: dict[str, Post], snapshot_posts: dict[str, Post]) -> list[Post]:
    merged: dict[str, Post] = dict(snapshot_posts)
    for post_id, logged in log_posts.items():
        if post_id not in merged:
            merged[post_id] = logged
            continue
        snap = merged[post_id]
        merged[post_id] = Post(
            id=post_id,
            created_at=snap.created_at or logged.created_at,
            product=logged.product or snap.product,
            text=snap.text or logged.text,
            url=snap.url or logged.url,
            kind=logged.kind or snap.kind,
            source_url=logged.source_url or snap.source_url,
            metrics=snap.metrics,
            metrics_snapshot_at=snap.metrics_snapshot_at,
        )
    return sorted(merged.values(), key=lambda post: post.created_at)

def sale_product(row: dict[str, Any]) -> str:
    product = normalize_product(row.get("product"))
    if product:
        return product
    return "saneapps"

def sale_amount(row: dict[str, Any]) -> float:
    for key in ("net", "subtotal", "total"):
        value = row.get(key)
        if isinstance(value, (int, float)):
            return float(value)
    return 0.0

def aggregate_downloads(payload: dict[str, Any]) -> dict[str, dict[date, int]]:
    out: dict[str, dict[date, int]] = defaultdict(lambda: defaultdict(int))
    for row in payload.get("rows") or []:
        product = normalize_product(row.get("app"))
        try:
            row_date = date.fromisoformat(str(row.get("date")))
        except ValueError:
            continue
        out[product][row_date] += int(row.get("count") or 0)
    return out

def aggregate_events(payload: dict[str, Any]) -> dict[str, dict[str, dict[date, int]]]:
    out: dict[str, dict[str, dict[date, int]]] = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    rows = payload.get("events") or payload.get("rows") or []
    for row in rows:
        product = normalize_product(row.get("app"))
        event = str(row.get("event") or "")
        if not product or not event:
            continue
        try:
            row_date = date.fromisoformat(str(row.get("date")))
        except ValueError:
            continue
        out[product][event][row_date] += int(row.get("count") or 0)
    return out

def sum_dates(series: dict[date, int], start: date, days: int) -> int:
    return sum(series.get(start + timedelta(days=offset), 0) for offset in range(days))

def avg_before(series: dict[date, int], end: date, days: int) -> float:
    if days <= 0:
        return 0.0
    return sum(series.get(end - timedelta(days=offset), 0) for offset in range(1, days + 1)) / days

def matching_product(post_product: str, row_product: str) -> bool:
    if post_product == "saneapps":
        return False
    return post_product == row_product

def sales_windows(post: Post, sales_rows: list[dict[str, Any]]) -> dict[str, Any]:
    windows = {"24h": timedelta(hours=24), "48h": timedelta(hours=48), "7d": timedelta(days=7)}
    result = {name: {"count": 0, "net": 0.0, "all_count": 0, "all_net": 0.0} for name in windows}
    for sale in sales_rows:
        if sale.get("refunded") is True:
            continue
        sold_at = parse_dt(sale.get("created_at"))
        if not sold_at or sold_at < post.created_at:
            continue
        delta = sold_at - post.created_at
        product = sale_product(sale)
        amount = sale_amount(sale)
        for name, window in windows.items():
            if delta <= window:
                result[name]["all_count"] += 1
                result[name]["all_net"] += amount
                if matching_product(post.product, product):
                    result[name]["count"] += 1
                    result[name]["net"] += amount
    return result

def daily_window(series: dict[date, int], post_day: date, baseline_days: int) -> dict[str, Any]:
    baseline = avg_before(series, post_day, baseline_days)
    post_plus_next = sum_dates(series, post_day, 2)
    expected = baseline * 2
    return {
        "post_day": series.get(post_day, 0),
        "next_day": series.get(post_day + timedelta(days=1), 0),
        "post_plus_next": post_plus_next,
        "baseline_daily": round(baseline, 2),
        "expected_2d": round(expected, 2),
        "delta_vs_expected_2d": round(post_plus_next - expected, 2),
    }

def classify_evidence(post_result: dict[str, Any]) -> str:
    if post_result["product"] != "saneapps" and post_result["sales"]["48h"]["count"] > 0:
        return "possible_sale_touch"
    checkout = post_result["events"].get("checkout_clicked", {})
    downloads = post_result.get("downloads", {})
    if checkout.get("delta_vs_expected_2d", 0) > 0 and downloads.get("delta_vs_expected_2d", 0) > 0:
        return "traffic_lift_no_sale"
    if engagement_score(post_result["metrics"]) > 0:
        return "engaged_no_conversion_signal"
    return "no_signal"

def build_report(
    posts: list[Post],
    sales_rows: list[dict[str, Any]],
    downloads_payload: dict[str, Any],
    events_payload: dict[str, Any],
    baseline_days: int,
    lookback_days: int,
) -> dict[str, Any]:
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    scoped_posts = [post for post in posts if post.created_at >= cutoff]
    download_series = aggregate_downloads(downloads_payload)
    event_series = aggregate_events(events_payload)
    post_results: list[dict[str, Any]] = []
    for post in scoped_posts:
        post_day = local_date(post.created_at)
        events = {
            event: daily_window(series, post_day, baseline_days)
            for event, series in event_series.get(post.product, {}).items()
            if event in {"checkout_clicked", "new_free_user", "license_activated", "appstore_purchase_started"}
        }
        result = {
            "id": post.id,
            "url": post.url,
            "created_at": post.created_at.isoformat(),
            "local_date": post_day.isoformat(),
            "product": post.product,
            "product_label": PRODUCT_LABELS.get(post.product, post.product),
            "kind": post.kind,
            "source_url": post.source_url,
            "text": post.text,
            "metrics": post.metrics,
            "engagement_score": engagement_score(post.metrics),
            "metrics_snapshot_at": post.metrics_snapshot_at,
            "sales": sales_windows(post, sales_rows),
            "downloads": daily_window(download_series.get(post.product, {}), post_day, baseline_days),
            "events": events,
        }
        result["evidence"] = classify_evidence(result)
        post_results.append(result)
    post_results.sort(key=lambda row: row["created_at"], reverse=True)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "lookback_days": lookback_days,
        "baseline_days": baseline_days,
        "post_count": len(post_results),
        "sales_rows": len(sales_rows),
        "downloads_total": downloads_payload.get("total", 0),
        "posts": post_results,
        "summary": summarize(post_results),
        "caveats": [
            "Daily downloads/events can only show coarse correlation around post dates.",
            "Sales are timestamped, but untagged links cannot prove attribution.",
            "Use UTM-tagged links in future posts for stronger source matching.",
        ],
    }

def summarize(posts: list[dict[str, Any]]) -> dict[str, Any]:
    by_evidence: dict[str, int] = defaultdict(int)
    for post in posts:
        by_evidence[post["evidence"]] += 1
    top_engagement = sorted(posts, key=lambda row: row["engagement_score"], reverse=True)[:5]
    likely_sales = [post for post in posts if post["sales"]["48h"]["count"] > 0]
    return {
        "by_evidence": dict(sorted(by_evidence.items())),
        "top_engagement": [
            {
                "id": post["id"],
                "product": post["product_label"],
                "impressions": post["metrics"].get("impression_count", 0),
                "engagement_score": post["engagement_score"],
                "url": post["url"],
            }
            for post in top_engagement
        ],
        "possible_sale_touches": len(likely_sales),
    }

def render_markdown(report: dict[str, Any], paths: dict[str, Any], max_posts: int = 25) -> str:
    lines = [
        "# X Impact Report",
        "",
        f"- Generated: {report['generated_at']}",
        f"- Posts analyzed: {report['post_count']}",
        f"- Sales rows available: {report['sales_rows']}",
        f"- Download total in source payload: {report['downloads_total']}",
        f"- Baseline: previous {report['baseline_days']} day(s) per product",
        "",
        "## Readout",
    ]
    evidence = report["summary"]["by_evidence"]
    if not report["posts"]:
        lines.append("- No posts found in the selected lookback window.")
    else:
        lines.append(f"- Possible sale touches: {report['summary']['possible_sale_touches']}")
        lines.append(f"- Evidence buckets: {', '.join(f'{key}={value}' for key, value in evidence.items()) or 'none'}")
    if paths.get("errors"):
        lines.append(f"- Collection warnings: {json.dumps(paths['errors'], sort_keys=True)}")
    lines.extend(["", "## Posts"])
    visible_posts = report["posts"][: max(0, max_posts)]
    for post in visible_posts:
        metrics = post["metrics"]
        sales_48h = post["sales"]["48h"]
        downloads = post["downloads"]
        checkout = post["events"].get("checkout_clicked", {})
        lines.extend(
            [
                f"### {post['product_label']} - {post['local_date']} - {post['evidence']}",
                f"- URL: {post['url']}",
                f"- Text: {post['text'][:220]}",
                f"- Engagement: {metrics.get('impression_count', 0)} impressions, "
                f"{metrics.get('like_count', 0)} likes, {metrics.get('reply_count', 0)} replies, "
                f"score {post['engagement_score']} (snapshot {post['metrics_snapshot_at']})",
                f"- Sales after post: matching product 48h={sales_48h['count']} "
                f"net=${sales_48h['net']:.2f}; all products 48h={sales_48h['all_count']} "
                f"net=${sales_48h['all_net']:.2f}",
                f"- Downloads post+next={downloads['post_plus_next']} vs expected {downloads['expected_2d']} "
                f"(delta {downloads['delta_vs_expected_2d']})",
            ]
        )
        if checkout:
            lines.append(
                f"- Checkout clicks post+next={checkout['post_plus_next']} vs expected {checkout['expected_2d']} "
                f"(delta {checkout['delta_vs_expected_2d']})"
            )
        lines.append("")
    hidden = len(report["posts"]) - len(visible_posts)
    if hidden > 0:
        lines.append(f"- {hidden} additional post(s) are included in the JSON report but omitted here for readability.")
        lines.append("")
    lines.extend(["## Caveats"])
    lines.extend(f"- {item}" for item in report["caveats"])
    return "\n".join(lines).rstrip() + "\n"
