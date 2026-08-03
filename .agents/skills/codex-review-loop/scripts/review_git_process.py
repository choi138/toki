"""Bounded Git command execution for review scope resolution."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


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


def run_git_bounded(
    repo: Path,
    arguments: list[str],
    max_bytes: int,
) -> tuple[bytes, bool]:
    with tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(
            ["git", *arguments],
            cwd=repo,
            stdout=subprocess.PIPE,
            stderr=stderr,
        )
        if process.stdout is None:
            raise ScopeError("git command did not expose stdout")
        output = process.stdout.read(max_bytes + 1)
        complete = len(output) <= max_bytes
        if not complete and process.poll() is None:
            process.terminate()
        return_code = process.wait()
        process.stdout.close()
        if complete and return_code != 0:
            stderr.seek(0)
            detail = stderr.read().decode("utf-8", errors="replace").strip()
            command = arguments[0] if arguments else "command"
            raise ScopeError(f"git {command} failed: {detail or 'unknown git error'}")
    return output[:max_bytes], complete
