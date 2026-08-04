# Remote Sync Lane

Review protocol, Agent, Hub, and app sync behavior for:

- Encryption and authentication ordering, nonce uniqueness, key/identity
  binding, signature validation, and downgrade resistance.
- Replay, rollback, stale snapshot, anchor, generation, and replacement checks.
- Validation symmetry across producer, transport, Hub storage, cache, and app
  consumption.
- Atomic durable writes, crash recovery, lock behavior, and corrupt-state
  fallback.
- Cache reuse and offline fallback that could accept incompatible or older
  data.
- Vapor route authentication, payload limits, status mapping, and error
  disclosure.
- Linux Agent/Hub behavior and wire-format compatibility.

Treat weakened validation or recovery that can silently accept stale or
unauthenticated data as a high-priority correctness or security defect.
