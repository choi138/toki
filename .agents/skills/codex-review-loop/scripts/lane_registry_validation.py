"""Invariant validation for Codex review lane registries."""

from __future__ import annotations

from pathlib import Path
from typing import Any


VERIFICATION_PROFILES = frozenset(
    {
        "common",
        "swift-package",
        "hub",
        "app-format",
        "app-lint",
        "app-tests",
        "project",
    }
)


class RegistryError(ValueError):
    """Raised when a lane registry violates the review contract."""


def validate_registry_contract(
    registry: dict[str, Any],
    *,
    skill_dir: Path,
) -> None:
    lanes_dir = (skill_dir / "references" / "lanes").resolve()
    baseline: dict[str, Any] | None = None
    for lane in registry["lanes"]:
        lane_id = lane["id"]
        if lane_id == "baseline" and lane.get("always") is not True:
            raise RegistryError("baseline lane must be always-on")
        if type(lane.get("always")) is not bool:
            raise RegistryError(f"{lane_id}.always must be a boolean")
        if lane_id == "baseline":
            baseline = lane

        profiles = lane["verificationProfiles"]
        if (
            not profiles
            or len(profiles) != len(set(profiles))
            or not set(profiles).issubset(VERIFICATION_PROFILES)
        ):
            raise RegistryError(f"{lane_id}.verificationProfiles is invalid")

        execution = lane["execution"]
        if (
            set(execution) != {"replicas", "adjudication"}
            or type(execution["replicas"]) is not int
            or execution["replicas"] != 1
            or execution["adjudication"] is not False
        ):
            raise RegistryError(f"{lane_id}.execution is unsupported")

        prompt = lane["prompt"]
        if Path(prompt).is_absolute() or not prompt.endswith(".md"):
            raise RegistryError(f"{lane_id}.prompt must be a relative lane Markdown path")
        prompt_path = (skill_dir / prompt).resolve()
        try:
            prompt_path.relative_to(lanes_dir)
            prompt_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError, ValueError) as error:
            raise RegistryError(f"{lane_id}.prompt is not a readable lane prompt") from error

    if baseline is None or baseline["always"] is not True:
        raise RegistryError("baseline lane must be always-on")
