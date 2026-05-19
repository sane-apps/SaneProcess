#!/usr/bin/env python3
"""Regression checks for public reporting, support review, and GitHub triage."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SANEAPPS = ROOT.parents[1]
CHECK_INBOX = SANEAPPS / "infra" / "scripts" / "check-inbox.sh"
APPS = SANEAPPS / "apps"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def assert_contains(path: Path, *needles: str) -> None:
    text = read(path)
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise AssertionError(f"{path} missing: {missing}")


def test_all_bug_templates_warn_public_and_large_media() -> None:
    apps = ["SaneBar", "SaneClick", "SaneClip", "SaneHosts", "SaneSales", "SaneSync", "SaneVideo"]
    for app in apps:
        template = APPS / app / ".github" / "ISSUE_TEMPLATE" / "bug_report.md"
        assert_contains(
            template,
            "GitHub issues are public",
            "hi@saneapps.com",
            "large videos",
            "file-sharing link",
        )


def test_feature_request_templates_exist_for_all_customer_repos() -> None:
    apps = ["SaneBar", "SaneClick", "SaneClip", "SaneHosts", "SaneSales", "SaneSync", "SaneVideo"]
    for app in apps:
        template = APPS / app / ".github" / "ISSUE_TEMPLATE" / "feature_request.md"
        assert template.exists(), f"missing feature request template: {template}"
        assert_contains(template, "[Feature]: ", "enhancement")


def test_saneclip_ios_github_repo_is_not_double_prefixed() -> None:
    settings = APPS / "SaneClip" / "iOS" / "Views" / "SettingsTab.swift"
    assert_contains(settings, 'githubRepo: "SaneClip"')
    assert "githubRepo: \"sane-apps/SaneClip\"" not in read(settings)


def test_private_repo_customer_surfaces_use_email_first() -> None:
    assert_contains(APPS / "SaneSync" / "README.md", "Email bug reports to", "hi@saneapps.com")
    assert_contains(APPS / "SaneSync" / "SaneSyncApp.swift", "Email Support", "mailto:hi@saneapps.com")
    assert_contains(APPS / "SaneSync" / "PRIVACY.md", "Email [hi@saneapps.com]")
    assert_contains(APPS / "SaneVideo" / "PRIVACY.md", "Email [hi@saneapps.com]")


def test_check_inbox_uses_actionable_github_classifier_in_status() -> None:
    text = read(CHECK_INBOX)
    assert '"$0" issues --limit 50' in text
    assert "$SANEPROCESS_GITHUB_QUEUE\" issues --scope support-apps --limit 20" not in text


def test_check_inbox_does_not_hide_active_threads_as_positive_feedback() -> None:
    text = read(CHECK_INBOX)
    start = text.index('if s in ("pending", "needs_human", "new", "error"):')
    prefix = text[:start].rsplit('if is_non_customer_promo_or_listing(e):', 1)[-1]
    assert "positive_feedback_snippet(e)" not in prefix


def test_check_inbox_flags_share_links_without_metadata_update_false_positives() -> None:
    text = read(CHECK_INBOX)
    for needle in [
        "drive|docs",
        "dropbox",
        "icloud",
        "loom",
        "LINKED_MEDIA_REVIEW_REQUIRED",
        "media_expected=1",
    ]:
        assert needle in text, f"missing guard: {needle}"

    issues_block = text[
        text.index('if [[ "${1:-}" == "issues" ]]') : text.index('if [[ "${1:-}" == "issue-review" ]]')
    ]
    issue_review_block = text[
        text.index('if [[ "${1:-}" == "issue-review" ]]') : text.index('if [[ "${1:-}" == "whois" ]]')
    ]
    for block_name, block in [("issues", issues_block), ("issue-review", issue_review_block)]:
        assert "last_external = updated_at" not in block, (
            f"{block_name} must not treat GitHub issue.updatedAt as an external reply; "
            "label and metadata edits update that timestamp."
        )


def run() -> None:
    tests = [
        test_all_bug_templates_warn_public_and_large_media,
        test_feature_request_templates_exist_for_all_customer_repos,
        test_saneclip_ios_github_repo_is_not_double_prefixed,
        test_private_repo_customer_surfaces_use_email_first,
        test_check_inbox_uses_actionable_github_classifier_in_status,
        test_check_inbox_does_not_hide_active_threads_as_positive_feedback,
        test_check_inbox_flags_share_links_without_metadata_update_false_positives,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")


if __name__ == "__main__":
    run()
