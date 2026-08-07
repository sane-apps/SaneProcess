## AgentMemory unresponsive-engine lifecycle | Updated: 2026-08-02 | Status: verified | TTL: 30d

### Finding

The Mini AgentMemory outage is an upstream lifecycle failure, not evidence of
lost corpus data. AgentMemory 0.9.27 can leave an unresponsive iii-engine
listener behind: `agentmemory stop --force` computes `force` but exits from the
unresponsive-engine branch without honoring it. A later worker can reconnect to
that engine while the still-open iii-sdk reconnect defect fails to replay HTTP
registrations, leaving `/agentmemory/livez` at 404 or timeout. Repeated launchd
restarts then collide on port 3111 and grow the logs.

### Local evidence

- Launchd rollback completed: `com.saneapps.agentmemory` is disabled and
  unloaded; ports 3111/3112/3113/49134 are currently free.
- `~/data/state_store.db/mem%3Amemories.bin` is present and about 2.2 MB. A
  persisted health row recorded one connected 0.11.2 worker with 263 functions,
  including `api::liveness` and `api::health`; CLI `Memories: 0` was a masked
  API-failure fallback, not a corpus count.
- Logs contain the full chain: REST refusal/404/timeouts, repeated
  `iii-http` address 127.0.0.1:3111 already in use, startup deadline, and worker
  re-registration against the surviving engine.
- Installed `runStop()` in 0.9.27 exits before the force-signaling path when the
  listener exists but `isEngineRunning()` is false.

### Upstream evidence

- Open PR 624 documents and patches the ignored `--force` branch for an
  unresponsive engine: https://github.com/rohitg00/agentmemory/pull/624
- Open PR 610 documents iii-sdk reconnecting without replaying registered HTTP
  routes, leaving `/agentmemory/*` at 404:
  https://github.com/rohitg00/agentmemory/pull/610
- Current npm/GitHub release is 0.9.28 (2026-07-19). It is a security update,
  but both lifecycle PRs remain open, so upgrading alone is not the supervisor
  fix: https://github.com/rohitg00/agentmemory/releases/tag/v0.9.28

### Implementation decision

Keep the Mini fail-closed. Harden the existing SaneProcess supervisor and
installer so they own and validate the exact AgentMemory worker and iii-engine
processes, verify the canonical port quartet is free before bootstrap/restart,
restart the pair together after route loss, refuse to signal unrelated
listeners, require livez plus JSON health plus positive corpus plus a
well-formed search-route response, and bound/rotate logs. Search relevance is not a
health signal; the independently configurable corpus minimum preserves this
Mini's nonempty store. Do not start another direct worker or
lengthen timeouts as a workaround.

### Implemented verification

The code-only hardening now uses a shared authenticated health helper; exact
worker, engine, listener, and PID correlation; bounded TERM shutdown; a
fail-closed canonical-port gate; transactional installer rollback; and a
strict launchctl absent-domain classifier. A missing candidate job is accepted
as already unloaded, while permission or operational launchctl errors still
block restoration. The dependency baseline requires AgentMemory 0.9.28, while
the supervisor remains necessary because the two lifecycle fixes above are not
part of that release.

Isolated focused proof is 65/65 green: service/installer 12, supervisor 11,
installer rollback safety 7, dependency baseline 24, and Air/Mini acceptance
11. Bash/Ruby syntax, registry JSON, diff checks, and line limits also pass.
An independent final security review returned GO with no actionable findings.
No live package install, launchd mutation, or second AgentMemory retry was made
after the controlled health failure and rollback. Post-test read-back confirmed
all four canonical ports free, launchd unloaded, and unchanged production-log
hashes.

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

### Implemented CWS watcher receipt

The owner accepted Google's API Services User Data Policy and explicitly
authorized the exact `chromewebstore.readonly` grant. A dedicated external/test
OAuth configuration and Desktop client now live only in `SaneApps Store
Operations`; the owner account is the sole test user. Client ID, secret, and
refresh token were passed through stdin to the existing private credential
cache, and the one-time authorization state was purged from the control
runtime.

The official `fetchStatus` GET returned version 1.0.9 in `PENDING_REVIEW`.
Initial watcher execution delivered one transition notification with zero
pending alerts and zero diagnostics; the next run returned clean no-change.
The existing 15-minute `SaneApps App Review Watch` heartbeat now runs both
Apple and CWS watchers and remains the only CWS-enabled automation.

The failed setup was removed from legacy project `onyx-478920`: the Chrome Web
Store API is disabled and the Aug 2 `SaneApps CWS Review Watch` client is in
Google's 30-day recoverable-deletion state. A Nov 22 legacy Desktop client was
left untouched because it predates this work.

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

## Capability authorization for agent actions | Updated: 2026-08-02 | Status: verified | TTL: 90d

### Question

Can SaneProcess reduce repeated OS and credential prompts by granting the trusted
Mini broader operational access up front while retaining a hard safety boundary?

### Finding

Yes, provided the broad access exists only at the OS/tool bootstrap layer and
SaneProcess narrows every consequential action into an explicit capability.
Blanket admin tokens or wildcard grants increase blast radius and are not the
answer. The enforcement model should be default deny for consequential actions,
with non-overridable catastrophic forbids, exact short-lived grants, one-time
consumption, independent review for ambiguous high-impact actions, and redacted
decision receipts.

### Authoritative patterns

- NIST least privilege restricts a user or process to the minimum resources and
  authorizations required for its assigned task:
  https://csrc.nist.gov/glossary/term/least_privilege
- Cedar authorization uses default deny and makes any satisfied `forbid`
  override a satisfied `permit`:
  https://docs.cedarpolicy.com/auth/authorization.html
- Open Policy Agent decision logs bind a decision ID to policy input, result,
  bundle revision, and timestamp, and support masking sensitive input fields:
  https://www.openpolicyagent.org/docs/management-decision-logs

### Local control assessment

SaneProcess already has a non-overridable catastrophic guard, Brave-only shell
guards, exact-body email and GitHub approvals, source-bound independent review
evidence, and an Ed25519 release-receipt signer. The current general
`StateSigner` and process gate-certifier are not authorization boundaries because
an executing same-user agent can invoke them. A same-session subagent is useful
review evidence but is not cryptographic independence by itself.

The narrow implementation should reuse the constrained Ed25519 producer pattern:
the executor submits a canonical envelope; a fixed approver accepts only known
capabilities and schema; the receipt binds operation, canonical target, host,
account/project/store item, body or file hash, source fingerprint, session,
issued/expiry times, nonce, and maximum uses. Hard deny runs before receipt
evaluation. Parse, policy, reviewer, signer, mismatch, replay, and expiry errors
fail closed. Catastrophic repository/history, production-data, ownership,
credential, license, and money destruction remains manual-only.

Do not add OPA or Cedar as a runtime dependency yet. Their semantics are useful,
but the current local control plane is small and already has the needed signing
and guard adapters. Reassess only if policy volume or multi-service distribution
outgrows the focused Ruby module.

### Platform boundary

macOS and tool-owned confirmations still apply to security-setting changes and
new persistent credentials. Bootstrap those once on the Mini, then use scoped
read/write credentials internally. Raw MCP and UI tools that bypass shell hooks
must be disabled, declared read-only, provider-scoped, or covered by a native
client pre-tool gate; a Ruby shell hook alone cannot claim universal coverage.
