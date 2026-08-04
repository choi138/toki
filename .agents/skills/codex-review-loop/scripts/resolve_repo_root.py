#!/usr/bin/env python3
"""Emit an exact NUL-terminated repository root for the shell runner."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from review_git_process import ScopeError, git_root


def main() -> int:
    try:
        root = git_root(Path(sys.argv[1]))
    except (OSError, RuntimeError, ScopeError) as error:
        print(f"resolve_repo_root.py: {error}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(os.fsencode(root))
    sys.stdout.buffer.write(b"\0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
