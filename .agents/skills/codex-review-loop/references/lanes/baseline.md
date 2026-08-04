# Baseline Lane

Review every change for:

- Incorrect behavior, broken invariants, off-by-one and boundary mistakes.
- Missing error handling, failure propagation, or invalid fallback behavior.
- Crashes, data loss, corruption, stale state, and silent partial success.
- Compatibility regressions in public or persisted data contracts.
- Unsafe assumptions about optional values, file presence, ordering, or input
  shape.
- Material performance regressions on frequently executed paths.

Trace important callers and consumers when the changed code alters a contract.
Do not duplicate a specialist finding unless baseline reasoning independently
identifies the same root cause.
