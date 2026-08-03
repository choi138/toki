from __future__ import annotations

import importlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SKILL_DIR = Path(__file__).resolve().parents[1]
RESOLVER = SKILL_DIR / "scripts" / "resolve_review_scope.py"
sys.path.insert(0, str(RESOLVER.parent))
review_scope_git = importlib.import_module("review_scope_git")


class ScopeSecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "review-test@example.com")
        self.git("config", "user.name", "Review Test")
        self.git("config", "diff.renames", "true")
        (self.repo / "README.md").write_text("fixture\n", encoding="utf-8")
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
        completed = subprocess.run(
            ["python3", str(RESOLVER), "--repo", str(self.repo), *scope],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return json.loads(completed.stdout)

    def commit_secret(self) -> None:
        content = "".join(f"SECRET_{index}=value\n" for index in range(20))
        (self.repo / ".env").write_text(content, encoding="utf-8")
        self.git("add", ".env")
        self.git("commit", "-q", "-m", "add secret fixture")

    def rename_secret(self) -> None:
        (self.repo / ".env").rename(self.repo / "harmless.txt")
        renamed = self.repo / "harmless.txt"
        content = renamed.read_text(encoding="utf-8")
        renamed.write_text(
            content.replace("SECRET_19=value", "SECRET_19=changed"),
            encoding="utf-8",
        )

    def assert_secret_is_blocked(self, result: dict) -> None:
        self.assertTrue(result["hasChanges"])
        self.assertFalse(result["safeToReview"])
        self.assertEqual(result["excludedChanges"], [{"pattern": ".env", "count": 1}])

    def test_unstaged_rename_out_of_secret_path_is_blocked(self) -> None:
        self.commit_secret()
        self.rename_secret()

        result = self.resolve("--uncommitted")

        self.assert_secret_is_blocked(result)

    def test_staged_rename_out_of_secret_path_is_blocked(self) -> None:
        self.commit_secret()
        self.rename_secret()
        self.git("add", "-A")

        result = self.resolve("--uncommitted")

        self.assert_secret_is_blocked(result)

    def test_base_rename_out_of_secret_path_is_blocked(self) -> None:
        self.commit_secret()
        self.git("switch", "-q", "-c", "feature")
        self.rename_secret()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "rename secret")

        result = self.resolve("--base", "main")

        self.assert_secret_is_blocked(result)

    def test_commit_rename_out_of_secret_path_is_blocked(self) -> None:
        self.commit_secret()
        self.rename_secret()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "rename secret")
        commit = self.git("rev-parse", "HEAD").strip()

        result = self.resolve("--commit", commit)

        self.assert_secret_is_blocked(result)

    def test_mixed_case_root_environment_file_is_blocked(self) -> None:
        environment = self.repo / ".ENV"
        environment.write_text("API_TOKEN=secret\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertFalse(result["safeToReview"])
        self.assertEqual(result["excludedChanges"], [{"pattern": ".env", "count": 1}])

    def test_mixed_case_nested_private_key_is_blocked(self) -> None:
        private_key = self.repo / "keys" / "service.PEM"
        private_key.parent.mkdir()
        private_key.write_text("private key fixture\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertFalse(result["safeToReview"])
        self.assertEqual(
            result["excludedChanges"],
            [{"pattern": "**/*.pem", "count": 1}],
        )

    def test_local_usage_reader_paths_are_blocked(self) -> None:
        sensitive_paths = [
            ".claude/projects/session.jsonl",
            ".codex/state_5.sqlite",
            ".codex/sessions/rollout.jsonl",
            ".codex/archived_sessions/rollout.jsonl",
            ".config/Cursor/User/globalStorage/state.vscdb",
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            ".gemini/tmp/chat.json",
            ".gjc/agent/sessions/session.jsonl",
            ".local/share/opencode/opencode.db",
            ".openclaw/agents/main/sessions/session.jsonl",
            ".local/state/toki-agent/usage-cache.json",
            ".local/state/toki/usage-cache.json",
            "Library/Application Support/Toki/usage-cache.json",
        ]
        for relative_path in sensitive_paths:
            sensitive = self.repo / relative_path
            sensitive.parent.mkdir(parents=True, exist_ok=True)
            sensitive.write_text("sensitive fixture\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertFalse(result["safeToReview"])
        self.assertEqual(result["changedPaths"], [])
        self.assertEqual(
            sum(change["count"] for change in result["excludedChanges"]),
            len(sensitive_paths),
        )

    def test_untracked_symlink_outside_repository_is_rejected(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "notes.txt").symlink_to(outside)

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertIn("changed symbolic link", raised.exception.stderr)

    def test_staged_symlink_outside_repository_is_rejected(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "notes.txt").symlink_to(outside)
        self.git("add", "notes.txt")

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertIn("changed symbolic link", raised.exception.stderr)

    def test_tracked_file_replaced_by_symlink_is_rejected(self) -> None:
        notes = self.repo / "notes.txt"
        notes.write_text("safe fixture\n", encoding="utf-8")
        self.git("add", "notes.txt")
        self.git("commit", "-q", "-m", "add tracked fixture")
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        notes.unlink()
        notes.symlink_to(outside)

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertIn("changed symbolic link", raised.exception.stderr)

    def test_base_scope_symlink_outside_repository_is_rejected(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "notes.txt").symlink_to(outside)
        self.git("add", "notes.txt")
        self.git("commit", "-q", "-m", "add symlink")

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--base", "main")

        self.assertIn("changed symbolic link", raised.exception.stderr)

    def test_commit_scope_symlink_outside_repository_is_rejected(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "notes.txt").symlink_to(outside)
        self.git("add", "notes.txt")
        self.git("commit", "-q", "-m", "add symlink")
        commit = self.git("rev-parse", "HEAD").strip()

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--commit", commit)

        self.assertIn("changed symbolic link", raised.exception.stderr)

    def test_untracked_non_utf8_path_is_rejected(self) -> None:
        with mock.patch(
            "review_scope_git.run_git",
            side_effect=[b"", b"", b"invalid-\xff.txt\0", b"invalid-\xff.txt\0"],
        ), mock.patch(
            "review_scope_git.run_git_bounded",
            return_value=(b"", True),
        ):
            with self.assertRaisesRegex(
                review_scope_git.ScopeError,
                "Git path is not valid UTF-8",
            ):
                review_scope_git.uncommitted_scope(self.repo, [])

    def test_staged_non_utf8_path_is_rejected(self) -> None:
        with mock.patch(
            "review_scope_git.run_git",
            side_effect=[b"", b"invalid-\xff.txt\0", b"", b""],
        ), mock.patch(
            "review_scope_git.run_git_bounded",
            return_value=(b"", True),
        ):
            with self.assertRaisesRegex(
                review_scope_git.ScopeError,
                "Git path is not valid UTF-8",
            ):
                review_scope_git.uncommitted_scope(self.repo, [])

    def test_large_untracked_file_activates_specialists_conservatively(self) -> None:
        notes = self.repo / "docs" / "large.md"
        notes.parent.mkdir()
        notes.write_text(
            ("ordinary text\n" * 87_381) + "MainActor\n",
            encoding="utf-8",
        )

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertFalse(result["semanticInspectionComplete"])
        self.assertIn("concurrency-lifecycle", lane_ids)

    def test_aggregate_untracked_content_activates_specialists_conservatively(self) -> None:
        notes = self.repo / "docs"
        notes.mkdir()
        content = "ordinary text\n" * 69_230
        for index in range(5):
            (notes / f"large-{index}.md").write_text(content, encoding="utf-8")

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertFalse(result["semanticInspectionComplete"])
        self.assertIn("concurrency-lifecycle", lane_ids)

    def test_aggregate_untracked_binary_content_counts_toward_budget(self) -> None:
        assets = self.repo / "assets"
        assets.mkdir()
        content = b"\0" + (b"x" * 900_000)
        for index in range(5):
            (assets / f"large-{index}.bin").write_bytes(content)

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertFalse(result["semanticInspectionComplete"])
        self.assertIn("concurrency-lifecycle", lane_ids)

    def test_safe_text_rename_does_not_route_unchanged_content(self) -> None:
        notes = self.repo / "docs"
        notes.mkdir()
        original = notes / "original.txt"
        original.write_text("MainActor\n" * 50_000, encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add rename fixture")
        self.git("mv", "docs/original.txt", "docs/renamed.txt")

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertIn("docs/original.txt", result["changedPaths"])
        self.assertIn("docs/renamed.txt", result["changedPaths"])
        self.assertNotIn("concurrency-lifecycle", lane_ids)

    def test_large_tracked_diff_activates_specialists_conservatively(self) -> None:
        notes = self.repo / "docs"
        notes.mkdir()
        (notes / "large.txt").write_text(
            "ordinary text\n" * 350_000,
            encoding="utf-8",
        )
        self.git("add", ".")

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertFalse(result["semanticInspectionComplete"])
        self.assertIn("concurrency-lifecycle", lane_ids)

    def test_semantic_diff_does_not_execute_textconv_filter(self) -> None:
        attributes = self.repo / ".gitattributes"
        attributes.write_text("*.review diff=unsafe\n", encoding="utf-8")
        reviewed = self.repo / "sample.review"
        reviewed.write_text("before\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add textconv fixture")

        converter = self.repo.parent / "textconv.py"
        converter.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import sys\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n"
            "sys.stdout.buffer.write(Path(sys.argv[1]).read_bytes())\n",
            encoding="utf-8",
        )
        converter.chmod(0o755)
        marker = converter.with_suffix(".invoked")
        self.git("config", "diff.unsafe.textconv", str(converter))
        reviewed.write_text("after\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertTrue(result["hasChanges"])
        self.assertFalse(marker.exists())

    def test_scope_resolution_does_not_execute_clean_filter(self) -> None:
        attributes = self.repo / ".gitattributes"
        attributes.write_text("*.review filter=unsafe\n", encoding="utf-8")
        reviewed = self.repo / "sample.review"
        reviewed.write_text("before\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add clean filter fixture")

        clean_filter = self.repo.parent / "clean-filter.py"
        clean_filter.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import sys\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n"
            "sys.stdout.buffer.write(sys.stdin.buffer.read())\n",
            encoding="utf-8",
        )
        clean_filter.chmod(0o755)
        marker = clean_filter.with_suffix(".invoked")
        self.git("config", "filter.unsafe.clean", str(clean_filter))
        reviewed.write_text("after\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertTrue(result["hasChanges"])
        self.assertFalse(marker.exists())

    def test_literal_backslash_parent_name_does_not_read_outside_repository(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("MainActor\n", encoding="utf-8")
        literal_name = r"..\outside.txt"
        (self.repo / literal_name).write_text("ordinary text\n", encoding="utf-8")

        result = self.resolve("--uncommitted")
        lane_ids = {lane["id"] for lane in result["activatedLanes"]}

        self.assertNotIn("concurrency-lifecycle", lane_ids)
        self.assertIn(literal_name, result["changedPaths"])
        self.assertIn(literal_name, result["untrackedReviewedPaths"])


if __name__ == "__main__":
    unittest.main()
