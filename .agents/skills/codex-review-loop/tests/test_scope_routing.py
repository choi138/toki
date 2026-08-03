from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
RESOLVER = SKILL_DIR / "scripts" / "resolve_review_scope.py"


class ScopeRoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "review-test@example.com")
        self.git("config", "user.name", "Review Test")

        (self.repo / "README.md").write_text("fixture\n", encoding="utf-8")
        docs = self.repo / "docs" / "notes.md"
        docs.parent.mkdir(parents=True)
        docs.write_text("ordinary notes\n", encoding="utf-8")
        reader = self.repo / "Sources" / "TokiUsageReaders" / "Reader.swift"
        reader.parent.mkdir(parents=True)
        reader.write_text("struct Reader {}\n", encoding="utf-8")
        app_test = self.repo / "TokiTests" / "BehaviorTests.swift"
        app_test.parent.mkdir()
        app_test.write_text("func verifyBehavior() {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "initial")

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

    def resolve(self, *scope: str) -> dict:
        result = subprocess.run(
            ["python3", str(RESOLVER), "--repo", str(self.repo), *scope],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return json.loads(result.stdout)

    @staticmethod
    def lane_ids(result: dict) -> set[str]:
        return {lane["id"] for lane in result["activatedLanes"]}

    def test_base_scope_routes_protocol_change_to_remote_and_testing(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        cipher = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        cipher.parent.mkdir(parents=True)
        cipher.write_text("func seal(nonce: String) {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add cipher")

        result = self.resolve("--base", "main")

        self.assertTrue(result["safeToReview"])
        self.assertTrue(result["hasChanges"])
        self.assertEqual(result["scope"]["codexArgs"], ["--base", "main"])
        self.assertTrue(
            {"baseline", "remote-sync", "testing"}.issubset(self.lane_ids(result))
        )

    def test_commit_scope_preserves_exact_sha_target(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        cipher = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        cipher.parent.mkdir(parents=True)
        cipher.write_text("func open(ciphertext: String) {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add open")
        commit = self.git("rev-parse", "HEAD").strip()

        result = self.resolve("--commit", commit)

        self.assertEqual(result["scope"]["codexArgs"], ["--commit", commit])
        self.assertIn("remote-sync", self.lane_ids(result))

    def test_uncommitted_reader_change_activates_usage_privacy_and_testing(self) -> None:
        reader = self.repo / "Sources" / "TokiUsageReaders" / "Reader.swift"
        reader.write_text("struct Reader { let tokenCount: Int }\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertTrue(result["safeToReview"])
        self.assertTrue(
            {"baseline", "usage-pricing", "privacy-security", "testing"}.issubset(
                self.lane_ids(result)
            )
        )

    def test_semantic_signal_activates_lane_outside_normal_path(self) -> None:
        notes = self.repo / "docs" / "notes.md"
        notes.write_text("Review the MainActor handoff.\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertIn("concurrency-lifecycle", self.lane_ids(result))

    def test_direct_app_test_path_activates_testing_lane(self) -> None:
        app_test = self.repo / "TokiTests" / "BehaviorTests.swift"
        app_test.write_text("func verifyBehavior() { _ = 1 }\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertIn("testing", self.lane_ids(result))

    def test_safe_untracked_directory_routes_individual_source_file(self) -> None:
        service = self.repo / "Sources" / "TokiAgentCore" / "NewService.swift"
        service.parent.mkdir()
        service.write_text("actor NewService {}\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertTrue(result["safeToReview"])
        self.assertIn(
            "Sources/TokiAgentCore/NewService.swift",
            result["untrackedReviewedPaths"],
        )
        self.assertTrue(
            {"remote-sync", "concurrency-lifecycle", "testing"}.issubset(
                self.lane_ids(result)
            )
        )

    def test_excluded_untracked_directory_blocks_uncommitted_review(self) -> None:
        sensitive = self.repo / ".hermes" / "session.log"
        sensitive.parent.mkdir()
        sensitive.write_text("sensitive fixture\n", encoding="utf-8")

        result = self.resolve("--uncommitted")
        serialized = json.dumps(result)

        self.assertTrue(result["hasChanges"])
        self.assertFalse(result["safeToReview"])
        self.assertNotIn("session.log", serialized)
        self.assertEqual(result["excludedChanges"], [{"pattern": ".hermes", "count": 1}])

    def test_clean_scope_reports_no_changes(self) -> None:
        result = self.resolve("--uncommitted")

        self.assertFalse(result["hasChanges"])
        self.assertTrue(result["safeToReview"])
        self.assertEqual(self.lane_ids(result), {"baseline"})


if __name__ == "__main__":
    unittest.main()
