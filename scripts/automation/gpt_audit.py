#!/usr/bin/env python3
"""Run independent read-only Codex or Responses API audit perspectives."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import secrets
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gpt_audit_security import (
    acquire_output_lock,
    atomic_write,
    bind_process_group,
    command_binding,
    minimal_child_env,
    prepare_outputs,
    read_bundle,
    read_prompts,
    resolve_codex,
    resolve_python_interpreter,
    terminate_bound_process_group,
    terminate_unbound_spawn,
    validate_repo,
)
from gpt_audit_source import (
    finalize_repo_source_evidence,
    repo_source_snapshot,
    sha256_file,
    write_manifest,
)


API_URL = "https://api.openai.com/v1/responses"
DEFAULT_BACKEND = "codex-exec"
DEFAULT_API_MODEL = "gpt-5-mini"
DEFAULT_API_SYNTH_MODEL = "gpt-5"
DEFAULT_REASONING_EFFORT = "low"
REASONING_EFFORTS = {"minimal", "low", "medium", "high", "xhigh"}
CANCEL_REQUESTED = threading.Event()


@dataclass
class PerspectiveResult:
    name: str
    prompt_file: str
    ok: bool
    output_path: str
    output_sha256: str
    usage: dict[str, Any] | None = None
    error: str | None = None
    duration_seconds: float | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a multi-perspective GPT audit from a bundle and prompt directory."
    )
    parser.add_argument("--bundle", required=True, help="Path to the bundled audit input")
    parser.add_argument("--prompts-dir", required=True, help="Directory of perspective prompt markdown files")
    parser.add_argument("--out-dir", required=True, help="Directory for raw perspective outputs and manifest")
    parser.add_argument("--report", required=True, help="Consolidated markdown report path")
    parser.add_argument("--title", default="Audit", help="Human-readable audit title")
    parser.add_argument(
        "--backend",
        choices=("codex-exec", "responses-api"),
        default=DEFAULT_BACKEND,
        help="Execution backend (Responses API requires OPENAI_API_KEY)",
    )
    parser.add_argument("--repo", default=".", help="Repository root passed to codex exec -C")
    parser.add_argument("--codex-bin", default="codex", help="Non-authoritative test/partial-run Codex executable override")
    parser.add_argument("--model", help="Perspective model override (Codex uses its active default if omitted)")
    parser.add_argument("--synth-model", help="Synthesis model override (Codex uses its active default if omitted)")
    parser.add_argument(
        "--reasoning-effort",
        default=DEFAULT_REASONING_EFFORT,
        choices=sorted(REASONING_EFFORTS),
        help="Reasoning effort for perspective runs",
    )
    parser.add_argument(
        "--synth-reasoning-effort",
        default=DEFAULT_REASONING_EFFORT,
        choices=sorted(REASONING_EFFORTS),
        help="Reasoning effort for the synthesis pass",
    )
    parser.add_argument("--max-output-tokens", type=int, default=2200)
    parser.add_argument("--synth-max-output-tokens", type=int, default=4200)
    parser.add_argument("--max-workers", type=int, default=4)
    parser.add_argument("--required-success", type=int, help="Required successful perspectives (defaults to every prompt)")
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="Allow a lower quorum for diagnostic output; never authoritative and never emits a receipt",
    )
    parser.add_argument("--timeout-seconds", type=float, default=180)
    parser.add_argument(
        "--use-web-search",
        action="store_true",
        help="Allow the model to use OpenAI web search during perspective runs",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_prompts(prompts_dir: Path) -> list[tuple[str, Path, str]]:
    prompts = []
    for path in sorted(prompts_dir.glob("*.md")):
        prompts.append((path.stem, path, read_text(path).strip()))
    if not prompts:
        raise SystemExit(f"No prompt files found in {prompts_dir}")
    return prompts


def build_tools(use_web_search: bool) -> list[dict[str, Any]]:
    if not use_web_search:
        return []
    return [{"type": "web_search_preview"}]


def extract_output_text(response: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                text = content.get("text", "")
                if text:
                    parts.append(text)
    return "\n\n".join(parts).strip()


def call_responses_api(
    *,
    api_key: str,
    model: str | None,
    instructions: str,
    input_text: str,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: float,
    tools: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "instructions": instructions,
        "input": input_text,
        "max_output_tokens": max_output_tokens,
        "reasoning": {"effort": reasoning_effort},
        "store": False,
        "text": {"format": {"type": "text"}},
    }
    if tools:
        payload["tools"] = tools

    request = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {body[:1200]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Network error: {exc}") from exc


def needs_visible_text_retry(response: dict[str, Any], output_text: str) -> bool:
    incomplete = response.get("incomplete_details") or {}
    return not output_text and incomplete.get("reason") == "max_output_tokens"


def call_for_visible_text(
    *,
    api_key: str,
    model: str,
    instructions: str,
    input_text: str,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: int,
    tools: list[dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], str]:
    response = call_responses_api(
        api_key=api_key,
        model=model,
        instructions=instructions,
        input_text=input_text,
        reasoning_effort=reasoning_effort,
        max_output_tokens=max_output_tokens,
        timeout_seconds=timeout_seconds,
        tools=tools,
    )
    output_text = extract_output_text(response)
    if not needs_visible_text_retry(response, output_text):
        return response, output_text

    retry_response = call_responses_api(
        api_key=api_key,
        model=model,
        instructions=instructions,
        input_text=input_text,
        reasoning_effort="minimal",
        max_output_tokens=max(max_output_tokens * 2, 1600),
        timeout_seconds=timeout_seconds,
        tools=tools,
    )
    return retry_response, extract_output_text(retry_response)


def perspective_instructions(prompt_text: str) -> str:
    return textwrap.dedent(
        f"""\
        {prompt_text}

        You are one perspective in a multi-perspective audit.
        Use the provided bundle as your primary evidence.
        If something is unknown, say UNKNOWN instead of guessing.
        Prefer concrete contradictions, stale instructions, broken standard paths,
        missing tooling, and duplicated or fragmented documentation.
        Return markdown.
        """
    ).strip()


def perspective_input(title: str, perspective: str, bundle_text: str) -> str:
    return textwrap.dedent(
        f"""\
        Audit title: {title}
        Perspective: {perspective}

        Audit bundle:
        {bundle_text}

        Audit from this perspective.
        Use sections: Verdict, Critical Issues, Warnings, Evidence, Recommended Fixes.
        """
    ).strip()


def codex_prompt(instructions: str, input_text: str) -> str:
    return f"{instructions}\n\n---\n\n{input_text}\n"


def stop_all_process_groups() -> None:
    CANCEL_REQUESTED.set()


def call_codex_exec(
    *,
    codex_bin: str,
    repo: Path,
    model: str,
    instructions: str,
    input_text: str,
    reasoning_effort: str,
    timeout_seconds: float,
    output_dir: Path,
) -> str:
    """Run one ephemeral read-only lane without a shell or shared session."""
    with tempfile.NamedTemporaryFile(
        prefix=".gpt-audit-", suffix=".md", dir=output_dir, delete=False
    ) as handle:
        last_message_path = Path(handle.name)
    last_message_path.unlink()

    command = [
        codex_bin,
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "-s",
        "read-only",
        "-C",
        str(repo),
        "--color",
        "never",
    ]
    if model:
        command.extend(["-m", model])
    command.extend(
        [
            "-c",
            f'model_reasoning_effort="{reasoning_effort}"',
            "-o",
            str(last_message_path),
            "-",
        ]
    )
    process = subprocess.Popen(  # noqa: S603 - argv only; executable is operator-configured
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        env=minimal_child_env(),
    )
    try:
        identity = bind_process_group(process)
    except BaseException as exc:
        cleaned, detail = terminate_unbound_spawn(process)
        suffix = "" if cleaned else f"; cleanup failed safely: {detail}"
        raise RuntimeError(f"Could not bind Codex process identity{suffix}") from exc
    try:
        deadline = time.monotonic() + timeout_seconds
        prompt = codex_prompt(instructions, input_text)
        cleanup_attempted = False
        try:
            while True:
                try:
                    stdout, stderr = process.communicate(
                        input=prompt, timeout=max(0.01, min(0.1, deadline - time.monotonic()))
                    )
                    break
                except subprocess.TimeoutExpired as exc:
                    prompt = None
                    if CANCEL_REQUESTED.is_set() or time.monotonic() >= deadline:
                        cleanup_attempted = True
                        cleaned, detail = terminate_bound_process_group(process, identity)
                        if cleaned:
                            process.communicate()
                        reason = "cancelled" if CANCEL_REQUESTED.is_set() else f"timed out after {timeout_seconds:g}s"
                        suffix = "" if cleaned else f"; cleanup failed safely: {detail}"
                        raise RuntimeError(f"codex exec {reason}{suffix}") from exc
        except BaseException as exc:
            if process.returncode is None and not cleanup_attempted:
                cleaned, detail = terminate_bound_process_group(process, identity)
                if cleaned:
                    process.communicate()
                if not cleaned:
                    raise RuntimeError(f"Codex cleanup failed safely: {detail}") from exc
            raise

        if process.returncode != 0:
            detail = stderr.strip()[-1200:] or stdout.strip()[-1200:] or "no diagnostic output"
            raise RuntimeError(f"codex exec exited {process.returncode}: {detail}")
        output_text = (
            read_text(last_message_path).strip()
            if last_message_path.exists()
            else stdout.strip()
        )
        if not output_text:
            raise RuntimeError("Empty codex exec output")
        return output_text
    finally:
        last_message_path.unlink(missing_ok=True)


def run_perspective(
    *,
    backend: str,
    api_key: str | None,
    codex_bin: str,
    repo: Path,
    title: str,
    perspective_name: str,
    prompt_path: Path,
    prompt_text: str,
    bundle_text: str,
    out_dir: Path,
    model: str | None,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: float,
    tools: list[dict[str, Any]],
) -> PerspectiveResult:
    output_path = out_dir / f"{perspective_name}.md"
    started_at = time.monotonic()
    try:
        usage = None
        if backend == "codex-exec":
            output_text = call_codex_exec(
                codex_bin=codex_bin,
                repo=repo,
                model=model,
                instructions=perspective_instructions(prompt_text),
                input_text=perspective_input(title, perspective_name, bundle_text),
                reasoning_effort=reasoning_effort,
                timeout_seconds=timeout_seconds,
                output_dir=out_dir,
            )
        else:
            response, output_text = call_for_visible_text(
                api_key=api_key or "",
                model=model,
                instructions=perspective_instructions(prompt_text),
                input_text=perspective_input(title, perspective_name, bundle_text),
                reasoning_effort=reasoning_effort,
                max_output_tokens=max_output_tokens,
                timeout_seconds=int(timeout_seconds),
                tools=tools,
            )
            usage = response.get("usage")
        if not output_text:
            raise RuntimeError("Empty response output")
        atomic_write(output_path, output_text + "\n")
        return PerspectiveResult(
            name=perspective_name,
            prompt_file=str(prompt_path),
            ok=True,
            output_path=str(output_path),
            output_sha256=sha256_file(output_path),
            usage=usage,
            duration_seconds=round(time.monotonic() - started_at, 3),
        )
    except Exception as exc:  # noqa: BLE001
        atomic_write(output_path, f"# {perspective_name}\n\nERROR: {exc}\n")
        return PerspectiveResult(
            name=perspective_name,
            prompt_file=str(prompt_path),
            ok=False,
            output_path=str(output_path),
            output_sha256=sha256_file(output_path),
            error=str(exc),
            duration_seconds=round(time.monotonic() - started_at, 3),
        )


def synthesis_instructions() -> str:
    return textwrap.dedent(
        """\
        You are consolidating a multi-perspective audit.
        Merge duplicates. Keep the most concrete wording.
        Call out contradictions between perspectives.
        Be strict about documentation fragmentation and broken standard paths.
        Return markdown with these sections exactly:
        1. Executive Summary
        2. Critical Issues
        3. Warnings
        4. Contradictions Or Drift
        5. Recommended Next Steps
        6. Perspective Coverage
        """
    ).strip()


def synthesis_input(title: str, results: list[PerspectiveResult], out_dir: Path) -> str:
    chunks = [f"Audit title: {title}", ""]
    for result in results:
        status = "PASS" if result.ok else "ERROR"
        chunks.append(f"## Perspective: {result.name} ({status})")
        chunks.append(read_text(Path(result.output_path)).strip())
        chunks.append("")
    return "\n".join(chunks).strip()


def print_manifest_receipt(manifest_path: Path, invocation: dict[str, str]) -> None:
    print(
        f"CODEX_FANOUT_RECEIPT={manifest_path.resolve()} "
        f"CODEX_FANOUT_NONCE={invocation['nonce']} "
        f"CODEX_FANOUT_COMMAND_SHA256={invocation['command_sha256']}"
    )


def fallback_report(title: str, results: list[PerspectiveResult], report_path: Path, reason: str) -> None:
    lines = [
        f"# {title}",
        "",
        f"Synthesis fallback used: {reason}",
        "",
        "## Perspective Coverage",
    ]
    for result in results:
        status = "OK" if result.ok else "ERROR"
        lines.append(f"- {result.name}: {status}")
    lines.append("")
    for result in results:
        lines.append(f"## {result.name}")
        lines.append("")
        lines.append(read_text(Path(result.output_path)).strip())
        lines.append("")
    atomic_write(report_path, "\n".join(lines).strip() + "\n")


def main() -> int:
    args = parse_args()
    testing_mode = os.environ.get("GPT_AUDIT_TESTING") == "1"
    codex_bin_override = any(
        value == "--codex-bin" or value.startswith("--codex-bin=") for value in sys.argv[1:]
    )
    api_key = os.environ.get("OPENAI_API_KEY")
    if args.backend == "responses-api" and not api_key:
        raise SystemExit("OPENAI_API_KEY is required for --backend responses-api")
    if args.backend == "codex-exec" and args.use_web_search:
        raise SystemExit("--use-web-search is only supported by --backend responses-api")
    if codex_bin_override and not args.allow_partial:
        raise SystemExit("--codex-bin is not allowed for authoritative runs")

    repo, _workspace = validate_repo(args.repo)
    bundle_path, bundle_text, bundle_evidence = read_bundle(args.bundle, repo)
    prompts, prompt_evidence = read_prompts(args.prompts_dir)
    out_dir, report_path = prepare_outputs(args.out_dir, args.report, repo)
    acquire_output_lock(out_dir)
    source_evidence = repo_source_snapshot(repo)

    if args.backend == "codex-exec":
        model = args.model
        synth_model = args.synth_model
    else:
        model = args.model or DEFAULT_API_MODEL
        synth_model = args.synth_model or DEFAULT_API_SYNTH_MODEL

    required_success = args.required_success if args.required_success is not None else len(prompts)
    if required_success < 1:
        raise SystemExit("--required-success must be at least 1")
    if required_success > len(prompts):
        raise SystemExit(
            f"--required-success {required_success} exceeds prompt count {len(prompts)}"
        )
    if required_success < len(prompts) and not args.allow_partial:
        raise SystemExit("A partial quorum requires explicit --allow-partial")
    if args.allow_partial and required_success >= len(prompts):
        raise SystemExit("--allow-partial requires --required-success below the prompt count")
    if args.backend == "codex-exec":
        if codex_bin_override:
            override = Path(args.codex_bin).expanduser().resolve()
            if not override.is_file():
                raise SystemExit(f"Invalid --codex-bin: {override}")
            codex_path, codex_digest = str(override), sha256_file(override)
        else:
            codex_path, codex_digest = resolve_codex()
        args.codex_bin = codex_path
    else:
        codex_path, codex_digest = "", ""
    python_path, python_digest = resolve_python_interpreter()
    command_digest, normalized_command = command_binding(sys.argv, Path(__file__), Path(python_path))
    invocation = {
        "nonce": secrets.token_hex(16),
        "command_sha256": command_digest,
        "normalized_command": normalized_command,
        "python_interpreter": {"realpath": python_path, "sha256": python_digest},
    }
    input_evidence = {
        "bundle": bundle_evidence,
        "prompts": prompt_evidence,
        "repo_source": source_evidence,
    }
    codex_binary = {"realpath": codex_path, "sha256": codex_digest}
    tools = build_tools(args.use_web_search)
    started_at = time.time()

    results: list[PerspectiveResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.max_workers)) as executor:
        futures = [
            executor.submit(
                run_perspective,
                backend=args.backend,
                api_key=api_key,
                codex_bin=args.codex_bin,
                repo=repo,
                title=args.title,
                perspective_name=name,
                prompt_path=prompt_path,
                prompt_text=prompt_text,
                bundle_text=bundle_text,
                out_dir=out_dir,
                model=model,
                reasoning_effort=args.reasoning_effort,
                max_output_tokens=args.max_output_tokens,
                timeout_seconds=args.timeout_seconds,
                tools=tools,
            )
            for name, prompt_path, prompt_text in prompts
        ]
        try:
            for future in concurrent.futures.as_completed(futures):
                results.append(future.result())
        except BaseException:
            for future in futures:
                future.cancel()
            stop_all_process_groups()
            raise

    results.sort(key=lambda item: item.name)
    manifest_path = out_dir / "manifest.json"

    successful = [result for result in results if result.ok]
    if len(successful) < required_success:
        incomplete_reason = (
            f"only {len(successful)} perspectives succeeded; required {required_success}"
        )
        fallback_report(
            args.title,
            results,
            report_path,
            incomplete_reason,
        )
        finalize_repo_source_evidence(input_evidence, repo)
        write_manifest(
            manifest_path=manifest_path,
            title=args.title,
            backend=args.backend,
            repo=repo,
            model=model,
            synth_model=synth_model,
            started_at=started_at,
            results=results,
            report_path=report_path,
            required_success=required_success,
            allow_partial=args.allow_partial,
            codex_bin_override=codex_bin_override,
            synthesis_status="not_run",
            synthesis_error=incomplete_reason,
            input_evidence=input_evidence,
            invocation=invocation,
            codex_binary=codex_binary,
            testing_mode=testing_mode,
        )
        print(
            f"Audit incomplete: {len(successful)}/{len(results)} perspectives succeeded. "
            f"Fallback report written to {report_path}",
            file=sys.stderr,
        )
        return 2

    synthesis_error = None
    try:
        if args.backend == "codex-exec":
            synthesized = call_codex_exec(
                codex_bin=args.codex_bin,
                repo=repo,
                model=synth_model,
                instructions=synthesis_instructions(),
                input_text=synthesis_input(args.title, results, out_dir),
                reasoning_effort=args.synth_reasoning_effort,
                timeout_seconds=args.timeout_seconds,
                output_dir=out_dir,
            )
        else:
            _synthesis_response, synthesized = call_for_visible_text(
                api_key=api_key or "",
                model=synth_model,
                instructions=synthesis_instructions(),
                input_text=synthesis_input(args.title, results, out_dir),
                reasoning_effort=args.synth_reasoning_effort,
                max_output_tokens=args.synth_max_output_tokens,
                timeout_seconds=int(args.timeout_seconds),
                tools=[],
            )
        if not synthesized:
            raise RuntimeError("Empty synthesis output")
        atomic_write(report_path, synthesized + "\n")
    except Exception as exc:  # noqa: BLE001
        synthesis_error = str(exc)
        fallback_report(args.title, results, report_path, synthesis_error)

    source_stable = finalize_repo_source_evidence(input_evidence, repo)
    write_manifest(
        manifest_path=manifest_path,
        title=args.title,
        backend=args.backend,
        repo=repo,
        model=model,
        synth_model=synth_model,
        started_at=started_at,
        results=results,
        report_path=report_path,
        required_success=required_success,
        allow_partial=args.allow_partial,
        codex_bin_override=codex_bin_override,
        synthesis_status="failed" if synthesis_error else "succeeded",
        synthesis_error=synthesis_error,
        input_evidence=input_evidence,
        invocation=invocation,
        codex_binary=codex_binary,
        testing_mode=testing_mode,
    )
    if synthesis_error:
        print(
            f"Audit incomplete: synthesis failed. Non-authoritative report written to {report_path}",
            file=sys.stderr,
        )
        return 2
    if not source_stable:
        print(
            "Audit completed against a changing repository; the manifest is non-authoritative and no receipt was emitted.",
            file=sys.stderr,
        )
        return 2
    if args.allow_partial:
        print(
            "Audit completed with an explicitly partial quorum; report is non-authoritative and no receipt was emitted.",
            file=sys.stderr,
        )
        return 2
    if testing_mode:
        print(
            "Audit completed in test mode; report and manifest are non-authoritative and no receipt was emitted.",
            file=sys.stderr,
        )
    else:
        print_manifest_receipt(manifest_path, invocation)

    print(
        f"Audit complete via {args.backend}: {len(successful)}/{len(results)} perspectives succeeded. "
        f"Report: {report_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
