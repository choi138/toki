"""Bounded Git command execution for review scope resolution."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


class ScopeError(RuntimeError):
    """Raised when a review scope cannot be resolved safely."""


def decode_git_path(encoded_path: bytes) -> str:
    try:
        return encoded_path.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ScopeError("Git path is not valid UTF-8") from error


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


def changed_paths_without_symlinks(repo: Path, arguments: list[str]) -> list[str]:
    records = [record for record in run_git(repo, arguments).split(b"\0") if record]
    if len(records) % 2 != 0:
        raise ScopeError("Git raw diff has an invalid record count")
    paths: list[str] = []
    for metadata, encoded_path in zip(records[::2], records[1::2]):
        fields = metadata.split()
        if len(fields) != 5 or not fields[0].startswith(b":"):
            raise ScopeError("Git raw diff has invalid metadata")
        path = decode_git_path(encoded_path)
        if fields[1] == b"120000":
            raise ScopeError(f"changed symbolic link cannot be reviewed safely: {path}")
        paths.append(path)
    return paths


def ignored_paths_matching(repo: Path, patterns: list[str]) -> list[str]:
    pathspecs = [f":(glob,icase){pattern}" for pattern in patterns]
    output = run_git(
        repo,
        [
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "-z",
            "--",
            *pathspecs,
        ],
    )
    return [decode_git_path(path) for path in output.split(b"\0") if path]


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
