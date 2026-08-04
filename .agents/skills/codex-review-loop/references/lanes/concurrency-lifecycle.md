# Concurrency And Lifecycle Lane

Review asynchronous and lifecycle behavior for:

- Actor isolation, `Sendable` assumptions, shared mutable state, and race
  conditions.
- Main-actor blocking by file IO, SQLite, network calls, parsing, scanning, or
  aggregation.
- Unstructured tasks that outlive their owner, duplicate work, or ignore
  cancellation.
- Timer and notification lifecycles, retain cycles, repeated registration, and
  missed teardown.
- Lock ordering, reentrancy, deadlocks, and state read outside protection.
- Stale async results overwriting newer refresh or configuration state.
- Errors or cancellation converted into successful or permanently loading UI
  state.

Verify ownership from creation through cancellation and deinitialization, not
only the task body.
