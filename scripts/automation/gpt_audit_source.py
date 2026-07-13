#!/usr/bin/env python3
"""Content-complete source snapshots shared by GPT audit authorization."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import struct
import subprocess
import time
from pathlib import Path
from typing import Any

from gpt_audit_security import atomic_write


SOURCE_ALGORITHM = "git-ls-files-content-v1"
SOURCE_DOMAIN = b"saneprocess-gpt-audit-source-v1\0"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _update_entry(digest: hashlib._Hash, path_bytes: bytes, kind: bytes, executable: bool,
                  payload_size: int) -> None:
    digest.update(struct.pack(">Q", len(path_bytes)))
    digest.update(path_bytes)
    digest.update(kind)
    digest.update(b"\x01" if executable else b"\x00")
    digest.update(struct.pack(">Q", payload_size))


def _safe_worktree_path(repo: Path, path_bytes: bytes) -> Path:
    relative = Path(os.fsdecode(path_bytes))
    if relative.is_absolute() or not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
        raise RuntimeError(f"Unsafe git worktree path: {relative}")
    current = repo
    for part in relative.parts[:-1]:
        current /= part
        if current.is_symlink():
            raise RuntimeError(f"Symlinked worktree parent is not reviewable: {relative}")
    return repo / relative


def repo_source_snapshot(repo: Path) -> dict[str, object]:
    """Hash tracked and nonignored untracked names, types, modes, and bytes."""
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", ".", ":(exclude)outputs/**",
         ":(exclude).claude/state.json", ":(exclude).claude/state.json.lock",
         ":(exclude).claude/sanetrack.log", ":(exclude).claude/gate-hits.json",
         ":(exclude).claude/gate-overrides.json",
         ":(exclude).sanemaster/process_metrics.jsonl"],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git ls-files failed while snapshotting audit source: {result.stderr.decode(errors='replace').strip()}")

    paths = sorted(set(item for item in result.stdout.split(b"\0") if item))
    digest = hashlib.sha256(SOURCE_DOMAIN)
    for path_bytes in paths:
        path = _safe_worktree_path(repo, path_bytes)
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            _update_entry(digest, path_bytes, b"D", False, 0)
            continue
        if stat.S_ISLNK(metadata.st_mode):
            target = os.fsencode(os.readlink(path))
            _update_entry(digest, path_bytes, b"L", False, len(target))
            digest.update(target)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f"Unsupported worktree entry type: {path}")

        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            before = os.fstat(fd)
            identity = (before.st_dev, before.st_ino, before.st_mode, before.st_size,
                        before.st_mtime_ns, before.st_ctime_ns)
            _update_entry(digest, path_bytes, b"F", bool(before.st_mode & 0o111), before.st_size)
            remaining = before.st_size
            while remaining:
                chunk = os.read(fd, min(65536, remaining))
                if not chunk:
                    raise RuntimeError(f"Worktree file shortened during snapshot: {path}")
                digest.update(chunk)
                remaining -= len(chunk)
            if os.read(fd, 1):
                raise RuntimeError(f"Worktree file grew during snapshot: {path}")
            after = os.fstat(fd)
            current = (after.st_dev, after.st_ino, after.st_mode, after.st_size,
                       after.st_mtime_ns, after.st_ctime_ns)
            if identity != current:
                raise RuntimeError(f"Worktree file changed during snapshot: {path}")
        finally:
            os.close(fd)
    return {"algorithm": SOURCE_ALGORITHM, "sha256": digest.hexdigest(), "file_count": len(paths)}


def finalize_repo_source_evidence(input_evidence: dict[str, Any], repo: Path) -> bool:
    completed = repo_source_snapshot(repo)
    source = input_evidence["repo_source"]
    source["completed_sha256"] = completed["sha256"]
    source["completed_file_count"] = completed["file_count"]
    source["stable"] = (
        source["algorithm"] == completed["algorithm"]
        and source["sha256"] == completed["sha256"]
        and source["file_count"] == completed["file_count"]
    )
    return source["stable"] is True


def write_manifest(
    *, manifest_path: Path, title: str, backend: str, repo: Path, model: str | None,
    synth_model: str | None, started_at: float, results: list[Any], report_path: Path,
    required_success: int, allow_partial: bool, codex_bin_override: bool,
    synthesis_status: str, synthesis_error: str | None, input_evidence: dict[str, Any],
    invocation: dict[str, Any], codex_binary: dict[str, str], testing_mode: bool,
) -> None:
    succeeded = sum(result.ok for result in results)
    authoritative = (
        not allow_partial and not codex_bin_override and required_success == len(results)
        and succeeded == len(results) and synthesis_status == "succeeded"
        and input_evidence.get("repo_source", {}).get("stable") is True and not testing_mode
    )
    manifest = {
        "runner": {"path": str(Path(__file__).with_name("gpt_audit.py").resolve()), "schema_version": 4},
        "invocation": invocation, "inputs": input_evidence, "title": title,
        "backend": backend, "repo": str(repo),
        "execution": {
            "command_mode": "codex exec --ephemeral" if backend == "codex-exec" else "responses-api",
            "read_only": backend == "codex-exec", "isolated_user_config": backend == "codex-exec",
            "allow_partial": allow_partial, "codex_bin_override": codex_bin_override,
            "codex_binary": codex_binary, "testing_mode": testing_mode,
        },
        "model": model or ("codex-default" if backend == "codex-exec" else "gpt-5-mini"),
        "synth_model": synth_model or ("codex-default" if backend == "codex-exec" else "gpt-5"),
        "started_at": started_at, "completed_at": time.time(), "report": str(report_path),
        "report_sha256": sha256_file(report_path),
        "summary": {
            "total": len(results), "succeeded": succeeded, "failed": len(results) - succeeded,
            "required_success": required_success, "minimum_met": succeeded >= required_success,
            "authoritative": authoritative,
        },
        "synthesis": {"status": synthesis_status, "error": synthesis_error},
        "results": [
            {
                "name": result.name, "prompt_file": result.prompt_file, "ok": result.ok,
                "output_path": result.output_path, "output_sha256": result.output_sha256,
                "usage": result.usage, "error": result.error, "duration_seconds": result.duration_seconds,
                "command_mode": "codex exec --ephemeral" if backend == "codex-exec" else "responses-api",
                "read_only": backend == "codex-exec", "isolated_user_config": backend == "codex-exec",
                "output_nonempty": result.ok and Path(result.output_path).exists()
                and bool(Path(result.output_path).read_text(encoding="utf-8").strip()),
            }
            for result in results
        ],
    }
    atomic_write(manifest_path, json.dumps(manifest, indent=2) + "\n")
