# TOKI INFRASTRUCTURE LAYER

## OVERVIEW

Platform access and data production: usage aggregation over agent-log/DB readers,
remote sync transport and caching, security scanning (filesystem + SQLite), activity
monitoring, and launch-at-login. Exposes domain-level results, never UI values.

## STRUCTURE

```text
Infrastructure/
├── UsageReaders/         # aggregation over readers from the TokiRemote package
│   ├── OriginPartitionedTokenReader.swift  # protocol refining TokenReader; per-origin slices
│   ├── UsageAggregator.swift               # UsageAggregationRequest -> aggregated usage
│   ├── UsageModelSourceMerge.swift         # merge model/source stats across readers
│   ├── RemotePricingCatalog.swift          # pricing data refresh/lookup
│   └── ReaderFetchResult.swift             # per-reader fetch outcome/status
├── RemoteSync/           # hub client, snapshot cache/anchors, config + Keychain, remote reader
├── SecurityAudit/        # discovery, rules, masking, file + SQLite scanners, result cache
├── Activity/             # ActivityMonitor, TokenVelocityMonitor (actor)
└── System/               # LaunchAtLoginService (ServiceManagement)
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Aggregation across readers | `UsageReaders/UsageAggregator.swift` | Entry: `UsageAggregationRequest`; enabled readers passed by name |
| Per-origin reader contract | `UsageReaders/OriginPartitionedTokenReader.swift` | Default `readUsage` sums `UsageOriginSlice`s |
| Concrete CLI readers (Claude Code, Codex, …) | `core/Sources/TokiUsageReaders/` (SPM package, outside this dir) | Registered via `LocalUsageReaderRegistry` there; this dir only aggregates |
| Pricing catalog | `UsageReaders/RemotePricingCatalog.swift` | Test-host refresh guard covered in `TokiTests/TokiTests.swift` |
| Remote hub HTTP + response bounding | `RemoteSync/RemoteHubClient.swift` | `RemoteBoundedResponseLoader` caps payloads |
| Remote snapshot cache/validation | `RemoteSync/RemoteSnapshotCache.swift`, `RemoteSync/RemoteSnapshotValidation.swift`, `RemoteSync/RemoteSnapshotAnchorStore.swift` | Cache entries are Codable; validate before use |
| Remote sync config + credentials | `RemoteSync/RemoteSyncConfigurationStore.swift` | `KeychainCredentialStore` — secrets go to Keychain, not UserDefaults |
| Remote usage as a reader | `RemoteSync/RemoteUsageReader.swift` | Conforms to `OriginPartitionedTokenReader` |
| Security scan orchestration | `SecurityAudit/SecurityAuditScanner.swift` | Implements `SecurityAuditScanning` from Domain |
| Scan rules and masking | `SecurityAudit/SecurityAuditRules.swift` | `SecurityEvidenceMasker` masks all evidence output |
| SQLite scanning | `SecurityAudit/SecurityAuditSQLiteScanner.swift` | Uses `SQLite3`; WAL signatures in `SecurityAuditCacheStore.swift` |
| Active time / token velocity | `Activity/ActivityMonitor.swift` | `TokenVelocityMonitor` is an actor |

## LOCAL INVARIANTS

- Local agent logs, usage databases, security findings, and detected secrets are sensitive: no telemetry, no network transmission of their contents, no unmasked logging. Reader failures must stay diagnosable without exposing content.
- Security evidence must pass through `SecurityEvidenceMasker` before leaving this layer; cache fields must not widen the sensitivity surface.
- Remote sync credentials live in the Keychain (`KeychainCredentialStore`), never in plain config storage.
- Expose Domain-level results (structs from `Domain/` or `TokiUsageCore`), not SwiftUI/presentation types. No SwiftUI imports here.
- Keep reader/scanner behavior deterministic: date ranges are injected, and remote responses are size-bounded (`RemoteBoundedResponseLoader`, `RemoteSnapshotPayloadBudget`).
- New concrete agent readers belong in the `TokiRemote` package (`core/Sources/TokiUsageReaders/`), not in this directory.

## RELEVANT CONVENTIONS

This file narrows, not replaces, upper-level guidance: root `AGENTS.md` (workspace
rules, safety rules) still applies in full.

- `.agents/skills/project-conventions/conventions.md` (always read)
- `.agents/skills/project-conventions/references/architecture.md` (reader/scanner boundaries, sensitive data rules)
- `.agents/skills/project-conventions/references/testing-verification.md`

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
