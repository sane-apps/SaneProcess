#!/usr/bin/env python3
from __future__ import annotations

import json
import hashlib
import os
import signal
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

from gpt_audit_security import (
    ProcessIdentity,
    _same_process,
    bind_process_group,
    process_identity,
    terminate_bound_process_group,
    terminate_unbound_spawn,
    valid_codex_signature,
)
from gpt_audit_source import repo_source_snapshot


SCRIPT_PATH = Path(__file__).with_name("gpt_audit.py")
README_PATH = SCRIPT_PATH.with_name("README.md")

FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

args = sys.argv[1:]
prompt = sys.stdin.read()
record = {"args": args, "pid": os.getpid(), "prompt": prompt, "secret_seen": os.environ.get("UNRELATED_SECRET_TOKEN")}
fd = os.open(os.environ["FAKE_CODEX_LOG"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
try:
    os.write(fd, (json.dumps(record) + "\n").encode())
finally:
    os.close(fd)

if "FAIL_LANE" in prompt:
    print("intentional fake lane failure", file=sys.stderr)
    raise SystemExit(7)

if "EMPTY_LANE" in prompt:
    raise SystemExit(0)

if os.environ.get("FAKE_CODEX_SYNTH_FAIL") == "1" and "You are consolidating" in prompt:
    print("intentional fake synthesis failure", file=sys.stderr)
    raise SystemExit(8)

if "SLOW_LANE" in prompt:
    marker = os.environ["FAKE_CODEX_CHILD_MARKER"]
    child = "import time; from pathlib import Path; time.sleep(1); Path(%r).write_text('orphan')" % marker
    subprocess.Popen([sys.executable, "-c", child])
    time.sleep(20)

if "BLOCK_LANE" in prompt:
    Path(os.environ["FAKE_CODEX_LOCK_MARKER"]).write_text("ready", encoding="utf-8")
    time.sleep(1.5)

if "MUTATE_SOURCE" in prompt:
    Path(os.environ["FAKE_CODEX_SOURCE_MUTATION"]).write_text("changed during audit\n", encoding="utf-8")

out_path = Path(args[args.index("-o") + 1])
match = re.search(r"Perspective: ([^\n]+)", prompt)
text = "# Synthesized Report\n" if "You are consolidating" in prompt else f"# Lane {match.group(1)}\n"
out_path.write_text(text, encoding="utf-8")
print(text)
'''

PATH_SHADOW_CODEX = r'''#!/usr/bin/env python3
from pathlib import Path
import os
Path(os.environ["FAKE_CODEX_PATH_SHADOW_MARKER"]).write_text("executed", encoding="utf-8")
raise SystemExit(91)
'''


class GptAuditCodexExecTests(unittest.TestCase):
    def make_fixture(self, root: Path, prompts: dict[str, str]) -> tuple[Path, Path, Path]:
        if not (root / ".git").exists():
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            (root / ".gitignore").write_text(
                "/home/\n/outputs/\n/path-shadow-bin/\n/fake-codex.jsonl\n/*-marker\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "-C", str(root), "add", ".gitignore"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", "fixture"], check=True)
        bundle = root / "bundle.txt"
        bundle.write_text("audit evidence\n", encoding="utf-8")
        prompts_dir = root / "home" / ".codex" / "skills" / "audit" / "prompts"
        prompts_dir.mkdir(parents=True, exist_ok=True)
        for name, text in prompts.items():
            (prompts_dir / f"{name}.md").write_text(text + "\n", encoding="utf-8")
        trusted_bin = root / "home" / ".codex" / "packages" / "standalone" / "current" / "bin"
        trusted_bin.mkdir(parents=True, exist_ok=True)
        fake_codex = trusted_bin / "codex"
        fake_codex.write_text(FAKE_CODEX, encoding="utf-8")
        fake_codex.chmod(0o755)
        fake_bin = root / "path-shadow-bin"
        fake_bin.mkdir(exist_ok=True)
        path_shadow = fake_bin / "codex"
        path_shadow.write_text(PATH_SHADOW_CODEX, encoding="utf-8")
        path_shadow.chmod(0o755)
        return bundle, prompts_dir, fake_codex

    def run_audit(
        self,
        root: Path,
        prompts: dict[str, str],
        *,
        required_success: int | None,
        timeout: float = 5,
        extra_args: list[str] | None = None,
        synth_fail: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        bundle, prompts_dir, fake_codex = self.make_fixture(root, prompts)
        out_dir = root / "outputs" / "audit"
        report = out_dir / "report.md"
        log = root / "fake-codex.jsonl"
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env["FAKE_CODEX_LOG"] = str(log)
        env["FAKE_CODEX_CHILD_MARKER"] = str(root / "orphan-marker")
        env["FAKE_CODEX_PATH_SHADOW_MARKER"] = str(root / "path-shadow-executed")
        env["FAKE_CODEX_LOCK_MARKER"] = str(root / "lock-marker")
        env["FAKE_CODEX_SOURCE_MUTATION"] = str(root / "source-mutation.txt")
        env["GPT_AUDIT_TESTING"] = "1"
        env["HOME"] = str(root / "home")
        env["SANEAPPS_ROOT"] = str(root)
        env["PATH"] = f"{root / 'path-shadow-bin'}{os.pathsep}{env.get('PATH', '')}"
        if synth_fail:
            env["FAKE_CODEX_SYNTH_FAIL"] = "1"
        command = [
            sys.executable,
            str(SCRIPT_PATH),
            "--bundle",
            str(bundle),
            "--prompts-dir",
            str(prompts_dir),
            "--out-dir",
            str(out_dir),
            "--report",
            str(report),
            "--repo",
            str(root),
            "--timeout-seconds",
            str(timeout),
        ]
        if required_success is not None:
            command.extend(["--required-success", str(required_success)])
        command.extend(extra_args or [])
        result = subprocess.run(command, text=True, capture_output=True, env=env, timeout=15)
        return result, out_dir, log

    def run_paths(self, root: Path, bundle: Path, prompts_dir: Path, out_dir: Path, report: Path):
        env = os.environ.copy()
        env.update({
            "HOME": str(root / "home"), "SANEAPPS_ROOT": str(root),
            "GPT_AUDIT_TESTING": "1", "FAKE_CODEX_LOG": str(root / "raw-log.jsonl"),
            "FAKE_CODEX_CHILD_MARKER": str(root / "raw-orphan"),
            "FAKE_CODEX_PATH_SHADOW_MARKER": str(root / "raw-path-shadow"),
            "PATH": f"{root / 'path-shadow-bin'}{os.pathsep}{env.get('PATH', '')}",
        })
        return subprocess.run([
            sys.executable, str(SCRIPT_PATH), "--bundle", str(bundle),
            "--prompts-dir", str(prompts_dir), "--out-dir", str(out_dir),
            "--report", str(report), "--repo", str(root),
        ], text=True, capture_output=True, env=env, timeout=15)

    def test_codex_backend_runs_every_prompt_as_an_independent_read_only_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prompts = {f"lane-{index}": f"Review perspective {index}" for index in range(8)}
            result, out_dir, log = self.run_audit(
                root, prompts, required_success=None, extra_args=["--max-workers", "3"]
            )

            self.assertEqual(0, result.returncode, result.stderr)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual("codex-exec", manifest["backend"])
            self.assertEqual(str(root.resolve()), manifest["repo"])
            self.assertEqual("codex-default", manifest["model"])
            self.assertEqual("codex-default", manifest["synth_model"])
            self.assertEqual(str(SCRIPT_PATH.resolve()), manifest["runner"]["path"])
            self.assertEqual(4, manifest["runner"]["schema_version"])
            self.assertEqual("codex exec --ephemeral", manifest["execution"]["command_mode"])
            self.assertTrue(manifest["execution"]["read_only"])
            self.assertTrue(manifest["execution"]["isolated_user_config"])
            self.assertFalse(manifest["execution"]["allow_partial"])
            self.assertFalse(manifest["execution"]["codex_bin_override"])
            self.assertEqual(str(fake_codex := (root / "home" / ".codex" / "packages" / "standalone" / "current" / "bin" / "codex").resolve()), manifest["execution"]["codex_binary"]["realpath"])
            self.assertEqual(hashlib.sha256(fake_codex.read_bytes()).hexdigest(), manifest["execution"]["codex_binary"]["sha256"])
            self.assertFalse((root / "path-shadow-executed").exists())
            self.assertRegex(manifest["invocation"]["nonce"], r"\A[0-9a-f]{32}\Z")
            self.assertEqual(64, len(manifest["invocation"]["command_sha256"]))
            interpreter = manifest["invocation"]["python_interpreter"]
            self.assertEqual(str(Path(sys.executable).resolve()), interpreter["realpath"])
            self.assertEqual(hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest(), interpreter["sha256"])
            self.assertEqual(hashlib.sha256((root / "bundle.txt").read_bytes()).hexdigest(), manifest["inputs"]["bundle"]["sha256"])
            source = manifest["inputs"]["repo_source"]
            self.assertEqual("git-ls-files-content-v1", source["algorithm"])
            self.assertTrue(source["stable"])
            self.assertEqual(source["sha256"], source["completed_sha256"])
            self.assertEqual(source["file_count"], source["completed_file_count"])
            self.assertEqual(
                {
                    "total": 8,
                    "succeeded": 8,
                    "failed": 0,
                    "required_success": 8,
                    "minimum_met": True,
                    "authoritative": False,
                },
                manifest["summary"],
            )
            self.assertEqual({"status": "succeeded", "error": None}, manifest["synthesis"])
            self.assertEqual(8, len(manifest["results"]))
            self.assertTrue(all(item["ok"] for item in manifest["results"]))
            self.assertTrue(all(item["read_only"] for item in manifest["results"]))
            self.assertTrue(all(item["isolated_user_config"] for item in manifest["results"]))
            self.assertTrue(all(item["output_nonempty"] for item in manifest["results"]))
            for item in manifest["results"]:
                expected = hashlib.sha256(Path(item["output_path"]).read_bytes()).hexdigest()
                self.assertEqual(expected, item["output_sha256"])
            self.assertTrue(all((out_dir / f"lane-{index}.md").exists() for index in range(8)))
            self.assertIn("Synthesized Report", (out_dir / "report.md").read_text(encoding="utf-8"))
            self.assertNotIn("CODEX_FANOUT_RECEIPT=", result.stdout)
            self.assertTrue(manifest["execution"]["testing_mode"])
            self.assertEqual([], list(out_dir.glob(".manifest-*.json")))

            calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(9, len(calls))  # eight perspectives plus synthesis
            self.assertEqual(9, len({call["pid"] for call in calls}))
            for call in calls:
                args = call["args"]
                self.assertEqual("exec", args[0])
                self.assertIn("--ephemeral", args)
                self.assertIn("--ignore-user-config", args)
                self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", args)
                self.assertNotIn("--dangerously-bypass-hook-trust", args)
                self.assertNotIn("-m", args)
                self.assertEqual("read-only", args[args.index("-s") + 1])
                self.assertEqual(str(root.resolve()), args[args.index("-C") + 1])

    def test_explicit_model_overrides_are_forwarded_to_the_matching_lanes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, log = self.run_audit(
                root,
                {"lane": "normal"},
                required_success=1,
                extra_args=["--model", "perspective-model", "--synth-model", "synthesis-model"],
            )

            self.assertEqual(0, result.returncode, result.stderr)
            calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            perspective = next(call for call in calls if "You are consolidating" not in call["prompt"])
            synthesis = next(call for call in calls if "You are consolidating" in call["prompt"])
            self.assertEqual("perspective-model", perspective["args"][perspective["args"].index("-m") + 1])
            self.assertEqual("synthesis-model", synthesis["args"][synthesis["args"].index("-m") + 1])
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual("perspective-model", manifest["model"])
            self.assertEqual("synthesis-model", manifest["synth_model"])

    def test_too_few_successful_lanes_fails_closed_with_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, log = self.run_audit(
                root,
                {"good-a": "normal a", "bad": "FAIL_LANE", "good-b": "normal b"},
                required_success=3,
            )

            self.assertEqual(2, result.returncode)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(2, sum(item["ok"] for item in manifest["results"]))
            self.assertFalse(manifest["summary"]["minimum_met"])
            self.assertFalse(manifest["summary"]["authoritative"])
            self.assertEqual("not_run", manifest["synthesis"]["status"])
            self.assertNotIn("CODEX_FANOUT_RECEIPT=", result.stdout)
            self.assertIn("only 2 perspectives succeeded", (out_dir / "report.md").read_text())
            self.assertEqual(3, len(log.read_text(encoding="utf-8").splitlines()))

    def test_empty_lane_is_failed_and_recorded_as_nonempty_false(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, _log = self.run_audit(
                root, {"empty": "EMPTY_LANE"}, required_success=1
            )

            self.assertEqual(2, result.returncode)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(0, manifest["summary"]["succeeded"])
            self.assertFalse(manifest["results"][0]["output_nonempty"])
            self.assertIn("Empty codex exec output", manifest["results"][0]["error"])

    def test_explicit_partial_quorum_is_never_authoritative_or_receipted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, log = self.run_audit(
                root,
                {"good-a": "normal a", "bad": "FAIL_LANE", "good-b": "normal b"},
                required_success=2,
                extra_args=["--allow-partial"],
            )

            self.assertEqual(2, result.returncode, result.stderr)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(3, manifest["summary"]["total"])
            self.assertEqual(2, manifest["summary"]["succeeded"])
            self.assertEqual(1, manifest["summary"]["failed"])
            self.assertTrue(manifest["summary"]["minimum_met"])
            self.assertFalse(manifest["summary"]["authoritative"])
            self.assertTrue(manifest["execution"]["allow_partial"])
            self.assertNotIn("CODEX_FANOUT_RECEIPT=", result.stdout)
            self.assertEqual(4, len(log.read_text(encoding="utf-8").splitlines()))

    def test_partial_threshold_without_allow_partial_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, _out_dir, log = self.run_audit(
                root, {"one": "normal one", "two": "normal two"}, required_success=1
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("partial quorum requires explicit --allow-partial", result.stderr)
            self.assertFalse(log.exists())

    def test_impossible_threshold_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, _out_dir, log = self.run_audit(
                root, {"one": "normal one", "two": "normal two"}, required_success=3
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("exceeds prompt count 2", result.stderr)
            self.assertFalse(log.exists())

    def test_codex_binary_override_is_rejected_for_authoritative_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, _out_dir, log = self.run_audit(
                root,
                {"one": "normal"},
                required_success=1,
                extra_args=["--codex-bin", "/bin/false"],
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("--codex-bin is not allowed for authoritative runs", result.stderr)
            self.assertFalse(log.exists())

    def test_authoritative_run_ignores_path_shadowing_codex(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, _log = self.run_audit(
                root, {"one": "normal"}, required_success=1
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse((root / "path-shadow-executed").exists())
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(
                str((root / "home" / ".codex" / "packages" / "standalone" / "current" / "bin" / "codex").resolve()),
                manifest["execution"]["codex_binary"]["realpath"],
            )

    def test_synthesis_failure_is_non_authoritative_and_returns_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, log = self.run_audit(
                root, {"good": "normal"}, required_success=1, synth_fail=True
            )

            self.assertEqual(2, result.returncode)
            self.assertNotIn("CODEX_FANOUT_RECEIPT=", result.stdout)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertTrue(manifest["summary"]["minimum_met"])
            self.assertFalse(manifest["summary"]["authoritative"])
            self.assertEqual("failed", manifest["synthesis"]["status"])
            self.assertIn("intentional fake synthesis failure", manifest["synthesis"]["error"])
            self.assertIn("Synthesis fallback used", (out_dir / "report.md").read_text())
            self.assertEqual(2, len(log.read_text(encoding="utf-8").splitlines()))

    def test_source_changes_during_audit_make_manifest_non_authoritative(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, _log = self.run_audit(
                root, {"mutator": "MUTATE_SOURCE"}, required_success=1
            )

            self.assertEqual(2, result.returncode)
            self.assertIn("changing repository", result.stderr)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertFalse(manifest["summary"]["authoritative"])
            self.assertFalse(manifest["inputs"]["repo_source"]["stable"])

    def test_concurrent_runs_cannot_mix_fixed_output_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first_result: list[tuple[subprocess.CompletedProcess[str], Path, Path]] = []
            thread = threading.Thread(
                target=lambda: first_result.append(
                    self.run_audit(root, {"blocker": "BLOCK_LANE"}, required_success=1)
                )
            )
            thread.start()
            deadline = time.monotonic() + 5
            while not (root / "lock-marker").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((root / "lock-marker").exists())

            second, _out, _log = self.run_audit(
                root, {"blocker": "BLOCK_LANE"}, required_success=1
            )
            self.assertNotEqual(0, second.returncode)
            self.assertIn("already active", second.stderr)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
            self.assertEqual(0, first_result[0][0].returncode, first_result[0][0].stderr)

    def test_source_snapshot_changes_for_tracked_and_untracked_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            tracked = root / "tracked.txt"
            tracked.write_text("one\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "tracked.txt"], check=True)
            before = repo_source_snapshot(root)
            tracked.write_text("two\n", encoding="utf-8")
            tracked_change = repo_source_snapshot(root)
            untracked = root / "new.txt"
            untracked.write_text("alpha\n", encoding="utf-8")
            untracked_a = repo_source_snapshot(root)
            untracked.write_text("beta\n", encoding="utf-8")
            untracked_b = repo_source_snapshot(root)
            operational = root / ".sanemaster" / "process_metrics.jsonl"
            operational.parent.mkdir()
            operational.write_text("runtime event\n", encoding="utf-8")
            operational_change = repo_source_snapshot(root)
            state = root / ".claude" / "state.json"
            state.parent.mkdir()
            state.write_text('{"runtime": true}\n', encoding="utf-8")
            state_change = repo_source_snapshot(root)
            settings = root / ".claude" / "settings.json"
            settings.write_text('{"source": true}\n', encoding="utf-8")
            settings_change = repo_source_snapshot(root)
            self.assertNotEqual(before["sha256"], tracked_change["sha256"])
            self.assertNotEqual(tracked_change["sha256"], untracked_a["sha256"])
            self.assertNotEqual(untracked_a["sha256"], untracked_b["sha256"])
            self.assertEqual(untracked_b, operational_change)
            self.assertEqual(operational_change, state_change)
            self.assertNotEqual(state_change["sha256"], settings_change["sha256"])

    def test_timeout_kills_the_lane_process_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result, out_dir, _log = self.run_audit(
                root, {"slow": "SLOW_LANE"}, required_success=1, timeout=0.2
            )

            self.assertEqual(2, result.returncode)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertIn("timed out", manifest["results"][0]["error"])
            time.sleep(1.1)
            self.assertFalse((root / "orphan-marker").exists())

    def test_cleanup_never_signals_a_changed_root_identity(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            start_new_session=True,
        )
        try:
            identity = process_identity(process.pid)
            if identity is None:
                identity = ProcessIdentity(
                    process.pid, process.pid, os.getpid(),
                    f"unavailable-{process.pid}", "synthetic expected identity", ""
                )
            forged = identity._replace(started="Mon Jan  1 00:00:00 1990")
            cleaned, detail = terminate_bound_process_group(process, forged)
            self.assertFalse(cleaned)
            self.assertIn("identity changed", detail)
            self.assertIsNone(process.poll())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()

    def test_cleanup_identity_survives_exec_and_setsid_observation_changes(self):
        original = process_identity(os.getpid())
        if original is None:
            original = ProcessIdentity(
                os.getpid(), os.getpgrp(), os.getppid(),
                f"unavailable-{os.getpid()}", "synthetic current identity", ""
            )
        changed = original._replace(
            pgid=original.pgid + 1,
            ppid=1,
            executable="/different/executable",
            command_sha256="0" * 64,
        )
        self.assertTrue(_same_process(original, changed))

    def test_cleanup_rejects_unbound_process_without_calling_process_kill(self):
        class UnboundProcess:
            pid = 999_999

            def kill(self):
                raise AssertionError("process.kill must never run without a validated identity")

        cleaned, detail = terminate_bound_process_group(UnboundProcess(), None)
        self.assertFalse(cleaned)
        self.assertIn("never identity-bound", detail)

    def test_failed_initial_binding_can_kill_the_isolated_direct_child_group(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            start_new_session=True,
        )
        cleaned, detail = terminate_unbound_spawn(process)
        self.assertTrue(cleaned, detail)
        self.assertIsNotNone(process.poll())

    def test_process_identity_uses_absolute_ps_and_rejects_malformed_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_ps = Path(tmp) / "ps"
            marker = Path(tmp) / "shadow-ran"
            fake_ps.write_text(f"#!/bin/sh\ntouch '{marker}'\n", encoding="utf-8")
            fake_ps.chmod(0o755)
            old_path = os.environ.get("PATH")
            os.environ["PATH"] = tmp
            try:
                identity = process_identity(os.getpid())
                if identity is not None:
                    self.assertEqual(os.getpid(), identity.pid)
                self.assertFalse(marker.exists())
            finally:
                if old_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = old_path

        malformed = subprocess.CompletedProcess(["/bin/ps"], 0, stdout="broken\n", stderr="")
        with mock.patch("gpt_audit_security.subprocess.run", return_value=malformed):
            with self.assertRaisesRegex(RuntimeError, "Malformed /bin/ps identity row"):
                process_identity(os.getpid())

    def test_cleanup_kills_term_ignoring_and_escaped_children_after_root_exit(self):
        fixture = r'''
import os, signal, sys, time
marker, mode = sys.argv[1:]
child = os.fork()
if child == 0:
    if mode == "escaped":
        os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(marker, "w").write(str(os.getpid()))
    while True: time.sleep(1)
if mode == "escaped":
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
else:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True: time.sleep(1)
'''
        process_inventory_available = process_identity(os.getpid()) is not None
        modes = ("group", "escaped") if process_inventory_available else ("group",)
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                marker = Path(tmp) / "child.pid"
                process = subprocess.Popen(
                    [sys.executable, "-c", fixture, str(marker), mode],
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 3
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(marker.exists())
                    binding = bind_process_group(process)
                    child_pid = int(marker.read_text())
                    cleaned, detail = terminate_bound_process_group(process, binding)
                    self.assertTrue(cleaned, detail)
                    self.assertIsNone(process_identity(child_pid))
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()

    def test_cleanup_captures_late_descendant_created_after_term(self):
        if process_identity(os.getpid()) is None:
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                start_new_session=True,
            )
            binding = bind_process_group(process)
            cleaned, detail = terminate_bound_process_group(process, binding)
            self.assertTrue(cleaned, detail)
            self.assertIsNotNone(process.poll())
            return

        fixture = r'''
import os, signal, sys, time
marker = sys.argv[1]
terminate = False
def request(*_):
    global terminate
    terminate = True
signal.signal(signal.SIGTERM, request)
while not terminate: time.sleep(0.01)
child = os.fork()
if child == 0:
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(marker, "w").write(str(os.getpid()))
    while True: time.sleep(1)
time.sleep(0.15)
os._exit(0)
'''
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "late.pid"
            process = subprocess.Popen(
                [sys.executable, "-c", fixture, str(marker)],
                start_new_session=True,
            )
            binding = bind_process_group(process)
            try:
                cleaned, detail = terminate_bound_process_group(process, binding)
                self.assertTrue(cleaned, detail)
                self.assertTrue(marker.exists())
                self.assertIsNone(process_identity(int(marker.read_text())))
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_responses_backend_still_requires_explicit_api_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, prompts_dir, _fake = self.make_fixture(root, {"lane": "normal"})
            env = os.environ.copy()
            env.pop("OPENAI_API_KEY", None)
            env["HOME"] = str(root / "home")
            env["SANEAPPS_ROOT"] = str(root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--backend",
                    "responses-api",
                    "--bundle",
                    str(bundle),
                    "--prompts-dir",
                    str(prompts_dir),
                    "--out-dir",
                    str(root / "outputs" / "api"),
                    "--report",
                    str(root / "outputs" / "api" / "report.md"),
                ],
                text=True,
                capture_output=True,
                env=env,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("OPENAI_API_KEY is required for --backend responses-api", result.stderr)

    def test_rejects_bundle_symlink_and_secret_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, prompts, _fake = self.make_fixture(root, {"lane": "review"})
            secret = root / "secret.txt"
            secret.write_text("top-secret\n", encoding="utf-8")
            bundle.unlink()
            bundle.symlink_to(secret)
            result = self.run_paths(root, bundle, prompts, root / "outputs" / "audit", root / "outputs" / "audit" / "report.md")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("must not be a symlink", result.stderr)
            result = self.run_paths(root, Path("/etc/passwd"), prompts, root / "outputs" / "audit", root / "outputs" / "audit" / "report.md")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Bundle must be inside", result.stderr)

    def test_rejects_output_traversal_symlink_and_arbitrary_report_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, prompts, _fake = self.make_fixture(root, {"lane": "review"})
            outside = root / "outside"
            result = self.run_paths(root, bundle, prompts, outside, outside / "report.md")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Output directory must be under", result.stderr)
            allowed = root / "outputs" / "audit"
            allowed.mkdir(parents=True)
            target = root / "victim.txt"
            target.write_text("preserve\n", encoding="utf-8")
            report_link = allowed / "report.md"
            report_link.symlink_to(target)
            result = self.run_paths(root, bundle, prompts, allowed, report_link)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual("preserve\n", target.read_text(encoding="utf-8"))

    def test_rejects_empty_and_duplicate_prompt_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, prompts, _fake = self.make_fixture(root, {"one": "same", "two": "same"})
            result = self.run_paths(root, bundle, prompts, root / "outputs" / "audit", root / "outputs" / "audit" / "report.md")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Duplicate prompt content", result.stderr)
            bundle.write_text("", encoding="utf-8")
            (prompts / "two.md").write_text("different\n", encoding="utf-8")
            result = self.run_paths(root, bundle, prompts, root / "outputs" / "audit", root / "outputs" / "audit" / "report.md")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Input size outside", result.stderr)

    def test_child_environment_excludes_parent_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            secret = "must-not-reach-child"
            os.environ["UNRELATED_SECRET_TOKEN"] = secret
            try:
                result, _out, log = self.run_audit(root, {"lane": "review"}, required_success=1)
                self.assertEqual(0, result.returncode, result.stderr)
                calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
                self.assertTrue(all(call["secret_seen"] is None for call in calls))
            finally:
                os.environ.pop("UNRELATED_SECRET_TOKEN", None)

    def test_readme_gpt_audit_commands_use_canonical_executable_paths_and_roots(self):
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
        self.assertEqual(3, len(commands))
        self.assertTrue(all("~" not in command and "$" not in command for command in commands))
        repo = Path("/Users/stephansmac/SaneApps/infra/SaneProcess")
        for command in commands:
            tokens = shlex.split(command)
            self.assertEqual("/Applications/Xcode.app/Contents/Developer/usr/bin/python3", tokens[0])
            self.assertEqual(str(SCRIPT_PATH), tokens[1])
            options = {tokens[index]: tokens[index + 1] for index in range(2, len(tokens) - 1) if tokens[index].startswith("--") and not tokens[index + 1].startswith("--")}
            self.assertEqual(str(repo), options["--repo"])
            self.assertTrue(Path(options["--bundle"]).is_relative_to(repo))
            self.assertIn(options["--prompts-dir"], [
                "/Users/stephansmac/.codex/skills/audit/prompts",
                "/Users/stephansmac/.codex/skills/critic/prompts",
            ])
            self.assertTrue(Path(options["--out-dir"]).is_relative_to(repo / "outputs"))
            self.assertEqual(Path(options["--out-dir"]), Path(options["--report"]).parent)

    def test_unsigned_codex_fixture_is_rejected_without_explicit_test_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle, _prompts, fake_codex = self.make_fixture(root, {"lane": "review"})
            old = os.environ.pop("GPT_AUDIT_TESTING", None)
            try:
                self.assertFalse(valid_codex_signature(fake_codex.resolve()))
            finally:
                if old is not None:
                    os.environ["GPT_AUDIT_TESTING"] = old


if __name__ == "__main__":
    unittest.main()
