# Privacy And Security Lane

Review local data and security-audit behavior for:

- Raw prompts, transcripts, usage rows, credentials, tokens, private keys, or
  audit matches reaching logs, diagnostics, caches, exports, or the network.
- Missing masking, unsafe previews, secret reconstruction, or overly broad
  persisted cache fields.
- Unsafe filesystem traversal, symlink handling, permissions, or SQLite query
  construction.
- Scanner false negatives caused by decoding, truncation, cancellation, or
  cache invalidation errors.
- Telemetry or network transmission added without explicit product intent.
- Error messages that disclose sensitive paths or values.

Never quote a discovered secret or sensitive record in a finding. Identify only
the data category and affected code path.
