from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path


AGENTS_DIR = Path(__file__).resolve().parents[3]
ACTIVATION_HOOK = AGENTS_DIR / "hooks" / "skill_activation.ts"


class ActivationHookTests(unittest.TestCase):
    def run_hook(
        self,
        *,
        review_child: bool,
        prompt: str = "Run a Codex code review for the current diff.",
    ) -> str:
        environment = os.environ.copy()
        if review_child:
            environment["TOKI_REVIEW_CHILD"] = "1"
        else:
            environment.pop("TOKI_REVIEW_CHILD", None)
        completed = subprocess.run(
            [
                "node",
                "--no-warnings",
                "--experimental-strip-types",
                str(ACTIVATION_HOOK),
            ],
            input=json.dumps(
                {
                    "prompt": prompt,
                    "session_id": "activation-test",
                }
            ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=True,
        )
        if not completed.stdout:
            return ""
        output = json.loads(completed.stdout)
        return output["hookSpecificOutput"]["additionalContext"]

    def test_normal_request_activates_review_loop(self) -> None:
        context = self.run_hook(review_child=False)

        self.assertIn("Apply `codex-review-loop`", context)

    def test_leaf_reviewer_does_not_reactivate_review_loop(self) -> None:
        context = self.run_hook(review_child=True)

        self.assertNotIn("Apply `codex-review-loop`", context)
        self.assertIn("project-conventions", context)

    def test_bare_commit_sha_activates_review_loop(self) -> None:
        context = self.run_hook(
            review_child=False,
            prompt="Please review b32dfa83",
        )

        self.assertIn("Apply `codex-review-loop`", context)

    def test_commit_sha_before_korean_review_activates_review_loop(self) -> None:
        context = self.run_hook(
            review_child=False,
            prompt="b32dfa83 리뷰해줘",
        )

        self.assertIn("Apply `codex-review-loop`", context)

    def test_plain_review_request_does_not_activate_review_loop(self) -> None:
        context = self.run_hook(
            review_child=False,
            prompt="Please review this",
        )

        self.assertNotIn("codex-review-loop", context)


if __name__ == "__main__":
    unittest.main()
