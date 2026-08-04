"""Bounded workspace inventory for safe native review."""

from __future__ import annotations

import os
from pathlib import Path

from review_git_process import (
    ScopeError,
    decode_git_path,
    display_git_path,
    run_git_bounded,
)
from review_path_matching import matching_pattern


MAX_PATH_INVENTORY_BYTES = 8 * 1_048_576


def bounded_path_output(repo: Path, arguments: list[str]) -> bytes:
    output, complete = run_git_bounded(repo, arguments, MAX_PATH_INVENTORY_BYTES)
    if not complete:
        raise ScopeError("Git path inventory exceeds the safe byte limit")
    return output


def safe_symlink_target(repo: Path, path: str) -> str | None:
    candidate = repo / path
    if not candidate.is_symlink():
        return None
    try:
        target = candidate.resolve(strict=True).relative_to(repo.resolve())
    except (OSError, RuntimeError, ValueError) as error:
        raise ScopeError(
            "workspace symbolic link cannot be reviewed safely: "
            f"{display_git_path(path)}"
        ) from error
    if not target.parts or target.parts[0] == ".git":
        raise ScopeError(
            "workspace symbolic link cannot be reviewed safely: "
            f"{display_git_path(path)}"
        )
    return target.as_posix()


def expand_workspace_paths(repo: Path, paths: list[str]) -> list[str]:
    pending = list(paths)
    expanded: list[str] = []
    seen: set[str] = set()
    inventory_bytes = 0
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        if path:
            try:
                inventory_bytes += len(path.encode("utf-8", errors="strict")) + 1
            except UnicodeEncodeError as error:
                raise ScopeError("Git path is not valid UTF-8") from error
            if inventory_bytes > MAX_PATH_INVENTORY_BYTES:
                raise ScopeError("workspace path inventory exceeds the safe byte limit")
        candidate = repo / path
        is_symlink = candidate.is_symlink()
        is_directory = candidate.is_dir()
        if path and (is_symlink or not is_directory):
            expanded.append(path)
        if is_symlink or not is_directory:
            continue
        try:
            entries = sorted(candidate.iterdir(), key=lambda entry: os.fsencode(entry.name))
        except OSError as error:
            raise ScopeError(
                f"cannot inspect workspace directory: {display_git_path(path)}"
            ) from error
        if path and any(entry.name == ".git" for entry in entries):
            raise ScopeError(
                "embedded Git repository cannot be reviewed safely: "
                f"{display_git_path(path)}"
            )
        pending.extend(
            entry.relative_to(repo).as_posix()
            for entry in entries
            if entry.name != ".git"
        )
    return expanded


def workspace_paths_without_symlinks(repo: Path) -> list[str]:
    tracked_output = bounded_path_output(repo, ["ls-files", "--stage", "-z"])
    tracked_paths: list[str] = []
    symlink_aliases: list[tuple[str, str]] = []
    for record in tracked_output.split(b"\0"):
        if not record:
            continue
        metadata, separator, encoded_path = record.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise ScopeError("Git tracked path inventory has invalid metadata")
        path = decode_git_path(encoded_path)
        if fields[0] == b"160000":
            raise ScopeError(
                f"workspace submodule cannot be reviewed safely: {display_git_path(path)}"
            )
        if fields[0] == b"120000":
            target = safe_symlink_target(repo, path)
            if target is None:
                raise ScopeError(
                    "workspace symbolic link cannot be reviewed safely: "
                    f"{display_git_path(path)}"
                )
            symlink_aliases.append((path, target))
        tracked_paths.append(path)

    filesystem_paths = expand_workspace_paths(repo, [""])
    for path in filesystem_paths:
        target = safe_symlink_target(repo, path)
        if target is not None:
            symlink_aliases.append((path, target))
    workspace_paths = list(
        dict.fromkeys(
            [
                *tracked_paths,
                *filesystem_paths,
                *(target for _, target in symlink_aliases),
            ]
        )
    )
    alias_paths = [
        f"{alias}{path.removeprefix(target)}"
        for path in workspace_paths
        for alias, target in symlink_aliases
        if path == target or path.startswith(f"{target}/")
    ]
    return list(dict.fromkeys([*workspace_paths, *alias_paths]))


def excluded_workspace_paths(repo: Path, exclusions: list[str]) -> list[str]:
    return [
        path
        for path in workspace_paths_without_symlinks(repo)
        if matching_pattern(path, exclusions) is not None
    ]
