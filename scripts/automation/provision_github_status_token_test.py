#!/usr/bin/env python3
"""Behavioral tests for provision-github-status-token.sh.

Regression (2026-07-14): the status GitHub lanes require a hardened token
file (~/.codex/secrets/github_token). The file existed only where it had been
provisioned by hand, so every status run on an unprovisioned machine reported
four unavailable GitHub lanes and exited 3. The provisioning script must
resolve the token from the keychain store, write the file with owner-only
permissions, validate it with the exact reader the status lanes use, and
never accept or print a token value.
"""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("provision-github-status-token.sh")
FIXTURE_TOKEN = "ghp_fixture0123456789fixture0123456789ab"


def make_stub_security(bin_dir, token=FIXTURE_TOKEN, fail=False):
    stub = bin_dir / "security"
    if fail:
        body = "#!/bin/bash\nexit 44\n"
    else:
        body = f"#!/bin/bash\nprintf '%s' '{token}'\n"
    stub.write_text(body, encoding="utf-8")
    stub.chmod(0o755)
    return stub


def run_provision(tmp, fail_keychain=False):
    bin_dir = Path(tmp) / "bin"
    bin_dir.mkdir()
    stub = make_stub_security(bin_dir, fail=fail_keychain)
    token_path = Path(tmp) / "secrets" / "github_token"
    env = os.environ.copy()
    env.update(
        STATUS_TEST_MODE="1",
        STATUS_SECURITY_BIN=str(stub),
        STATUS_GITHUB_TOKEN_FILE=str(token_path),
    )
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result, token_path


class ProvisionGithubStatusTokenTests(unittest.TestCase):
    def test_provisions_validated_owner_only_token_file(self):
        with tempfile.TemporaryDirectory(prefix="provision-token-") as tmp:
            result, token_path = run_provision(tmp)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(token_path.is_file())
            mode = stat.S_IMODE(token_path.stat().st_mode)
            self.assertEqual(mode, 0o600)
            self.assertEqual(token_path.read_text(encoding="utf-8"), FIXTURE_TOKEN)
            # The success line must not leak the token value.
            self.assertNotIn(FIXTURE_TOKEN, result.stdout + result.stderr)

    def test_missing_keychain_entry_fails_without_writing_a_file(self):
        with tempfile.TemporaryDirectory(prefix="provision-token-") as tmp:
            result, token_path = run_provision(tmp, fail_keychain=True)

            self.assertEqual(result.returncode, 1)
            self.assertIn("keychain service", result.stderr)
            self.assertFalse(token_path.exists())

    def test_reader_error_names_the_provisioning_script(self):
        helper = SCRIPT.with_name("sane-status-github.sh")
        with tempfile.TemporaryDirectory(prefix="provision-token-") as tmp:
            missing = Path(tmp) / "absent_token"
            probe = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'export STATUS_GITHUB_TOKEN_SOURCE_PATH="{missing}"; source "{helper}"; status_read_github_token',
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(probe.returncode, 0)
            self.assertIn("provision-github-status-token.sh", probe.stderr)


if __name__ == "__main__":
    unittest.main()
