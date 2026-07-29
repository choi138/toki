from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import sync_codex_review_labels as sync  # noqa: E402


class TimelineEvidenceTests(unittest.TestCase):
    head_sha = "a" * 40
    allowed_authors = {"chatgpt-codex-connector[bot]"}

    def head_node(self) -> dict[str, object]:
        return {
            "__typename": "PullRequestCommit",
            "commit": {"oid": self.head_sha},
        }

    def review_node(self, *, state: str = "COMMENTED", database_id: int = 42) -> dict[str, object]:
        return {
            "__typename": "PullRequestReview",
            "databaseId": database_id,
            "state": state,
            "author": {"login": "chatgpt-codex-connector[bot]"},
            "bodyText": "No major issues found",
            "commit": {"oid": self.head_sha},
            "url": "https://example.test/review",
        }

    def test_missing_head_anchor_blocks_another_review_request(self) -> None:
        self.assertTrue(
            sync.has_codex_news_after_current_head(
                [],
                head_sha=self.head_sha,
                allowed_authors=self.allowed_authors,
            )
        )

    def test_dismissed_review_is_not_clean_or_current_news(self) -> None:
        timeline = [self.head_node(), self.review_node(state="DISMISSED")]

        self.assertEqual(
            sync.find_current_head_codex_review_state(
                timeline,
                head_sha=self.head_sha,
                allowed_authors=self.allowed_authors,
            ),
            ("none", None),
        )
        self.assertFalse(
            sync.has_codex_news_after_current_head(
                timeline,
                head_sha=self.head_sha,
                allowed_authors=self.allowed_authors,
            )
        )

    def test_comments_from_dismissed_review_are_not_merged(self) -> None:
        timeline = [self.head_node(), self.review_node(state="DISMISSED")]
        comment = {
            "__typename": "PullRequestReviewComment",
            "pullRequestReviewDatabaseId": 42,
            "author": {"login": "chatgpt-codex-connector[bot]"},
            "bodyText": "**[P1] dismissed finding**",
            "commit": {"oid": self.head_sha},
            "url": "https://example.test/comment",
        }

        self.assertEqual(sync.merge_review_comment_nodes(timeline, [comment]), timeline)


class DecisionTests(unittest.TestCase):
    head_sha = "b" * 40
    allowed_authors = {"chatgpt-codex-connector[bot]"}

    def head_node(self) -> dict[str, object]:
        return {
            "__typename": "PullRequestCommit",
            "commit": {"oid": self.head_sha},
        }

    def clean_review_node(self) -> dict[str, object]:
        return {
            "__typename": "PullRequestReview",
            "databaseId": 7,
            "state": "COMMENTED",
            "author": {"login": "chatgpt-codex-connector[bot]"},
            "bodyText": "No major issues found",
            "commit": {"oid": self.head_sha},
            "url": "https://example.test/review",
        }

    def decide_for_draft(self, timeline: list[dict[str, object]], labels: set[str]) -> sync.SyncDecision:
        with (
            mock.patch.object(sync, "pr_timeline_evidence", return_value=(self.head_sha, timeline)),
            mock.patch.object(sync, "issue_label_names", return_value=labels),
            mock.patch.object(sync, "commit_checks_state", return_value="success"),
            mock.patch.object(sync, "pr_merge_state", return_value="DRAFT"),
            mock.patch.object(sync, "unresolved_codex_finding_thread_urls", return_value=()),
        ):
            return sync.decide_pr(
                "choi138/toki",
                64,
                allowed_authors=self.allowed_authors,
                ignore_checks=False,
            )

    def test_draft_removes_existing_ok_label(self) -> None:
        decision = self.decide_for_draft(
            [self.head_node(), self.clean_review_node()],
            {sync.CODEX_OK_LABEL},
        )

        self.assertFalse(decision.wants_ok_label)
        self.assertEqual(decision.ok_action, "remove")
        self.assertIn("merge state is draft", decision.reason)

    def test_draft_never_triggers_codex_review(self) -> None:
        decision = self.decide_for_draft([self.head_node()], set())

        self.assertFalse(decision.trigger_codex_review)

    def test_action_required_is_pending_not_failed(self) -> None:
        state = sync.classify_check_state(
            [{"name": "Build", "conclusion": "ACTION_REQUIRED"}],
            {},
            required_check_names=frozenset({"Build"}),
        )

        self.assertEqual(state, "pending")


class CommandAndWorkflowTests(unittest.TestCase):
    def test_all_open_with_no_pull_requests_is_successful(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(sync, "ensure_label", return_value=()),
            mock.patch.object(sync, "list_open_pr_numbers", return_value=[]),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = sync.main(["--repo", "choi138/toki", "--all-open"])

        self.assertEqual(exit_code, 0)
        self.assertIn("no open PRs; nothing to sync", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")

    def test_omitting_pr_selection_still_fails(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(sync, "ensure_label", return_value=()),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = sync.main(["--repo", "choi138/toki"])

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("no PRs selected; pass --pr or --all-open", stderr.getvalue())

    def test_workflow_serializes_writes_and_cannot_approve_fork_runs(self) -> None:
        workflow_path = SCRIPT_DIR.parent / "workflows" / "codex-review-labels.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        script = Path(sync.__file__).read_text(encoding="utf-8")

        self.assertIn("group: codex-review-labels-${{ github.repository }}", workflow)
        self.assertIn("actions: read", workflow)
        self.assertNotIn("actions: write", workflow)
        self.assertNotIn("/approve", script)
        self.assertNotIn("approve_workflow_runs", script)


if __name__ == "__main__":
    unittest.main()
