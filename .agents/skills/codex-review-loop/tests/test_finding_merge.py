from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
MERGER = SKILL_DIR / "scripts" / "merge_findings.py"


def finding(
    *,
    priority: str = "P2",
    title: str = "Reject stale snapshot",
    root_cause: str = "Snapshot generation is not compared",
    file: str = "Sources/TokiSyncProtocol/SnapshotValidation.swift",
    start: int = 20,
    end: int = 23,
) -> dict:
    return {
        "priority": priority,
        "confidence": 0.9,
        "title": title,
        "file": file,
        "startLine": start,
        "endLine": end,
        "rootCause": root_cause,
        "evidence": "An older generation can reach the acceptance branch.",
        "impact": "A stale snapshot can replace current state.",
        "suggestedFix": "Compare generations before replacement.",
        "verification": ["swift test"],
    }


def lane_result(lane: str, findings: list[dict]) -> dict:
    return {
        "schemaVersion": "1.0",
        "lane": lane,
        "verdict": "findings" if findings else "clean",
        "summary": "Actionable findings." if findings else "No actionable findings.",
        "findings": findings,
    }


class FindingMergeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)

    def write_result(self, name: str, result: dict) -> Path:
        path = self.directory / name
        path.write_text(json.dumps(result), encoding="utf-8")
        return path

    def run_merger(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(MERGER), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_merges_overlapping_root_cause_and_keeps_priority_opinions(self) -> None:
        baseline = self.write_result("baseline.json", lane_result("baseline", [finding()]))
        remote = self.write_result(
            "remote.json",
            lane_result(
                "remote-sync",
                [
                    finding(
                        priority="P0",
                        title="Stale snapshots bypass generation checks",
                        root_cause="Snapshot generation comparison is missing",
                        start=21,
                        end=24,
                    )
                ],
            ),
        )

        completed = self.run_merger("merge", str(baseline), str(remote))
        merged = json.loads(completed.stdout)

        self.assertEqual(merged["verdict"], "findings")
        self.assertEqual(len(merged["findings"]), 1)
        result = merged["findings"][0]
        self.assertEqual(result["priority"], "P0")
        self.assertEqual(result["lanes"], ["baseline", "remote-sync"])
        self.assertEqual(
            result["priorityOpinions"],
            {"baseline": "P2", "remote-sync": "P0"},
        )
        self.assertEqual(len(merged["conflicts"]), 1)

    def test_keeps_non_overlapping_findings_separate(self) -> None:
        first = self.write_result("first.json", lane_result("baseline", [finding()]))
        second = self.write_result(
            "second.json",
            lane_result(
                "testing",
                [
                    finding(
                        title="Missing corrupt-cache coverage",
                        root_cause="Corrupt cache fixture is not tested",
                        start=80,
                        end=82,
                    )
                ],
            ),
        )

        completed = self.run_merger("merge", str(first), str(second))
        merged = json.loads(completed.stdout)

        self.assertEqual(len(merged["findings"]), 2)

    def test_rejects_parent_relative_finding_path(self) -> None:
        invalid = finding(file="../secret.txt")
        path = self.write_result("invalid.json", lane_result("baseline", [invalid]))

        completed = self.run_merger("validate", str(path), check=False)

        self.assertEqual(completed.returncode, 2)
        self.assertIn("repository-relative", completed.stderr)

    def test_rejects_clean_verdict_with_findings(self) -> None:
        invalid = lane_result("baseline", [finding()])
        invalid["verdict"] = "clean"
        path = self.write_result("invalid.json", invalid)

        completed = self.run_merger("validate", str(path), check=False)

        self.assertEqual(completed.returncode, 2)
        self.assertIn("clean requires no findings", completed.stderr)

    def test_rejects_duplicate_lane_results(self) -> None:
        first = self.write_result("first.json", lane_result("baseline", []))
        second = self.write_result("second.json", lane_result("baseline", []))

        completed = self.run_merger("merge", str(first), str(second), check=False)

        self.assertEqual(completed.returncode, 2)
        self.assertIn("each lane may appear only once", completed.stderr)


if __name__ == "__main__":
    unittest.main()
