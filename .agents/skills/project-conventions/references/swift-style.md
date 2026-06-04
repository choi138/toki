# Swift Style Reference

## Formatting And Linting

- Follow `.swiftformat` and `.swiftlint.yml`.
- Use 4 spaces and keep lines near 120 columns when practical.
- Use `lowerCamelCase` for values/functions and `UpperCamelCase` for types.
- Prefer clear names over abbreviations. Keep accepted short names only where
  the local lint config allows them and the surrounding code already uses them.
- Keep imports minimal and grouped as SwiftFormat expects.

## SwiftUI

- Keep `body` focused on composition. Extract repeated UI into small views or
  helper builders when it improves readability.
- Avoid doing expensive parsing, scanning, aggregation, or file IO in a view
  body.
- Keep `@State`, `@StateObject`, `@ObservedObject`, and `@Environment` ownership
  aligned with nearby files.
- Prefer stable layout dimensions for compact menu bar UI so loading states,
  counters, and labels do not cause visual jumps.
- Do not introduce marketing-style screens into the app surface. Toki is a
  compact operational menu bar tool.

## Foundation And Data Handling

- Reuse cached `DateFormatter`, `NumberFormatter`, and related formatters for
  repeated formatting work.
- Keep date-range and timezone behavior explicit in reader/report code.
- Prefer small pure helpers for token/cost/time calculations so they can be unit
  tested.
- For SQLite and filesystem readers, keep resource cleanup and error handling
  clear. Return diagnostics/status where the UI needs to explain reader state.

## Sensitive Data

- Mask secrets and credential-like strings.
- Avoid logging raw local agent log entries or database rows.
- Do not add network submission of usage or audit data without explicit user
  direction.
