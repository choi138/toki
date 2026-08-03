# SwiftUI Architecture Lane

Review app, menu-bar, view, and view-model changes for:

- Correct ownership of `@State`, `@StateObject`, `@ObservedObject`, and
  environment values.
- Views performing parsing, aggregation, scanning, persistence, file IO, or
  refresh orchestration.
- Feedback loops, repeated `onAppear` work, stale bindings, and state reset
  caused by view identity changes.
- Main-actor correctness and observable updates arriving from background work.
- Menu-bar, panel, status-item, AppKit bridge, and application lifecycle
  regressions.
- Loading, failure, and empty states that make operational status misleading.
- Compact layout instability that makes controls or counters jump or disappear.

Respect the existing Toki layer boundaries and compact operational design.
