# M0–M2 execution record — 2026-09-08

The scoped reader and app/agent changes pass the correctness gates below.
Performance acceptance remains open: OpenCode and OpenClaw exceed the 20% warm
runtime threshold on the bounded synthetic workload. Publication makes these
changes and limitations reviewable; it does not establish complete Tokscale
parity, production compatibility or merge acceptance.

The five-PR stack covers Hermes profiles, OpenCode stores/legacy JSON, OpenClaw
SQLite/models, common paths/manifest, and app/agent integration. The base is
`7fe0c4b485d0fcfdc65a971bba4932c9a0116fd0`; its tree equals the original lane base
`62538f45d98c167ef34b5e26e343b5ce0ef803f1`.

## Correctness and build gates

| Gate | Observed result | Local evidence artifact |
| --- | --- | --- |
| macOS core package | 549 tests, zero failures | `final-core-7.log` |
| Native app suite | 700 tests, zero failures | `final-native-5.log`, XCTest result bundle |
| Hub package | 25 tests, zero failures; release build succeeded | `final-hub.log`, `final-hub-release.log` |
| macOS agent release | Build succeeded | `final-agent-release-6.log` |
| SwiftFormat / strict SwiftLint | 349 files checked / passed | `final-format-7.log`, `final-lint-6.log` |
| Linux Swift 5.9.2 core | 549 tests, zero failures; final-fix focus 19 passed | `final-linux-run-4.log`, `final-core-linux.log` |
| Linux agent release / isolated CLI | Build and synthetic CLI assertions passed; lockfile unchanged | `final-linux-run-4.log` |
| Common-path intermediate stack | 524 core tests, zero failures; format/lint passed | `publication-stage4-tests-3.log` |
| Earlier standalone stack gates | Hermes 59, OpenCode 51, OpenClaw 58 passed | respective publication-stage logs |
| Native source-view rendering | Healthy Hermes 132 tokens, $0.25 and 30 seconds remain visible beside amber Partial status and a one-profile warning | synthetic XCTest PNG attachment |

The native image uses the real Hermes reader → fetch result → SwiftUI source view,
rendered with `ImageRenderer` and inspected. It covers this fixture/view, not all
screens. Native tests use isolated `CFFIXED_USER_HOME` and XDG directories; core
fixtures inject separate homes, roots, caches and environments. No production app
or agent was launched, replaced or deployed for verification.

macOS uses Swift 6.2.3, Xcode 26.2 (17C52), macOS 26.3.1 (a), arm64, 32 GiB RAM
and 10 physical CPU cores. Commands, from the final candidate checkout:

```sh
swift test --package-path core --scratch-path ../continuation/core-build --jobs 2 --disable-automatic-resolution
swift test --package-path hub --scratch-path ../continuation/hub-build --jobs 2
swift build --package-path core --scratch-path ../continuation/core-build -c release --product toki-agent --jobs 2 --disable-automatic-resolution
swiftformat . --lint
swiftlint lint --strict --quiet
```

Native builds used CLI-first `codex-xcode build build-for-testing`, project
`menubar/Toki.xcodeproj`, scheme `Toki`, destination `platform=macOS`, jobs 2,
parallel testing disabled and signing disabled. `test-without-building` used the
isolated generated `.xctestrun`. The generated project includes the new test file.

Linux ran as UID 1000 in a disposable `swift:5.9.2-jammy` container on aarch64,
SQLite 3.37.2, Linux `6.18.34+rpt-rpi-v8`. A separate fresh UID 1001 fixture home
isolates CLI checks from test-created legacy ledgers. Source and build mounts are
task-specific; package resolution is disabled and job count is two.

## Reproduced defects and review disposition

| Surface | Corrected invariant and adjacent cases |
| --- | --- |
| Hermes profiles | Healthy siblings survive denied profiles with explicit partial status; incomplete snapshot collections fail. Default and named-profile ledgers retain isolated identities. |
| Hermes canonical paths | Preserve the active journal alias; reject conflicting nonempty journals. Bind membership writes to the discovered collection root and reject live root retargeting. Explicit selection of the actual default home retains legacy history. |
| Agent selected locations | Refresh canonical DB/sidecar, membership, ledger and key paths; propagate denied selections. Hash physical alias membership, including path-only addition/removal, and compare late paths to original mounts and nearest ancestors. |
| OpenCode input accounting | Every selected row, including skipped non-assistant roles, consumes row/record/aggregate budgets. Absolute override paths retain whitespace. WAL-owning aliases are retained; conflicting journals fail. |
| OpenCode malformed stores | A selected v1/v2 store with no decodable records fails with a sanitized error. Empty, valid user-only, mixed valid/invalid and cross-generation cases retain compatibility. Healthy independent stores cannot hide a broken store. Six tests failed 14 assertions before correction and now pass. |
| OpenClaw identity/models | Session ID participates in timestamp-less fallback identity; DB/JSON replicas deduplicate. Explicit null aliases fall through to supported token fields. Non-hot rollback journals remain readable; active journals fail. |
| OpenClaw SQLite sorting | Sort physical transcript columns before bounded metadata lookup in the same transaction; repeated metadata cannot amplify the sorter before read guards. |
| Gemini non-usage data | Empty and user-only legacy chats return empty usage; unsupported recording schemas remain diagnosed. |
| GJC shared roots | The actual Pi/OMP parsers select common records; GJC retains headerless, model-less and task usage that the owner rejects. Pi, OMP, combined ownership and leading-title differences are covered; all observed GJC rows count toward budgets. Three tests failed 17 assertions before correction. |
| GJC source signatures | A shared-owner alias retarget changes selection identity even if GJC files are unchanged. Regression proves 12 → 0 → 12 tokens and signature change/restore; it failed two assertions before correction. |
| Claude diagnostics | Discovery and cached JSONL failures expose no project/file names or original URL-bearing errors. Cancellation, malformed data, safe line numbers and size limits remain distinct. Nine tests failed 16 assertions before correction. |
| App partial results | Healthy profile usage stays visible; model-scoped fallback does not reuse stale cache for partial sources. |

The independent review completed the repository's maximum three rounds. Baseline,
privacy/security, usage/pricing, remote sync, concurrency/lifecycle, build/portability
and testing lanes participated in round 3; SwiftUI was clean in round 2 and no UI
code changed later. All three round-3 P2 findings above were reproduced and fixed.
Earlier round findings, including the WAL/alias-signature P1s, were also fixed.
There was no fourth review or independent post-fix approval claim.

Review was bounded static inspection. Reviewers did not execute tests; the testing
lane reached its 16-batch cap and some large outputs were truncated. Coordinator
runtime evidence is separate from that review. The final GJC lint correction only
moves the unchanged `sharedSelectionIdentity` body to a same-file package extension;
macOS core checks and five focused tests cover that organization; the measured
source hashes below make the distinction explicit.

## SQLite allocation regression proof

The synthetic public-reader diagnostic uses 256 events and 4 KiB model metadata.
The old joined sorter grew SQLite allocations by 1,258,808 bytes without the index
and 122,888 bytes with it; the source DBs were 118,784 and 131,072 bytes. Corrected
runs previously measured 187,968 and 116,672 bytes. macOS SQLite reports zero memory
counters, so it provides no allocation evidence.

Final mutation proof passed. Restoring the old joined query in a throwaway copy
made the public-reader test fail exactly one `XCTAssertLessThan` assertion:
1,259,344 bytes exceeded 524,288 bytes without the index (indexed: 123,424 bytes).
Restoring the corrected query made the same test pass: 187,968 bytes unindexed
and 116,672 bytes indexed. Logs: `sorter-assertion-red-2.log` and
`sorter-assertion-green-2.log`. An earlier invocation failed before test execution
because root reused a non-root SwiftPM lock; it is retained as an infrastructure
failure and excluded from regression proof. Both proof runs use UID 1000.
Production and published sources are untouched by this mutation.

## Performance method and complete results

The final quiet repeat ran 2026-09-08 10:07:21–10:08:41 UTC, with 72 successful
XCTest subprocesses and 216 timed samples (80.4 seconds summed process time).
Identical synthetic fixtures total 1,038,336 bytes: 512 Hermes SQLite sessions,
2,048 OpenCode v1 rows over 16 sessions, and 16 legacy OpenClaw JSONL files of 128
rows. All formats are supported by both revisions. The event window is
2026-08-20 00:00–2026-08-21 00:00 UTC. No production data or network is involved.

Both revisions use the identical temporary XCTest harness with release builds and
`-Xswiftc -enable-testing`. Three trials alternate revision order. Cold means a
fresh process/state with an initialized empty Hermes ledger; bootstrap is outside
timing. Restart uses persisted state. Warm primes once then times seven reads per
process (21 samples per revision). OS disk caches are not flushed.

Snapshot injects these three reader descriptors with empty `sourceLocations`.
It measures public reader collection, snapshot assembly, identifier hashing and
encrypted-envelope size checks. Default-registry dynamic signatures, mount
monitoring, network upload and hub execution are outside this benchmark.

Wall times below are medians in milliseconds. RSS is the median of three whole
XCTest process peaks in MiB, including runtime, priming and correctness-summary
allocations; it is not reader-only allocation. Full samples and commands remain
in `performance-published/` outside the repository.

| Scenario | Mode | Samples/revision | Baseline ms | Candidate ms | Runtime change | Baseline peak MiB | Candidate peak MiB | RSS change |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Hermes | cold | 3 | 44.90 | 45.46 | +1.3% | 61.34 | 61.70 | +0.6% |
| Hermes | restart | 3 | 40.46 | 39.13 | -3.3% | 59.95 | 60.25 | +0.5% |
| Hermes | warm | 21 | 23.53 | 23.40 | -0.5% | 73.91 | 74.31 | +0.5% |
| OpenCode | cold | 3 | 23.53 | 74.59 | +216.9% | 67.88 | 71.91 | +5.9% |
| OpenCode | restart | 3 | 23.81 | 73.18 | +207.4% | 67.91 | 72.14 | +6.2% |
| OpenCode | warm | 21 | 21.61 | 68.69 | +217.9% | 122.78 | 133.70 | +8.9% |
| OpenClaw | cold | 3 | 329.39 | 404.01 | +22.7% | 68.45 | 71.20 | +4.0% |
| OpenClaw | restart | 3 | 325.87 | 408.51 | +25.4% | 68.42 | 71.27 | +4.2% |
| OpenClaw | warm | 21 | 318.63 | 392.36 | +23.1% | 122.86 | 134.45 | +9.4% |
| Snapshot | cold | 3 | 622.81 | 718.28 | +15.3% | 103.45 | 107.12 | +3.5% |
| Snapshot | restart | 3 | 621.68 | 725.80 | +16.7% | 104.33 | 109.50 | +5.0% |
| Snapshot | warm | 21 | 620.41 | 707.38 | +14.0% | 112.06 | 118.44 | +5.7% |

OpenCode's +217.9% warm increase (21.61 → 68.69 ms) remains a measured limitation.
The old reader projects/filter fields in SQLite; the candidate bounds and decodes
full JSON, reconciles migration identities and sorts before date filtering. These
paths run for all 2,048 rows. Earlier diagnostic instrumentation supported JSON
decoding as the largest added phase; no percentage-level profiler attribution or
out-of-window history claim is made.

OpenClaw's +23.1% warm increase (318.63 → 392.36 ms) also crosses the threshold.
Its JSONL path adds bounded line IO, record/byte accounting, before/after file
signatures, dictionary/context validation, namespaced session digests and global
sorting/activity union. This is a source-supported explanation, not a sampled
profile. The semantic change below limits strict equivalent-output comparison.
No mode's median process peak RSS increased by 10% or more. These measurements do
not establish behavior at the reader's maximum budgets or Linux performance.

## Arithmetic and equivalence

The harness's final whole-result equivalence assertion exits 1: OpenClaw overall
and per-model wall time changes from summing 16 overlapping streams (10,640 s) to
their union (665 s). That failure is retained; it is not reported as a passing
baseline-equivalence gate. Hermes, OpenCode and aggregate snapshot normalized
outputs match. Independent fixture arithmetic validates all 108 candidate samples.

| Scenario | Tokens | Events | Agent seconds | Wall seconds | Numeric cost |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hermes | 69,120 | 512 | 15,360 | 541 | $0.512 |
| OpenCode | 276,480 | 2,048 | 10,640 | 665 | $1.273344 |
| OpenClaw | 276,480 | 2,048 | 10,640 | 665 | $0, unknown |
| Aggregate snapshot | 622,080 | 4,608 | 36,640 | 665 | $1.785344 |

Token buckets, event digests, numeric costs and stream counts are conserved.
Snapshot has 544 activity streams. Raw cost-known annotations intentionally improve:
OpenCode unspecified → true, OpenClaw unspecified → false. Opaque session-ID bytes
are not compared; session cardinality and activity/work-time grouping are compared.
This evidence is narrower than byte-identical exported snapshots.

## Provenance and retained scope

Manifest SHA-256 values hash sorted path/byte-size/file-SHA records encoded as
JSON with sorted keys. Source manifests exclude build outputs and private logs.

| Manifest | SHA-256 |
| --- | --- |
| Baseline core sources | `37608c7f910edb2d2ec6b454f04ff49cb08a2720782071a62caa781a404ea25b` |
| Measured core sources | `777f3dcd27da70eff2daa1d06fe7c4487ea7ed21b41577b7c118e422ac75ed9c` |
| Final core sources | `deec2648b705bdcdf303655505f252934a6cf8a5a18f8337ad6b79c9ef9335f3` |
| Final core/menubar sources, tests and configuration (378 files) | `de6055f8d28064cc58fd3e20f943afb480cf2d728d7e458191e469070c5d069a` |
| Performance fixture, unchanged before/after | `dfba9d003242ace096813660cbb87f3a65a7042f5cfc36d83d9fa727c472874c` |

The measured core matched the frozen publish copy through measurement completion.
The only subsequent source difference is the GJC same-file extension move described
above; its function body is byte-identical. Documentation then records final evidence.

The inventory remains 53 upstream IDs, 17 common IDs mapped to 18 Toki readers and
36 deferred new clients. M3 Cursor expansion, M4 pricing and M5 new clients remain
excluded. Manifest statuses stay scoped `implemented`/`existing`/`planned`.
Unsupported formats and product variants remain explicit.

Raw logs, per-file manifests, reviews, benchmark samples and XCTest attachments
are retained under the task's local `continuation/` directory. Only synthetic
fixtures and this evidence summary belong in the PRs. No merge or deployment was
performed.
