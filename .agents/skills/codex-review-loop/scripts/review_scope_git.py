"""Git scope resolution for the Toki Codex review loop."""

from __future__ import annotations

import fnmatch
import os
import re
import subprocess
from pathlib import Path
from typing import Iterable

from review_git_process import ScopeError, run_git, run_git_bounded


COMMIT_RE = re.compile(r"^[0-9a-fA-F]{4,64}$")
MAX_SEMANTIC_FILE_BYTES = 1_048_576
MAX_SEMANTIC_TOTAL_BYTES = 4 * MAX_SEMANTIC_FILE_BYTES


def git_root(repo: Path) -> Path:
    output = run_git(repo, ["rev-parse", "--show-toplevel"])
    return Path(output.decode("utf-8", errors="strict").strip()).resolve()


def decode_z(output: bytes) -> list[str]:
    return [os.fsdecode(item) for item in output.split(b"\0") if item]


def normalize_path(path: str) -> str:
    normalized = path
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized.rstrip("/")


def ordered_unique(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        normalized = normalize_path(value)
        if normalized and normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def matches_pattern(path: str, pattern: str) -> bool:
    return fnmatch.fnmatchcase(path, pattern)


def matching_pattern(path: str, patterns: list[str]) -> str | None:
    folded_path = path.casefold()
    return next(
        (
            pattern
            for pattern in patterns
            if fnmatch.fnmatchcase(folded_path, pattern.casefold())
        ),
        None,
    )


def validate_base(repo: Path, base: str) -> None:
    if not base or base.startswith("-") or "\0" in base:
        raise ScopeError("base branch is invalid")
    result = subprocess.run(
        ["git", "check-ref-format", "--branch", base],
        cwd=repo,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise ScopeError(f"base branch is not a valid branch name: {base}")
    run_git(repo, ["rev-parse", "--verify", f"{base}^{{commit}}"])


def validate_commit(repo: Path, commit: str) -> None:
    if COMMIT_RE.fullmatch(commit) is None:
        raise ScopeError("commit must be a hexadecimal SHA")
    run_git(repo, ["rev-parse", "--verify", f"{commit}^{{commit}}"])


def untracked_semantic_diff(
    repo: Path,
    paths: list[str],
    exclusions: list[str],
    max_total_bytes: int = MAX_SEMANTIC_TOTAL_BYTES,
) -> tuple[bytes, bool]:
    changed_content = bytearray()
    inspected_bytes = 0
    repo_root = repo.resolve()
    for path in paths:
        if matching_pattern(path, exclusions) is not None:
            continue
        candidate = repo / path
        if candidate.is_symlink():
            continue
        candidate = candidate.resolve()
        try:
            candidate.relative_to(repo_root)
        except ValueError:
            return bytes(changed_content), False
        if not candidate.is_file():
            continue
        remaining_bytes = max_total_bytes - inspected_bytes
        with candidate.open("rb") as handle:
            file_size = os.fstat(handle.fileno()).st_size
            if (
                file_size > MAX_SEMANTIC_FILE_BYTES
                or file_size > remaining_bytes
            ):
                return bytes(changed_content), False
            content = handle.read(min(MAX_SEMANTIC_FILE_BYTES, remaining_bytes) + 1)
        if (
            len(content) > MAX_SEMANTIC_FILE_BYTES
            or len(content) > remaining_bytes
        ):
            return bytes(changed_content), False
        inspected_bytes += len(content)
        if b"\0" in content:
            continue
        for line in content.splitlines():
            required_bytes = len(line) + 1 + bool(changed_content)
            if len(changed_content) + required_bytes > max_total_bytes:
                return bytes(changed_content), False
            if changed_content:
                changed_content.extend(b"\n")
            changed_content.extend(b"+")
            changed_content.extend(line)
    return bytes(changed_content), True


def uncommitted_scope(
    repo: Path,
    exclusions: list[str],
) -> tuple[list[str], list[str], bytes, bool]:
    unstaged = decode_z(run_git(repo, ["diff", "--no-renames", "--name-only", "-z", "--"]))
    staged = decode_z(
        run_git(repo, ["diff", "--cached", "--no-renames", "--name-only", "-z", "--"])
    )
    untracked_roots = decode_z(
        run_git(repo, ["ls-files", "--others", "--exclude-standard", "--directory", "-z"])
    )
    tracked_paths = ordered_unique([*unstaged, *staged])
    collapsed_untracked = ordered_unique(untracked_roots)
    has_excluded_candidate = any(
        matching_pattern(path, exclusions) is not None
        for path in [*tracked_paths, *collapsed_untracked]
    )
    if has_excluded_candidate:
        untracked = collapsed_untracked
    else:
        untracked = ordered_unique(
            decode_z(run_git(repo, ["ls-files", "--others", "--exclude-standard", "-z"]))
        )
    paths = ordered_unique([*unstaged, *staged, *untracked])
    semantic_content = bytearray()
    semantic_inspection_complete = True
    diff_arguments = [
        ["diff", "--find-renames", "--no-ext-diff", "--unified=0", "--"],
        [
            "diff",
            "--cached",
            "--find-renames",
            "--no-ext-diff",
            "--unified=0",
            "--",
        ],
    ]
    for arguments in diff_arguments:
        separator_bytes = 1 if semantic_content else 0
        remaining_bytes = MAX_SEMANTIC_TOTAL_BYTES - len(semantic_content)
        part, complete = run_git_bounded(
            repo,
            arguments,
            max(remaining_bytes - separator_bytes, 0),
        )
        if part:
            if semantic_content:
                semantic_content.extend(b"\n")
            semantic_content.extend(part)
        if not complete:
            semantic_inspection_complete = False
            break
    if semantic_inspection_complete:
        separator_bytes = 1 if semantic_content else 0
        remaining_bytes = MAX_SEMANTIC_TOTAL_BYTES - len(semantic_content)
        untracked_diff, semantic_inspection_complete = untracked_semantic_diff(
            repo,
            untracked,
            exclusions,
            max(remaining_bytes - separator_bytes, 0),
        )
        if untracked_diff:
            if semantic_content:
                semantic_content.extend(b"\n")
            semantic_content.extend(untracked_diff)
    return (
        paths,
        ordered_unique(untracked),
        bytes(semantic_content),
        semantic_inspection_complete,
    )


def base_scope(repo: Path, base: str) -> tuple[list[str], bytes, bool]:
    validate_base(repo, base)
    range_spec = f"{base}...HEAD"
    paths = decode_z(
        run_git(repo, ["diff", "--no-renames", "--name-only", "-z", range_spec, "--"])
    )
    diff, complete = run_git_bounded(
        repo,
        ["diff", "--find-renames", "--no-ext-diff", "--unified=0", range_spec, "--"],
        MAX_SEMANTIC_TOTAL_BYTES,
    )
    return ordered_unique(paths), diff, complete


def commit_scope(repo: Path, commit: str) -> tuple[list[str], bytes, bool]:
    validate_commit(repo, commit)
    merge_mode = "--diff-merges=first-parent"
    paths = decode_z(
        run_git(
            repo,
            [
                "diff-tree",
                "--root",
                merge_mode,
                "--no-renames",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                commit,
                "--",
            ],
        )
    )
    diff, complete = run_git_bounded(
        repo,
        [
            "show",
            merge_mode,
            "--find-renames",
            "--format=",
            "--no-ext-diff",
            "--unified=0",
            commit,
            "--",
        ],
        MAX_SEMANTIC_TOTAL_BYTES,
    )
    return ordered_unique(paths), diff, complete


def semantic_text(diff: bytes) -> str:
    decoded = diff.decode("utf-8", errors="replace")
    changed_lines = [
        line[1:]
        for line in decoded.splitlines()
        if (line.startswith("+") or line.startswith("-"))
        and not line.startswith("+++")
        and not line.startswith("---")
    ]
    return "\n".join(changed_lines)
