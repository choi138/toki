from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
RUNNER = SKILL_DIR / "scripts" / "run_review_lane.sh"


class RunnerContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "review-test@example.com")
        self.git("config", "user.name", "Review Test")

        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.parent.mkdir(parents=True)
        source.write_text("func seal() {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "initial")
        self.git("switch", "-q", "-c", "feature")
        source.write_text("func seal(nonce: String) {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "change cipher")

        self.capture = self.root / "capture.json"
        self.fake_codex = self.root / "fake-codex"
        self.fake_codex.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
prompt = sys.stdin.read()
output_index = arguments.index("--output-last-message") + 1
output_path = Path(arguments[output_index])
lane_marker = "Set the output lane field to: "
lane = prompt.split(lane_marker, 1)[1].splitlines()[0].strip()
result = {
    "schemaVersion": "1.0",
    "lane": lane,
    "verdict": "clean",
    "summary": "No actionable findings.",
    "findings": [],
}
output_path.write_text(json.dumps(result), encoding="utf-8")
Path(os.environ["TOKI_REVIEW_CAPTURE_FILE"]).write_text(
    json.dumps({
        "arguments": arguments,
        "prompt": prompt,
        "reviewChild": os.environ.get("TOKI_REVIEW_CHILD"),
    }),
    encoding="utf-8",
)
""",
            encoding="utf-8",
        )
        self.fake_codex.chmod(0o755)

    def git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return result.stdout

    def run_runner(
        self,
        *arguments: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["TOKI_REVIEW_CODEX_BIN"] = str(self.fake_codex)
        environment["TOKI_REVIEW_CAPTURE_FILE"] = str(self.capture)
        return subprocess.run(
            ["bash", str(RUNNER), "--repo", str(self.repo), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=check,
        )

    def test_passes_scope_schema_and_prompt_through_stdin_without_writes(self) -> None:
        status_before = self.git("status", "--porcelain=v1", "--untracked-files=all")

        completed = self.run_runner("--lane", "baseline", "--base", "main")

        status_after = self.git("status", "--porcelain=v1", "--untracked-files=all")
        output = json.loads(completed.stdout)
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        arguments = capture["arguments"]
        self.assertEqual(output["lane"], "baseline")
        self.assertEqual(status_before, status_after)
        self.assertIn("--ephemeral", arguments)
        self.assertIn("--output-schema", arguments)
        self.assertIn("--base", arguments)
        self.assertEqual(arguments[arguments.index("--base") + 1], "main")
        self.assertEqual(arguments[-1], "-")
        self.assertEqual(capture["reviewChild"], "1")
        self.assertIn("Common Reviewer Contract", capture["prompt"])
        self.assertIn("Baseline Lane", capture["prompt"])

    def test_refuses_excluded_uncommitted_scope_before_invoking_codex(self) -> None:
        sensitive = self.repo / ".hermes" / "session.log"
        sensitive.parent.mkdir()
        sensitive.write_text("sensitive fixture\n", encoding="utf-8")

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("excluded sensitive or generated paths", completed.stderr)
        self.assertFalse(self.capture.exists())

    def test_refuses_lane_that_is_not_active(self) -> None:
        completed = self.run_runner(
            "--lane",
            "swiftui-architecture",
            "--base",
            "main",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("lane is not active", completed.stderr)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
