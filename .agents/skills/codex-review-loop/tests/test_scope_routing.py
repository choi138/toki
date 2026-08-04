from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
RESOLVER = SKILL_DIR / "scripts" / "resolve_review_scope.py"
REGISTRY = SKILL_DIR / "references" / "lane-registry.json"
# The runner narrows PATH to the platform default, so it can execute an older
# interpreter than the one running these tests. Exercise the same one.
RUNNER_PYTHON = shutil.which("python3", path=os.defpath) or "/usr/bin/python3"


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
            [RUNNER_PYTHON, str(RESOLVER), "--repo", str(self.repo), *scope],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return json.loads(result.stdout)

    def resolve_registry(
        self,
        registry: dict | bytes,
        name: str,
    ) -> subprocess.CompletedProcess[str]:
        registry_path = self.repo.parent / name
        if isinstance(registry, bytes):
            registry_path.write_bytes(registry)
        else:
            registry_path.write_text(json.dumps(registry), encoding="utf-8")
        return subprocess.run(
            [
                RUNNER_PYTHON,
                str(RESOLVER),
                "--repo",
                str(self.repo),
                "--registry",
                str(registry_path),
                "--uncommitted",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

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

    def test_commit_scope_preserves_root_commit_handling(self) -> None:
        root_commit = self.git("rev-list", "--max-parents=0", "HEAD").strip()

        result = self.resolve("--commit", root_commit)

        self.assertTrue(result["hasChanges"])
        self.assertIn("README.md", result["changedPaths"])
        self.assertIn(
            "Sources/TokiUsageReaders/Reader.swift",
            result["changedPaths"],
        )
        self.assertEqual(result["scope"]["codexArgs"], ["--commit", root_commit])

    def test_commit_scope_resolves_merge_against_first_parent(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        reader = self.repo / "Sources" / "TokiUsageReaders" / "MergedReader.swift"
        reader.write_text("struct MergedReader {}\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add merged reader")
        self.git("switch", "-q", "main")
        self.git("merge", "-q", "--no-ff", "feature", "-m", "merge feature")
        merge_commit = self.git("rev-parse", "HEAD").strip()

        result = self.resolve("--commit", merge_commit)

        self.assertTrue(result["hasChanges"])
        self.assertIn(
            "Sources/TokiUsageReaders/MergedReader.swift",
            result["changedPaths"],
        )
        self.assertIn("usage-pricing", self.lane_ids(result))
        self.assertEqual(result["scope"]["codexArgs"], ["--commit", merge_commit])

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

    def test_binary_attribute_uses_conservative_semantic_fallback(self) -> None:
        (self.repo / ".gitattributes").write_text(
            "docs/*.md binary\n",
            encoding="utf-8",
        )
        self.git("add", ".gitattributes")
        self.git("commit", "-q", "-m", "mark docs binary")
        notes = self.repo / "docs" / "notes.md"
        notes.write_text("MainActor\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertFalse(result["semanticInspectionComplete"])
        self.assertIn("concurrency-lifecycle", self.lane_ids(result))

    def test_untracked_semantic_signal_activates_lane_outside_normal_path(self) -> None:
        notes = self.repo / "docs" / "new.md"
        notes.write_text("Review the MainActor handoff.\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertIn("docs/new.md", result["untrackedReviewedPaths"])
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

    def test_root_environment_file_blocks_uncommitted_review(self) -> None:
        environment = self.repo / ".env"
        environment.write_text("API_TOKEN=secret\n", encoding="utf-8")

        result = self.resolve("--uncommitted")
        serialized = json.dumps(result)

        self.assertTrue(result["hasChanges"])
        self.assertFalse(result["safeToReview"])
        self.assertNotIn("API_TOKEN", serialized)
        self.assertEqual(result["excludedChanges"], [{"pattern": ".env", "count": 1}])

    def test_nested_environment_file_blocks_uncommitted_review(self) -> None:
        environment = self.repo / "config" / ".env.local"
        environment.parent.mkdir()
        environment.write_text("API_TOKEN=secret\n", encoding="utf-8")

        result = self.resolve("--uncommitted")
        serialized = json.dumps(result)

        self.assertTrue(result["hasChanges"])
        self.assertFalse(result["safeToReview"])
        self.assertNotIn("API_TOKEN", serialized)
        self.assertEqual(
            result["excludedChanges"],
            [{"pattern": "**/.env.*", "count": 1}],
        )

    def test_private_key_file_blocks_uncommitted_review(self) -> None:
        private_key = self.repo / "keys" / "service.pem"
        private_key.parent.mkdir()
        private_key.write_text("private key fixture\n", encoding="utf-8")

        result = self.resolve("--uncommitted")
        serialized = json.dumps(result)

        self.assertTrue(result["hasChanges"])
        self.assertFalse(result["safeToReview"])
        self.assertNotIn("private key fixture", serialized)
        self.assertEqual(
            result["excludedChanges"],
            [{"pattern": "**/*.pem", "count": 1}],
        )

    def test_registry_requires_baseline_to_be_always_on(self) -> None:
        cases = (
            ("false", False),
            ("missing", None),
            ("string", "true"),
            ("integer", 1),
            ("null", None),
        )
        for index, (mode, always_value) in enumerate(cases):
            with self.subTest(mode=mode):
                registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
                baseline = next(
                    lane for lane in registry["lanes"] if lane["id"] == "baseline"
                )
                if mode == "missing":
                    baseline.pop("always")
                else:
                    baseline["always"] = always_value

                completed = self.resolve_registry(
                    registry,
                    f"registry-{index}.json",
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn("baseline lane must be always-on", completed.stderr)

    def test_registry_rejects_invalid_verification_profiles(self) -> None:
        invalid_profiles = ([], ["unknown"], ["common", "common"])
        for index, profiles in enumerate(invalid_profiles):
            with self.subTest(profiles=profiles):
                registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
                registry["lanes"][0]["verificationProfiles"] = profiles

                completed = self.resolve_registry(
                    registry,
                    f"profiles-{index}.json",
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn("verificationProfiles", completed.stderr)

    def test_registry_rejects_unsupported_execution_settings(self) -> None:
        invalid_execution = (
            {"replicas": 2, "adjudication": False},
            {"replicas": 1, "adjudication": True},
            {"replicas": 1, "adjudication": False, "unknown": True},
        )
        for index, execution in enumerate(invalid_execution):
            with self.subTest(execution=execution):
                registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
                registry["lanes"][0]["execution"] = execution

                completed = self.resolve_registry(
                    registry,
                    f"execution-{index}.json",
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn("execution", completed.stderr)

    def test_registry_rejects_noncanonical_prompt_paths(self) -> None:
        invalid_prompts = (
            str((SKILL_DIR / "references" / "lanes" / "baseline.md").resolve()),
            "references/verification.md",
            "references/lane-registry.json",
        )
        for index, prompt in enumerate(invalid_prompts):
            with self.subTest(prompt=prompt):
                registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
                registry["lanes"][0]["prompt"] = prompt

                completed = self.resolve_registry(
                    registry,
                    f"prompt-{index}.json",
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn("prompt", completed.stderr)

    def test_registry_rejects_raw_non_utf8_without_traceback(self) -> None:
        completed = self.resolve_registry(
            b'{"version":"1.0","pathExclusions":[],"lanes":["' + bytes([0xFF]) + b'"]}',
            "raw-invalid.json",
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("cannot load lane registry", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

    def test_clean_scope_reports_no_changes(self) -> None:
        result = self.resolve("--uncommitted")

        self.assertFalse(result["hasChanges"])
        self.assertTrue(result["safeToReview"])
        self.assertEqual(self.lane_ids(result), {"baseline"})


if __name__ == "__main__":
    unittest.main()
