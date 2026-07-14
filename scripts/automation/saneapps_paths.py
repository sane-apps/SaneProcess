#!/usr/bin/env python3
"""Canonical SaneApps tree resolution for automation scripts and tests.

SaneMaster verify relocates SaneProcess into a ~/.sanemaster/verify-workspaces
snapshot that contains only SaneProcess (and SaneUI). Anything that needs the
surrounding operator tree — infra/scripts helpers, app repos, website sources —
must not trust __file__-relative parents alone: in a relocated run those point
into the sparse workspace and every dependent suite fails (regression
2026-07-14). Resolve the umbrella root from the executing tree when it is a
real operator checkout, otherwise fall back to the canonical home checkout.
"""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# A file that exists in every operator SaneApps tree but is never part of the
# SaneProcess repo itself, so a sparse verify-workspace copy cannot fake it.
_CANONICAL_SENTINEL = ("infra", "scripts", "check-inbox.sh")


def saneapps_root() -> Path:
    derived = REPO_ROOT.parents[1]
    if derived.joinpath(*_CANONICAL_SENTINEL).exists():
        return derived
    return Path.home() / "SaneApps"


def infra_scripts_dir() -> Path:
    return saneapps_root() / "infra" / "scripts"


def check_inbox_script() -> Path:
    return infra_scripts_dir() / "check-inbox.sh"
