# Verification Profiles

Run verification only after the user authorizes fixes. During review-only mode,
use read-only inspection commands and do not run `xcodegen generate` or other
commands that rewrite files.

## Profiles

### common

~~~bash
git diff --check
~~~

### swift-package

Use for root package, protocol, reader, durable-storage, and Agent changes:

~~~bash
swift test
~~~

For broad Agent changes, also build the release product:

~~~bash
swift build -c release --product toki-agent
~~~

### hub

~~~bash
swift test --package-path TokiHub
swift build --package-path TokiHub -c release --product toki-hub
~~~

### app-format

~~~bash
swiftformat . --lint
~~~

### app-lint

~~~bash
swiftlint lint --strict --quiet
~~~

### app-tests

~~~bash
xcodebuild test \
  -project Toki.xcodeproj \
  -scheme Toki \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
~~~

### project

After an explicitly approved `project.yml` or resource change:

~~~bash
xcodegen generate
git diff -- Toki.xcodeproj
~~~

Include the generated project diff with the source configuration change.

### review-loop-scripts

For changes to this skill's own scripts:

~~~bash
python3 -m unittest discover -s .agents/skills/codex-review-loop/tests -p 'test_*.py'
~~~

The runner narrows `PATH` to the platform default, so it executes
`/usr/bin/python3`, which can be much older than the ambient `python3` that runs
these tests. The tests therefore invoke scripts through `RUNNER_PYTHON`, resolved
with `shutil.which("python3", path=os.defpath)`, so a failure that only appears
on the runner's interpreter is still caught. Keep the scripts working on that
interpreter, and never assert version-specific behavior of standard-library
calls without forcing it, as `tests/test_path_resolution.py` does for the
`Path.resolve()` symbolic link loop that only raises before Python 3.13.

## Selection

- Start with the narrowest profile named by the affected lane and path.
- Run every affected package's tests for cross-package contract changes.
- Run the full format, lint, package, Hub, and app test set before a PR or broad
  source change.
- Never print raw local logs, database rows, prompts, transcripts, audit
  findings, or secret-bearing fixtures in test output.

## Failed Verification

1. Preserve the pre-fix user state.
2. Identify the exact patch introduced for the current finding.
3. Reverse only that patch with `apply_patch`.
4. Mark the finding `skipped` with the failed command and concise reason.
5. Stop instead of reverting when the fix boundary overlaps unrelated work.
