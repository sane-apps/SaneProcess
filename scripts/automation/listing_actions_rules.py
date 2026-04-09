#!/usr/bin/env python3
"""Classification and aggregation helpers for listing action exports."""

from __future__ import annotations

import html
import re
from collections import defaultdict
from datetime import datetime, timezone

URL_RE = re.compile(r"https?://[^\s<>()\"']+")
LISTING_CONTEXT_TOKENS = (
    "listing",
    "directory",
    "vendor portal",
    "software page",
    "software request",
    "get listed",
    "submission report",
    "claim this",
    "listing profile",
)
LISTING_REQUIRED_TOKENS = (
    "activate",
    "activation",
    "verify",
    "claim",
    "complete profile",
    "finish profile",
    "create account",
    "set password",
    "vendor portal",
)
LISTING_OPTIONAL_TOKENS = (
    "featured",
    "premium",
    "upgrade",
    "expedite",
    "sponsored",
    "paid listing",
)
LISTING_MONITOR_TOKENS = (
    "queue",
    "queued",
    "under review",
    "review time",
    "review eta",
    "submission received",
    "request received",
    "queue position",
)
LISTING_IGNORE_TOKENS = (
    "security alert",
    "refund",
    "bug report",
    "app store review",
    "github issue",
    "dmca",
    "copyright",
    "infringing",
    "homebrew tap",
    "webinar",
    "newsletter",
)


def extract_urls(*chunks):
    urls = []
    seen = set()
    for chunk in chunks:
        text = html.unescape(str(chunk or ""))
        for match in URL_RE.findall(text):
            url = match.rstrip(").,>;]}")
            if url not in seen:
                seen.add(url)
                urls.append(url)
    return urls


def sender_site_name(from_email):
    domain = str(from_email or "").split("@")[-1].strip().lower()
    if not domain:
        return "Unknown"
    if domain.startswith("www."):
        domain = domain[4:]
    parts = [part for part in domain.split(".") if part]
    if len(parts) >= 2:
        host = parts[-2]
        if host in {"co", "com", "net", "org", "app", "io"} and len(parts) >= 3:
            host = parts[-3]
    else:
        host = parts[0]
    words = [word for word in re.split(r"[-_]+", host) if word]
    return " ".join(word.title() for word in words) or "Unknown"


def infer_generic_listing_status(haystack):
    if any(token in haystack for token in LISTING_OPTIONAL_TOKENS):
        return "Optional"
    if any(token in haystack for token in LISTING_REQUIRED_TOKENS):
        return "Required"
    if any(token in haystack for token in LISTING_MONITOR_TOKENS):
        return "Monitor"
    return ""


def generic_listing_action(row, urls):
    subject = str(row.get("subject") or "")
    body_text = str(row.get("body_text") or "")
    from_email = str(row.get("from_email") or "")
    haystack = " ".join([subject, body_text, " ".join(urls)]).lower()

    if any(token in haystack for token in LISTING_IGNORE_TOKENS):
        return None
    if not urls:
        return None

    has_context = any(token in haystack for token in LISTING_CONTEXT_TOKENS)
    inferred_status = infer_generic_listing_status(haystack)
    if not has_context or not inferred_status:
        return None

    site = sender_site_name(from_email)
    if inferred_status == "Required":
        workflow = "Review new listing/setup email"
        action = "Review this new listing/setup email and complete the requested setup."
        instructions = (
            "This sender is not covered by a dedicated listing rule yet. Open the vendor link, "
            "complete the setup/claim/activation step, then promote the sender to an explicit rule "
            "in listing_actions_rules.py if it recurs."
        )
    elif inferred_status == "Optional":
        workflow = "Review optional listing offer"
        action = "Review this optional listing/visibility offer."
        instructions = (
            "This matched the generic listing heuristic as an optional upsell. Review the link and "
            "decide whether paid placement or an upgraded listing is worth doing."
        )
    else:
        workflow = "Monitor new listing queue/update"
        action = "Monitor this new listing queue/update email for follow-up."
        instructions = (
            "This matched the generic listing heuristic as a queue/status update. Track it in the "
            "workbook now, and add a dedicated rule later if this sender becomes recurring."
        )

    return action_item(
        site,
        workflow,
        inferred_status,
        action,
        instructions,
        urls,
        note="Generic heuristic match. Promote to a dedicated rule if this sender recurs.",
    )


def pick_url(urls, includes=(), excludes=()):
    for url in urls:
        lower = url.lower()
        if includes and not any(token in lower for token in includes):
            continue
        if excludes and any(token in lower for token in excludes):
            continue
        return url
    return urls[0] if urls else ""


def action_item(
    site,
    workflow,
    required,
    action,
    instructions,
    urls,
    *,
    primary_include=(),
    primary_exclude=(),
    secondary_link="",
    secondary_include=(),
    secondary_exclude=(),
    note="",
):
    return {
        "site": site,
        "workflow": workflow,
        "required": required,
        "action": action,
        "instructions": instructions,
        "primary_link": pick_url(urls, includes=primary_include, excludes=primary_exclude),
        "secondary_link": secondary_link or pick_url(urls, includes=secondary_include, excludes=secondary_exclude),
        "note": note,
    }


def classify_email(row):
    subject = str(row.get("subject") or "")
    subject_l = subject.lower()
    from_email = str(row.get("from_email") or "").lower()
    urls = extract_urls(row.get("body_text"), row.get("body_html"))

    if "saasworthy.com" in from_email:
        if "welcome to saasworthy" in subject_l:
            return action_item(
                "SaaSworthy",
                "Verify vendor portal invite",
                "Required",
                "Verify the SaaSworthy invite email to activate vendor portal access.",
                "Use the verification link. The email said it expires after 72 hours; if it is stale, ask SaaSworthy to resend the invite.",
                urls,
                primary_include=("sendgrid.net/ls/click",),
                secondary_link="https://www.saasworthy.com/",
                note="This is the initial free-listing activation email.",
            )
        if "vendor portal access is now active" in subject_l:
            return action_item(
                "SaaSworthy",
                "Complete vendor portal profile",
                "Required",
                "Log into the SaaSworthy Vendor Portal and finish the SaneBar profile.",
                "Use hi@saneapps.com, request the OTP, then update product details, pricing, screenshots, and listing copy in the vendor portal.",
                urls,
                primary_include=("sendgrid.net/ls/click",),
                secondary_link="mailto:support@saasworthy.com",
                note="This is the current required SaaSworthy setup step.",
            )
        if "upgrade with your free listing profile" in subject_l:
            return action_item(
                "SaaSworthy",
                "Optional premium visibility upsell",
                "Optional",
                "Optional: book a call if you want Featured Listing or Premium Profile placement.",
                "Not required for the free listing. Only use this if you want paid visibility / lead-gen options.",
                urls,
                primary_include=("calendly.com",),
                secondary_link="https://www.saasworthy.com/",
                note="Sales upsell, not a blocker for the free listing.",
            )

    if "sourceforge.net" in from_email or "slashdotmedia.com" in from_email:
        if "software request" in subject_l:
            return action_item(
                "SourceForge",
                "Create vendor account",
                "Required",
                "Create a SourceForge business account so the future software page can be managed.",
                "Open the registration link, create the business account, then use it for the later claim/edit steps.",
                urls,
                primary_include=("registration_business",),
                secondary_include=("software/vendors",),
                note="SourceForge explicitly says an account is needed to manage the page.",
            )
        if "sanebar on sourceforge" in subject_l:
            return action_item(
                "SourceForge",
                "Claim the SaneBar page",
                "Required",
                "Claim the SaneBar SourceForge page and take editing control.",
                "Open the page link, click Claim this Software Page, then update the listing while signed into the business account.",
                urls,
                primary_include=("claim", "claim-this-software-page"),
                primary_exclude=("sourceforge.net/software/vendors",),
                secondary_include=("sourceforge",),
                secondary_exclude=("claim",),
                note="This is the concrete SourceForge listing handoff.",
            )

    if "gartner.com" in from_email or "digitalmarkets" in from_email:
        return action_item(
            "Gartner Digital Markets",
            "Activate account and complete profile",
            "Required",
            "Activate the Gartner Digital Markets account and fill in the remaining profile details.",
            "Use the activation link from the email. If it expired, use the password recovery link in the same email to request a fresh activation path.",
            urls,
            primary_include=("activate", "click?upn="),
            secondary_include=("password", "recover"),
            note="The email said the activation link expires in 7 days.",
        )

    if "startupstash.com" in from_email:
        return action_item(
            "Startup Stash",
            "Choose a paid listing tier",
            "Optional",
            "Decide whether to buy a Basic or Premium Startup Stash listing for SaneBar.",
            "Startup Stash is offering paid listing tiers only: Basic is $199/year and Premium is $399/year.",
            urls,
            primary_include=("buy.stripe.com", "8wmaih7nv"),
            secondary_include=("buy.stripe.com", "ev"),
            note="No listing happens until one of the payment links is used.",
        )

    if "promotebusinessdirectory.com" in from_email:
        return action_item(
            "PromoteBusinessDirectory",
            "Decide between waiting or paying for featured review",
            "Optional",
            "Either wait for regular review or pay to convert the submission to a featured listing.",
            "Regular review takes 4-5 months and is not guaranteed. The optional featured payment is for urgent listing.",
            urls,
            primary_include=("payment.php",),
            secondary_link="https://www.promotebusinessdirectory.com/",
            note="This is an upsell, not a required setup step.",
        )

    if "confettisaas.com" in from_email:
        return action_item(
            "ConfettiSaaS",
            "Monitor queue status",
            "Monitor",
            "No setup right now. Track the queue position and wait for review.",
            "Use the status link to check placement. Current email says SaneBar is #302 of 328 with an estimated 31-week wait.",
            urls,
            primary_include=("submit-success",),
            secondary_link="https://confettisaas.com/",
            note="Monitoring only.",
        )

    if any(token in from_email for token in ("startupsubmit", "websparked.com")):
        if "submission report is ready" in subject_l:
            return action_item(
                "StartupSubmit",
                "Review master sheet deliverables",
                "Required",
                "Open the StartupSubmit Airtable master sheet and review the live links, screenshots, usernames, and passwords they created.",
                "Use the Airtable sheet as the master inventory for what StartupSubmit claims to have submitted. Review whether any listing still needs manual completion.",
                urls,
                primary_include=("airtable.com",),
                secondary_include=("reddit-marketing", "startupsubmit.app"),
                note="This is the main deliverable from StartupSubmit.",
            )
        return action_item(
            "StartupSubmit",
            "Decide whether vendor must redo manual setups",
            "Required",
            "Decide whether to accept the current StartupSubmit deliverables or require them to redo any directories that still need manual setup under the correct email path.",
            "The transcript shows you explicitly said you did not want to do all the setup yourself. Use the Airtable sheet and chat record to force cleanup/redelivery if needed.",
            urls,
            primary_include=("airtable.com", "resume", "startupsubmit.app"),
            secondary_link="https://startupsubmit.app/",
            note="Vendor admitted some directories routed to the business email because of site requirements.",
        )

    if "startupbuffer.com" in from_email:
        return action_item(
            "Startup Buffer",
            "Optional expedited review",
            "Optional",
            "Optional: buy the expedited review if you want Startup Buffer to move faster.",
            "The base submission was already received. This email only offers a paid expedite path.",
            urls,
            secondary_link="https://startupbuffer.com/",
            note="Not required for the submission itself.",
        )

    if "selldigitals.com" in from_email:
        return action_item(
            "SellDigitals",
            "Create account for purchased listing assets",
            "Optional",
            "Optional: create a SellDigitals account if you need access to the purchased listing assets and order details.",
            "Use the order-details link to review what was bought, and create an account only if you need ongoing access to those assets.",
            urls,
            primary_include=("orders/", "details"),
            secondary_include=("auth/registration",),
            note="Part of the StartupSubmit-related listing workflow, not a direct SaneBar directory listing.",
        )

    return generic_listing_action(row, urls)


def parse_timestamp(value):
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return datetime.min.replace(tzinfo=timezone.utc)


def build_email_history(rows):
    history = []
    for row in rows:
        classification = classify_email(row)
        if not classification:
            continue
        urls = extract_urls(row.get("body_text"), row.get("body_html"))
        history.append(
            {
                "site": classification["site"],
                "workflow": classification["workflow"],
                "required": classification["required"],
                "action": classification["action"],
                "instructions": classification["instructions"],
                "primary_link": classification["primary_link"],
                "secondary_link": classification["secondary_link"],
                "note": classification["note"],
                "email_id": row.get("id"),
                "status": row.get("status") or "",
                "category": row.get("category") or "",
                "from_email": row.get("from_email") or "",
                "subject": row.get("subject") or "",
                "created_at": row.get("created_at") or "",
                "all_urls": "\n".join(urls[:12]),
            }
        )
    history.sort(key=lambda item: parse_timestamp(item["created_at"]), reverse=True)
    return history


def build_current_actions(history_rows):
    grouped = defaultdict(list)
    for row in history_rows:
        grouped[(row["site"], row["workflow"])].append(row)

    current = []
    for rows in grouped.values():
        rows.sort(key=lambda item: parse_timestamp(item["created_at"]), reverse=True)
        latest = rows[0]
        current.append(
            {
                "site": latest["site"],
                "workflow": latest["workflow"],
                "action_status": latest["required"] if latest["required"] in {"Optional", "Monitor"} else "Needs action",
                "required": latest["required"],
                "latest_date": latest["created_at"],
                "latest_email_id": latest["email_id"],
                "latest_thread_status": latest["status"],
                "latest_subject": latest["subject"],
                "action": latest["action"],
                "instructions": latest["instructions"],
                "primary_link": latest["primary_link"],
                "secondary_link": latest["secondary_link"],
                "source_email_ids": ", ".join(str(item["email_id"]) for item in rows),
                "note": latest["note"],
            }
        )
    status_rank = {"Needs action": 0, "Optional": 1, "Monitor": 2}
    current.sort(key=lambda item: (status_rank.get(item["action_status"], 9), item["site"], item["workflow"]))
    return current
