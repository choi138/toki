#!/usr/bin/env python3
"""Validate and conservatively merge structured Toki review findings."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


TOP_LEVEL_FIELDS = {"schemaVersion", "lane", "verdict", "summary", "findings"}
FINDING_FIELDS = {
    "priority",
    "confidence",
    "title",
    "file",
    "startLine",
    "endLine",
    "rootCause",
    "evidence",
    "impact",
    "suggestedFix",
    "verification",
}
PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
LANE_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
WORD_RE = re.compile(r"[a-z0-9]+")


class FindingError(ValueError):
    """Raised for malformed lane output."""


def require_non_empty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FindingError(f"{field} must be a non-empty string")
    return value.strip()


def validate_repo_path(value: Any) -> str:
    path = require_non_empty_string(value, "file")
    if path.startswith("/") or "\\" in path:
        raise FindingError("file must be a repository-relative POSIX path")
    parts = path.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise FindingError(
            "file must be repository-relative without empty, current, or parent path segments"
        )
    return path


def validate_lane_result(data: Any, expected_lane: str | None = None) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise FindingError("lane result must be an object")
    if set(data) != TOP_LEVEL_FIELDS:
        missing = sorted(TOP_LEVEL_FIELDS - set(data))
        extra = sorted(set(data) - TOP_LEVEL_FIELDS)
        raise FindingError(f"lane result fields mismatch; missing={missing} extra={extra}")
    if data["schemaVersion"] != "1.0":
        raise FindingError("schemaVersion must be 1.0")

    lane = require_non_empty_string(data["lane"], "lane")
    if LANE_RE.fullmatch(lane) is None:
        raise FindingError("lane has an invalid format")
    if expected_lane is not None and lane != expected_lane:
        raise FindingError(f"expected lane {expected_lane}, got {lane}")

    verdict = data["verdict"]
    if verdict not in {"clean", "findings"}:
        raise FindingError("verdict must be clean or findings")
    require_non_empty_string(data["summary"], "summary")
    findings = data["findings"]
    if not isinstance(findings, list):
        raise FindingError("findings must be an array")
    if (verdict == "clean") != (len(findings) == 0):
        raise FindingError("clean requires no findings and findings requires at least one")

    for index, finding in enumerate(findings):
        prefix = f"findings[{index}]"
        if not isinstance(finding, dict):
            raise FindingError(f"{prefix} must be an object")
        if set(finding) != FINDING_FIELDS:
            missing = sorted(FINDING_FIELDS - set(finding))
            extra = sorted(set(finding) - FINDING_FIELDS)
            raise FindingError(f"{prefix} fields mismatch; missing={missing} extra={extra}")
        if finding["priority"] not in PRIORITY_RANK:
            raise FindingError(f"{prefix}.priority is invalid")
        confidence = finding["confidence"]
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
            raise FindingError(f"{prefix}.confidence must be numeric")
        if not 0 <= confidence <= 1:
            raise FindingError(f"{prefix}.confidence must be between 0 and 1")
        for field in ("title", "rootCause", "evidence", "impact", "suggestedFix"):
            require_non_empty_string(finding[field], f"{prefix}.{field}")
        validate_repo_path(finding["file"])
        start = finding["startLine"]
        end = finding["endLine"]
        if type(start) is not int or start < 1:
            raise FindingError(f"{prefix}.startLine must be a positive integer")
        if type(end) is not int or end < start:
            raise FindingError(f"{prefix}.endLine must be an integer at least startLine")
        verification = finding["verification"]
        if (
            not isinstance(verification, list)
            or not verification
            or not all(isinstance(item, str) and item.strip() for item in verification)
        ):
            raise FindingError(f"{prefix}.verification must contain non-empty strings")
    return data


def load_result(path: Path, expected_lane: str | None = None) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FindingError(f"cannot load {path}: {error}") from error
    return validate_lane_result(data, expected_lane)


def normalized_words(value: str) -> set[str]:
    return set(WORD_RE.findall(value.casefold()))


def similarity(left: str, right: str) -> float:
    left_words = normalized_words(left)
    right_words = normalized_words(right)
    if not left_words or not right_words:
        return 0
    token_similarity = len(left_words & right_words) / len(left_words | right_words)
    phrase_similarity = difflib.SequenceMatcher(
        None,
        left.casefold(),
        right.casefold(),
    ).ratio()
    return max(token_similarity, phrase_similarity)


def ranges_overlap(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return left["startLine"] <= right["endLine"] and right["startLine"] <= left["endLine"]


def is_duplicate(group: dict[str, Any], finding: dict[str, Any]) -> bool:
    if group["file"] != finding["file"] or not ranges_overlap(group, finding):
        return False
    return (
        similarity(group["rootCause"], finding["rootCause"]) >= 0.65
        or similarity(group["title"], finding["title"]) >= 0.65
    )


def ordered_unique(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def finding_id(group: dict[str, Any]) -> str:
    root = " ".join(sorted(normalized_words(group["rootCause"])))
    digest = hashlib.sha256(f"{group['file']}:{root}".encode("utf-8")).hexdigest()[:12]
    return f"RF-{digest}"


def new_group(lane: str, finding: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": "",
        "lanes": [lane],
        "priority": finding["priority"],
        "priorityOpinions": {lane: finding["priority"]},
        "confidence": finding["confidence"],
        "title": finding["title"].strip(),
        "file": finding["file"],
        "startLine": finding["startLine"],
        "endLine": finding["endLine"],
        "rootCause": finding["rootCause"].strip(),
        "evidence": [{"lane": lane, "text": finding["evidence"].strip()}],
        "impact": finding["impact"].strip(),
        "suggestedFix": finding["suggestedFix"].strip(),
        "verification": ordered_unique(item.strip() for item in finding["verification"]),
        "status": "proposed",
        "occurrences": 1,
    }


def merge_into(group: dict[str, Any], lane: str, finding: dict[str, Any]) -> None:
    current_rank = PRIORITY_RANK[group["priority"]]
    incoming_rank = PRIORITY_RANK[finding["priority"]]
    use_incoming = incoming_rank < current_rank or (
        incoming_rank == current_rank and finding["confidence"] > group["confidence"]
    )
    if use_incoming:
        for field in ("title", "rootCause", "impact", "suggestedFix"):
            group[field] = finding[field].strip()

    group["priority"] = min(
        (group["priority"], finding["priority"]),
        key=lambda priority: PRIORITY_RANK[priority],
    )
    group["confidence"] = max(group["confidence"], finding["confidence"])
    group["startLine"] = min(group["startLine"], finding["startLine"])
    group["endLine"] = max(group["endLine"], finding["endLine"])
    group["lanes"] = ordered_unique([*group["lanes"], lane])
    group["priorityOpinions"][lane] = finding["priority"]
    evidence = {"lane": lane, "text": finding["evidence"].strip()}
    if evidence not in group["evidence"]:
        group["evidence"].append(evidence)
    group["verification"] = ordered_unique(
        [*group["verification"], *(item.strip() for item in finding["verification"])]
    )


def merge_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    groups: list[dict[str, Any]] = []
    lane_results: list[dict[str, Any]] = []
    for result in results:
        lane = result["lane"]
        lane_results.append(
            {
                "lane": lane,
                "verdict": result["verdict"],
                "summary": result["summary"].strip(),
            }
        )
        for finding in result["findings"]:
            duplicate = next((group for group in groups if is_duplicate(group, finding)), None)
            if duplicate is None:
                groups.append(new_group(lane, finding))
            else:
                merge_into(duplicate, lane, finding)

    for group in groups:
        group["id"] = finding_id(group)
    groups.sort(
        key=lambda group: (
            PRIORITY_RANK[group["priority"]],
            group["file"],
            group["startLine"],
            group["id"],
        )
    )

    conflicts: list[dict[str, Any]] = []
    for group in groups:
        ranks = [PRIORITY_RANK[value] for value in group["priorityOpinions"].values()]
        if ranks and max(ranks) - min(ranks) >= 2:
            conflicts.append(
                {
                    "id": group["id"],
                    "priorityOpinions": group["priorityOpinions"],
                    "reason": "Contributing lanes differ by at least two priority levels.",
                }
            )

    return {
        "schemaVersion": "1.0",
        "verdict": "findings" if groups else "clean",
        "laneResults": lane_results,
        "findings": groups,
        "conflicts": conflicts,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate", help="Validate one lane result.")
    validate_parser.add_argument("--lane", help="Require this lane ID.")
    validate_parser.add_argument("result", type=Path)

    merge_parser = subparsers.add_parser("merge", help="Merge validated lane results.")
    merge_parser.add_argument("results", nargs="+", type=Path)
    merge_parser.add_argument("--compact", action="store_true")
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "validate":
            result = load_result(arguments.result, arguments.lane)
            output: dict[str, Any] = {
                "valid": True,
                "lane": result["lane"],
                "findingCount": len(result["findings"]),
            }
            compact = True
        else:
            results = [load_result(path) for path in arguments.results]
            lanes = [result["lane"] for result in results]
            if len(lanes) != len(set(lanes)):
                raise FindingError("each lane may appear only once in a merge")
            output = merge_results(results)
            compact = arguments.compact
    except FindingError as error:
        print(f"merge_findings.py: {error}", file=sys.stderr)
        return 2

    json.dump(
        output,
        sys.stdout,
        ensure_ascii=False,
        indent=None if compact else 2,
        separators=(",", ":") if compact else None,
        sort_keys=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
