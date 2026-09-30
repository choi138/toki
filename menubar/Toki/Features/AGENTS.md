# TOKI FEATURES LAYER

## OVERVIEW

SwiftUI screens and view models for the menu bar panel and the security audit UI.
Views render state and forward actions; view models own refresh, loading, settings,
and presentation transforms built on Domain/Infrastructure.

## STRUCTURE

```text
Features/
├── UsagePanel/           # menu panel UI, tabs, settings, refresh, exports
│   ├── UsagePanelView.swift              # root panel layout
│   ├── UsagePanelViewModel.swift         # @MainActor ObservableObject; UsageServiceSnapshot
│   ├── UsagePanelRefreshCoordinator.swift # refresh identity + UsageWindowResultCache
│   ├── UsagePanelSettings.swift          # ObservableObject settings persistence
│   ├── UsagePeriodTotals.swift           # period totals + PeriodTokenTotalsCache
│   ├── PanelTab.swift / PanelTabBarView.swift / PanelTabReordering.swift
│   ├── Panel*View.swift                  # per-tab views (ByModel, DailyTokenChart, Hourly, ProjectTimeline, Settings, …)
│   ├── PanelModelDetail*.swift           # model detail presentation structs + views
│   ├── ProjectTimelineBreakdown.swift    # presentation-side timeline math
│   ├── TokenVelocityState.swift          # @MainActor ObservableObject over TokenVelocityMonitor
│   ├── LaunchAtLoginViewModel.swift      # wraps LaunchAtLoginServicing
│   ├── RemoteSyncSettingsView/ViewModel/Error.swift
│   └── PanelPalette.swift                # shared colors/styles
└── SecurityAudit/
    ├── SecurityAuditView.swift
    ├── SecurityAuditFindingListView.swift
    └── SecurityAuditViewModel.swift      # @MainActor ObservableObject; drives SecurityAuditScanning
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Panel state / data flow | `UsagePanel/UsagePanelViewModel.swift` | `UsageServiceSnapshot` is the render snapshot |
| Refresh/caching behavior | `UsagePanel/UsagePanelRefreshCoordinator.swift` | `UsageWindowResultCache` keyed by window; tests in `TokiTests/UsageService*Tests.swift` |
| Add/reorder a panel tab | `UsagePanel/PanelTab.swift`, `UsagePanel/PanelTabReordering.swift` | Order persisted via settings; tests in `TokiTests/PanelTabReorderingTests.swift` |
| Settings persistence | `UsagePanel/UsagePanelSettings.swift` | Tests: `TokiTests/UsagePanelSettingsTests.swift` |
| Model detail presentation | `UsagePanel/PanelModelDetailPresentation.swift` | Pure presentation structs, unit-testable without UI |
| Source export UI | `UsagePanel/PanelSourceExportViews.swift` | Export payloads come from `Domain/Usage/UsageReportExport.swift` |
| Remote sync settings flow | `UsagePanel/RemoteSyncSettingsViewModel.swift` | Talks to `Infrastructure/RemoteSync/` stores; tests in `TokiTests/RemoteSyncSettingsViewModelTests.swift` |
| Security audit UI state | `SecurityAudit/SecurityAuditViewModel.swift` | Consumes `SecurityAuditScanning`; findings render masked |

## LOCAL INVARIANTS

- Views are presentation-only: no parsing, aggregation, pricing, security scanning, or persistence in `body`. That logic belongs in Domain, Infrastructure, or the view models here.
- View models are `@MainActor final class … : ObservableObject`. Follow the existing pattern for new feature state.
- Presentation math that can be pure (e.g. `PanelHeroComparisonContent`, `PanelModelDetailPresentation`, `ProjectTimelineBreakdown`) is kept in plain structs/enums so it is unit-testable without rendering.
- Security findings are displayed masked; never add UI that logs or transmits raw finding evidence.
- Keep SwiftUI `body` implementations readable — extract subviews/helpers rather than nesting deeply.
- View-model, settings, tab-order, and presentation changes need matching tests in `menubar/TokiTests/`.

## RELEVANT CONVENTIONS

This file narrows, not replaces, upper-level guidance: root `AGENTS.md` (workspace
rules, safety rules) still applies in full.

- `.agents/skills/project-conventions/conventions.md` (always read)
- `.agents/skills/project-conventions/references/architecture.md` (feature boundary rules)
- `.agents/skills/project-conventions/references/swift-style.md` (SwiftUI state, naming)

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
