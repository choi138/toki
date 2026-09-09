# M0–M2 intermediate stack record — 2026-09-08

This branch is step 4 of the five-PR stack. It adds common-client path handling
and the pinned compatibility manifest on top of Hermes, OpenCode and OpenClaw
reader changes. The base is `7fe0c4b485d0fcfdc65a971bba4932c9a0116fd0`.

Standalone macOS gates passed: Hermes 59, OpenCode 51 and OpenClaw 58 tests.
The common-path full core suite passed 524 tests with zero failures
(`publication-stage4-tests-3.log`). SwiftFormat and strict SwiftLint passed. Final app/agent integration, native suite, Linux,
performance and bounded independent-review results belong to step 5.

The inventory is 53 upstream IDs, 17 common IDs mapped to 18 readers and 36
deferred new clients. All runtime fixtures are synthetic. Passing these tests
does not establish every format or production compatibility. M3 Cursor,
M4 pricing and M5 new clients remain excluded.
