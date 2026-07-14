#!/usr/bin/env python3
"""Fail-closed local file and process-input helpers for gpt_audit.py."""

from __future__ import annotations

import hashlib
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterable, NamedTuple

MAX_BUNDLE_BYTES = 8 * 1024 * 1024
MAX_PROMPT_BYTES = 256 * 1024
MAX_PROMPTS = 64
CODEX_TEAM_ID = "2DC432GLL2"
CODEX_REQUIREMENT = (
    '=identifier "codex" and anchor apple generic and '
    'certificate leaf[subject.OU] = "2DC432GLL2"'
)
TRUSTED_PYTHON_LAUNCHER = Path("/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
_OUTPUT_LOCK_FDS: list[int] = []


class ProcessIdentity(NamedTuple):
    pid: int
    pgid: int
    ppid: int
    started: str
    executable: str
    command_sha256: str
    owned_child: bool = False


class BoundProcessTree(NamedTuple):
    root: ProcessIdentity
    identities: dict[int, ProcessIdentity]


def beneath(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def no_symlink_components(path: Path, root: Path) -> bool:
    if not beneath(path, root):
        return False
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.exists() and current.is_symlink():
            return False
    return True


def read_regular(path: Path, max_bytes: int) -> tuple[str, str, int]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise SystemExit(f"Input must be a current-user regular file: {path}")
        if info.st_size < 1 or info.st_size > max_bytes:
            raise SystemExit(f"Input size outside 1..{max_bytes} bytes: {path}")
        data = b""
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) != info.st_size:
            raise SystemExit(f"Input changed while reading: {path}")
    finally:
        os.close(fd)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"Input is not UTF-8: {path}") from exc
    if not text.strip():
        raise SystemExit(f"Input must not be empty: {path}")
    return text, hashlib.sha256(data).hexdigest(), len(data)


def validate_repo(repo_arg: str) -> tuple[Path, Path]:
    workspace = Path(os.environ.get("SANEAPPS_ROOT", str(Path.home() / "SaneApps"))).expanduser().resolve()
    repo = Path(repo_arg).expanduser().resolve()
    if not workspace.is_dir() or not repo.is_dir() or not beneath(repo, workspace):
        raise SystemExit(f"Repository must be a real directory under {workspace}: {repo}")
    return repo, workspace


def trusted_input_root() -> Path:
    root = Path(tempfile.gettempdir()).resolve() / "saneprocess-gpt-audit-inputs"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    return root


def read_bundle(path_arg: str, repo: Path) -> tuple[Path, str, dict[str, object]]:
    raw = Path(path_arg).expanduser().absolute()
    if raw.is_symlink():
        raise SystemExit(f"Bundle must not be a symlink: {raw}")
    path = raw.resolve()
    roots = (repo, trusted_input_root())
    root = next((item for item in roots if beneath(path, item)), None)
    if root is None or not no_symlink_components(path, root):
        raise SystemExit("Bundle must be inside the repo or trusted GPT audit input root without symlinks")
    text, digest, size = read_regular(path, MAX_BUNDLE_BYTES)
    return path, text, {"path": str(path), "sha256": digest, "size": size}


def prompt_roots() -> tuple[Path, ...]:
    base = Path.home() / ".codex" / "skills"
    return tuple((base / name / "prompts").absolute() for name in ("audit", "critic"))


def read_prompts(path_arg: str) -> tuple[list[tuple[str, Path, str]], list[dict[str, object]]]:
    raw = Path(path_arg).expanduser().absolute()
    directory = raw.resolve()
    roots = tuple(root.resolve() for root in prompt_roots())
    if raw.is_symlink() or directory not in roots or not directory.is_dir():
        raise SystemExit(f"Prompts directory must be a canonical installed audit/critic prompt root: {directory}")
    files = sorted(directory.glob("*.md"))
    if not files or len(files) > MAX_PROMPTS:
        raise SystemExit(f"Prompt count must be 1..{MAX_PROMPTS}: {directory}")
    prompts, evidence, digests = [], [], set()
    for path in files:
        if path.is_symlink() or path.parent != directory:
            raise SystemExit(f"Prompt must be a direct non-symlink file: {path}")
        text, digest, size = read_regular(path, MAX_PROMPT_BYTES)
        if digest in digests:
            raise SystemExit(f"Duplicate prompt content is not allowed: {path}")
        digests.add(digest)
        prompts.append((path.stem, path, text.strip()))
        evidence.append({"name": path.stem, "path": str(path), "sha256": digest, "size": size})
    return prompts, evidence


def receipt_root() -> Path:
    root = Path(tempfile.gettempdir()).resolve() / "saneprocess-gpt-audit-receipts"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    return root


def prepare_outputs(out_arg: str, report_arg: str, repo: Path) -> tuple[Path, Path]:
    raw_out = Path(out_arg).expanduser().absolute()
    out_dir = raw_out.resolve()
    roots = (receipt_root(), repo / "outputs")
    root = next((item.absolute() for item in roots if beneath(out_dir, item.absolute())), None)
    if root is None or not no_symlink_components(out_dir, root):
        raise SystemExit("Output directory must be under the dedicated receipt root or repo outputs without symlinks")
    out_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if out_dir.is_symlink() or not out_dir.is_dir():
        raise SystemExit(f"Invalid output directory: {out_dir}")
    os.chmod(out_dir, 0o700)
    raw_report = Path(report_arg).expanduser().absolute()
    report = raw_report.resolve()
    if report.parent != out_dir or report.name in ("", ".", "..") or raw_report.is_symlink():
        raise SystemExit("Report must be a direct non-symlink file inside --out-dir")
    return out_dir, report


def acquire_output_lock(out_dir: Path) -> None:
    """Hold a process-lifetime lock so fixed artifact names cannot mix runs."""
    path = out_dir / ".gpt_audit.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        opened = os.fstat(fd)
        linked = path.lstat()
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
            raise SystemExit(f"Unsafe GPT audit output lock: {path}")
        if (opened.st_dev, opened.st_ino) != (linked.st_dev, linked.st_ino):
            raise SystemExit(f"GPT audit output lock changed while opening: {path}")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise SystemExit(f"Another GPT audit is already active in {out_dir}") from exc
        _OUTPUT_LOCK_FDS.append(fd)
    except BaseException:
        os.close(fd)
        raise


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise RuntimeError(f"Refusing unsafe output target: {path}")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def trusted_codex_paths() -> tuple[Path, ...]:
    """Return only the canonical absolute Codex installations, never PATH entries."""
    candidates = (
        Path.home() / ".codex" / "packages" / "standalone" / "current" / "bin" / "codex",
        Path.home() / ".codex" / "packages" / "standalone" / "current" / "codex",
        Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
    )
    trusted: list[Path] = []
    for candidate in candidates:
        try:
            path = candidate.resolve(strict=True)
            info = path.stat()
        except (FileNotFoundError, OSError):
            continue
        safe = info.st_uid in (0, os.getuid()) and stat.S_IMODE(info.st_mode) & 0o022 == 0
        if stat.S_ISREG(info.st_mode) and safe and os.access(path, os.X_OK) and valid_codex_signature(path) and path not in trusted:
            trusted.append(path)
    return tuple(trusted)


def valid_codex_signature(path: Path) -> bool:
    test_root = (Path.home() / ".codex" / "packages" / "standalone").resolve()
    if os.environ.get("GPT_AUDIT_TESTING") == "1" and beneath(path.resolve(), test_root):
        return True
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--requirement", CODEX_REQUIREMENT, str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        env={"PATH": "/usr/bin:/bin"},
    )
    return result.returncode == 0


def resolve_codex() -> tuple[str, str]:
    paths = trusted_codex_paths()
    if not paths:
        raise SystemExit("Codex not found at a canonical standalone or ChatGPT installation path")
    path = paths[0]
    return str(path), hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_python_interpreter() -> tuple[str, str]:
    try:
        trusted = TRUSTED_PYTHON_LAUNCHER.resolve(strict=True)
        invoked = Path(sys.executable).resolve(strict=True)
        info = invoked.stat()
    except (FileNotFoundError, OSError) as exc:
        raise SystemExit("Trusted absolute Python launcher is unavailable") from exc
    safe = info.st_uid == 0 and stat.S_IMODE(info.st_mode) & 0o022 == 0
    if invoked != trusted or not stat.S_ISREG(info.st_mode) or not safe:
        raise SystemExit(f"Authoritative audit requires {TRUSTED_PYTHON_LAUNCHER}")
    return str(invoked), hashlib.sha256(invoked.read_bytes()).hexdigest()


def minimal_child_env() -> dict[str, str]:
    allowed = ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR")
    env = {key: os.environ[key] for key in allowed if os.environ.get(key)}
    if os.environ.get("GPT_AUDIT_TESTING") == "1":
        for key, value in os.environ.items():
            if key.startswith("FAKE_CODEX_"):
                env[key] = value
    return env


def command_binding(argv: Iterable[str], runner: Path, interpreter: Path) -> tuple[str, str]:
    normalized = [str(interpreter.resolve()), str(runner.resolve()), *list(argv)[1:]]
    payload = json.dumps(normalized, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest(), json.dumps(normalized, separators=(",", ":"))


def _minimal_ps_env() -> dict[str, str]:
    return {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}


def process_identity(pid: int) -> ProcessIdentity | None:
    try:
        result = subprocess.run(
            [
                "/bin/ps", "-ww", "-p", str(pid),
                "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "stat=", "-o", "lstart=",
                "-o", "comm=", "-o", "command=",
            ],
            text=True,
            capture_output=True,
            check=False,
            env=_minimal_ps_env(),
        )
    except PermissionError:
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    fields = result.stdout.strip().split(maxsplit=10)
    if len(fields) != 11:
        raise RuntimeError(f"Malformed /bin/ps identity row for pid {pid}: {result.stdout!r}")
    found_pid, ppid, pgid = (int(value) for value in fields[:3])
    state = fields[3]
    if state.startswith("Z"):
        return None
    started = " ".join(fields[4:9])
    executable, command = fields[9:]
    if found_pid != pid or ppid < 0 or pgid <= 0 or not executable or not command:
        raise RuntimeError(f"Inconsistent /bin/ps identity row for pid {pid}: {result.stdout!r}")
    if len(started.split()) != 5:
        raise RuntimeError(f"Malformed /bin/ps start time for pid {pid}: {started!r}")
    try:
        if os.getpgid(pid) != pgid:
            return None
    except ProcessLookupError:
        return None
    return ProcessIdentity(
        pid, pgid, ppid, started, executable,
        hashlib.sha256(command.encode("utf-8")).hexdigest(),
    )


def _process_relations() -> dict[int, tuple[int, int]]:
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
            text=True, capture_output=True, check=False, env=_minimal_ps_env(),
        )
    except PermissionError as exc:
        raise RuntimeError("/bin/ps process snapshot is unavailable in this client sandbox") from exc
    if result.returncode != 0:
        raise RuntimeError(f"/bin/ps process snapshot failed: {result.returncode}")
    relations: dict[int, tuple[int, int]] = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 3:
            raise RuntimeError(f"Malformed /bin/ps process snapshot row: {line!r}")
        pid, ppid, pgid = (int(value) for value in fields)
        if pid <= 0 or ppid < 0 or pgid <= 0 or pid in relations:
            raise RuntimeError(f"Inconsistent /bin/ps process snapshot row: {line!r}")
        relations[pid] = (ppid, pgid)
    if not relations:
        raise RuntimeError("Malformed empty /bin/ps process snapshot")
    return relations


def _same_process(expected: ProcessIdentity, current: ProcessIdentity | None) -> bool:
    if current is None:
        return False
    # PID plus kernel process birth time is the stable identity. PGID, PPID,
    # executable, and command may all change after a captured child calls
    # setsid(2), reparents, or exec(2); treating those as identity lets it evade
    # cleanup and makes the survivor check lie.
    return (expected.pid, expected.started) == (current.pid, current.started)


def _capture_bound_members(binding: BoundProcessTree) -> None:
    if binding.root.owned_child:
        return
    relations = _process_relations()
    root_current = process_identity(binding.root.pid)
    valid_roots = [identity for identity in binding.identities.values() if _same_process(identity, process_identity(identity.pid))]
    candidates: set[int] = set()
    if _same_process(binding.root, root_current):
        candidates.update(pid for pid, (_ppid, pgid) in relations.items() if pgid == binding.root.pgid)
    queue = [identity.pid for identity in valid_roots]
    while queue:
        parent = queue.pop()
        children = [pid for pid, (ppid, _pgid) in relations.items() if ppid == parent]
        candidates.update(children)
        queue.extend(children)
    for pid in candidates:
        if pid in binding.identities:
            continue
        identity = process_identity(pid)
        relation = relations.get(pid)
        if identity is not None and relation == (identity.ppid, identity.pgid):
            binding.identities[pid] = identity


def bind_process_group(process: subprocess.Popen[str]) -> BoundProcessTree:
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        identity = process_identity(process.pid)
        # Bind the immutable PID/birth identity immediately. Waiting for a
        # launcher to exec creates a pre-bind interval in which it can fork an
        # untracked child. Executable and command changes are legitimate after
        # exec and are intentionally not part of _same_process.
        if identity is not None and identity.pgid == process.pid:
            binding = BoundProcessTree(identity, {identity.pid: identity})
            _capture_bound_members(binding)
            return binding
        if identity is None and process.poll() is None:
            try:
                pgid = os.getpgid(process.pid)
            except (ProcessLookupError, PermissionError):
                pgid = -1
            if pgid == process.pid:
                owned = ProcessIdentity(
                    process.pid,
                    pgid,
                    os.getpid(),
                    f"owned-child-{process.pid}",
                    "owned isolated Codex child",
                    "",
                    True,
                )
                return BoundProcessTree(owned, {owned.pid: owned})
        if process.poll() is not None:
            break
        time.sleep(0.01)
    raise RuntimeError("Could not bind stable isolated Codex root process identity")


def terminate_unbound_spawn(process: subprocess.Popen[str]) -> tuple[bool, str]:
    """Best-effort fail-closed cleanup for the direct child if initial binding fails."""
    if process.poll() is not None:
        return False, "unbound root exited before identity capture"
    try:
        if os.getpgid(process.pid) != process.pid:
            return False, "unbound root was not its isolated process-group leader"
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=1)
        return True, "killed unbound isolated child group"
    except (ProcessLookupError, ChildProcessError):
        return True, "unbound isolated child group already exited"
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"could not clean unbound isolated child group: {exc}"


def terminate_bound_process_group(
    process: subprocess.Popen[str], identity: BoundProcessTree | ProcessIdentity | None
) -> tuple[bool, str]:
    """Terminate only identities captured from the bound process tree."""
    if identity is None:
        return False, "process tree was never identity-bound; no signal sent"
    binding = identity if isinstance(identity, BoundProcessTree) else BoundProcessTree(identity, {identity.pid: identity})
    if binding.root.pid != process.pid or binding.root.pgid != process.pid:
        return False, "bound root does not match the isolated subprocess; no signal sent"
    if binding.root.owned_child:
        if process.poll() is not None:
            return True, "owned isolated child already exited"
        try:
            if os.getpgid(process.pid) != process.pid:
                return False, "owned child no longer leads its isolated process group"
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except PermissionError:
                process.terminate()
            time.sleep(0.2)
            if process.poll() is not None:
                return True, "owned isolated child exited after TERM without process-table access"
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except PermissionError:
                process.kill()
            except ProcessLookupError:
                return True, "owned isolated child group exited after TERM"
            process.wait(timeout=1)
            return True, "terminated owned isolated child group without process-table access"
        except (ProcessLookupError, ChildProcessError):
            return True, "owned isolated child group already exited"
        except (OSError, subprocess.TimeoutExpired) as exc:
            return False, f"could not terminate owned isolated child group: {exc}"
    root_before = process_identity(binding.root.pid)
    if not _same_process(binding.root, root_before) and len(binding.identities) == 1:
        return False, f"root identity changed or disappeared before TERM: expected={binding.root!r} current={root_before!r}"
    try:
        _capture_bound_members(binding)
    except (OSError, RuntimeError) as exc:
        return False, f"could not safely refresh bound process tree before TERM: {exc}"

    root_current = process_identity(binding.root.pid)
    if _same_process(binding.root, root_current):
        try:
            os.killpg(binding.root.pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for member in list(binding.identities.values()):
        if member.pid != binding.root.pid and _same_process(member, process_identity(member.pid)):
            try:
                os.kill(member.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    deadline = time.monotonic() + 0.2
    while time.monotonic() < deadline:
        try:
            _capture_bound_members(binding)
        except (OSError, RuntimeError) as exc:
            return False, f"could not safely refresh bound process tree after TERM: {exc}"
        time.sleep(0.02)

    survivors = [member for member in binding.identities.values() if _same_process(member, process_identity(member.pid))]
    root_current = process_identity(binding.root.pid)
    if _same_process(binding.root, root_current) and any(member.pgid == binding.root.pgid for member in survivors):
        try:
            os.killpg(binding.root.pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for member in survivors:
        if _same_process(member, process_identity(member.pid)):
            try:
                os.kill(member.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    time.sleep(0.05)
    remaining = [member.pid for member in binding.identities.values() if _same_process(member, process_identity(member.pid))]
    if remaining:
        return False, f"bound process identities survived cleanup: {remaining}"
    return True, "terminated bound process tree"
