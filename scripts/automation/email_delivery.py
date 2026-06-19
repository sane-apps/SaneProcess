#!/usr/bin/env python3
"""Shared helpers for classifying Resend outbound delivery evidence."""

from __future__ import annotations

import re
from datetime import datetime, timezone

DELIVERED_EVENTS = {"delivered", "opened", "clicked", "complained"}
BOUNCED_EVENTS = {"bounced"}


def parse_ts(value: str):
    value = (value or "").strip()
    if not value:
        return None
    value = value.replace("Z", "+00:00")
    value = re.sub(r"([+-]\d{2})$", r"\1:00", value)
    value = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", value)
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


def normalize_addr(value: str) -> str:
    value = (value or "").strip().lower()
    if "<" in value and ">" in value:
        value = value.split("<", 1)[1].split(">", 1)[0].strip().lower()
    return value


def clean_subject(value: str) -> str:
    subject = (value or "").strip().lower()
    while True:
        new = re.sub(r"^(re|fwd|fw)\s*[:\-\]]\s*", "", subject).strip()
        if new == subject:
            break
        subject = new
    return subject


def thread_key(email: dict) -> tuple[str, str]:
    return (
        normalize_addr(email.get("from_email") or email.get("from") or ""),
        clean_subject(email.get("subject") or ""),
    )


def is_strictly_related(sent_subject: str, original_subject: str) -> bool:
    return bool(clean_subject(sent_subject) and clean_subject(sent_subject) == clean_subject(original_subject))


def is_related(sent_subject: str, original_subject: str) -> bool:
    sent_raw = (sent_subject or "").strip()
    orig_raw = (original_subject or "").strip()
    sent_clean = clean_subject(sent_raw)
    orig_clean = clean_subject(orig_raw)

    if not sent_clean or not orig_clean:
        return False
    if sent_clean == orig_clean:
        return True
    if orig_clean in sent_clean or sent_clean in orig_clean:
        return True

    sent_words = set(re.findall(r"[a-z]{3,}", sent_clean))
    orig_words = set(re.findall(r"[a-z]{3,}", orig_clean))
    if "re:" in sent_raw.lower() and sent_words.intersection(orig_words):
        return True
    return False


def delivery_bucket(event: str) -> str:
    normalized = (event or "").strip().lower()
    if normalized in DELIVERED_EVENTS:
        return "delivered"
    if normalized in BOUNCED_EVENTS:
        return "bounced"
    return "pending"


def build_recipient_index(resend_payload) -> dict[str, list[dict]]:
    payload = resend_payload if isinstance(resend_payload, dict) else {}
    index: dict[str, list[dict]] = {}

    for email in payload.get("data", []):
        recipients = [normalize_addr(addr) for addr in email.get("to", []) if isinstance(addr, str)]
        for recipient in recipients:
            if recipient:
                index.setdefault(recipient, []).append(email)

    for rows in index.values():
        rows.sort(key=lambda row: row.get("created_at") or "")
    return index


def related_events(
    target: str,
    original_subject: str,
    original_created: str,
    resend_payload,
    recipient_index=None,
    *,
    strict_subject: bool = True,
) -> list[dict]:
    target = normalize_addr(target)
    original_dt = parse_ts(original_created)
    payload = resend_payload if isinstance(resend_payload, dict) else {}
    rows = []
    candidates = recipient_index.get(target, []) if recipient_index is not None else payload.get("data", [])

    for email in candidates:
        if recipient_index is None:
            recipients = [normalize_addr(addr) for addr in email.get("to", []) if isinstance(addr, str)]
            if target not in recipients:
                continue

        sent_dt = parse_ts(email.get("created_at", ""))
        if original_dt and not sent_dt:
            continue
        if original_dt and sent_dt and sent_dt < original_dt:
            continue
        subject_matches = (
            is_strictly_related(email.get("subject", ""), original_subject)
            if strict_subject
            else is_related(email.get("subject", ""), original_subject)
        )
        if not subject_matches:
            continue

        event = (email.get("last_event") or email.get("status") or "").strip().lower()
        rows.append(
            {
                "id": email.get("id"),
                "created_at": email.get("created_at"),
                "subject": email.get("subject"),
                "to": email.get("to", []),
                "last_event": event,
                "bucket": delivery_bucket(event),
            }
        )

    rows.sort(key=lambda row: row.get("created_at") or "")
    return rows


def summarize_related_events(
    target: str,
    original_subject: str,
    original_created: str,
    resend_payload,
    recipient_index=None,
    *,
    strict_subject: bool = True,
) -> dict:
    rows = related_events(
        target,
        original_subject,
        original_created,
        resend_payload,
        recipient_index,
        strict_subject=strict_subject,
    )
    summary = {"delivered": 0, "bounced": 0, "pending": 0, "rows": rows}
    for row in rows:
        summary[row["bucket"]] += 1
    terminal_rows = [row for row in rows if row["bucket"] in {"delivered", "bounced"}]
    latest = terminal_rows[-1] if terminal_rows else (rows[-1] if rows else None)
    summary["latest_bucket"] = latest["bucket"] if latest else "none"
    summary["latest_event"] = latest.get("last_event") if latest else ""
    summary["latest_at"] = latest.get("created_at") if latest else ""
    return summary


def thread_delivery_evidence(rows, resend_payload, recipient_index=None, include_statuses=None) -> dict[int, int]:
    thread_latest_inbound = {}
    for email in rows or []:
        status = (email.get("status") or "").strip().lower()
        category = (email.get("category") or "").strip().lower()
        if category == "spam" or status == "spam":
            continue
        key = thread_key(email)
        if not key[0] or not key[1]:
            continue
        created = parse_ts(email.get("created_at", ""))
        if created is None:
            continue
        if key not in thread_latest_inbound or created > thread_latest_inbound[key]:
            thread_latest_inbound[key] = created

    evidence = {}
    for email in rows or []:
        status = (email.get("status") or "").strip().lower()
        category = (email.get("category") or "").strip().lower()
        if category == "spam" or status == "spam":
            continue
        if include_statuses is not None and status not in include_statuses:
            continue

        try:
            email_id = int(email.get("id"))
        except (TypeError, ValueError):
            continue

        key = thread_key(email)
        latest_inbound = thread_latest_inbound.get(key)
        summary = summarize_related_events(
            email.get("from_email", ""),
            email.get("subject", ""),
            email.get("created_at", ""),
            resend_payload,
            recipient_index,
        )
        delivered_after_latest = 0
        for row in summary["rows"]:
            if row["bucket"] != "delivered":
                continue
            delivered_at = parse_ts(row.get("created_at", ""))
            if latest_inbound is not None and delivered_at is not None and delivered_at <= latest_inbound:
                continue
            delivered_after_latest += 1
        evidence[email_id] = delivered_after_latest
    return evidence


def open_thread_delivery_evidence(rows, resend_payload, recipient_index=None) -> dict[int, int]:
    return thread_delivery_evidence(
        rows,
        resend_payload,
        recipient_index,
        include_statuses={"pending", "needs_human", "new", "error"},
    )
