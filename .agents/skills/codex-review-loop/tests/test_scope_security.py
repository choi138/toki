from __future__ import annotations

import importlib
import json
import os
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

        self.assertIn("symbolic link cannot be reviewed safely", raised.exception.stderr)

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

    def test_committed_regular_file_replaced_by_symlink_is_rejected_for_object_scopes(
        self,
    ) -> None:
        self.git("switch", "-q", "-c", "feature")
        reviewed = self.repo / "reviewed.txt"
        reviewed.write_text("committed\n", encoding="utf-8")
        self.git("add", "reviewed.txt")
        self.git("commit", "-q", "-m", "add reviewed file")
        commit = self.git("rev-parse", "HEAD").strip()
        reviewed.unlink()
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        reviewed.symlink_to(outside)

        for scope in (("--base", "main"), ("--commit", commit)):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("symbolic link", raised.exception.stderr)

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

    def test_ignored_sensitive_file_blocks_base_and_commit_scopes(self) -> None:
        (self.repo / ".gitignore").write_text(".env\n", encoding="utf-8")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignore environment")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        (self.repo / ".env").write_text("API_TOKEN=secret\n", encoding="utf-8")

        for scope in (("--base", "main"), ("--commit", commit)):
            with self.subTest(scope=scope):
                result = self.resolve(*scope)

                self.assertFalse(result["safeToReview"])
                self.assertIn(
                    {"pattern": ".env", "count": 1},
                    result["excludedChanges"],
                )

    def test_untracked_sensitive_file_blocks_base_and_commit_scopes(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        (self.repo / ".env").write_text("API_TOKEN=secret\n", encoding="utf-8")

        for scope in (("--base", "main"), ("--commit", commit)):
            with self.subTest(scope=scope):
                result = self.resolve(*scope)

                self.assertFalse(result["safeToReview"])

    def test_embedded_repository_sensitive_file_blocks_every_scope(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        vendor = self.repo / "vendor"
        vendor.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=vendor, check=True)
        (vendor / ".env").write_text("API_TOKEN=secret\n", encoding="utf-8")

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("embedded Git repository", raised.exception.stderr)

    def test_embedded_repository_external_symlink_is_rejected_everywhere(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        vendor = self.repo / "vendor"
        vendor.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=vendor, check=True)
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (vendor / "link").symlink_to(outside)

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("cannot be reviewed safely", raised.exception.stderr)

    def test_tracked_submodule_is_rejected_for_every_scope(self) -> None:
        submodule = self.repo / "vendor"
        submodule.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=submodule, check=True)
        subprocess.run(
            ["git", "config", "user.email", "review-test@example.com"],
            cwd=submodule,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Review Test"],
            cwd=submodule,
            check=True,
        )
        (submodule / "README.md").write_text("submodule\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=submodule, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "submodule"],
            cwd=submodule,
            check=True,
        )
        submodule_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=submodule,
            text=True,
        ).strip()
        self.git(
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            submodule_commit,
            "vendor",
        )
        self.git("commit", "-q", "-m", "track submodule")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("submodule", raised.exception.stderr)

    def test_nested_git_metadata_under_tracked_directory_is_rejected(self) -> None:
        tracked_directory = self.repo / "vendor"
        tracked_directory.mkdir()
        (tracked_directory / "README.md").write_text("tracked\n", encoding="utf-8")
        self.git("add", "vendor/README.md")
        self.git("commit", "-q", "-m", "track vendor directory")
        external_git = self.repo.parent / "external-git"
        external_git.mkdir()
        (tracked_directory / ".git").symlink_to(external_git)

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertIn("embedded Git repository", raised.exception.stderr)

    def test_swift_build_cache_with_embedded_git_is_rejected(self) -> None:
        checkout = self.repo / ".build" / "checkouts" / "dependency"
        (checkout / ".git").mkdir(parents=True)
        (checkout / "README.md").write_text("generated checkout\n", encoding="utf-8")
        (self.repo / "README.md").write_text("changed\n", encoding="utf-8")

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertIn("embedded Git repository", raised.exception.stderr)

    def test_internal_symlink_alias_preserves_sensitive_exclusions(self) -> None:
        (self.repo / ".gitignore").write_text(
            ".agents/projects/\n",
            encoding="utf-8",
        )
        (self.repo / ".agents").mkdir()
        (self.repo / ".claude").symlink_to(".agents")
        self.git("add", ".gitignore", ".claude")
        self.git("commit", "-q", "-m", "add internal agent alias")
        session = self.repo / ".agents" / "projects" / "session.jsonl"
        session.parent.mkdir()
        session.write_text("sensitive transcript\n", encoding="utf-8")

        result = self.resolve("--uncommitted")

        self.assertFalse(result["safeToReview"])
        self.assertTrue(
            any(
                item["pattern"] == ".claude/projects/**"
                for item in result["excludedChanges"]
            )
        )

    def test_ignored_symlink_is_rejected_for_every_scope(self) -> None:
        (self.repo / ".gitignore").write_text("ignored-link\n", encoding="utf-8")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignore link")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "ignored-link").symlink_to(outside)

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("symbolic link", raised.exception.stderr)

    def test_untracked_symlink_is_rejected_for_base_and_commit_scopes(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "notes-link").symlink_to(outside)

        for scope in (("--base", "main"), ("--commit", commit)):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("symbolic link", raised.exception.stderr)

    def test_unchanged_tracked_symlink_is_rejected_for_every_scope(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / "tracked-link").symlink_to(outside)
        self.git("add", "tracked-link")
        self.git("commit", "-q", "-m", "track link")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.resolve(*scope)

                self.assertIn("symbolic link", raised.exception.stderr)

    def test_unchanged_internal_tracked_symlink_is_allowed_for_every_scope(self) -> None:
        target = self.repo / "Sources"
        target.mkdir()
        (self.repo / "tracked-link").symlink_to(target)
        self.git("add", "tracked-link")
        self.git("commit", "-q", "-m", "track internal link")
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                result = self.resolve(*scope)

                self.assertTrue(result["safeToReview"])

    def test_symlink_deletion_is_rejected_for_every_scope(self) -> None:
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        link = self.repo / "tracked-link"
        link.symlink_to(outside)
        self.git("add", "tracked-link")
        self.git("commit", "-q", "-m", "track link")
        self.git("switch", "-q", "-c", "feature")
        link.unlink()
        self.git("add", "tracked-link")

        with self.assertRaises(subprocess.CalledProcessError):
            self.resolve("--uncommitted")

        self.git("commit", "-q", "-m", "delete link")
        commit = self.git("rev-parse", "HEAD").strip()
        for scope in (("--base", "main"), ("--commit", commit)):
            with self.subTest(scope=scope):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.resolve(*scope)

    def test_untracked_non_utf8_path_is_rejected(self) -> None:
        with mock.patch(
            "review_scope_git.changed_paths_without_symlinks",
            return_value=[],
        ), mock.patch(
            "review_scope_git.run_git",
            return_value=b"invalid-\xff.txt\0",
        ):
            with self.assertRaisesRegex(
                review_scope_git.ScopeError,
                "Git path is not valid UTF-8",
            ):
                review_scope_git.uncommitted_scope(self.repo, [])

    def test_staged_non_utf8_path_is_rejected(self) -> None:
        with mock.patch(
            "review_scope_git.changed_paths_without_symlinks",
            side_effect=[
                [],
                review_scope_git.ScopeError("Git path is not valid UTF-8"),
            ],
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

    def test_scope_resolution_does_not_execute_fsmonitor_hook(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        (self.repo / "README.md").write_text("feature\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "-q", "-m", "feature")
        commit = self.git("rev-parse", "HEAD").strip()
        fsmonitor = self.repo.parent / "fsmonitor.py"
        fsmonitor.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n",
            encoding="utf-8",
        )
        fsmonitor.chmod(0o755)
        marker = fsmonitor.with_suffix(".invoked")
        self.git("config", "core.fsmonitor", str(fsmonitor))
        (self.repo / "README.md").write_text("dirty feature\n", encoding="utf-8")

        for scope in (
            ("--uncommitted",),
            ("--base", "main"),
            ("--commit", commit),
        ):
            with self.subTest(scope=scope):
                marker.unlink(missing_ok=True)
                result = self.resolve(*scope)

                self.assertTrue(result["hasChanges"])
                self.assertFalse(marker.exists())

    def test_repository_selection_environment_cannot_hide_filter_config(self) -> None:
        attributes = self.repo / ".gitattributes"
        attributes.write_text("*.review filter=unsafe\n", encoding="utf-8")
        reviewed = self.repo / "sample.review"
        reviewed.write_text("before\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add filtered file")
        marker = self.repo.parent / "filter-invoked"
        filter_script = self.repo.parent / "filter.py"
        filter_script.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import sys\n"
            f"Path({str(marker)!r}).write_text('invoked\\n')\n"
            "sys.stdout.buffer.write(sys.stdin.buffer.read())\n",
            encoding="utf-8",
        )
        filter_script.chmod(0o755)
        self.git("config", "filter.unsafe.clean", str(filter_script))
        self.git("config", "filter.unsafe.required", "true")
        reviewed.write_text("after\n", encoding="utf-8")
        decoy = self.repo.parent / "decoy"
        decoy.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=decoy, check=True)
        environment = os.environ.copy()
        environment["GIT_DIR"] = str(decoy / ".git")

        completed = subprocess.run(
            [
                "python3",
                str(RESOLVER),
                "--repo",
                str(self.repo),
                "--uncommitted",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=True,
        )
        result = json.loads(completed.stdout)

        self.assertTrue(result["hasChanges"])
        self.assertFalse(marker.exists())

    def test_repository_root_preserves_trailing_whitespace(self) -> None:
        whitespace_repo = self.repo.parent / "repo "
        whitespace_repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=whitespace_repo, check=True)
        subprocess.run(
            ["git", "config", "user.email", "review-test@example.com"],
            cwd=whitespace_repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Review Test"],
            cwd=whitespace_repo,
            check=True,
        )
        (whitespace_repo / "README.md").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=whitespace_repo, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "initial"],
            cwd=whitespace_repo,
            check=True,
        )
        (whitespace_repo / ".env").write_text("API_TOKEN=secret\n", encoding="utf-8")

        completed = subprocess.run(
            [
                "python3",
                str(RESOLVER),
                "--repo",
                str(whitespace_repo),
                "--uncommitted",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        result = json.loads(completed.stdout)

        self.assertFalse(result["safeToReview"])

    def test_symlink_error_escapes_terminal_control_characters(self) -> None:
        unsafe_name = "\x1b]0;PWN\x07link"
        outside = self.repo.parent / "outside.txt"
        outside.write_text("credential fixture\n", encoding="utf-8")
        (self.repo / unsafe_name).symlink_to(outside)

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.resolve("--uncommitted")

        self.assertNotIn("\x1b", raised.exception.stderr)
        self.assertNotIn("\x07", raised.exception.stderr)
        self.assertIn("\\x1b", raised.exception.stderr)

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
