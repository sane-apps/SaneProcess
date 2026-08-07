## Store compliance automation landscape | Updated: 2026-08-02 | Status: verified | TTL: 30d

### Question

Can SaneProcess adopt an existing machine-readable Apple App Store and Chrome
Web Store compliance checker instead of maintaining another one-off checklist?

### Finding

No official or credible third-party tool preapproves an app against every
human-review policy. Both stores publish authoritative policy pages and APIs
for submission/status, but neither API returns a complete policy-compliance
verdict. The reliable design is a hybrid gate: adopt authoritative validators
and mature narrow linters, then add only the missing cross-surface checks to
the existing SaneMaster release path.

### Authoritative sources

- Apple App Review Guidelines:
  https://developer.apple.com/app-store/review/guidelines/
- App Store Connect API and review submissions:
  https://developer.apple.com/app-store-connect/api/
  https://developer.apple.com/documentation/appstoreconnectapi/review-submissions
- Apple upload and `altool --validate-app`:
  https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Apple privacy manifests and Required Reason APIs:
  https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Apple screenshot specifications and upcoming requirements:
  https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
  https://developer.apple.com/news/upcoming-requirements/
- Chrome Web Store Program Policies:
  https://developer.chrome.com/docs/webstore/program-policies/policies
- Chrome listing image rules and listing guidance:
  https://developer.chrome.com/docs/webstore/images
  https://developer.chrome.com/docs/webstore/best-listing
- Chrome Web Store API v2 and discovery document:
  https://developer.chrome.com/docs/webstore/api/reference/rest
  https://chromewebstore.googleapis.com/$discovery/rest?version=v2

### Chrome Web Store transition monitoring

The supported read-only status route is
`GET /v2/publishers/{publisherId}/items/{itemId}:fetchStatus`. Its response
separates `submittedItemRevisionStatus` from `publishedItemRevisionStatus`,
includes the submitted CRX version in `distributionChannels`, and exposes
`takenDown` and `warned` policy flags. The documented item states are
`PENDING_REVIEW`, `STAGED`, `PUBLISHED`, `PUBLISHED_TO_TESTERS`, `REJECTED`,
and `CANCELLED`. `STAGED` means approved and ready to publish; it is not the
same as a published listing. The API requires publisher-scoped OAuth or a
publisher-authorized service account, so a durable watcher must fail closed
when that credential is absent rather than scrape or automate the dashboard.

Source: https://developer.chrome.com/docs/webstore/api/reference/rest/v2/publishers.items/fetchStatus

### Existing tool assessment

| Tool | Coverage | Decision |
| --- | --- | --- |
| Apple Xcode/Transporter/altool | Exact binary upload validation and delivery diagnostics | Adopt as mandatory exact-package evidence |
| App Store Connect API/OpenAPI | Live metadata, build, review, asset, and submission state | Keep as canonical portal read-back |
| fastlane `precheck` 2.237.0 | Mature metadata heuristics: placeholders, competitor names, future/test wording, URL reachability, copyright | Adopt as a narrow advisory/error-producing stage; do not make fastlane a second release pipeline |
| `app-store-preflight-skills` | MIT, useful 100+ guideline index and app-type checklists; only a small young agent-skill repository | Borrow reviewed rule ideas and source links; do not execute it as release authority |
| `claude-ios-gatekeeper` | Broad claimed coverage; two commits and no adoption | Reject as release authority |
| `claude-chrome-gatekeeper` | Useful manifest/security checklist; one commit and minimal adoption | Borrow reviewed rule ideas only |
| Mozilla `addons-linter` 10.9.0 | Mature, actively maintained package/schema/security linter used by AMO and `web-ext` | Adopt compatible generic WebExtension checks, but classify Firefox-only results separately |
| `web-ext` 10.5.0 | Maintained extension build/lint runner around addons-linter | Optional runner; no Chrome listing or reviewer-flow coverage |
| CWS upload CLI / Plasmo BPP | Upload, publish, and status only | Do not confuse with compliance checking |

### Missing checks SaneProcess must own

1. Bind every receipt to the exact package hash, source/worktree fingerprint,
   listing metadata hash, screenshot hashes, store item/version, and timestamp.
2. Test the reviewer path live: credentials/invite are non-expiring for the
   review window, the route accepts the documented method, and the documented
   workflow reaches real review-scoped data without payment.
3. Reconcile claims across source/runtime, review notes, privacy policy,
   permissions/entitlements, screenshots, and live store metadata.
4. Scan listing copy and OCR text for fake rankings, ratings, user counts,
   status badges, unsupported premium/free claims, placeholders, and features
   absent from the exact submitted build.
5. Verify screenshot format/dimensions plus semantic truth: current real UX,
   no synthetic store metrics, no misleading device/status claims.
6. Verify Chrome MV3 permissions, CSP, remote code, host permissions, single
   purpose, data disclosure, Limited Use statement, and reviewer access.
7. Verify the archived Apple package, every embedded framework/privacy
   manifest, entitlements, Required Reason API declarations, and Apple upload
   validation. Source-only string scans are insufficient.
8. Require live App Store Connect reconciliation for locales, screenshots,
   review details, build selection, encryption, accessibility, IAP state, and
   submission membership. Privacy-label parity needs a signed portal/read-back
   attestation because the public API does not expose the complete answers.
9. Refresh official policy sources on a TTL and fail closed when the source is
   stale or materially changed until rule mappings are reviewed.
10. Keep subjective findings explicit: deterministic failures block; strong
    semantic contradictions block; ambiguous policy judgment requires a human
    attestation. Never claim that a green linter guarantees approval.

### SaneLot rejection regression set

- Apple: enterprise companion versus IAP/website-purchase contradiction;
  invalid reviewer route/method or expired code; missing iPad/iPhone assets;
  incomplete review notes; privacy/runtime mismatch; wrong build attached.
- Chrome: synthetic stars/counts/rank badges; misleading Premium/status copy;
  screenshots not showing current real UX; overly broad or unjustified
  permissions; undeclared service-worker hosts; missing Limited Use language;
  gated feature with no durable reviewer access; stale package/listing drift.

### Implementation decision

Extend SaneMaster rather than adding another release pipeline. Keep the current
`appstore_preflight` and exact-package signed receipt. Add an external-validator
stage and a shared policy-source freshness/semantic contract. Add a canonical
`webstore_preflight` whose signed receipt is required by the CWS upload path.
Use new focused modules under `scripts/sanemaster/`; `release.rb` is already far
over the project file-size limit and should not absorb another subsystem.
