# App Store Review SOP — `iap_policy: none` (Stripe-only companions)

Use this lane when `.saneprocess` sets `appstore.iap_policy: none` (no StoreKit, no IAP, billing outside the App Store).

## What Apple is rejecting

Guideline **2.1(b)** when an **in-app purchase or subscription is still associated with the app version in App Store Connect** but **does not exist in the submitted binary**.

Fixing the iOS binary alone is **not sufficient**. Apple expects Monetization cleanup **before** resubmit.

## Root failure mode we hit (SaneLot ×3)

1. StoreKit was removed from the app.
2. `appstore_preflight` did not enforce `iap_policy: none`.
3. `com.sanelot.app.core.monthly` remained in App Store Connect with a **DEVELOPER_REJECTED** subscription version.
4. Submission still carried (or Apple still treated) the subscription as associated with version 1.1.0.
5. Review failed again with the same 2.1(b) text.

## Mandatory pre-submit checklist

### A. Binary (local)

- [ ] No StoreKit / IAP / price / subscribe / restore strings in Release IPA (`appstore_preflight` monetization guards).
- [ ] `appstore.iap_policy: none` and `retired_product_ids` list every legacy ASC product still on the app.

### B. App Store Connect Monetization (Brave on Mini)

- [ ] Open **Distribution → iOS → inflight version → Included Assets**.
- [ ] **No** subscriptions or IAP selected under **In-App Purchases and Subscriptions**.
- [ ] For each `retired_product_ids` entry: product is **not for sale** (no territories / not available in new territories).
- [ ] If a subscription has a **DEVELOPER_REJECTED** subscription version: remove from Included Assets, remove from sale. Permanent deletion often returns `SUBSCRIPTION_DELETE_NOT_ALLOWED` — treat as a **tombstone** (unavailable + detached + Resolution Center reply stating retired/not offered). Do not resubmit only a new binary without that reply.

### C. Automated gates (must pass before Submit for Review)

From the app project root on Mini:

```bash
ruby ../../infra/SaneProcess/scripts/appstore_submit.rb \
  --app-id <ASC_APP_ID> \
  --version <MARKETING_VERSION> \
  --platform ios \
  --project-root "$PWD" \
  --iap-only
```

Also run package-bound preflight:

```bash
./scripts/SaneMaster.rb appstore_preflight
```

**Both must pass with zero issues.** Warnings-only is not enough if No-IAP policy reports issues.

Successful `--iap-only` writes `outputs/appstore_no_iap_readiness_receipt.json`.

### D. Review submission contents

- [ ] Review submission items contain **only** the app store version (no IAP/subscription items).
- [ ] Review notes explain 3.1.3(c) enterprise companion + no in-app purchase surface.
- [ ] Do not reference IAP prices or "monthly subscription" in metadata unless removing the product from ASC.

## What not to do

- Do **not** resubmit hoping a clean binary alone fixes 2.1(b) IAP association.
- Do **not** skip `--iap-only` because "we already removed StoreKit."
- Do **not** treat `appstore_preflight` warnings-only as ship-ready for no-IAP apps.
- Do **not** manually submit in Brave without running `--iap-only` in the same session immediately before Submit for Review.

## SaneLot current blocker (2026-07-28)

Build **1118** rejected again: subscription **SaneLot Monthly** (`com.sanelot.app.core.monthly`) still associated; subscription version **DEVELOPER_REJECTED**.

**Before build 1119:** clean Monetization in ASC, confirm `--iap-only` and `appstore_preflight` pass, then archive/upload/submit.
