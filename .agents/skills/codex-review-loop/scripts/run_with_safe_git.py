#!/usr/bin/env python3
"""Run a review child with repository-selected Git filters disabled."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from review_git_process import ScopeError, git_environment_without_filters


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print(
            "run_with_safe_git.py: usage: REPO -- COMMAND [ARG ...]",
            file=sys.stderr,
        )
        return 2
    repo = Path(sys.argv[1]).resolve()
    environment = git_environment_without_filters(repo)
    environment["TOKI_REVIEW_CHILD"] = "1"
    result = subprocess.run(
        sys.argv[3:],
        cwd=repo,
        env=environment,
        check=False,
    )
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ScopeError) as error:
        print(f"run_with_safe_git.py: {error}", file=sys.stderr)
        raise SystemExit(2) from error
