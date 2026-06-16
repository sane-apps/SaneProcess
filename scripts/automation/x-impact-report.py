#!/usr/bin/env python3
"""Build a cautious X outreach impact report.

The report intentionally avoids hard attribution claims. It combines:
- SaneApps X post logs and optional X API post snapshots
- Lemon Squeezy sales JSON
- sane-dist download/event daily aggregates

The backtest is daily-grain for downloads/events and timestamp-grain for sales.
Use tagged links going forward if you need stronger attribution.
"""

from __future__ import annotations

import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from x_impact_report_core import (
    Post,
    parse_dt,
    product_from_tweet,
    sales_windows,
)
from x_impact_report_io import X_API_PYTHON, main, maybe_reexec_x_venv

__all__ = [
    "Post",
    "X_API_PYTHON",
    "main",
    "maybe_reexec_x_venv",
    "parse_dt",
    "product_from_tweet",
    "sales_windows",
]


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
