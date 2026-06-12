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
  ls-sales.py --find-customer-orders --email reed@reed-a.ca --name Reed --product SaneBar
  ls-sales.py --license-status 766800DD-3877-4EAA-938F-D60D42FFA0D7
  ls-sales.py --disable-license-key D1918A18-BCC3-4DA2-AC6B-C67CC912CA5C
  ls-sales.py --refund-order 1234 --refund-type discretionary --customer-thread email#123 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt
  ls-sales.py --refund-order-number 5678 --refund-type duplicate_purchase --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt
  ls-sales.py --refund-duplicate-license-key D1918... --keep-license-key 7668... --refund-order-number 270691528 --customer-thread email#542 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt
  ls-sales.py --json       # Raw JSON output (for piping)
"""
import argparse
import difflib
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.parse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

INFRA_SCRIPTS_DIR = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(INFRA_SCRIPTS_DIR))
from customer_email_corrections import canonical_email, email_variants

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
REFUND_AUDIT_DIR = Path(os.environ.get("SANE_REFUND_AUDIT_DIR", "~/.sanemaster/refunds")).expanduser()
API_BASE = "https://api.lemonsqueezy.com"

OWNER_APPROVAL_RE = re.compile(
    r"\b("
    r"user approved|owner approved|approved by (?:user|owner|sj|stephan|mr\.?\s*sane)|"
    r"(?:sj|stephan|mr\.?\s*sane) approved|explicit (?:user|owner) approval"
    r")\b",
    re.I,
)
DISCRETIONARY_REFUND_REASON_RE = re.compile(
    r"\b("
    r"documented bug|unresolved bug|cannot fix within 24|can't fix within 24|"
    r"cannot be fixed within 24|unresolved after 24|license/payment broken|"
    r"core functionality|major accessibility|data loss|case-by-case"
    r")\b",
    re.I,
)
DUPLICATE_REFUND_REASON_RE = re.compile(
    r"\b(duplicate|double[- ]purchase|paid twice|charged twice|transactional)\b",
    re.I,
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


def fetch_json_api(api_key, url, context):
    last_error = None
    for attempt in range(1, 4):
        result = subprocess.run(
            [
                "curl",
                "-sS",
                "-g",
                "--max-time",
                "30",
                url,
                "-H",
                f"Authorization: Bearer {api_key}",
                "-H",
                "Accept: application/vnd.api+json",
                "-H",
                "Content-Type: application/vnd.api+json",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            last_error = (result.stderr or result.stdout or f"curl exited {result.returncode}").strip()
        else:
            try:
                data = json.loads(result.stdout)
            except json.JSONDecodeError:
                body = (result.stdout or "").lower()
                if "just a moment" in body:
                    last_error = "LemonSqueezy API returned a Cloudflare challenge"
                else:
                    last_error = "LemonSqueezy API returned non-JSON response"
            else:
                if isinstance(data, dict) and data.get("errors"):
                    last_error = json.dumps(data.get("errors"))[:500]
                else:
                    return data
        if attempt < 3:
            # Lemon's list endpoints occasionally return transient empty/non-JSON
            # bodies under load. Retry before failing the operator workflow.
            import time

            time.sleep(attempt * 2)
    raise RuntimeError(f"{context}: {last_error or 'unknown API failure'}")


def fetch_orders(api_key):
    all_orders = []
    params = urllib.parse.urlencode({"page[size]": 100})
    next_url = f"{API_BASE}/v1/orders?{params}"
    seen_urls = set()
    page = 0
    while True:
        if not next_url:
            break
        if next_url in seen_urls:
            raise RuntimeError(f"LemonSqueezy pagination loop detected at {next_url}")
        seen_urls.add(next_url)
        page += 1
        data = fetch_json_api(api_key, next_url, f"Bad API response on orders page {page}")
        orders = data.get("data", [])
        all_orders.extend(orders)
        links = data.get("links") or {}
        next_url = links.get("next")
        if not next_url:
            break
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


def find_order_by_id(orders, order_id):
    needle = str(order_id).strip()
    for order in orders:
        if str(order.get("id", "")).strip() == needle:
            return order
    return None


def normalize_customer_name(value):
    tokens = re.findall(r"[a-z0-9]+", (value or "").lower())
    return " ".join(tokens)


def identity_tokens(value):
    return {token for token in re.findall(r"[a-z0-9]+", (value or "").lower()) if len(token) >= 2}


def email_local_part_tokens(value):
    email = canonical_email(value)
    if not email or "@" not in email:
        return set()
    local = email.split("@", 1)[0]
    return identity_tokens(local)


def fuzzy_token_matches(left_tokens, right_tokens, min_ratio=0.75):
    matches = set()
    for left in left_tokens:
        for right in right_tokens:
            if left == right:
                matches.add((left, right))
                continue
            if difflib.SequenceMatcher(a=left, b=right).ratio() >= min_ratio:
                matches.add((left, right))
    return matches


def validate_license_key_public(license_key, allow_failure=False):
    payload = urllib.parse.urlencode({"license_key": license_key})
    result = subprocess.run(
        [
            "curl",
            "-sS",
            "-X",
            "POST",
            "https://api.lemonsqueezy.com/v1/licenses/validate",
            "-H",
            "Accept: application/json",
            "-H",
            "Content-Type: application/x-www-form-urlencoded",
            "--data",
            payload,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        if allow_failure:
            return {
                "valid": False,
                "error": f"license validation request failed: {result.stderr.strip()}",
                "license_key_id": None,
                "license_key": license_key,
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
        print(f"Error: license validation request failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        if allow_failure:
            return {
                "valid": False,
                "error": f"license validation response was not valid JSON: {result.stdout[:400]}",
                "license_key_id": None,
                "license_key": license_key,
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
                "raw": result.stdout,
                "disabled": False,
                "validation_failed": True,
            }
        print(f"Error: license validation response was not valid JSON: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        if allow_failure:
            return {
                "valid": False,
                "error": f"unexpected license validation payload: {result.stdout[:400]}",
                "license_key_id": None,
                "license_key": license_key,
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
                "raw": data,
                "disabled": False,
                "validation_failed": True,
            }
        print(f"Error: unexpected license validation payload: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    return summarize_license_validation(data)


def summarize_license_validation(data):
    license_key = data.get("license_key") or {}
    meta = data.get("meta") or {}
    status = str(license_key.get("status") or "")
    return {
        "valid": bool(data.get("valid")),
        "error": data.get("error"),
        "license_key_id": license_key.get("id"),
        "license_key": license_key.get("key"),
        "license_key_status": status,
        "activation_limit": license_key.get("activation_limit"),
        "activation_usage": license_key.get("activation_usage"),
        "order_id": meta.get("order_id"),
        "order_item_id": meta.get("order_item_id"),
        "customer_id": meta.get("customer_id"),
        "customer_name": meta.get("customer_name") or "",
        "customer_email": canonical_email(meta.get("customer_email", "")),
        "customer_email_raw": meta.get("customer_email", ""),
        "product_id": meta.get("product_id"),
        "product_name": meta.get("product_name") or "",
        "store_id": meta.get("store_id"),
        "raw": data,
        "disabled": status == "disabled",
        "validation_failed": False,
    }


def disable_license_key(api_key, license_key_id):
    payload = {
        "data": {
            "type": "license-keys",
            "id": str(license_key_id),
            "attributes": {
                "disabled": True,
            },
        },
    }
    result = subprocess.run(
        [
            "curl",
            "-sS",
            "-X",
            "PATCH",
            f"https://api.lemonsqueezy.com/v1/license-keys/{license_key_id}",
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
        print(f"Error: disable license key request failed for {license_key_id}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    try:
        response = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        print(f"Error: disable license key response was not valid JSON: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    if "errors" in response:
        print(json.dumps(response["errors"], indent=2), file=sys.stderr)
        sys.exit(1)
    data = response.get("data")
    if not isinstance(data, dict):
        print(f"Error: disable license key response missing payload: {result.stdout[:400]}", file=sys.stderr)
        sys.exit(1)
    attrs = data.get("attributes") or {}
    return {
        "license_key_id": data.get("id"),
        "license_key": attrs.get("key"),
        "status": attrs.get("status"),
        "disabled": bool(attrs.get("disabled", False)),
        "order_id": attrs.get("order_id"),
        "customer_email": canonical_email(attrs.get("user_email", "")),
        "customer_name": attrs.get("user_name") or "",
        "product_id": attrs.get("product_id"),
        "raw": response,
    }


def score_order_candidate(order, query_email="", query_name="", product=None):
    summary = order_to_summary(order)
    if product and summary.get("product") != product:
        return None

    score = 0
    reasons = []

    query_emails = email_variants(query_email)
    order_emails = email_variants(summary.get("user_email_raw") or summary.get("user_email"))
    email_match = query_emails & order_emails
    if email_match:
        score += 100
        reasons.append(f"email={sorted(email_match)[0]}")

    query_name_norm = normalize_customer_name(query_name)
    order_name_norm = normalize_customer_name(summary.get("user_name"))
    if query_name_norm and order_name_norm:
        if query_name_norm == order_name_norm:
            score += 60
            reasons.append("name=exact")
        else:
            shared_name_tokens = identity_tokens(query_name_norm) & identity_tokens(order_name_norm)
            if shared_name_tokens:
                score += 20 + (10 * len(shared_name_tokens))
                reasons.append("name_tokens=" + ",".join(sorted(shared_name_tokens)))

    query_identity_tokens = identity_tokens(query_name) | email_local_part_tokens(query_email)
    order_identity_tokens = identity_tokens(summary.get("user_name")) | email_local_part_tokens(summary.get("user_email"))
    fuzzy_matches = fuzzy_token_matches(query_identity_tokens, order_identity_tokens)
    fuzzy_pairs = {(left, right) for left, right in fuzzy_matches if left != right}
    if fuzzy_pairs:
        score += 12 * len(fuzzy_pairs)
        sample = sorted(f"{left}~{right}" for left, right in fuzzy_pairs)[:3]
        reasons.append("fuzzy=" + ",".join(sample))

    if score == 0:
        return None

    summary["match_score"] = score
    summary["match_reasons"] = reasons
    return summary


def find_customer_order_candidates(orders, query_email="", query_name="", product=None, limit=10):
    matches = []
    for order in orders:
        candidate = score_order_candidate(order, query_email=query_email, query_name=query_name, product=product)
        if candidate:
            matches.append(candidate)
    grouped_counts = defaultdict(int)
    for candidate in matches:
        customer_key = candidate.get("user_email") or normalize_customer_name(candidate.get("user_name")) or str(candidate.get("order_number"))
        grouped_counts[(customer_key, candidate.get("product"))] += 1
    for candidate in matches:
        customer_key = candidate.get("user_email") or normalize_customer_name(candidate.get("user_name")) or str(candidate.get("order_number"))
        duplicate_count = grouped_counts[(customer_key, candidate.get("product"))]
        if duplicate_count > 1:
            candidate["match_score"] += 30 * (duplicate_count - 1)
            candidate.setdefault("match_reasons", []).append(f"repeat_product_orders={duplicate_count}")
    matches.sort(
        key=lambda item: (
            -item.get("match_score", 0),
            item.get("created_at") or "",
            item.get("order_number") or 0,
        ),
        reverse=False,
    )
    return matches[:limit]


def print_customer_order_candidates(candidates, query_email="", query_name="", product=None):
    print("Customer order candidates")
    if query_email:
        print(f"  Query email: {query_email}")
    if query_name:
        print(f"  Query name: {query_name}")
    if product:
        print(f"  Product filter: {product}")
    for candidate in candidates:
        print(f"  - score={candidate['match_score']} order={candidate.get('order_number')} product={candidate.get('product')} customer={candidate.get('user_name') or '?'} <{candidate.get('user_email') or '?'}>")
        print(f"    reasons: {', '.join(candidate.get('match_reasons') or [])}")


def write_duplicate_license_proof_file(path, duplicate_summary, approval_note_path=None, approval_note_text=None):
    refunded_order = duplicate_summary["refunded_order"]
    kept_license = duplicate_summary["kept_license"]
    refunded_license = duplicate_summary["refunded_license"]
    disabled_license = duplicate_summary["disabled_license"]
    lines = [
        "Lemon Squeezy duplicate-license resolution",
        f"Refunded order ID: {refunded_order.get('id')}",
        f"Refunded order number: {refunded_order.get('order_number')}",
        f"Customer: {refunded_order.get('user_name') or '?'} <{refunded_order.get('user_email') or '?'}>",
        f"Product: {refunded_order.get('product')}",
        f"Refunded amount: {refunded_order.get('refunded_amount_formatted')}",
        f"Refunded at: {refunded_order.get('refunded_at') or 'n/a'}",
        f"Kept key: {kept_license.get('license_key') or '?'}",
        f"Kept key valid: {kept_license.get('valid')}",
        f"Kept key order ID: {kept_license.get('order_id')}",
        f"Refunded key: {refunded_license.get('license_key') or '?'}",
        f"Refunded key disabled: {disabled_license.get('disabled')}",
        f"Refunded key final status: {duplicate_summary['refunded_license_final'].get('license_key_status')}",
    ]
    if kept_license.get("validation_failed"):
        lines.append(f"Kept key post-check warning: {kept_license.get('error') or 'validation failed'}")
    if duplicate_summary["refunded_license_final"].get("validation_failed"):
        lines.append(f"Refunded key post-check warning: {duplicate_summary['refunded_license_final'].get('error') or 'validation failed'}")
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


def refund_duplicate_license(api_key, orders, args):
    approval_note_path, approval_note_text = validate_refund_approval(args, refund_type="duplicate_purchase")
    if not args.keep_license_key:
        print("Error: --keep-license-key is required for duplicate-license refunds.", file=sys.stderr)
        sys.exit(1)
    if not args.refund_order_number:
        print("Error: --refund-order-number is required for duplicate-license refunds.", file=sys.stderr)
        sys.exit(1)

    kept_license = validate_license_key_public(args.keep_license_key)
    refunded_license = validate_license_key_public(args.refund_duplicate_license_key)

    if not kept_license.get("valid"):
        print(f"Error: keep-license-key is not currently valid: {kept_license.get('error') or 'unknown error'}", file=sys.stderr)
        sys.exit(1)
    if not refunded_license.get("license_key_id"):
        print("Error: refunded duplicate key could not be resolved to a Lemon Squeezy license key.", file=sys.stderr)
        sys.exit(1)

    if kept_license.get("product_id") and refunded_license.get("product_id") and kept_license["product_id"] != refunded_license["product_id"]:
        print("Error: keep/refund keys belong to different products.", file=sys.stderr)
        sys.exit(1)
    if kept_license.get("customer_id") and refunded_license.get("customer_id") and kept_license["customer_id"] != refunded_license["customer_id"]:
        print("Error: keep/refund keys belong to different customers.", file=sys.stderr)
        sys.exit(1)

    refund_order = find_order_by_number(orders, args.refund_order_number)
    if refund_order is None:
        print(f"Error: order number {args.refund_order_number} not found.", file=sys.stderr)
        sys.exit(1)
    refund_order_id = str(refund_order.get("id", "")).strip()
    if str(refunded_license.get("order_id", "")).strip() != refund_order_id:
        print(
            f"Error: refund-order-number {args.refund_order_number} does not match refunded key order id {refunded_license.get('order_id')}.",
            file=sys.stderr,
        )
        sys.exit(1)

    refund_attrs = refund_order.get("attributes", {})
    if refund_attrs.get("refunded"):
        refunded_order_payload = refund_order
    else:
        refunded_order_payload = issue_order_refund(api_key, refund_order_id, amount=args.amount)
    refunded_order = order_to_summary(refunded_order_payload)

    if refunded_license.get("license_key_status") != "disabled":
        disabled_license = disable_license_key(api_key, refunded_license["license_key_id"])
    else:
        disabled_license = {
            "license_key_id": refunded_license["license_key_id"],
            "license_key": refunded_license.get("license_key"),
            "status": refunded_license.get("license_key_status"),
            "disabled": True,
            "order_id": refunded_license.get("order_id"),
            "customer_email": refunded_license.get("customer_email"),
            "customer_name": refunded_license.get("customer_name"),
            "product_id": refunded_license.get("product_id"),
            "raw": refunded_license.get("raw"),
        }

    kept_license_final = validate_license_key_public(args.keep_license_key, allow_failure=True)
    refunded_license_final = validate_license_key_public(args.refund_duplicate_license_key, allow_failure=True)

    summary = {
        "kept_license": kept_license_final,
        "refunded_license": refunded_license,
        "refunded_license_final": refunded_license_final,
        "disabled_license": disabled_license,
        "refunded_order": refunded_order,
    }
    if args.proof_file:
        write_duplicate_license_proof_file(args.proof_file, summary, str(approval_note_path), approval_note_text)
        write_refund_audit_record(
            refunded_order,
            "duplicate_purchase",
            args,
            approval_note_path=str(approval_note_path),
            approval_note_text=approval_note_text,
            action="duplicate_license_refund",
        )
    return summary


def print_duplicate_license_summary(summary):
    kept_license = summary["kept_license"]
    refunded_license = summary["refunded_license"]
    refunded_license_final = summary["refunded_license_final"]
    refunded_order = summary["refunded_order"]
    print("Duplicate license refund completed")
    print(f"  Refunded order: {refunded_order.get('order_number')} (ID {refunded_order.get('id')})")
    print(f"  Customer: {refunded_order.get('user_name') or '?'} <{refunded_order.get('user_email') or '?'}>")
    print(f"  Refunded amount: {refunded_order.get('refunded_amount_formatted')}")
    print(f"  Keep key: {kept_license.get('license_key')}")
    print(f"  Keep key valid: {kept_license.get('valid')}")
    print(f"  Refunded key: {refunded_license.get('license_key')}")
    print(f"  Refunded key final status: {refunded_license_final.get('license_key_status')}")
    if kept_license.get("validation_failed"):
        print(f"  Keep key post-check warning: {kept_license.get('error')}")
    if refunded_license_final.get("validation_failed"):
        print(f"  Refunded key post-check warning: {refunded_license_final.get('error')}")


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


def validate_refund_approval(args, refund_type="discretionary"):
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

    if not OWNER_APPROVAL_RE.search(note_text):
        print("Error: Refund blocked. Approval note must include explicit owner/user approval.", file=sys.stderr)
        print("  Example: 'Owner approved refund for order ... on YYYY-MM-DD.'", file=sys.stderr)
        sys.exit(1)

    if refund_type == "duplicate_purchase":
        if not DUPLICATE_REFUND_REASON_RE.search(note_text):
            print("Error: Duplicate-purchase refund blocked. Approval note must document the duplicate/transactional reason.", file=sys.stderr)
            sys.exit(1)
    elif refund_type == "discretionary":
        if not DISCRETIONARY_REFUND_REASON_RE.search(note_text):
            print("Error: Discretionary refund blocked. Approval note must document the unresolved qualifying issue.", file=sys.stderr)
            print("  Use duplicate_purchase for proven duplicate charges; otherwise document the bug and 24h fix status.", file=sys.stderr)
            sys.exit(1)

    return note_path, note_text


def refund_audit_slug(summary, refund_type):
    order_number = summary.get("order_number") or summary.get("id") or "unknown"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    clean_type = re.sub(r"[^a-z0-9_-]+", "-", str(refund_type).lower()).strip("-") or "unknown"
    return f"{timestamp}_order_{order_number}_{clean_type}"


def write_refund_audit_record(summary, refund_type, args, approval_note_path=None, approval_note_text=None, action="issued"):
    REFUND_AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        REFUND_AUDIT_DIR.chmod(0o700)
    except OSError:
        pass

    slug = refund_audit_slug(summary, refund_type)
    path = REFUND_AUDIT_DIR / f"{slug}.md"
    proof_path = Path(args.proof_file).expanduser() if getattr(args, "proof_file", None) else None
    customer_thread = getattr(args, "customer_thread", None) or "not recorded"
    approval_source = getattr(args, "approval_source", None) or "approval note"
    amount = getattr(args, "amount", None)

    lines = [
        "# Lemon Squeezy Refund Audit",
        "",
        f"- Action: {action}",
        f"- Refund type: {refund_type}",
        f"- Order ID: {summary.get('id')}",
        f"- Order number: {summary.get('order_number')}",
        f"- Customer: {summary.get('user_name') or '?'} <{summary.get('user_email') or '?'}>",
        f"- Product: {summary.get('product')}",
        f"- Order total: {summary.get('total_formatted')}",
        f"- Refunded amount: {summary.get('refunded_amount_formatted')}",
        f"- Requested partial amount: {amount if amount is not None else 'full refund'}",
        f"- Refunded flag: {summary.get('refunded')}",
        f"- Refunded at: {summary.get('refunded_at') or 'partial/not-finalized timestamp unavailable'}",
        f"- Customer thread: {customer_thread}",
        f"- Approval source: {approval_source}",
        f"- Approval note path: {approval_note_path or 'not recorded'}",
        f"- Proof file path: {proof_path or 'not requested'}",
        f"- Receipt: {summary.get('receipt_url') or 'n/a'}",
        f"- Recorded at: {datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}",
    ]
    if approval_note_text:
        lines.extend(["", "## Approval Note", "", approval_note_text])
    if proof_path and proof_path.is_file():
        lines.extend(["", "## Proof File Snapshot", "", proof_path.read_text(encoding="utf-8", errors="replace")])

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return path


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


def print_refund_summary(summary, heading="Refund issued"):
    print(heading)
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
    parser.add_argument("--find-customer-orders", action="store_true", help="Find likely orders for a customer using email/name heuristics")
    parser.add_argument("--email", type=str, help="Customer support email or suspected purchase email for customer/order lookup")
    parser.add_argument("--name", type=str, help="Customer display name for customer/order lookup")
    parser.add_argument("--product", type=str, help="Optional product filter for customer/order lookup")
    parser.add_argument("--limit", type=int, default=10, help="Max customer order candidates to print")
    parser.add_argument("--license-status", type=str, help="Inspect a Lemon Squeezy license key using the public validation endpoint")
    parser.add_argument("--disable-license-key", type=str, help="Disable a Lemon Squeezy license key by key string")
    parser.add_argument("--refund-order", type=str, help="Issue a refund for Lemon Squeezy order ID")
    parser.add_argument("--refund-order-number", type=str, help="Issue a refund for Lemon Squeezy order number")
    parser.add_argument("--refund-duplicate-license-key", type=str, help="Refund the order tied to a duplicate license key and disable that key")
    parser.add_argument("--keep-license-key", type=str, help="Companion key to keep active during duplicate-license refund handling")
    parser.add_argument("--amount", type=int, help="Refund amount in cents (omit for full refund)")
    parser.add_argument("--proof-file", type=str, help="Write a human-readable refund proof file")
    parser.add_argument("--approval-note", type=str, help="Path to the explicit refund approval note")
    parser.add_argument(
        "--refund-type",
        choices=["discretionary", "duplicate_purchase", "external"],
        default="discretionary",
        help="Refund classification for audit and approval policy",
    )
    parser.add_argument("--customer-thread", type=str, help="Support thread, issue, or customer record tied to the refund")
    parser.add_argument("--approval-source", type=str, help="Where explicit owner approval was captured")
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

    if args.find_customer_orders:
        candidates = find_customer_order_candidates(
            all_orders,
            query_email=args.email or "",
            query_name=args.name or "",
            product=args.product,
            limit=max(int(args.limit or 10), 1),
        )
        if args.json:
            json.dump(candidates, sys.stdout, indent=2)
            print()
        else:
            if not candidates:
                print("No likely customer order matches found.")
            else:
                print_customer_order_candidates(candidates, query_email=args.email or "", query_name=args.name or "", product=args.product)
        return

    if args.license_status:
        summary = validate_license_key_public(args.license_status)
        if args.json:
            json.dump(summary, sys.stdout, indent=2)
            print()
        else:
            print("License key status")
            print(f"  Key: {summary.get('license_key') or args.license_status}")
            print(f"  Valid: {summary.get('valid')}")
            print(f"  Status: {summary.get('license_key_status') or 'unknown'}")
            print(f"  Customer: {summary.get('customer_name') or '?'} <{summary.get('customer_email') or summary.get('customer_email_raw') or '?'}>")
            print(f"  Product: {summary.get('product_name') or '?'}")
            print(f"  Order ID: {summary.get('order_id') or '?'}")
            if summary.get("error"):
                print(f"  Error: {summary['error']}")
        return

    if args.disable_license_key:
        api_key = get_api_key()
        summary = validate_license_key_public(args.disable_license_key)
        license_key_id = summary.get("license_key_id")
        if not license_key_id:
            print("Error: could not resolve license key id for disable operation.", file=sys.stderr)
            sys.exit(1)
        disabled = disable_license_key(api_key, license_key_id)
        if args.json:
            json.dump(disabled, sys.stdout, indent=2)
            print()
        else:
            print("License key disabled")
            print(f"  Key: {disabled.get('license_key') or args.disable_license_key}")
            print(f"  Status: {disabled.get('status') or 'unknown'}")
            print(f"  Customer: {disabled.get('customer_name') or '?'} <{disabled.get('customer_email') or '?'}>")
        return

    if args.refund_duplicate_license_key:
        summary = refund_duplicate_license(api_key, all_orders, args)
        if args.json:
            json.dump(summary, sys.stdout, indent=2)
            print()
        else:
            print_duplicate_license_summary(summary)
        return

    if args.refund_order or args.refund_order_number:
        target_order = None
        if args.refund_order:
            target_id = str(args.refund_order).strip()
            target_order = find_order_by_id(all_orders, target_id)
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
                print_refund_summary(summary, heading="Refund already recorded")
            if args.proof_file:
                write_proof_file(args.proof_file, summary)
                audit_path = write_refund_audit_record(summary, "external", args, action="already_refunded_observed")
                if not args.json:
                    print(f"  Audit record: {audit_path}")
            return

        approval_note_path, approval_note_text = validate_refund_approval(args, refund_type=args.refund_type)
        refunded_order = issue_order_refund(api_key, target_id, amount=args.amount)
        summary = order_to_summary(refunded_order)
        audit_path = None
        if args.proof_file:
            write_proof_file(args.proof_file, summary, str(approval_note_path), approval_note_text)
            audit_path = write_refund_audit_record(
                summary,
                args.refund_type,
                args,
                approval_note_path=str(approval_note_path),
                approval_note_text=approval_note_text,
            )
        if args.json:
            payload = dict(summary)
            if audit_path:
                payload["audit_record"] = str(audit_path)
            json.dump(payload, sys.stdout, indent=2)
            print()
        else:
            print_refund_summary(summary)
            if audit_path:
                print(f"  Audit record: {audit_path}")
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
