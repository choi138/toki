"""Validation for structured Toki review findings."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


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
