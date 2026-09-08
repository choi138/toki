# Compatibility verification template

The observed M0–M2 results are in
[verification-20260908.md](verification-20260908.md). Use this template for a
future run; empty cells and authored assertions are not passing evidence.

| Field | Evidence required |
| --- | --- |
| Candidate / baseline | Commit or source-manifest hash, isolated checkout paths |
| Upstream | Pinned revision and archive/content hashes |
| Toolchain / OS | Exact Swift/Xcode/SQLite versions, OS and architecture |
| Scope | Filter, suites discovered, fixture count/size/content hashes |
| Isolation | Synthetic homes/environment, unique caches/output, build job limit |
| Command | Exact command, working directory, timestamp and timezone |
| Outcome | Process exit, tests executed, failures/skips, saved artifact |

Record semantic RED and focused GREEN, relevant legacy suites, public-reader
events/per-model totals, snapshot/signature cold and warm paths, consumer
conservation, empty stores and cache/ledger upgrades. Include source addition and
removal, alias retargeting, mount changes and real WAL-only updates where relevant.
Keep native rendering evidence separate from unit assertions, and Linux execution
separate from macOS compilation.

For performance fix the dataset hash, event window/timezone, root/file counts,
bytes, cache state and iteration count. Record samples and median wall time and
peak memory for both revisions. Diagnose a warm regression above 20%. Memory
counters that return zero are unavailable evidence, not zero allocation. Preserve
failed baseline-equivalence checks and validate intended semantic changes against
independent fixture arithmetic. Record every measured mode, including regressions,
and distinguish measured source hashes from later nonsemantic organization changes.

Update manifest statuses only for the exact verified fixture/path/format/OS
scope. Retain explicit product variants and later milestones as deferred.
