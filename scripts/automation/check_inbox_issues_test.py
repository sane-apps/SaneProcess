#!/usr/bin/env python3
"""Execute the real embedded issue classifier with fake read-only GitHub replies."""
import contextlib
import io
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

from saneapps_paths import check_inbox_script


class IssueQueueTests(unittest.TestCase):
    def report(self, issue):
        source = check_inbox_script().read_text()
        start = source.index('if [[ "${1:-}" == "issues" ]]')
        start = source.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
        code = source[start:source.index("\nPYEOF", start)]
        output = io.StringIO()

        def github(args, **_kwargs):
            self.assertEqual(args[:2], ["gh", "issue"])
            self.assertIn(args[2], ["list", "view"])
            return json.dumps([{"number": issue["number"]}] if args[2] == "list" else issue)

        with patch.object(sys, "argv", ["report", "20", "sane-apps/Fixture", "fixture"]), \
                patch.object(subprocess, "check_output", github), contextlib.redirect_stdout(output):
            exec(compile(code, str(check_inbox_script()), "exec"), {})
        return output.getvalue()

    def issue(self, author="MrSaneApps", comments=None, labels=None):
        return {"number": 11, "title": "Finish customer workflow proof", "url": "https://example.invalid/11",
                "author": {"login": author}, "createdAt": "2026-08-01T12:00:00Z",
                "comments": comments or [], "labels": labels or []}

    def comment(self, author, date):
        return {"author": {"login": author}, "createdAt": date, "body": "Please retest the delivered fix."}

    def test_owner_only_work_is_actionable_even_with_old_patched_label(self):
        for comments, labels in [
            ([], []),
            ([self.comment("MrSaneApps", "2026-08-02T12:00:00Z")], []),
            ([self.comment("MrSaneApps", "2026-08-02T12:00:00Z")], [{"name": "release:patched-pending"}]),
        ]:
            with self.subTest(comments=comments, labels=labels):
                result = self.report(self.issue(comments=comments, labels=labels))
                self.assertIn("MAINTAINER ACTION NEEDED", result)
                self.assertNotIn("WAITING FOR REPORTER", result)
                self.assertNotIn("ASSUME FIXED", result)
                self.assertNotIn("No open issues", result)

    def test_actual_customer_wait_and_new_customer_reply_remain_distinct(self):
        result = self.report(self.issue(author="customer",
                            comments=[self.comment("MrSaneApps", "2026-08-02T12:00:00Z")]))
        self.assertIn("WAITING FOR REPORTER", result)
        self.assertNotIn("MAINTAINER ACTION NEEDED", result)
        result = self.report(self.issue(author="customer", comments=[
            self.comment("MrSaneApps", "2026-08-02T12:00:00Z"),
            self.comment("customer", "2026-08-03T12:00:00Z")]))
        self.assertIn("NEEDS MAINTAINER REPLY", result)
        self.assertNotIn("WAITING FOR REPORTER", result)

    def test_owner_issue_with_real_external_participant_can_wait_for_retest(self):
        result = self.report(self.issue(comments=[
            self.comment("customer", "2026-08-02T12:00:00Z"),
            self.comment("MrSaneApps", "2026-08-03T12:00:00Z")]))
        self.assertIn("WAITING FOR REPORTER", result)
        self.assertNotIn("MAINTAINER ACTION NEEDED", result)


if __name__ == "__main__":
    unittest.main()
