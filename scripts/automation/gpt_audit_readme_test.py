#!/usr/bin/env python3
"""README contract tests for gpt_audit.py operator commands.

Split from gpt_audit_test.py (Rule #10 size limit). These tests own the
documentation contract: README commands must reference the canonical operator
checkout with absolute paths, independent of where the executing repo copy
lives. Verify relocates the tree into a ~/.sanemaster/verify-workspaces
snapshot, so any __file__-derived expectation breaks in every relocated run
(regression 2026-07-14).
"""
import shlex
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("gpt_audit.py")
README_PATH = SCRIPT_PATH.with_name("README.md")
# Anchor the expected root to the canonical checkout and keep only the
# script's in-repo location derived from the live file, so README drift is
# still caught while relocated runs stay green.
CANONICAL_REPO = Path("/Users/stephansmac/SaneApps/infra/SaneProcess")
CANONICAL_SCRIPT_PATH = CANONICAL_REPO / SCRIPT_PATH.relative_to(SCRIPT_PATH.parents[2])


def readme_gpt_audit_commands():
    section = README_PATH.read_text(encoding="utf-8").split("### gpt_audit.py", 1)[1].split("### tool_discovery_receipt.rb", 1)[0]
    commands = []
    current = ""
    for line in section.splitlines():
        if line.startswith("/Applications/Xcode.app/Contents/Developer/usr/bin/python3 "):
            current = line
        elif current and line.startswith("  --"):
            current += " " + line
        elif current:
            commands.append(current.replace("\\", ""))
            current = ""
    if current:
        commands.append(current.replace("\\", ""))
    return commands


class GptAuditReadmeContractTests(unittest.TestCase):
    def test_readme_gpt_audit_commands_use_canonical_executable_paths_and_roots(self):
        commands = readme_gpt_audit_commands()
        self.assertEqual(3, len(commands))
        self.assertTrue(all("~" not in command and "$" not in command for command in commands))
        repo = CANONICAL_REPO
        for command in commands:
            tokens = shlex.split(command)
            self.assertEqual("/Applications/Xcode.app/Contents/Developer/usr/bin/python3", tokens[0])
            self.assertEqual(str(CANONICAL_SCRIPT_PATH), tokens[1])
            options = {tokens[index]: tokens[index + 1] for index in range(2, len(tokens) - 1) if tokens[index].startswith("--") and not tokens[index + 1].startswith("--")}
            self.assertEqual(str(repo), options["--repo"])
            self.assertTrue(Path(options["--bundle"]).is_relative_to(repo))
            self.assertIn(options["--prompts-dir"], [
                "/Users/stephansmac/.codex/skills/audit/prompts",
                "/Users/stephansmac/.codex/skills/critic/prompts",
            ])
            self.assertTrue(Path(options["--out-dir"]).is_relative_to(repo / "outputs"))
            self.assertEqual(Path(options["--out-dir"]), Path(options["--report"]).parent)

    def test_readme_script_token_is_relocation_independent(self):
        # Regression (2026-07-14): Air-routed verify runs this suite from a
        # relocated verify-workspace snapshot. The documented script token must
        # match the canonical expectation even when computed from a repo copy
        # that lives somewhere else entirely.
        documented = [shlex.split(command)[1] for command in readme_gpt_audit_commands()]
        self.assertTrue(documented)
        relocated_script = Path(tempfile.gettempdir()) / "verify-ws" / "SaneApps" / "infra" / "SaneProcess" / "scripts" / "automation" / "gpt_audit.py"
        relocated_expectation = CANONICAL_REPO / relocated_script.relative_to(relocated_script.parents[2])
        for token in documented:
            self.assertEqual(str(relocated_expectation), token)
            self.assertTrue(Path(token).is_relative_to(CANONICAL_REPO))


if __name__ == "__main__":
    unittest.main()
