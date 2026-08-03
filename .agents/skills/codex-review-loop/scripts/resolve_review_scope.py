#!/usr/bin/env python3
"""Resolve a Toki review scope and activate additive specialist lanes."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
DEFAULT_REGISTRY = SKILL_DIR / "references" / "lane-registry.json"
LANE_ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{4,64}$")


class ScopeError(RuntimeError):
    """Raised when a review scope cannot be resolved safely."""


def run_git(repo: Path, arguments: list[str]) -> bytes:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        command = arguments[0] if arguments else "command"
        raise ScopeError(f"git {command} failed: {detail or 'unknown git error'}")
    return result.stdout


def git_root(repo: Path) -> Path:
    output = run_git(repo, ["rev-parse", "--show-toplevel"])
    return Path(output.decode("utf-8", errors="strict").strip()).resolve()


def decode_z(output: bytes) -> list[str]:
    values: list[str] = []
    for item in output.split(b"\0"):
        if not item:
            continue
        values.append(os.fsdecode(item))
    return values


def normalize_path(path: str) -> str:
    normalized = path.replace("\\", "/")
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
    for pattern in patterns:
        if matches_pattern(path, pattern):
            return pattern
    return None


def load_registry(path: Path) -> dict[str, Any]:
    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ScopeError(f"cannot load lane registry: {error}") from error

    if not isinstance(registry, dict) or registry.get("version") != "1.0":
        raise ScopeError("lane registry must be a version 1.0 object")
    exclusions = registry.get("pathExclusions")
    lanes = registry.get("lanes")
    if not isinstance(exclusions, list) or not all(isinstance(item, str) for item in exclusions):
        raise ScopeError("lane registry pathExclusions must be a string array")
    if not isinstance(lanes, list) or not lanes:
        raise ScopeError("lane registry lanes must be a non-empty array")

    seen_ids: set[str] = set()
    for lane in lanes:
        if not isinstance(lane, dict):
            raise ScopeError("every lane must be an object")
        lane_id = lane.get("id")
        if not isinstance(lane_id, str) or LANE_ID_RE.fullmatch(lane_id) is None:
            raise ScopeError(f"invalid lane id: {lane_id!r}")
        if lane_id in seen_ids:
            raise ScopeError(f"duplicate lane id: {lane_id}")
        seen_ids.add(lane_id)

        for field in ("pathPatterns", "semanticPatterns", "verificationProfiles"):
            value = lane.get(field)
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ScopeError(f"{lane_id}.{field} must be a string array")
        for pattern in lane["semanticPatterns"]:
            try:
                re.compile(pattern)
            except re.error as error:
                raise ScopeError(f"invalid semantic pattern for {lane_id}: {error}") from error

        prompt = lane.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            raise ScopeError(f"{lane_id}.prompt must be a non-empty string")
        prompt_path = (SKILL_DIR / prompt).resolve()
        try:
            prompt_path.relative_to(SKILL_DIR)
        except ValueError as error:
            raise ScopeError(f"{lane_id}.prompt escapes the skill directory") from error
        if not prompt_path.is_file():
            raise ScopeError(f"lane prompt does not exist: {prompt}")

        execution = lane.get("execution")
        if (
            not isinstance(execution, dict)
            or type(execution.get("replicas")) is not int
            or execution["replicas"] < 1
            or type(execution.get("adjudication")) is not bool
        ):
            raise ScopeError(f"{lane_id}.execution is invalid")

    if "baseline" not in seen_ids:
        raise ScopeError("lane registry must include baseline")
    return registry


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


def uncommitted_scope(
    repo: Path,
    exclusions: list[str],
) -> tuple[list[str], list[str], bytes]:
    unstaged = decode_z(run_git(repo, ["diff", "--name-only", "-z", "--"]))
    staged = decode_z(run_git(repo, ["diff", "--cached", "--name-only", "-z", "--"]))
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
    diff = b"\n".join(
        [
            run_git(repo, ["diff", "--no-ext-diff", "--unified=0", "--"]),
            run_git(repo, ["diff", "--cached", "--no-ext-diff", "--unified=0", "--"]),
        ]
    )
    return paths, ordered_unique(untracked), diff


def base_scope(repo: Path, base: str) -> tuple[list[str], bytes]:
    validate_base(repo, base)
    range_spec = f"{base}...HEAD"
    paths = decode_z(run_git(repo, ["diff", "--name-only", "-z", range_spec, "--"]))
    diff = run_git(repo, ["diff", "--no-ext-diff", "--unified=0", range_spec, "--"])
    return ordered_unique(paths), diff


def commit_scope(repo: Path, commit: str) -> tuple[list[str], bytes]:
    validate_commit(repo, commit)
    paths = decode_z(
        run_git(
            repo,
            ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", commit, "--"],
        )
    )
    diff = run_git(repo, ["show", "--format=", "--no-ext-diff", "--unified=0", commit, "--"])
    return ordered_unique(paths), diff


def semantic_text(diff: bytes) -> str:
    decoded = diff.decode("utf-8", errors="replace")
    changed_lines: list[str] = []
    for line in decoded.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+") or line.startswith("-"):
            changed_lines.append(line[1:])
    return "\n".join(changed_lines)


def activate_lanes(
    registry: dict[str, Any],
    changed_paths: list[str],
    changed_semantics: str,
) -> list[dict[str, Any]]:
    activated: list[dict[str, Any]] = []
    for lane in registry["lanes"]:
        reasons: list[dict[str, Any]] = []
        if lane.get("always") is True:
            reasons.append({"type": "always"})

        path_hits = [
            path
            for path in changed_paths
            if any(matches_pattern(path, pattern) for pattern in lane["pathPatterns"])
        ]
        if path_hits:
            reasons.append({"type": "path", "matches": path_hits})

        semantic_hits = [
            pattern
            for pattern in lane["semanticPatterns"]
            if re.search(pattern, changed_semantics) is not None
        ]
        if semantic_hits:
            reasons.append(
                {
                    "type": "semantic",
                    "matchedPatternCount": len(semantic_hits),
                }
            )

        if reasons:
            activated.append(
                {
                    "id": lane["id"],
                    "prompt": lane["prompt"],
                    "verificationProfiles": lane["verificationProfiles"],
                    "execution": lane["execution"],
                    "reasons": reasons,
                }
            )
    return activated


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve a git review scope and select Toki review lanes."
    )
    parser.add_argument("--repo", default=".", help="Path inside the target git repository.")
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help="Lane registry path.",
    )
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output.")
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument("--uncommitted", action="store_true")
    scope.add_argument("--base")
    scope.add_argument("--commit")
    return parser.parse_args()


def resolve(arguments: argparse.Namespace) -> dict[str, Any]:
    root = git_root(Path(arguments.repo).resolve())
    registry = load_registry(arguments.registry.resolve())
    exclusions: list[str] = registry["pathExclusions"]
    if arguments.uncommitted:
        changed_paths, untracked_paths, diff = uncommitted_scope(root, exclusions)
        scope = {
            "kind": "uncommitted",
            "argument": None,
            "codexArgs": ["--uncommitted"],
        }
    elif arguments.base is not None:
        changed_paths, diff = base_scope(root, arguments.base)
        untracked_paths = []
        scope = {
            "kind": "base",
            "argument": arguments.base,
            "codexArgs": ["--base", arguments.base],
        }
    else:
        changed_paths, diff = commit_scope(root, arguments.commit)
        untracked_paths = []
        scope = {
            "kind": "commit",
            "argument": arguments.commit,
            "codexArgs": ["--commit", arguments.commit],
        }

    excluded_by_pattern: Counter[str] = Counter()
    reviewed_paths: list[str] = []
    for path in changed_paths:
        pattern = matching_pattern(path, exclusions)
        if pattern is None:
            reviewed_paths.append(path)
        else:
            excluded_by_pattern[pattern] += 1

    activated = activate_lanes(registry, reviewed_paths, semantic_text(diff))
    verification_profiles = ordered_unique(
        profile
        for lane in activated
        for profile in lane["verificationProfiles"]
    )
    blocking_reasons: list[str] = []
    if excluded_by_pattern:
        blocking_reasons.append(
            "The review scope contains excluded sensitive or generated paths that Codex cannot "
            "safely omit."
        )

    return {
        "schemaVersion": "1.0",
        "scope": scope,
        "hasChanges": bool(changed_paths),
        "safeToReview": not excluded_by_pattern,
        "changedPaths": reviewed_paths,
        "untrackedReviewedPaths": [
            path for path in untracked_paths if matching_pattern(path, exclusions) is None
        ],
        "excludedChanges": [
            {"pattern": pattern, "count": count}
            for pattern, count in sorted(excluded_by_pattern.items())
        ],
        "blockingReasons": blocking_reasons,
        "activatedLanes": activated,
        "verificationProfiles": verification_profiles,
    }


def main() -> int:
    arguments = parse_arguments()
    try:
        result = resolve(arguments)
    except (OSError, ScopeError) as error:
        print(f"resolve_review_scope.py: {error}", file=sys.stderr)
        return 2

    json.dump(
        result,
        sys.stdout,
        ensure_ascii=False,
        indent=2 if arguments.pretty else None,
        separators=None if arguments.pretty else (",", ":"),
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
