# TOKI UNIT TESTS

## OVERVIEW

XCTest unit-test bundle for the Toki menu bar app (target `TokiTests`, hosted in
`Toki.app`). Flat directory of ~80 focused test files plus shared `*TestSupport.swift`
helpers; covers readers, aggregation, formatting, security audit, settings, and view models.

## STRUCTURE

```text
TokiTests/                       # flat; grouped by filename prefix
├── <Agent>ReaderTests.swift     # per-agent reader behavior (ClaudeCode, Codex, Cursor, Hermes, …)
├── UsageService*Tests.swift     # refresh, date sync, fallback, diagnostics, active time
├── Usage*Tests.swift            # aggregation, attribution, export, formatting, model selection
├── Panel*Tests.swift            # tab reordering, model detail presentation, panel UX
├── SecurityAudit*Tests.swift    # scanner rules, cache, cancellation, SQLite integration
├── Remote*Tests.swift           # remote sync transport, snapshot cache, pricing catalog
├── TestSupport.swift            # tokiTestISODate, mockUsage, shared mocks
└── *TestSupport.swift           # area-specific fixtures (CodexReader, RemoteUsageReader, SecurityAuditScanner, SecurityAuditSQLite, RemoteSyncTransport, UsageBehavior)
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Shared date/usage mocks | `TestSupport.swift` | `tokiTestISODate(_:)`, `mockUsage(totalTokens:activeSeconds:)` |
| Usage service mocks/recorders | `UsageBehaviorTestSupport.swift` | `MockReader`/`MockReaderRecorder` pattern used by `UsageService*Tests` |
| Reader fixture patterns | `CodexReaderTestSupport.swift`, `RemoteUsageReaderTestSupport.swift`, `RemoteUsageReaderTestFixtures.swift` | Copy an existing fixture style for a new agent reader |
| Security scanner fixtures | `SecurityAuditScannerTestSupport.swift`, `SecurityAuditSQLiteTestSupport.swift` | SQLite tests import `SQLite3` directly |
| Test target config | `../project.yml` (`TokiTests` target) | `TEST_HOST` = Toki.app; depends on TokiRemote package products |
| Package-level tests (core readers) | `../../core/Tests/TokiAgentTests/` | Separate SPM test target — reader internals shared with the CLI live there |

## LOCAL INVARIANTS

- Standard import block: `import XCTest` + `@testable import Toki`; add `TokiUsageCore` / `@testable import TokiUsageReaders` / `TokiSyncProtocol` only when needed.
- One behavior area per file, named `<Subject><Aspect>Tests.swift`; test methods use `test_<subject>_<expectation>` snake-ish camel style (see `UsageServiceBehaviorTests.swift`).
- Keep tests deterministic: build dates with `tokiTestISODate`/`Calendar` math, inject date ranges — never depend on ambient wall-clock behavior.
- Prefer extending an existing `*TestSupport.swift` over duplicating large fixtures inline; new shared fixtures get their own `<Area>TestSupport.swift`.
- Fixtures must not contain real secrets, tokens, prompts, or transcripts — synthetic data only (security audit fixtures verify masking, so keep planted "secrets" obviously fake).
- Target sources are declared as the whole `TokiTests` directory in `menubar/project.yml`; after adding files, regenerate with `xcodegen generate` from `menubar/` rather than hand-editing `Toki.xcodeproj`.
- When changing date, time, cost, token, reader status, project attribution, or security audit behavior in app code, add/update a focused test here in the matching prefix group.

## RELEVANT CONVENTIONS

This file narrows, not replaces, upper-level guidance: root `AGENTS.md` (workspace
rules, safety rules) still applies in full.

- `.agents/skills/project-conventions/conventions.md` (always read)
- `.agents/skills/project-conventions/references/testing-verification.md` (what to test, focused checks)
- `.agents/skills/project-conventions/references/architecture.md` (which layer a behavior belongs to)

## COMMANDS

Run from the repository root:

```bash
xcodebuild test -project menubar/Toki.xcodeproj -scheme Toki \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swiftformat . --lint
swiftlint lint --strict --quiet
```
