#!/usr/bin/env python3
"""Behavioral tests for canonical SaneApps tree resolution.

Regression (2026-07-14): verify relocates SaneProcess into a sparse
~/.sanemaster/verify-workspaces snapshot. Path resolution derived only from
__file__ made every suite that needs the surrounding operator tree fail in
relocated runs. These tests exercise the resolver from a genuinely relocated
copy at runtime, so the bug fails red if the fallback regresses.
"""
import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("saneapps_paths.py")


def load_from(path):
    spec = importlib.util.spec_from_file_location(f"saneapps_paths_{path.parent.name}", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SaneappsPathsTests(unittest.TestCase):
    def test_relocated_copy_falls_back_to_canonical_home_checkout(self):
        with tempfile.TemporaryDirectory(prefix="saneapps-paths-relo-") as tmp:
            relocated_dir = Path(tmp) / "SaneApps" / "infra" / "SaneProcess" / "scripts" / "automation"
            relocated_dir.mkdir(parents=True)
            shutil.copy2(SOURCE, relocated_dir / "saneapps_paths.py")
            module = load_from(relocated_dir / "saneapps_paths.py")

            root = module.saneapps_root()
            self.assertEqual(Path.home() / "SaneApps", root)
            self.assertTrue(module.check_inbox_script().exists(), module.check_inbox_script())

    def test_canonical_checkout_resolves_to_its_own_umbrella(self):
        module = load_from(SOURCE)
        derived = SOURCE.resolve().parents[4]
        if derived.joinpath("infra", "scripts", "check-inbox.sh").exists():
            self.assertEqual(derived, module.saneapps_root())
        else:
            self.assertEqual(Path.home() / "SaneApps", module.saneapps_root())
        self.assertTrue(module.check_inbox_script().exists(), module.check_inbox_script())


if __name__ == "__main__":
    unittest.main()
