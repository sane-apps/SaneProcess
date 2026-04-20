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


def related_events(target: str, original_subject: str, original_created: str, resend_payload, recipient_index=None) -> list[dict]:
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
        if not is_related(email.get("subject", ""), original_subject):
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


def summarize_related_events(target: str, original_subject: str, original_created: str, resend_payload, recipient_index=None) -> dict:
    rows = related_events(target, original_subject, original_created, resend_payload, recipient_index)
    summary = {"delivered": 0, "bounced": 0, "pending": 0, "rows": rows}
    for row in rows:
        summary[row["bucket"]] += 1
    return summary


def open_thread_delivery_evidence(rows, resend_payload, recipient_index=None) -> dict[int, int]:
    evidence = {}
    for email in rows or []:
        status = (email.get("status") or "").strip().lower()
        category = (email.get("category") or "").strip().lower()
        if category == "spam" or status == "spam":
            continue
        if status not in {"pending", "needs_human", "new", "error"}:
            continue

        try:
            email_id = int(email.get("id"))
        except (TypeError, ValueError):
            continue

        summary = summarize_related_events(
            email.get("from_email", ""),
            email.get("subject", ""),
            email.get("created_at", ""),
            resend_payload,
            recipient_index,
        )
        evidence[email_id] = summary["delivered"]
    return evidence
