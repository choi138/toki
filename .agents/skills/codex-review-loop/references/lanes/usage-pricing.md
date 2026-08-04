# Usage And Pricing Lane

Review usage readers, pricing, aggregation, and reporting for:

- JSONL, SQLite, filesystem, and cache parsing across malformed, partial, or
  version-skewed records.
- Token totals, model/source/project attribution, deduplication, and migration
  behavior.
- Cost calculation, pricing fallback precedence, unpriced rows, and model-name
  normalization.
- Date boundaries, time zones, daylight-saving transitions, active time, and
  wall-clock aggregation.
- Reader diagnostics that distinguish missing data from parse or permission
  failures without exposing raw local content.
- Deterministic aggregation and focused tests for edge cases and fallbacks.

Treat a plausible overcount, undercount, or incorrect charge as a correctness
finding, not a cosmetic issue.
