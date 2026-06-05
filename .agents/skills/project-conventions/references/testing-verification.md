# Testing And Verification Reference

## Focused Checks

Choose the smallest useful check while iterating:

- Swift formatting only:

  ```bash
  swiftformat . --lint
  ```

- SwiftLint:

  ```bash
  swiftlint lint --strict --quiet
  ```

- Project regeneration after `project.yml` changes:

  ```bash
  xcodegen generate
  ```

- Full unit test run:

  ```bash
  xcodebuild test \
    -project Toki.xcodeproj \
    -scheme Toki \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
  ```

## What To Test

- Usage reader changes: add or update tests for the affected agent reader and
  reader diagnostics.
- Aggregation/report changes: test totals, costs, model/source breakdowns, date
  ranges, and export output as relevant.
- Activity/time changes: test active-time and wall-clock behavior.
- Security audit changes: test masking, matching, scanner source handling,
  SQLite scanning, and cache behavior.
- UI/view-model changes: test derived state, settings persistence, refresh
  coordination, and formatting behavior where practical.

## Before Finishing

- Run relevant checks or explain exactly why they were not run.
- If `xcodegen generate` changes `Toki.xcodeproj`, include that generated diff
  with the source/config change.
- Use `git diff --check` to catch whitespace problems before final response.
