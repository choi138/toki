"""Bounded Git command execution for review scope resolution."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


FILTER_KEY_RE = re.compile(
    r"^filter\.(.+)\.(?:clean|smudge|process|required)$",
    re.IGNORECASE,
)
DIFF_KEY_RE = re.compile(
    r"^diff\.(.+)\.(command|textconv)$",
    re.IGNORECASE,
)
SAFE_CAT = shutil.which("cat", path=os.defpath) or "/bin/cat"
TRUSTED_GIT = shutil.which("git", path=os.defpath) or "/usr/bin/git"
FILTER_OVERRIDES = (
    ("clean", SAFE_CAT),
    ("smudge", SAFE_CAT),
    ("process", ""),
    ("required", "false"),
)
DIFF_OVERRIDES = (
    ("textconv", SAFE_CAT),
)
STATIC_OVERRIDES = (
    ("core.fsmonitor", "false"),
    ("core.hooksPath", os.devnull),
)
UNSAFE_GIT_ENVIRONMENT_KEYS = (
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_PARAMETERS",
    "GIT_DIR",
    "GIT_EXEC_PATH",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
)


class ScopeError(RuntimeError):
    """Raised when a review scope cannot be resolved safely."""


def display_git_path(path: str) -> str:
    return ascii(path)


def decode_git_path(encoded_path: bytes) -> str:
    try:
        return encoded_path.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ScopeError("Git path is not valid UTF-8") from error


def decode_z(output: bytes) -> list[str]:
    return [
        decode_git_path(item)
        for item in output.split(b"\0")
        if item
    ]


def git_environment_without_filters(repo: Path) -> dict[str, str]:
    environment = dict(os.environ)
    has_external_diff = "GIT_EXTERNAL_DIFF" in environment
    environment.pop("GIT_EXTERNAL_DIFF", None)
    for key in UNSAFE_GIT_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    result = subprocess.run(
        [
            TRUSTED_GIT,
            "config",
            "--null",
            "--name-only",
            "--get-regexp",
            (
                r"^(filter\..*\.(clean|smudge|process|required)"
                r"|diff\..*\.(command|textconv)|diff\.external)$"
            ),
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
    filter_drivers: list[str] = []
    diff_drivers: list[str] = []
    for encoded_key in result.stdout.split(b"\0"):
        if not encoded_key:
            continue
        key = decode_git_path(encoded_key)
        if key.casefold() == "diff.external":
            has_external_diff = True
            continue
        filter_match = FILTER_KEY_RE.fullmatch(key)
        if filter_match is not None and filter_match.group(1) not in filter_drivers:
            filter_drivers.append(filter_match.group(1))
        diff_match = DIFF_KEY_RE.fullmatch(key)
        if diff_match is not None:
            if diff_match.group(2).casefold() == "command":
                has_external_diff = True
            elif diff_match.group(1) not in diff_drivers:
                diff_drivers.append(diff_match.group(1))
    if has_external_diff:
        raise ScopeError("external diff configuration cannot be reviewed safely")
    try:
        count = int(environment.get("GIT_CONFIG_COUNT", "0"))
    except ValueError as error:
        raise ScopeError("GIT_CONFIG_COUNT must be an integer") from error

    def add_override(key: str, value: str) -> None:
        nonlocal count
        environment[f"GIT_CONFIG_KEY_{count}"] = key
        environment[f"GIT_CONFIG_VALUE_{count}"] = value
        count += 1

    for key, value in STATIC_OVERRIDES:
        add_override(key, value)
    for driver in filter_drivers:
        for suffix, value in FILTER_OVERRIDES:
            add_override(f"filter.{driver}.{suffix}", value)
    for driver in diff_drivers:
        for suffix, value in DIFF_OVERRIDES:
            add_override(f"diff.{driver}.{suffix}", value)

    environment["GIT_CONFIG_COUNT"] = str(count)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    environment["PAGER"] = "cat"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    safe_path_entries = [str(Path(TRUSTED_GIT).parent)]
    candidate_path = environment.pop(
        "TOKI_REVIEW_ORIGINAL_PATH",
        environment.get("PATH", ""),
    )
    for entry in candidate_path.split(os.pathsep):
        if not entry or not Path(entry).is_absolute():
            continue
        try:
            resolved = Path(entry).resolve()
            resolved.relative_to(repo.resolve())
        except ValueError:
            if str(resolved) not in safe_path_entries:
                safe_path_entries.append(str(resolved))
        except (OSError, RuntimeError):
            # A PATH entry that cannot be resolved, including a symbolic link
            # loop on Python before 3.13, is dropped rather than trusted.
            continue
    environment["PATH"] = os.pathsep.join(safe_path_entries)
    environment["GIT_NO_LAZY_FETCH"] = "1"
    return environment


def run_git(repo: Path, arguments: list[str]) -> bytes:
    result = subprocess.run(
        [TRUSTED_GIT, *arguments],
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


def git_root(repo: Path) -> Path:
    output = run_git(repo, ["rev-parse", "--show-toplevel"])
    root = output.decode("utf-8", errors="strict").removesuffix("\n").removesuffix("\r")
    try:
        return Path(root).resolve()
    except (OSError, RuntimeError) as error:
        raise ScopeError("repository root cannot be resolved safely") from error


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
        modes = {fields[0].removeprefix(b":"), fields[1]}
        if b"120000" in modes:
            raise ScopeError(
                f"changed symbolic link cannot be reviewed safely: {display_git_path(path)}"
            )
        if b"160000" in modes:
            raise ScopeError(
                f"changed submodule cannot be reviewed safely: {display_git_path(path)}"
            )
        paths.append(path)
    return paths


def run_git_bounded(
    repo: Path,
    arguments: list[str],
    max_bytes: int,
) -> tuple[bytes, bool]:
    with tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(
            [TRUSTED_GIT, *arguments],
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
