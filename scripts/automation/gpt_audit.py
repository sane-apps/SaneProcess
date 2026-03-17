#!/usr/bin/env python3
"""Run a multi-perspective GPT audit with the OpenAI Responses API."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import textwrap
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


API_URL = "https://api.openai.com/v1/responses"
DEFAULT_MODEL = "gpt-5-mini"
DEFAULT_SYNTH_MODEL = "gpt-5"
DEFAULT_REASONING_EFFORT = "low"
REASONING_EFFORTS = {"minimal", "low", "medium", "high", "xhigh"}


@dataclass
class PerspectiveResult:
    name: str
    prompt_file: str
    ok: bool
    output_path: str
    usage: dict[str, Any] | None = None
    error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a multi-perspective GPT audit from a bundle and prompt directory."
    )
    parser.add_argument("--bundle", required=True, help="Path to the bundled audit input")
    parser.add_argument("--prompts-dir", required=True, help="Directory of perspective prompt markdown files")
    parser.add_argument("--out-dir", required=True, help="Directory for raw perspective outputs and manifest")
    parser.add_argument("--report", required=True, help="Consolidated markdown report path")
    parser.add_argument("--title", default="Audit", help="Human-readable audit title")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Model for perspective runs")
    parser.add_argument("--synth-model", default=DEFAULT_SYNTH_MODEL, help="Model for report synthesis")
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
    parser.add_argument("--required-success", type=int, default=3)
    parser.add_argument("--timeout-seconds", type=int, default=180)
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
    model: str,
    instructions: str,
    input_text: str,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: int,
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


def run_perspective(
    *,
    api_key: str,
    title: str,
    perspective_name: str,
    prompt_path: Path,
    prompt_text: str,
    bundle_text: str,
    out_dir: Path,
    model: str,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: int,
    tools: list[dict[str, Any]],
) -> PerspectiveResult:
    output_path = out_dir / f"{perspective_name}.md"
    try:
        response, output_text = call_for_visible_text(
            api_key=api_key,
            model=model,
            instructions=perspective_instructions(prompt_text),
            input_text=perspective_input(title, perspective_name, bundle_text),
            reasoning_effort=reasoning_effort,
            max_output_tokens=max_output_tokens,
            timeout_seconds=timeout_seconds,
            tools=tools,
        )
        if not output_text:
            raise RuntimeError("Empty response output")
        output_path.write_text(output_text + "\n", encoding="utf-8")
        return PerspectiveResult(
            name=perspective_name,
            prompt_file=str(prompt_path),
            ok=True,
            output_path=str(output_path),
            usage=response.get("usage"),
        )
    except Exception as exc:  # noqa: BLE001
        output_path.write_text(f"# {perspective_name}\n\nERROR: {exc}\n", encoding="utf-8")
        return PerspectiveResult(
            name=perspective_name,
            prompt_file=str(prompt_path),
            ok=False,
            output_path=str(output_path),
            error=str(exc),
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


def write_manifest(
    *,
    manifest_path: Path,
    title: str,
    model: str,
    synth_model: str,
    started_at: float,
    results: list[PerspectiveResult],
    report_path: Path,
) -> None:
    manifest = {
        "title": title,
        "model": model,
        "synth_model": synth_model,
        "started_at": started_at,
        "completed_at": time.time(),
        "report": str(report_path),
        "results": [
            {
                "name": result.name,
                "prompt_file": result.prompt_file,
                "ok": result.ok,
                "output_path": result.output_path,
                "usage": result.usage,
                "error": result.error,
            }
            for result in results
        ],
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


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
    report_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise SystemExit("OPENAI_API_KEY is required")

    bundle_path = Path(args.bundle).expanduser().resolve()
    prompts_dir = Path(args.prompts_dir).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    report_path = Path(args.report).expanduser().resolve()

    out_dir.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    bundle_text = read_text(bundle_path)
    prompts = load_prompts(prompts_dir)
    tools = build_tools(args.use_web_search)
    started_at = time.time()

    results: list[PerspectiveResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.max_workers)) as executor:
        futures = [
            executor.submit(
                run_perspective,
                api_key=api_key,
                title=args.title,
                perspective_name=name,
                prompt_path=prompt_path,
                prompt_text=prompt_text,
                bundle_text=bundle_text,
                out_dir=out_dir,
                model=args.model,
                reasoning_effort=args.reasoning_effort,
                max_output_tokens=args.max_output_tokens,
                timeout_seconds=args.timeout_seconds,
                tools=tools,
            )
            for name, prompt_path, prompt_text in prompts
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    results.sort(key=lambda item: item.name)
    manifest_path = out_dir / "manifest.json"

    successful = [result for result in results if result.ok]
    if len(successful) < args.required_success:
        fallback_report(
            args.title,
            results,
            report_path,
            f"only {len(successful)} perspectives succeeded; required {args.required_success}",
        )
        write_manifest(
            manifest_path=manifest_path,
            title=args.title,
            model=args.model,
            synth_model=args.synth_model,
            started_at=started_at,
            results=results,
            report_path=report_path,
        )
        print(
            f"Audit incomplete: {len(successful)}/{len(results)} perspectives succeeded. "
            f"Fallback report written to {report_path}",
            file=sys.stderr,
        )
        return 2

    try:
        synthesis_response, synthesized = call_for_visible_text(
            api_key=api_key,
            model=args.synth_model,
            instructions=synthesis_instructions(),
            input_text=synthesis_input(args.title, results, out_dir),
            reasoning_effort=args.synth_reasoning_effort,
            max_output_tokens=args.synth_max_output_tokens,
            timeout_seconds=args.timeout_seconds,
            tools=[],
        )
        if not synthesized:
            raise RuntimeError("Empty synthesis output")
        report_path.write_text(synthesized + "\n", encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        fallback_report(args.title, results, report_path, str(exc))

    write_manifest(
        manifest_path=manifest_path,
        title=args.title,
        model=args.model,
        synth_model=args.synth_model,
        started_at=started_at,
        results=results,
        report_path=report_path,
    )

    print(
        f"Audit complete: {len(successful)}/{len(results)} perspectives succeeded. "
        f"Report: {report_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
