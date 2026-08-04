from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SKILL_DIR = Path(__file__).resolve().parents[1]
RESOLVER = SKILL_DIR / "scripts" / "resolve_review_scope.py"
REGISTRY = SKILL_DIR / "references" / "lane-registry.json"
# The runner narrows PATH to the platform default, so it can execute an older
# interpreter than the one running these tests. Exercise the same one.
RUNNER_PYTHON = shutil.which("python3", path=os.defpath) or "/usr/bin/python3"

sys.path.insert(0, str(SKILL_DIR / "scripts"))

from lane_registry_validation import RegistryError, validate_registry_contract  # noqa: E402
from resolve_review_scope import load_registry  # noqa: E402
from review_git_process import ScopeError  # noqa: E402


def baseline_registry() -> dict:
    return {
        "lanes": [
            {
                "id": "baseline",
                "always": True,
                "verificationProfiles": ["common"],
                "execution": {"replicas": 1, "adjudication": False},
                "prompt": "references/lanes/baseline.md",
            }
        ]
    }


def resolve_raising_for(suffix: str):
    """Return a Path.resolve replacement that fails only for matching paths.

    Path.resolve() reports a symbolic link loop as RuntimeError before Python
    3.13 and resolves it silently afterwards, so raising directly keeps the guard
    covered on every interpreter the runner may select.
    """
    original = Path.resolve

    def replacement(self: Path, *args, **kwargs) -> Path:
        if self.name.endswith(suffix):
            raise RuntimeError(f"Symlink loop from {str(self)!r}")
        return original(self, *args, **kwargs)

    return replacement


class SymlinkLoopResolutionTests(unittest.TestCase):
    def test_registry_validation_rejects_unresolvable_prompt(self) -> None:
        with mock.patch.object(Path, "resolve", resolve_raising_for(".md")):
            with self.assertRaises(RegistryError):
                validate_registry_contract(baseline_registry(), skill_dir=SKILL_DIR)

    def test_registry_validation_rejects_unresolvable_lanes_directory(self) -> None:
        with mock.patch.object(Path, "resolve", resolve_raising_for("lanes")):
            with self.assertRaises(RegistryError):
                validate_registry_contract(baseline_registry(), skill_dir=SKILL_DIR)

    def test_load_registry_rejects_unresolvable_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry_path = Path(directory) / "registry.json"
            registry_path.write_text(
                REGISTRY.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            with mock.patch.object(Path, "resolve", resolve_raising_for(".md")):
                with self.assertRaises(ScopeError):
                    load_registry(registry_path)

    def test_resolver_reports_repository_symlink_loop_without_a_traceback(self) -> None:
        # End-to-end on the interpreter the runner selects. Older versions fail
        # while resolving the loop and newer ones fail the following Git lookup,
        # so both must exit with the resolver's own error rather than a traceback.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "loop-a"
            second = root / "loop-b"
            first.symlink_to(second.name)
            second.symlink_to(first.name)

            completed = subprocess.run(
                [
                    RUNNER_PYTHON,
                    str(RESOLVER),
                    "--repo",
                    str(first),
                    "--registry",
                    str(REGISTRY),
                    "--uncommitted",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertIn("resolve_review_scope.py:", completed.stderr)

    @staticmethod
    def git(repo: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", *arguments],
            cwd=repo,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


if __name__ == "__main__":
    unittest.main()
