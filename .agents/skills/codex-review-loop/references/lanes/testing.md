# Testing Lane

Review tests and test coverage for:

- Changed behavior without a focused regression test that would fail for the
  identified defect.
- Missing boundary cases for date ranges, time zones, pricing fallbacks,
  malformed reader input, security masking, and sync validation.
- Nondeterministic clocks, filesystem order, networking, timers, concurrency,
  or global state.
- Fixtures that accidentally contain real local usage data, secrets, prompts,
  or credentials.
- Assertions that cannot distinguish success from a silent fallback or empty
  result.
- Platform gaps between macOS app tests and Swift 5.9.2 Linux package tests.

Report a test-only finding only when the missing or incorrect test creates a
concrete regression risk. Avoid generic requests for more coverage.
