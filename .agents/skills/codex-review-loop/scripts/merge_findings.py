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

from finding_validation import FindingError, PRIORITY_RANK, load_result


WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)


def normalized_words(value: str) -> set[str]:
    return set(WORD_RE.findall(value.casefold()))


def similarity(left: str, right: str) -> float:
    left_words = normalized_words(left)
    right_words = normalized_words(right)
    phrase_similarity = difflib.SequenceMatcher(
        None,
        left.casefold(),
        right.casefold(),
    ).ratio()
    if not left_words or not right_words:
        return phrase_similarity
    token_similarity = len(left_words & right_words) / len(left_words | right_words)
    return max(token_similarity, phrase_similarity)


def ranges_overlap(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return left["startLine"] <= right["endLine"] and right["startLine"] <= left["endLine"]


def is_duplicate(group: dict[str, Any], finding: dict[str, Any]) -> bool:
    if group["file"] != finding["file"] or not ranges_overlap(group, finding):
        return False
    return similarity(group["rootCause"], finding["rootCause"]) >= 0.65


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
    if not root:
        root = group["rootCause"].casefold().strip()
    identity = f"{group['file']}:{group['startLine']}:{group['endLine']}:{root}"
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:12]
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
    group["occurrences"] += 1
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
