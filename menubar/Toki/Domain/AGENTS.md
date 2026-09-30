# TOKI DOMAIN LAYER

## OVERVIEW

Pure value types and builders for usage reporting and security audit results.
No UI, no I/O: this layer shapes data that Infrastructure produces and Features render.

## STRUCTURE

```text
Domain/
├── Usage/                # usage data shapes, report building, export, formatting
│   ├── UsageData.swift             # core value types: UsageOrigin, ModelStat, SourceStat, UsageData, ReaderStatus
│   ├── UsageReportBuilder.swift    # pure builder (caseless enum) composing UsageData reports
│   ├── UsageReportModelStats.swift # per-model stat derivation
│   ├── UsageReportModelSelection.swift # model scope/selection logic
│   ├── UsageReportExport.swift     # UsageExportFormat + export payload building
│   ├── UsageFormatting.swift       # token/cost/duration display formatting
│   └── CurrentUsageWindow.swift    # CurrentUsageWindow period enum
└── SecurityAudit/
    └── SecurityAuditModels.swift   # SecuritySeverity, SecurityFinding, SecurityAuditResult/Request/Progress, SecurityAuditScanning protocol
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Add/change a usage value type | `Usage/UsageData.swift` | Equatable structs and enums; `UsageData` is the aggregate root |
| Change report composition | `Usage/UsageReportBuilder.swift` | Caseless enum of pure static builders |
| Model breakdown/selection rules | `Usage/UsageReportModelStats.swift`, `Usage/UsageReportModelSelection.swift` | Feed `PanelByModelView` and model detail views |
| Export formats/payloads | `Usage/UsageReportExport.swift` | `UsageExportFormat` cases; tested by `TokiTests/UsageExportTests.swift` |
| Display formatting of tokens/costs | `Usage/UsageFormatting.swift` | Keep formatting here, not in SwiftUI views |
| Security audit contract | `SecurityAudit/SecurityAuditModels.swift` | `SecurityAuditScanning` protocol is implemented in `Infrastructure/SecurityAudit/SecurityAuditScanner.swift` |

## LOCAL INVARIANTS

- Do not import SwiftUI or AppKit here (the existing architecture boundary). Current imports are `Foundation`, `TokiUsageCore`, and `TokiUsageReaders`; this inventory describes today's state, not a new dependency allowlist.
- Types are value types (structs/enums) with `Equatable`/`Codable` conformances; builders are caseless enums of pure static functions. No side effects, no filesystem/network access.
- Inject or isolate dates/ranges when testing time-sensitive behavior. `UsageData.empty` currently uses `Date()`; this document does not claim every existing value is clock-independent.
- Security finding models carry masked evidence only. Do not add fields that widen exposure of raw secrets, prompts, or transcripts.
- Shared raw-usage primitives (`RawTokenUsage`, `TokenReader`, etc.) live in the `TokiRemote` SPM package under `core/Sources/` — extend there, not here, when the change is cross-target.

## RELEVANT CONVENTIONS

This file narrows, not replaces, upper-level guidance: root `AGENTS.md` (workspace
rules, safety rules) still applies in full.

- `.agents/skills/project-conventions/conventions.md` (always read)
- `.agents/skills/project-conventions/references/architecture.md` (directory ownership, boundary rules)
- `.agents/skills/project-conventions/references/swift-style.md`

## COMMANDS

Run from the repository root; project regeneration from `menubar/`:

```bash
swiftformat . --lint
swiftlint lint --strict --quiet
(cd menubar && xcodegen generate)   # only after project.yml changes
xcodebuild test -project menubar/Toki.xcodeproj -scheme Toki \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```
