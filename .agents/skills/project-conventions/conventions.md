# Toki Source Conventions

This is the always-read entry point for Toki source rules.
Use it before editing `Toki/**/*.swift`, `TokiTests/**/*.swift`, resources, or
project configuration.

Detailed rules live in `references/` and should be loaded only when relevant to
the task.

## Always Apply

- Keep responsibilities aligned with the existing tree:
  - `Toki/App`: app entry, app delegate, menu bar lifecycle.
  - `Toki/Domain`: pure usage and security audit domain models/builders.
  - `Toki/Infrastructure`: readers, SQLite access, filesystem access, caches,
    activity monitoring, pricing data, and scanner implementations.
  - `Toki/Features`: SwiftUI screens, view models, settings, refresh
    coordination, exports, and feature-specific presentation logic.
  - `TokiTests`: unit tests and local test support.
- Treat local agent logs, usage databases, security findings, and detected
  secrets as sensitive. Keep values local, mask findings, and avoid adding
  telemetry or unmasked logs.
- Prefer editing `project.yml` for project structure/config changes, then run
  `xcodegen generate`.
- Follow `.swiftformat` and `.swiftlint.yml`. Do not fight the configured style.
- Keep SwiftUI `body` implementations readable. Move heavy calculations,
  parsing, scanning, and formatting into helpers, domain types, services, or view
  models.
- When changing date, time, cost, token, reader status, project attribution, or
  security audit behavior, update or add focused tests.
- Do not edit generated build artifacts under `build/`, `DerivedData/`, or
  `.codegraph/`.

## Read By Task

- App structure, layer ownership, reader boundaries, security audit boundaries,
  or SwiftUI feature boundaries: read `references/architecture.md`.
- Swift style, SwiftUI state, formatting, naming, sensitive data handling, or
  resource usage: read `references/swift-style.md`.
- Before completing source or project changes: read
  `references/testing-verification.md`.

When a task touches multiple areas, read each matching reference. When unsure,
read the narrower reference first, then load another reference as soon as the
edit crosses into that area.
