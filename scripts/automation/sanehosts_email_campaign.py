#!/usr/bin/env python3
"""SaneHosts 12-week weekday sender.

Books Email 1 (cap 50/weekday) plus due Email 2/3 via Resend.
If a weekday is already partly booked, this tops up to 50 instead of skipping.
Campaign files live in the Mini outputs dir. This script is the git-tracked
runner so an unloaded Grok heartbeat cannot create another empty work day.

  source ~/.config/nv/env
  python3 sanehosts_email_campaign.py --dir ~/SaneApps/outputs/sanehosts-apollo-2026-08-27/campaign
  python3 sanehosts_email_campaign.py --dir ... --send
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, time as time_cls, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
WINDOW_START = date(2026, 9, 1)
WINDOW_END = date(2026, 11, 24)  # 12 weeks after Sep 1
E1_CAP = 50
E1_HOUR, E1_MINUTE = 9, 0
STEP_MINUTES = 3
LOT_BLOCK = ((9, 38), (10, 12))
LEAD_FLOOR = E1_CAP * 3
REFILL_SEARCH_CAP = 250
REFILL_ENRICH_LIMIT = 200
FROM = "Stephan Joseph <hi@saneapps.com>"
REPLY = "hi@saneapps.com"
CAMPAIGN = "sanehosts-apollo-20260827"
UA = "SaneHosts-Campaign/1.0"
STOP = ("unsubscribed", "bounced", "complained", "replied")
SKIP_ADDR = {
    "stephanjoseph2007@gmail.com",
    "hi@saneapps.com",
    "stephan@saneapps.com",
    "hello@saneapps.com",
    "support@saneapps.com",
}
DEFAULT_DIR = Path.home() / "SaneApps/outputs/sanehosts-apollo-2026-08-27/campaign"


def add_business_days(start, days: int) -> date:
    if isinstance(start, datetime):
        cur = start.date()
    elif isinstance(start, str):
        cur = date.fromisoformat(start[:10])
    else:
        cur = start
    added = 0
    while added < days:
        cur += timedelta(days=1)
        if cur.weekday() < 5:
            added += 1
    return cur


def skip_addr(email: str) -> bool:
    e = (email or "").strip().lower()
    if not e or "@" not in e or e in SKIP_ADDR:
        return True
    local, _, dom = e.partition("@")
    return dom == "saneapps.com" or local.startswith("stephanjoseph")


def load_state(path: Path) -> dict:
    if path.exists():
        try:
            data = json.loads(path.read_text())
            if isinstance(data, dict) and isinstance(data.get("contacts"), dict):
                return data
        except Exception:
            pass
    return {"contacts": {}, "campaign": CAMPAIGN}


def sent_e1(state: dict) -> set[str]:
    return {
        (email or "").strip().lower()
        for email, rec in state.get("contacts", {}).items()
        if rec.get("e1_date")
    }


def unsent_rows(roster: Path, state: dict) -> list[dict]:
    if not roster.exists():
        return []
    already = sent_e1(state)
    rows, seen = [], set()
    with roster.open(newline="", encoding="utf-8") as fh:
        for raw in csv.DictReader(fh):
            email = (raw.get("email") or "").strip().lower()
            if skip_addr(email) or email in already or email in seen:
                continue
            if rec_stopped(state, email):
                continue
            raw["email"] = email
            seen.add(email)
            rows.append(raw)
    return rows


def rec_stopped(state: dict, email: str) -> bool:
    rec = state.get("contacts", {}).get(email) or {}
    return rec.get("stop") in STOP


def due_rows(state: dict, today: date, touch: str) -> list[dict]:
    rows = []
    delay = 5 if touch == "e2" else 8
    start_key = "e1_date" if touch == "e2" else "e2_date"
    for email, rec in state.get("contacts", {}).items():
        if rec.get("stop") in STOP:
            continue
        if rec.get(f"{touch}_date"):
            continue
        start = rec.get(start_key)
        if not start:
            continue
        if add_business_days(start, delay) <= today:
            fn = (rec.get("first_name") or "there").strip() or "there"
            rows.append({"email": email, "first_name": fn})
    return rows


def _lot_block(day: date) -> tuple[datetime, datetime]:
    (ah, am), (bh, bm) = LOT_BLOCK
    start = datetime.combine(day, time_cls(ah, am), tzinfo=ET)
    end = datetime.combine(day, time_cls(bh, bm), tzinfo=ET)
    return start, end


def next_slot(when: datetime) -> datetime:
    lot_a, lot_b = _lot_block(when.date())
    if lot_a <= when < lot_b:
        return lot_b
    return when


def schedule_at(day: date, index: int, now: datetime | None = None) -> datetime:
    start = datetime.combine(day, time_cls(E1_HOUR, E1_MINUTE), tzinfo=ET)
    if now is not None:
        floor = now.astimezone(ET) + timedelta(minutes=15)
        if start < floor:
            start = floor
    when = next_slot(start)
    for _ in range(index):
        when = next_slot(when + timedelta(minutes=STEP_MINUTES))
    return when


def drip_start(day: date, touch: str, now: datetime | None = None) -> datetime:
    hm = (10, 20) if touch == "e2" else (10, 15)
    when = datetime.combine(day, time_cls(*hm), tzinfo=ET)
    if now is not None:
        floor = now.astimezone(ET) + timedelta(minutes=15)
        if when < floor:
            when = floor
    return when


def resend_send(key: str, payload: dict) -> str:
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "User-Agent": UA,
        },
    )
    return json.loads(urllib.request.urlopen(req, timeout=45).read().decode()).get("id", "?")


def book_touch(here: Path, key: str, today: date, touch: str, rows: list[dict], now: datetime, send: bool, on_sent=None) -> dict:
    n = touch[-1]
    subj = (here / f"email-{n}.subject").read_text().strip()
    text_tmpl = (here / f"email-{n}.txt").read_text()
    html_tmpl = (here / f"email-{n}.html").read_text()
    if touch == "e1":
        first = schedule_at(today, 0, now)
    else:
        first = drip_start(today, touch, now)
    ids, emails, errors = [], [], []
    for i, row in enumerate(rows):
        when = first + timedelta(minutes=i * STEP_MINUTES) if touch != "e1" else schedule_at(today, i, now)
        fn = (row.get("first_name") or "there").strip() or "there"
        payload = {
            "from": FROM,
            "to": [row["email"]],
            "subject": subj,
            "text": text_tmpl.replace("{{FIRST_NAME}}", fn),
            "html": html_tmpl.replace("{{FIRST_NAME}}", fn),
            "reply_to": REPLY,
            "headers": {"List-Unsubscribe": f"<mailto:{REPLY}?subject=unsubscribe>"},
            "scheduled_at": when.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "tags": [
                {"name": "campaign", "value": CAMPAIGN},
                {"name": "wave", "value": touch},
            ],
        }
        if not send:
            emails.append(row["email"])
            continue
        try:
            rid = resend_send(key, payload)
            ids.append(rid)
            emails.append(row["email"])
            print(f"{touch} {len(emails)} {when.strftime('%Y-%m-%d %H:%M %Z')} id={rid}")
            if on_sent:
                on_sent(row, rid, when)
        except urllib.error.HTTPError as exc:
            errors.append({"email": row["email"], "error": exc.read().decode()[:200]})
            print(f"{touch} ERROR {exc.code} {row['email']}", file=sys.stderr)
        time.sleep(0.25)
    wave = {"e1": "email-1", "e2": "email-2", "e3": "email-3"}[touch]
    return {
        "date": today.isoformat(),
        "wave": wave,
        "touch": touch,
        "scheduled": len(ids) if send else 0,
        "dry_run": not send,
        "count": len(rows),
        "errors": errors,
        "emails": emails if send else [],
        "ids": ids,
        "from": FROM,
        "subject": subj,
        "first_et": first.isoformat(),
    }


def e1_receipt_path(here: Path, today: date) -> Path:
    return here / f"e1-send-receipt-{today.isoformat()}.json"


def load_e1_receipt(here: Path, today: date) -> dict | None:
    path = e1_receipt_path(here, today)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def booked_today_count(receipt: dict | None) -> int:
    if not receipt:
        return 0
    ids = receipt.get("ids") or []
    emails = receipt.get("emails") or []
    scheduled = receipt.get("scheduled")
    return max(len(ids), len(emails), int(scheduled or 0))


def write_e1_receipt(here: Path, today: date, receipt: dict) -> None:
    e1_receipt_path(here, today).write_text(json.dumps(receipt, indent=2) + "\n")


def merge_e1_receipt(here: Path, today: date, new_receipt: dict) -> dict:
    old = load_e1_receipt(here, today) or {}
    merged = dict(old)
    merged.update({
        "date": today.isoformat(),
        "wave": "email-1",
        "touch": "e1",
        "from": new_receipt.get("from") or old.get("from"),
        "subject": new_receipt.get("subject") or old.get("subject"),
        "dry_run": False,
        "scheduled": booked_today_count(old) + int(new_receipt.get("scheduled") or 0),
        "count": booked_today_count(old) + int(new_receipt.get("count") or 0),
        "errors": (old.get("errors") or []) + (new_receipt.get("errors") or []),
        "emails": (old.get("emails") or []) + (new_receipt.get("emails") or []),
        "ids": (old.get("ids") or []) + (new_receipt.get("ids") or []),
        "first_et": old.get("first_et") or new_receipt.get("first_et"),
        "last_et": new_receipt.get("first_et"),
        "cap": E1_CAP,
    })
    topups = list(old.get("topups") or [])
    added = int(new_receipt.get("scheduled") or 0)
    if old and added > 1:
        topups.append(new_receipt.get("first_et"))
    merged["topups"] = topups
    write_e1_receipt(here, today, merged)
    return merged


def write_drip_receipt(here: Path, today: date, touch: str, receipt: dict) -> None:
    wave = "email-2" if touch == "e2" else "email-3"
    (here / f"{wave}-send-receipt-{today.isoformat()}.json").write_text(json.dumps(receipt, indent=2) + "\n")


def mark_sent(state: dict, rows: list[dict], ids: list[str], today: date, touch: str, subject: str | None = None) -> None:
    for i, row in enumerate(rows):
        if i >= len(ids):
            break
        rec = state["contacts"].setdefault(
            row["email"],
            {
                "email": row["email"],
                "first_name": "",
                "company": "",
                "e1_date": None,
                "e1_id": None,
                "e2_date": None,
                "e2_id": None,
                "e3_date": None,
                "e3_id": None,
                "e1_subject": None,
                "stop": None,
            },
        )
        rec[f"{touch}_date"] = today.isoformat()
        rec[f"{touch}_id"] = ids[i]
        rec["first_name"] = rec.get("first_name") or row.get("first_name") or ""
        rec["company"] = rec.get("company") or row.get("company") or ""
        if touch == "e1" and subject:
            rec["e1_subject"] = subject


def append_ledger(here: Path, lines: list[str]) -> None:
    path = here / "LEDGER.md"
    prev = path.read_text() if path.exists() else "# SaneHosts 12-week campaign ledger\n\n"
    path.write_text(prev.rstrip() + "\n\n" + "\n".join(lines) + "\n")


def refill_if_needed(here: Path, unsent: int, today: date, send: bool) -> dict:
    result = {"need_leads": unsent < LEAD_FLOOR, "ran": False, "sendable_added": 0}
    if unsent >= LEAD_FLOOR or today.weekday() >= 5:
        return result
    root = here.parent
    puller = root / "pull_sanehosts.py"
    enrich = here / "enrich_emails.py"
    if not puller.exists() or not enrich.exists():
        result["error"] = "puller-or-enrich-missing"
        return result
    if not send:
        result["skipped"] = "dry-run"
        return result
    subprocess.run(
        [sys.executable, str(puller), "--search", "--append", "--cap", str(REFILL_SEARCH_CAP), "--prefer-email"],
        cwd=str(root),
        check=False,
    )
    before = _sendable_count(here / "sanehosts-sendable.csv")
    subprocess.run(
        [sys.executable, str(enrich), "--append", "--limit", str(REFILL_ENRICH_LIMIT)],
        cwd=str(here),
        check=False,
    )
    after = _sendable_count(here / "sanehosts-sendable.csv")
    result["ran"] = True
    result["sendable_added"] = max(0, after - before)
    return result


def _sendable_count(path: Path) -> int:
    if not path.exists():
        return 0
    with path.open(newline="", encoding="utf-8") as fh:
        return sum(1 for _ in csv.DictReader(fh))


def plan_day(here: Path, today: date, now: datetime | None = None) -> dict:
    now = now or datetime.now(ET)
    state = load_state(here / "drip-state.json")
    abort = (here / "campaign-ABORT").exists()
    receipt = load_e1_receipt(here, today)
    booked = booked_today_count(receipt)
    remain = max(0, E1_CAP - booked)
    unsent = unsent_rows(here / "sanehosts-sendable.csv", state)
    e2 = due_rows(state, today, "e2")
    e3 = due_rows(state, today, "e3")
    in_window = WINDOW_START <= today <= WINDOW_END
    weekday = today.weekday() < 5
    e1 = unsent[:remain] if in_window and weekday and remain else []
    actions = []
    if abort:
        actions.append("abort-file")
    elif today.weekday() >= 5:
        actions.append("weekend-skip")
    elif not in_window:
        actions.append("outside-window")
    else:
        if e3:
            actions.append(f"email-3-{len(e3)}")
        if e2:
            actions.append(f"email-2-{len(e2)}")
        if booked >= E1_CAP:
            actions.append("e1-already-booked")
        elif e1:
            label = f"email-1-{len(e1)}"
            if booked:
                label += f"-topup-from-{booked}"
            actions.append(label)
        elif not e2 and not e3:
            actions.append("empty-blocked")
    return {
        "date": today.isoformat(),
        "in_window": in_window,
        "weekday": weekday,
        "abort": abort,
        "e1_already_booked": booked >= E1_CAP,
        "e1_booked_today": booked,
        "e1_remain": remain,
        "unsent_left": len(unsent),
        "e1": e1,
        "e2": e2,
        "e3": e3,
        "actions": actions,
        "need_leads": len(unsent) < LEAD_FLOOR,
        "window": f"{WINDOW_START.isoformat()}..{WINDOW_END.isoformat()}",
        "e1_cap": E1_CAP,
    }


def run(here: Path, send: bool) -> dict:
    now = datetime.now(ET)
    today = now.date()
    plan = plan_day(here, today, now)
    result = {
        "now": now.isoformat(),
        "campaign": CAMPAIGN,
        "send": send,
        "actions": list(plan["actions"]),
        "unsent_left": plan["unsent_left"],
        "need_leads": plan["need_leads"],
        "window": plan["window"],
    }
    if plan["abort"] or today.weekday() >= 5 or not plan["in_window"]:
        (here / "morning-latest.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return result
    if send and not os.environ.get("RESEND_API_KEY"):
        sys.exit("RESEND_API_KEY missing")
    key = os.environ.get("RESEND_API_KEY", "")
    state = load_state(here / "drip-state.json")

    if plan["e3"]:
        rec = book_touch(here, key, today, "e3", plan["e3"], now, send)
        result["email_3"] = {"count": rec["count"], "scheduled": rec["scheduled"], "errors": len(rec["errors"])}
        if send:
            write_drip_receipt(here, today, "e3", rec)
            mark_sent(state, plan["e3"], rec["ids"], today, "e3")

    if plan["e2"]:
        rec = book_touch(here, key, today, "e2", plan["e2"], now, send)
        result["email_2"] = {"count": rec["count"], "scheduled": rec["scheduled"], "errors": len(rec["errors"])}
        if send:
            write_drip_receipt(here, today, "e2", rec)
            mark_sent(state, plan["e2"], rec["ids"], today, "e2")

    if plan["e1"]:
        def persist_e1(row: dict, rid: str, when: datetime) -> None:
            mark_sent(state, [row], [rid], today, "e1", (here / "email-1.subject").read_text().strip())
            (here / "drip-state.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
            merge_e1_receipt(
                here,
                today,
                {
                    "scheduled": 1,
                    "count": 1,
                    "emails": [row["email"]],
                    "ids": [rid],
                    "errors": [],
                    "from": FROM,
                    "subject": (here / "email-1.subject").read_text().strip(),
                    "first_et": when.isoformat(),
                },
            )

        rec = book_touch(here, key, today, "e1", plan["e1"], now, send, on_sent=persist_e1 if send else None)
        result["email_1"] = {
            "count": rec["count"],
            "scheduled": rec["scheduled"],
            "errors": len(rec["errors"]),
            "booked_before": plan["e1_booked_today"],
        }
        if send:
            result["unsent_left"] = max(0, plan["unsent_left"] - len(rec["ids"]))

    if send:
        (here / "drip-state.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")

    refill = refill_if_needed(here, result["unsent_left"], today, send)
    result["refill"] = {k: v for k, v in refill.items() if k != "error" or v}
    if refill.get("ran"):
        result["actions"].append(f"refill-+{refill.get('sendable_added', 0)}")
        result["unsent_left"] = len(unsent_rows(here / "sanehosts-sendable.csv", load_state(here / "drip-state.json")))

    if send:
        append_ledger(
            here,
            [
                f"## {today.isoformat()} morning",
                f"- GO: yes. Window {WINDOW_START} → {WINDOW_END}. Cap {E1_CAP} Email 1 / weekday.",
                f"- Actions: {', '.join(result['actions']) or 'none'}.",
                f"- Sendable left after this run: {result['unsent_left']}. need_leads={result['need_leads']}.",
                f"- From {FROM}. Abort: `touch campaign-ABORT` in this directory.",
            ],
        )
    (here / "morning-latest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if "empty-blocked" in result["actions"]:
        sys.exit(2)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--send", action="store_true")
    parser.add_argument("--plan", action="store_true", help="print plan only")
    args = parser.parse_args()
    here = args.dir.expanduser().resolve()
    if args.plan:
        print(json.dumps({k: (len(v) if k in {"e1", "e2", "e3"} else v) for k, v in plan_day(here, datetime.now(ET).date()).items()}, indent=2))
        return
    run(here, send=args.send)


if __name__ == "__main__":
    main()
