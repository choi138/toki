# Toki Architecture Reference

## Directory Ownership

- `Toki/App`
  - Owns app entry and macOS menu bar lifecycle.
  - Keep startup wiring small. Push feature behavior into feature, domain, or
    infrastructure types.
- `Toki/Domain/Usage`
  - Owns usage data shapes, report building, export payloads, and formatting
    behavior that should not depend on SwiftUI.
- `Toki/Domain/SecurityAudit`
  - Owns security audit domain models and value semantics.
- `Toki/Infrastructure/UsageReaders`
  - Owns filesystem/database readers for Claude Code, Codex, Cursor, OpenCode,
    Gemini CLI, OpenClaw, pricing, and aggregation.
  - Keep reader failures diagnosable without exposing sensitive content.
- `Toki/Infrastructure/SecurityAudit`
  - Owns source discovery, rule matching, SQLite scanning, cache storage, and
    scanner implementation details.
- `Toki/Infrastructure/Activity`
  - Owns app activity monitoring and active-time estimation.
- `Toki/Features/UsagePanel`
  - Owns the menu panel UI, settings, refresh coordination, source exports,
    model/project/hourly breakdowns, and presentation-oriented view models.
- `Toki/Features/SecurityAudit`
  - Owns security audit UI and user-facing audit state.
- `TokiTests`
  - Mirror changed behavior with focused tests. Prefer test support helpers over
    duplicating large fixtures inline.

## Boundary Rules

- Domain code should not import SwiftUI or AppKit.
- Infrastructure may depend on Foundation, SQLite, and platform/file APIs, but
  should expose domain-level results rather than UI-specific values.
- Feature code may compose domain and infrastructure services, but keep heavy
  parsing/scanning/aggregation outside views.
- Views should render state and send user actions. View models/services should
  own refresh, scanning, loading, and transformation flows.
- Keep source-reader behavior deterministic. Do not rely on wall-clock time
  without injecting or isolating the date range in tests.

## Sensitive Local Data

- Do not print raw prompts, transcripts, tokens, API keys, JWTs, credentials,
  private keys, or database contents.
- Security audit findings should stay masked unless an existing flow explicitly
  supports revealing a safe preview.
- Cache data should not broaden the sensitivity surface. When adding cache
  fields, consider whether they can contain secrets.
