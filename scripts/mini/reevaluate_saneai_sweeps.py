#!/usr/bin/env python3
"""Re-evaluate SaneAI sweep adapters with the current eval contract."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
import time
from pathlib import Path


PROCESS_RE = re.compile(r"(mini-train\.sh|evaluate_model\.py|mlx_lm)")


def run(cmd: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def active_training_processes() -> str:
    proc = run(["ps", "-axo", "pid,etime,%mem,command"])
    current_pid = str(os.getpid())
    lines = []
    for line in (proc.stdout or "").splitlines():
        parts = line.split(None, 1)
        if parts and parts[0] == current_pid:
            continue
        if PROCESS_RE.search(line):
            lines.append(line)
    return "\n".join(lines)


def wait_for_idle(timeout_minutes: int) -> None:
    deadline = time.time() + timeout_minutes * 60
    while True:
        active = active_training_processes()
        if not active:
            return
        if time.time() >= deadline:
            raise TimeoutError(f"Timed out waiting for training/eval processes to finish:\n{active}")
        print("Waiting for Mini training/eval to finish before corrected re-eval:")
        print(active)
        sys.stdout.flush()
        time.sleep(300)


def parse_eval_output(output: str) -> dict[str, str]:
    result: dict[str, str] = {
        "workflow_pct": "",
        "workflow_pass": "",
        "workflow_total": "",
        "raw_pct": "",
        "raw_pass": "",
        "raw_total": "",
        "primary_pct": "",
        "primary_pass": "",
        "primary_total": "",
        "primary_gate": "",
        "commentary_pct": "",
        "core_pct": "",
        "guardrails_pct": "",
        "packs_pct": "",
        "invalid_json": "0",
        "schema_failures": "0",
        "return_code": "0",
    }

    invalid_json = 0
    schema_failures = 0
    for line in output.splitlines():
        if "invalid json" in line:
            invalid_json += 1
        if (
            "no item matched expected fields" in line
            or "workflow mismatch" in line
            or ("only " in line and " items" in line)
            or "summary missing expected terms" in line
        ):
            schema_failures += 1

        if line.startswith("SUITE:"):
            _, suite, passed, total, pct = line.split(":", 4)
            key = {
                "commentary_workflow": "commentary_pct",
                "core": "core_pct",
                "workflow_guardrails": "guardrails_pct",
                "workflow_packs": "packs_pct",
            }.get(suite)
            if key:
                result[key] = pct
            continue

        if line.startswith("PRIMARY_SUITE:"):
            parts = line.split(":")
            if len(parts) >= 7:
                result["primary_pass"] = parts[2]
                result["primary_total"] = parts[3]
                result["primary_pct"] = parts[4]
                result["primary_gate"] = parts[6]
            continue

        if line.startswith("RAW_SCORE:"):
            _, passed, total, pct = line.split(":", 3)
            result["raw_pass"] = passed
            result["raw_total"] = total
            result["raw_pct"] = pct
            continue

        if line.startswith("WEIGHTED_SCORE:") or line.startswith("SCORE:"):
            _, passed, total, pct = line.split(":", 3)
            result["workflow_pass"] = passed
            result["workflow_total"] = total
            result["workflow_pct"] = pct

    result["invalid_json"] = str(invalid_json)
    result["schema_failures"] = str(schema_failures)
    return result


def sweep_sort_key(path: Path) -> tuple[str, int, str]:
    match = re.match(r"sweep_(\d+)_(\d{4}-\d{2}-\d{2})", path.name)
    if not match:
        return ("9999-99-99", 999999, path.name)
    return (match.group(2), int(match.group(1)), path.name)


def write_reports(rows: list[dict[str, str]], output_dir: Path, token_cap: int) -> None:
    tsv = output_dir / f"corrected_saneai_sweeps_cap{token_cap}.tsv"
    md = output_dir / f"corrected_saneai_sweeps_cap{token_cap}.md"
    columns = [
        "sweep",
        "workflow_pct",
        "raw_pct",
        "primary_pct",
        "primary_gate",
        "commentary_pct",
        "core_pct",
        "guardrails_pct",
        "packs_pct",
        "invalid_json",
        "schema_failures",
        "return_code",
        "log",
    ]
    with tsv.open("w") as handle:
        handle.write("\t".join(columns) + "\n")
        for row in rows:
            handle.write("\t".join(row.get(column, "") for column in columns) + "\n")

    sorted_rows = sorted(rows, key=lambda row: int(row.get("workflow_pct") or 0), reverse=True)
    with md.open("w") as handle:
        handle.write(f"# Corrected SaneAI Sweep Re-Eval (cap {token_cap})\n\n")
        handle.write(f"Generated: {dt.datetime.now().isoformat(timespec='seconds')}\n\n")
        handle.write("| Sweep | Workflow | Raw | Primary | Gate | Commentary | Core | Guardrails | Packs | Invalid JSON | Schema failures | RC |\n")
        handle.write("|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in sorted_rows:
            handle.write(
                "| {sweep} | {workflow_pct}% | {raw_pct}% | {primary_pct}% | {primary_gate} | "
                "{commentary_pct}% | {core_pct}% | {guardrails_pct}% | {packs_pct}% | "
                "{invalid_json} | {schema_failures} | {return_code} |\n".format(**row)
            )
        if sorted_rows:
            best = sorted_rows[0]
            handle.write("\n")
            handle.write(
                f"Best corrected sweep: {best['sweep']} at {best['workflow_pct']}% workflow-first / "
                f"{best['raw_pct']}% raw.\n"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wait", action="store_true", help="Wait for active Mini train/eval processes to finish first")
    parser.add_argument("--wait-timeout-min", type=int, default=720)
    parser.add_argument("--token-cap", type=int, default=384)
    parser.add_argument("--max-tokens", type=int, default=128)
    args = parser.parse_args()

    home = Path.home()
    app_root = home / "SaneApps-automation/apps/SaneAI"
    output_root = home / "SaneApps/outputs/weekend_llama_optimization"
    run_id = f"corrected-reeval-cap{args.token_cap}-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    output_dir = output_root / run_id
    logs_dir = output_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    if args.wait:
        wait_for_idle(args.wait_timeout_min)

    active = active_training_processes()
    if active:
        print(f"Refusing to start corrected re-eval while MLX work is active:\n{active}", file=sys.stderr)
        return 2

    python = home / "mlx-env/bin/python3"
    eval_script = home / "SaneApps/infra/SaneProcess/scripts/mini/evaluate_model.py"
    sweeps_dir = app_root / "models/sweeps"
    sweeps = sorted(
        [
            path
            for path in sweeps_dir.glob("sweep_*")
            if (path / "adapters.safetensors").exists()
        ],
        key=sweep_sort_key,
    )

    rows: list[dict[str, str]] = []
    for sweep in sweeps:
        log_path = logs_dir / f"{sweep.name}.eval.log"
        cmd = [
            str(python),
            str(eval_script),
            "--model",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "--train-file",
            str(app_root / "training_data/train.jsonl"),
            "--system-prompt-file",
            str(app_root / "training_data/system_prompt.txt"),
            "--eval-glob",
            str(app_root / "training_data/eval_*.jsonl"),
            "--adapter-path",
            str(sweep),
            "--suite-weight",
            "commentary_workflow=4",
            "--suite-weight",
            "workflow_packs=2",
            "--suite-weight",
            "workflow_guardrails=2",
            "--suite-weight",
            "core=1",
            "--max-tokens",
            str(args.max_tokens),
            "--max-tokens-cap",
            str(args.token_cap),
            "--primary-suite",
            "commentary_workflow",
            "--primary-min-pct",
            "50",
        ]
        print(f"Re-evaluating {sweep.name}")
        sys.stdout.flush()
        proc = run(cmd)
        log_path.write_text(proc.stdout or "")
        parsed = parse_eval_output(proc.stdout or "")
        parsed["return_code"] = str(proc.returncode)
        parsed["sweep"] = sweep.name
        parsed["log"] = str(log_path)
        rows.append(parsed)
        write_reports(rows, output_dir, args.token_cap)
        mx_cache_clear = run(["/usr/bin/purge"])
        if mx_cache_clear.returncode != 0:
            pass

    write_reports(rows, output_dir, args.token_cap)
    latest_md = output_root / f"corrected_saneai_sweeps_cap{args.token_cap}_latest.md"
    latest_tsv = output_root / f"corrected_saneai_sweeps_cap{args.token_cap}_latest.tsv"
    latest_md.unlink(missing_ok=True)
    latest_tsv.unlink(missing_ok=True)
    latest_md.symlink_to(output_dir / f"corrected_saneai_sweeps_cap{args.token_cap}.md")
    latest_tsv.symlink_to(output_dir / f"corrected_saneai_sweeps_cap{args.token_cap}.tsv")
    print(output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
