"""Bounded Git command execution for review scope resolution."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


FILTER_KEY_RE = re.compile(
    r"^filter\.(.+)\.(?:clean|smudge|process|required)$",
    re.IGNORECASE,
)
FILTER_OVERRIDES = (
    ("clean", "cat"),
    ("smudge", "cat"),
    ("process", ""),
    ("required", "false"),
)


class ScopeError(RuntimeError):
    """Raised when a review scope cannot be resolved safely."""


def decode_git_path(encoded_path: bytes) -> str:
    try:
        return encoded_path.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ScopeError("Git path is not valid UTF-8") from error


def git_environment_without_filters(repo: Path) -> dict[str, str]:
    environment = dict(os.environ)
    result = subprocess.run(
        [
            "git",
            "config",
            "--null",
            "--name-only",
            "--get-regexp",
            r"^filter\..*\.(clean|smudge|process|required)$",
        ],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )
    if result.returncode not in {0, 1}:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ScopeError(f"git config failed: {detail or 'unknown git error'}")
    drivers: list[str] = []
    for encoded_key in result.stdout.split(b"\0"):
        if not encoded_key:
            continue
        key = decode_git_path(encoded_key)
        match = FILTER_KEY_RE.fullmatch(key)
        if match is not None and match.group(1) not in drivers:
            drivers.append(match.group(1))
    try:
        count = int(environment.get("GIT_CONFIG_COUNT", "0"))
    except ValueError as error:
        raise ScopeError("GIT_CONFIG_COUNT must be an integer") from error
    for driver in drivers:
        for suffix, value in FILTER_OVERRIDES:
            environment[f"GIT_CONFIG_KEY_{count}"] = f"filter.{driver}.{suffix}"
            environment[f"GIT_CONFIG_VALUE_{count}"] = value
            count += 1
    environment["GIT_CONFIG_COUNT"] = str(count)
    return environment


def run_git(repo: Path, arguments: list[str]) -> bytes:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=git_environment_without_filters(repo),
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
            env=git_environment_without_filters(repo),
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
