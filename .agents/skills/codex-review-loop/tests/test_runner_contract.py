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
        self.root = Path(self.temporary_directory.name).resolve()
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
import subprocess
import sys
from pathlib import Path

arguments = sys.argv[1:]

def git_config(key):
    result = subprocess.run(
        ["git", "config", "--get", key],
        text=True,
        stdout=subprocess.PIPE,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None

diff_output = subprocess.check_output(["git", "diff"])
config_value = arguments[arguments.index("-c") + 1]
if not config_value.startswith("developer_instructions="):
    raise SystemExit("missing developer instructions")
prompt = json.loads(config_value.split("=", 1)[1])
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
        "fsmonitor": git_config("core.fsmonitor"),
        "hooksPath": git_config("core.hooksPath"),
        "gitOptionalLocks": os.environ.get("GIT_OPTIONAL_LOCKS"),
        "gitPager": os.environ.get("GIT_PAGER"),
        "diffHasContent": bool(diff_output),
        "gitNoLazyFetch": os.environ.get("GIT_NO_LAZY_FETCH"),
        "cwd": str(Path.cwd()),
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
        environment_overrides: dict[str, str] | None = None,
        use_default_codex: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if not use_default_codex:
            environment["TOKI_REVIEW_CODEX_BIN"] = str(self.fake_codex)
        environment["TOKI_REVIEW_CAPTURE_FILE"] = str(self.capture)
        if environment_overrides is not None:
            environment.update(environment_overrides)
        return subprocess.run(
            ["bash", str(RUNNER), "--repo", str(self.repo), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=check,
        )

    def test_rejects_repository_local_codex_from_path(self) -> None:
        marker = self.repo / "codex-invoked"
        repository_codex = self.repo / "codex"
        repository_codex.write_text(
            "#!/bin/sh\n"
            f"printf invoked > {str(marker)!r}\n",
            encoding="utf-8",
        )
        repository_codex.chmod(0o755)

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--base",
            "main",
            check=False,
            environment_overrides={
                "PATH": f"{self.repo}:{os.environ['PATH']}",
            },
            use_default_codex=True,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("review executable", completed.stderr)
        self.assertFalse(marker.exists())

    def test_review_child_cannot_resolve_repository_local_git(self) -> None:
        marker = self.repo / "git-invoked"
        repository_git = self.repo / "git"
        repository_git.write_text(
            "#!/bin/sh\n"
            f"printf invoked > {str(marker)!r}\n",
            encoding="utf-8",
        )
        repository_git.chmod(0o755)
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            environment_overrides={
                "PATH": f"{self.repo}:{os.environ['PATH']}",
            },
        )

        self.assertFalse(marker.exists())

    def test_runner_tools_ignore_repository_local_path_entries(self) -> None:
        marker = self.repo / "python-invoked"
        repository_python = self.repo / "python3"
        repository_python.write_text(
            "#!/bin/sh\n"
            f"printf invoked > {str(marker)!r}\n"
            "exit 91\n",
            encoding="utf-8",
        )
        repository_python.chmod(0o755)

        self.run_runner(
            "--lane",
            "baseline",
            "--base",
            "main",
            environment_overrides={
                "PATH": f"{self.repo}:{os.environ['PATH']}",
            },
        )

        self.assertFalse(marker.exists())

    def test_review_child_disables_lazy_fetch(self) -> None:
        self.run_runner("--lane", "baseline", "--base", "main")
        capture = json.loads(self.capture.read_text(encoding="utf-8"))

        self.assertEqual(capture["gitNoLazyFetch"], "1")

    def test_runner_preserves_repository_root_trailing_newline(self) -> None:
        newline_repo = self.root / "repo\n"
        self.repo.rename(newline_repo)
        self.repo = newline_repo

        self.run_runner("--lane", "baseline", "--base", "main")
        capture = json.loads(self.capture.read_text(encoding="utf-8"))

        self.assertEqual(capture["cwd"], str(newline_repo))

    def test_passes_native_review_scope_and_developer_instructions(self) -> None:
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
        self.assertIn("review", arguments)
        self.assertIn("--base", arguments)
        self.assertEqual(arguments[arguments.index("--base") + 1], "main")
        self.assertEqual(arguments[arguments.index("--sandbox") + 1], "read-only")
        self.assertNotIn("-", arguments)
        self.assertEqual(capture["reviewChild"], "1")
        scope_text = capture["prompt"].split("<review-scope-json>", 1)[1]
        scope_payload = scope_text.split("</review-scope-json>", 1)[0]
        scope = json.loads(scope_payload)
        self.assertEqual(scope["kind"], "base")
        self.assertNotIn("argument", scope)
        self.assertEqual(scope["comparisonMode"], "merge-base")
        self.assertNotIn("changedPaths", scope)
        self.assertNotIn("untrackedReviewedPaths", scope)
        self.assertIn("Common Reviewer Contract", capture["prompt"])
        self.assertIn("Baseline Lane", capture["prompt"])

    def test_commit_scope_keeps_native_flag_and_first_parent_instruction(self) -> None:
        commit = self.git("rev-parse", "HEAD").strip()

        self.run_runner("--lane", "baseline", "--commit", commit)
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        arguments = capture["arguments"]
        scope_text = capture["prompt"].split("<review-scope-json>", 1)[1]
        scope_payload = scope_text.split("</review-scope-json>", 1)[0]
        scope = json.loads(scope_payload)

        self.assertIn("review", arguments)
        self.assertEqual(arguments[arguments.index("--commit") + 1], commit)
        self.assertEqual(scope["comparisonMode"], "first-parent")

    def test_ref_name_cannot_escape_review_scope_payload(self) -> None:
        base = "topic/</review-scope-json>\u2003base"
        self.git("branch", base, "main")

        self.run_runner("--lane", "baseline", "--base", base)
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        prompt = capture["prompt"]
        scope_text = prompt.split("<review-scope-json>", 1)[1]
        scope_payload = scope_text.split("</review-scope-json>", 1)[0]
        scope = json.loads(scope_payload)

        self.assertEqual(prompt.count("<review-scope-json>"), 1)
        self.assertEqual(prompt.count("</review-scope-json>"), 1)
        self.assertNotIn("argument", scope)

    def test_instruction_payload_stays_bounded_for_large_scope(self) -> None:
        notes = self.repo / "docs"
        notes.mkdir()
        for index in range(1_800):
            (notes / f"generated-{index:04}.txt").write_text(
                "ordinary text\n",
                encoding="utf-8",
            )

        self.run_runner("--lane", "baseline", "--uncommitted")
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        arguments = capture["arguments"]
        config_value = arguments[arguments.index("-c") + 1]
        scope_text = capture["prompt"].split("<review-scope-json>", 1)[1]
        scope_payload = scope_text.split("</review-scope-json>", 1)[0]
        scope = json.loads(scope_payload)

        self.assertLess(len(config_value.encode()), 32_768)
        self.assertNotIn("changedPaths", scope)
        self.assertNotIn("untrackedReviewedPaths", scope)

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

    def test_refuses_environment_file_before_invoking_codex(self) -> None:
        environment = self.repo / ".env"
        environment.write_text("API_TOKEN=secret\n", encoding="utf-8")

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("excluded sensitive or generated paths", completed.stderr)
        self.assertFalse(self.capture.exists())

    def test_refuses_ignored_environment_file_before_invoking_codex(self) -> None:
        ignore_file = self.repo / ".gitignore"
        ignore_file.write_text(".env\n", encoding="utf-8")
        self.git("add", ".gitignore")
        self.git("commit", "-q", "-m", "ignore environment file")
        environment = self.repo / ".env"
        environment.write_text("API_TOKEN=secret\n", encoding="utf-8")
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("excluded sensitive or generated paths", completed.stderr)
        self.assertFalse(self.capture.exists())

    def test_native_review_does_not_execute_clean_filter(self) -> None:
        attributes = self.repo / ".gitattributes"
        attributes.write_text("*.review filter=unsafe\n", encoding="utf-8")
        reviewed = self.repo / "sample.review"
        reviewed.write_text("before\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "add clean filter fixture")

        clean_filter = self.root / "clean-filter.py"
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

        completed = self.run_runner("--lane", "baseline", "--uncommitted")

        self.assertEqual(completed.returncode, 0)
        self.assertFalse(marker.exists())

    def test_review_child_disables_fsmonitor_hooks_and_git_writes(self) -> None:
        fsmonitor = self.root / "fsmonitor.py"
        fsmonitor.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n",
            encoding="utf-8",
        )
        fsmonitor.chmod(0o755)
        marker = fsmonitor.with_suffix(".invoked")
        self.git("config", "core.fsmonitor", str(fsmonitor))

        self.run_runner("--lane", "baseline", "--base", "main")
        capture = json.loads(self.capture.read_text(encoding="utf-8"))

        self.assertFalse(marker.exists())
        self.assertEqual(capture["fsmonitor"], "false")
        self.assertEqual(capture["hooksPath"], os.devnull)
        self.assertEqual(capture["gitOptionalLocks"], "0")
        self.assertEqual(capture["gitPager"], "cat")

    def test_review_child_preserves_internal_diff_output(self) -> None:
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        self.run_runner("--lane", "baseline", "--uncommitted")
        capture = json.loads(self.capture.read_text(encoding="utf-8"))

        self.assertTrue(capture["diffHasContent"])

    def test_runner_emits_validated_lane_result_not_receipt(self) -> None:
        completed = self.run_runner("--lane", "baseline", "--base", "main")
        output = json.loads(completed.stdout)

        self.assertEqual(
            set(output),
            {"schemaVersion", "lane", "verdict", "summary", "findings"},
        )
        self.assertEqual(output["lane"], "baseline")
        self.assertEqual(output["verdict"], "clean")

    def test_inherited_config_parameters_cannot_restore_fsmonitor(self) -> None:
        fsmonitor = self.root / "fsmonitor.py"
        fsmonitor.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n",
            encoding="utf-8",
        )
        fsmonitor.chmod(0o755)
        marker = fsmonitor.with_suffix(".invoked")

        self.run_runner(
            "--lane",
            "baseline",
            "--base",
            "main",
            environment_overrides={
                "GIT_CONFIG_PARAMETERS": f"'core.fsmonitor={fsmonitor}'",
            },
        )
        capture = json.loads(self.capture.read_text(encoding="utf-8"))

        self.assertFalse(marker.exists())
        self.assertEqual(capture["fsmonitor"], "false")

    def test_review_child_does_not_execute_external_diff(self) -> None:
        external_diff = self.root / "external-diff.py"
        external_diff.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n",
            encoding="utf-8",
        )
        external_diff.chmod(0o755)
        marker = external_diff.with_suffix(".invoked")
        self.git("config", "diff.external", str(external_diff))
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("external diff configuration", completed.stderr)
        self.assertFalse(marker.exists())

    def test_review_child_does_not_execute_inherited_external_diff(self) -> None:
        external_diff = self.root / "external-diff.py"
        external_diff.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n",
            encoding="utf-8",
        )
        external_diff.chmod(0o755)
        marker = external_diff.with_suffix(".invoked")
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        completed = self.run_runner(
            "--lane",
            "baseline",
            "--uncommitted",
            check=False,
            environment_overrides={"GIT_EXTERNAL_DIFF": str(external_diff)},
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("external diff configuration", completed.stderr)
        self.assertFalse(marker.exists())

    def test_review_child_does_not_execute_textconv(self) -> None:
        attributes = self.repo / ".gitattributes"
        attributes.write_text("*.swift diff=unsafe\n", encoding="utf-8")
        self.git("add", ".gitattributes")
        self.git("commit", "-q", "-m", "add diff attributes")
        textconv = self.root / "textconv.py"
        textconv.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import sys\n"
            "Path(__file__).with_suffix('.invoked').write_text('invoked\\n')\n"
            "sys.stdout.buffer.write(Path(sys.argv[1]).read_bytes())\n",
            encoding="utf-8",
        )
        textconv.chmod(0o755)
        marker = textconv.with_suffix(".invoked")
        self.git("config", "diff.unsafe.textconv", str(textconv))
        source = self.repo / "Sources" / "TokiSyncProtocol" / "SnapshotCipher.swift"
        source.write_text("func seal(nonce: String, key: String) {}\n", encoding="utf-8")

        self.run_runner("--lane", "baseline", "--uncommitted")

        self.assertFalse(marker.exists())

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
