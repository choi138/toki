"""Repository path normalization and exclusion matching."""

from __future__ import annotations

import fnmatch
from collections.abc import Iterable


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
