#!/usr/bin/env python3
"""Resolve a Toki review scope and activate additive specialist lanes."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from lane_registry_validation import RegistryError, validate_registry_contract
from review_scope_git import (
    ScopeError,
    base_scope,
    commit_scope,
    git_root,
    matches_pattern,
    matching_pattern,
    ordered_unique,
    semantic_text,
    uncommitted_scope,
)


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
DEFAULT_REGISTRY = SKILL_DIR / "references" / "lane-registry.json"
LANE_ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def load_registry(path: Path) -> dict[str, Any]:
    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
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
    try:
        validate_registry_contract(registry, skill_dir=SKILL_DIR)
    except RegistryError as error:
        raise ScopeError(str(error)) from error
    return registry


def activate_lanes(
    registry: dict[str, Any],
    changed_paths: list[str],
    changed_semantics: str,
    semantic_inspection_complete: bool,
) -> list[dict[str, Any]]:
    activated: list[dict[str, Any]] = []
    for lane in registry["lanes"]:
        reasons: list[dict[str, Any]] = []
        if lane.get("always") is True:
            reasons.append({"type": "always"})
        elif not semantic_inspection_complete:
            reasons.append({"type": "semantic-fallback"})

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
        changed_paths, untracked_paths, diff, semantic_inspection_complete = (
            uncommitted_scope(root, exclusions)
        )
        scope = {
            "kind": "uncommitted",
            "argument": None,
            "codexArgs": ["--uncommitted"],
        }
    elif arguments.base is not None:
        changed_paths, diff, semantic_inspection_complete = base_scope(
            root,
            arguments.base,
            exclusions,
        )
        untracked_paths = []
        scope = {
            "kind": "base",
            "argument": arguments.base,
            "codexArgs": ["--base", arguments.base],
        }
    else:
        changed_paths, diff, semantic_inspection_complete = commit_scope(
            root,
            arguments.commit,
            exclusions,
        )
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

    activated = activate_lanes(
        registry,
        reviewed_paths,
        semantic_text(diff),
        semantic_inspection_complete,
    )
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
        "semanticInspectionComplete": semantic_inspection_complete,
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
