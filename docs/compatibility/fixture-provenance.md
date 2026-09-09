# Fixture and source provenance

The comparison source is the task-supplied archive of
`junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17`, located at sibling
`upstream/`. It has no `.git` directory. The commit identity is supplied with the task, not independently established from that archive. The pinned JSON records
SHA-256 checksums of the inspected `clients.rs` and `scanner.rs` bytes.

Public source references are relative to that repository at the pinned commit:

| Source | Use in this candidate |
| --- | --- |
| `crates/tokscale-core/src/clients.rs` | Minimal facts from all 53 `define_clients!` entries: ID, index, display name, root, path, pattern and override/fallback. |
| `crates/tokscale-core/src/scanner.rs` | Supplemental common-root audit: Claude transcripts/cc-mirror, Codex archives/headless, Gemini extensions, GJC multi-root/XDG, Kimi Work, Copilot Desktop/VS Code, Senpi OmO config/header discovery. |
| `crates/tokscale-core/src/sessions/claudecode.rs` | Claude assistant envelope, `requestId`, `sessionId`, message model/usage and transcript compatibility. |
| `crates/tokscale-core/src/sessions/codex.rs` | Codex `session_meta`, `turn_context` and cumulative `token_count` fixture shape. |
| `crates/tokscale-core/src/sessions/gemini.rs` | JSON chat, direct JSONL, `init`/session headers, repeated message IDs, canonical buckets; alternate fields and stats explicitly excluded. |
| `crates/tokscale-core/src/sessions/gjc.rs`, `pi.rs`, `kimchi.rs` | Session/message envelopes, embedded cost, recursive GJC layout and Kimchi's shared Pi format. |
| Other common `sessions/*.rs` parsers named per manifest row | Audit of baseline format scope and unsupported product variants; no copied reader implementation. |

`tokscale-clients.pinned.json` is a minimal public provenance fixture. The registry
test also fixes the expected 53-ID set in Swift, so editing both JSON files cannot
silently redefine the comparison target. Tests require neither a network request
nor the sibling upstream checkout.

Runtime fixture data is constructed in the existing-source, Hermes, OpenCode,
OpenClaw and dedicated `*CoverageIntegrationTests.swift` suites. IDs,
paths, dates, token counts, costs, metadata and malformed payloads are synthetic.
They contain no user prompts, production sessions, database exports, credentials
or account data. Temporary homes and injected environments constrain discovery;
the snapshot pairing bundle uses newly generated test values and a noncontacted
`hub.example.com` URL. The cache-upgrade fixture is synthetic version-3 cache JSON.

The new tests adapt public schema facts and preserve existing Toki arithmetic;
they are not captured production golden files and do not establish live-product
compatibility. Existing test files listed in the manifest are regression targets;
their inclusion in a passing suite does not validate unsupported formats.

The upstream is MIT licensed, copyright (c) 2025 Junho Yeo. Its license is retained
verbatim in [tokscale-LICENSE.txt](tokscale-LICENSE.txt) for the extracted registry
facts and source-derived schema fixtures. No new dependency is introduced.

Observed assembled execution counts and their scope are recorded in
[tokscale-coverage.json](tokscale-coverage.json) and
[the execution record](verification-20260908.md). Hermes WAL fixtures hold active
read transactions; metadata-only synthetic sidecars in integration tests are
labeled separately and do not prove WAL coherence. The bounded sorter diagnostic
uses 256 events and 4 KiB model metadata, generated entirely from synthetic values.
