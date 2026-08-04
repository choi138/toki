"""Git scope resolution for the Toki Codex review loop."""

from __future__ import annotations

import os
import re
from pathlib import Path

from review_git_process import (
    ScopeError,
    changed_paths_without_symlinks,
    decode_z,
    display_git_path,
    git_root,
    run_git,
    run_git_bounded,
)
from review_path_matching import (
    matches_pattern,
    matching_pattern,
    ordered_unique,
)
from review_workspace import (
    excluded_workspace_paths,
    workspace_paths_without_symlinks,
)


COMMIT_RE = re.compile(r"^[0-9a-fA-F]{4,64}$")
MAX_SEMANTIC_FILE_BYTES = 1_048_576
MAX_SEMANTIC_TOTAL_BYTES = 4 * MAX_SEMANTIC_FILE_BYTES
SEMANTIC_DIFF_FLAGS = [
    "--find-renames",
    "--no-ext-diff",
    "--no-textconv",
    "--unified=0",
]
BINARY_DIFF_MARKERS = (b"Binary files ", b"GIT binary patch")


def semantic_output_complete(diff: bytes, bounded_complete: bool) -> bool:
    return bounded_complete and not any(marker in diff for marker in BINARY_DIFF_MARKERS)


def validate_base(repo: Path, base: str) -> None:
    if not base or base.startswith("-") or "\0" in base:
        raise ScopeError("base branch is invalid")
    try:
        run_git(repo, ["check-ref-format", "--branch", base])
    except ScopeError as error:
        raise ScopeError(
            f"base branch is not a valid branch name: {display_git_path(base)}"
        ) from error
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
        # A parent component can still be a symbolic link loop, which resolve()
        # reports as RuntimeError before Python 3.13. Treat any unresolvable
        # candidate as incomplete inspection rather than letting it escape.
        try:
            candidate = candidate.resolve()
            candidate.relative_to(repo_root)
        except (OSError, RuntimeError, ValueError):
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
    unstaged = changed_paths_without_symlinks(
        repo,
        ["diff", "--raw", "--no-renames", "-z", "--"],
    )
    staged = changed_paths_without_symlinks(
        repo,
        ["diff", "--cached", "--raw", "--no-renames", "-z", "--"],
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
    workspace_excluded = [
        path
        for path in excluded_workspace_paths(repo, exclusions)
        if not any(
            matching_pattern(root, exclusions) is not None
            and path != root
            and path.startswith(f"{root.rstrip('/')}/")
            for root in untracked
        )
    ]
    paths = ordered_unique([*unstaged, *staged, *untracked, *workspace_excluded])
    semantic_content = bytearray()
    semantic_inspection_complete = True
    diff_arguments = [
        ["diff", *SEMANTIC_DIFF_FLAGS, "--"],
        ["diff", "--cached", *SEMANTIC_DIFF_FLAGS, "--"],
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
        if not semantic_output_complete(part, complete):
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


def base_scope(
    repo: Path,
    base: str,
    exclusions: list[str],
) -> tuple[list[str], bytes, bool]:
    validate_base(repo, base)
    range_spec = f"{base}...HEAD"
    paths = changed_paths_without_symlinks(
        repo,
        ["diff", "--raw", "--no-renames", "-z", range_spec, "--"],
    )
    diff, complete = run_git_bounded(
        repo,
        ["diff", *SEMANTIC_DIFF_FLAGS, range_spec, "--"],
        MAX_SEMANTIC_TOTAL_BYTES,
    )
    return (
        ordered_unique([*paths, *excluded_workspace_paths(repo, exclusions)]),
        diff,
        semantic_output_complete(diff, complete),
    )


def commit_scope(
    repo: Path,
    commit: str,
    exclusions: list[str],
) -> tuple[list[str], bytes, bool]:
    validate_commit(repo, commit)
    merge_mode = "--diff-merges=first-parent"
    paths = changed_paths_without_symlinks(
        repo,
        [
            "diff-tree",
            "--root",
            merge_mode,
            "--raw",
            "--no-renames",
            "--no-commit-id",
            "-r",
            "-z",
            commit,
            "--",
        ],
    )
    diff, complete = run_git_bounded(
        repo,
        [
            "show",
            merge_mode,
            *SEMANTIC_DIFF_FLAGS,
            "--format=",
            commit,
            "--",
        ],
        MAX_SEMANTIC_TOTAL_BYTES,
    )
    return (
        ordered_unique([*paths, *excluded_workspace_paths(repo, exclusions)]),
        diff,
        semantic_output_complete(diff, complete),
    )


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
