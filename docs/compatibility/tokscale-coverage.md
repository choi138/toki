# Pinned Tokscale coverage candidate

This is the assembled M0–M2 integration candidate for existing common clients.
macOS reader/consumer/native gates and Linux core tests passed. Performance
acceptance remains open for OpenCode and OpenClaw; see the execution record. Full parity is not claimed. Comparison source is
[`junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17`](https://github.com/junhoyeo/tokscale/tree/3bd6dceb98925edab4e149c9bb1cf3fec9123f17).
The task supplied the source archive; its local copy has no Git metadata.
Registry/scanner content hashes and all 53 registry entries are retained in
[tokscale-clients.pinned.json](tokscale-clients.pinned.json).

[tokscale-coverage.json](tokscale-coverage.json) is the machine-readable inventory:
53 distinct upstream client IDs, 18 common clients corresponding to 19 default
Toki readers, and 35 explicitly deferred new clients. Kimi CLI and Kimi Code map
to the one upstream `kimi` ID. Desktop, headless, database and archive variants
are format/product subfeatures; they do not increase the registry count.

`existing` means baseline source exists. `implemented` means this candidate edits
that client's scoped behavior. Per-client verification fields state observed
execution and its limits. `planned` means deferred with no reader here.
`verified` requires execution evidence for the specified scope.
`blocked` is reserved for an observed gate.
Every row distinguishes paths, formats, tokens, model attribution, pricing,
fixture source, and remaining limitations.

## Complete common-client discovery audit

Paths use the caller-injected home and environment. New overrides require an
absolute POSIX path without NUL; unset, blank, relative, tilde and file-URI values
fall back. Spaces in valid paths are preserved. Existing Pi/OMP relative-profile
rules remain in their dedicated resolver.

| ID → Toki reader | Candidate discovery / format contract | Remaining gap or scope boundary |
| --- | --- | --- |
| `claude` → Claude Code | `CLAUDE_CONFIG_DIR` selects `{projects,transcripts}` exclusively; default `~/.claude`. Both recursively read assistant `message.usage` JSONL, including old-mtime files. | cc-mirror variant/config discovery deferred. Existing Toki request/message max merge retained. Malformed-record diagnostics fail the read with fixed messages that omit project/file names; cancellation remains distinct. |
| `codex` → Codex | `CODEX_HOME` selects `state_5.sqlite`, `sessions`, `archived_sessions` exclusively; default `~/.codex`. Existing rollout discovery runs even without the DB. | Date-directory/lookback and flat archive discovery retained. Arbitrarily nested or undated rollouts, Tokscale headless roots, `TOKSCALE_HEADLESS_DIR`, and OpenClaw harness reassignment deferred. |
| `gemini` → Gemini CLI | `GEMINI_CLI_HOME/tmp`, default `~/.gemini/tmp`; JSON chat `messages[]`, direct canonical-token JSONL, existing legacy `usageMetadata` JSON. | Headless `stats`/`result.stats`, alternate token keys, timestamp fallback and cache-inclusive normalization deferred. Unsupported recording data is diagnosed. |
| `gjc` → GJC | All of `GJC_CODING_AGENT_DIR/sessions`, `{GJC_CONFIG_DIR,PI_CONFIG_DIR}/agent/sessions`, explicitly configured `XDG_DATA_HOME/gjc/sessions`, and `~/.gjc/agent/sessions`. Includes nested children. | Canonical aliases/overlapping roots collapse; independent roots stay separate. Hard-link copies and root relocation identity are not reconciled. No 9Router source-label override. Shared Pi/OMP storage retains GJC-only headerless, model-less and task records; common records count once through their existing owner. Canonical shared ownership participates in fresh source signatures, including alias retargeting. |
| `kimchi` → Kimchi | `KIMCHI_CODING_AGENT_DIR/sessions` exclusive; otherwise existing `${XDG_CONFIG_HOME:-~/.config}/kimchi/harness/sessions`; existing Pi-compatible parser. | Upstream's fallback is literal `~/.config`; Toki's XDG extension is retained. No parser expansion. |
| `pi` → Pi | Existing `PI_CODING_AGENT_SESSION_DIR`, then `PI_CODING_AGENT_DIR/sessions`, default `~/.pi/agent/sessions`; existing Pi/OMP shared-root ownership. | Pinned upstream uses a fixed root to avoid duplicate Pi/OMP scans. Toki's preexisting overrides are retained; no extra reader is registered. |
| `omp` → Oh My Pi | Existing `PI_CONFIG_DIR`, `OMP_PROFILE`/`PI_PROFILE`, `~/.omp` and XDG profile/session roots. | Pinned upstream uses fixed `~/.omp/agent/sessions`; Toki profile/XDG behavior is retained. |
| `senpi` → Senpi | Existing `SENPI_CODING_AGENT_DIR`, `SENPI_CODING_AGENT_SESSION_DIR`, home and injected `PWD` `.omo` children/session roots. | Global transcript-header cwd probes and `.omo/omo.jsonc` or `omo.json` `task.state_dir` resolution deferred. These need bounded dynamic discovery coordinated with signatures and mount monitoring. |
| `kimi` → Kimi CLI, Kimi Code | Existing `~/.kimi/sessions`, `~/.kimi-code/sessions`, additive `KIMI_SHARE_DIR` and `KIMI_CODE_HOME`; `wire.jsonl`. | Kimi Work/Desktop app-data roots and config-directed `share_dir` deferred. Upstream Code override selection differs from Toki's retained additive policy. |
| `qwen` → Qwen CLI | Existing `~/.qwen/projects`, additive `QWEN_HOME/projects`, `QWEN_RUNTIME_DIR/projects`. | No equivalent client-specific override in pinned registry; Toki extensions retained. |
| `amp` → Amp | Existing `${XDG_DATA_HOME:-~/.local/share}/amp/threads`; JSON. | Root aligns; no blanket parser/replica parity claim. |
| `droid` → Factory Droid | Existing `~/.factory/sessions`; settings JSON and JSONL. | No client-specific root override in pinned registry/scanner. Generic extra directories excluded. |
| `copilot` → GitHub Copilot CLI | Existing `~/.copilot/otel` plus absolute `.jsonl` `COPILOT_OTEL_FILE_EXPORTER_PATH`. | Copilot Desktop `~/.copilot/data.db`, VS Code workspaceStorage chatSessions, and extensionless exporter files deferred. |
| `hermes` → Hermes | Default `~/.hermes/state.db` plus bounded named profiles; explicit `HERMES_HOME` remains exclusive. Fresh canonical DB/sidecar and selected membership/ledger/key paths feed signatures and mount validation. App retains healthy usage with partial status; CLI reports selected collection history. | Unmapped flat ledgers are not guessed into membership. Snapshot exports reject incomplete collections. The synthetic native partial-result source view and Linux core fixtures passed. |
| `opencode` → OpenCode | Registry uses injected home/environment: default and channel DBs, additive `OPENCODE_DB`, legacy `storage/message` JSON; fresh classifier-selected DB/sidecars/JSON feed signatures and mount validation. | Bounded v1/v2/legacy schemas; unknown schemas and wholly undecodable stores fail. Empty, user-only and mixed valid/invalid stores retain compatibility. No arbitrary replica relocation or pricing expansion. |
| `openclaw` → OpenClaw | All four injected-home agents roots: `.openclaw`, `.clawdbot`, `.moltbot`, `.moldbot`; nested JSONL, arbitrary deleted/reset suffixes and SQLite transcript events. Same fresh bounded classifier supplies canonical mount/signature paths without mtime cutoff. | Compressed archives and embedded Codex/app-server reassignment remain deferred. Explicit root initializers remain exclusive. |
| `cursor` → Cursor | Unmodified baseline OS-specific local Cursor SQLite reader. | Explicitly excluded. Upstream account-cache JSON/CSV is a different data surface; registry overlap does not imply equivalence. |
| `grok` → Grok CLI | `GROK_HOME/sessions`, default `~/.grok/sessions`; per-session `usage.json` turn deltas with per-model breakdown and reported `costUsdTicks`, plus sibling `summary.json` for cwd and title. | Pinned upstream pattern is `updates.jsonl`; its `turn_completed` numbers duplicate `usage.json`, which is read instead. Discovery is fixed at `sessions/<project>/<session>`, so a session's own `subagents/` children are not rescanned; each subagent is counted once under its own session directory. No pricing expansion — unpriced models stay unpriced rather than estimated. |

The audit includes the full pinned `clients.rs` registry and `scanner.rs`
supplemental paths, plus the common clients' parsers. See
[fixture-provenance.md](fixture-provenance.md) for source attribution. Generic
`TOKSCALE_EXTRA_DIRS`, scanner-settings roots and Synthetic attribution are outside
this candidate. No new client, protocol, dependency, pricing catalog or account
integration is added.

## Known-format and conservation boundaries

- Claude reuses Toki's request/message maximum counts, cache-write TTL pricing,
  attribution and activity merging across projects/transcript replicas. Id-less
  records retain file/line identity; raw request-ID merge policy is not redesigned.
  Parser cache version 4 rejects older entries for bounded reparse; ledger schemas
  are unchanged. Discovery and cached JSONL diagnostics retain no URL-bearing error
  object and omit encoded project names, including denied and oversized files.
- Codex retains cumulative/delta reconciliation, cache/reasoning inclusion,
  `session_meta` identity and pricing. The removed DB-presence gate permits existing
  current/archive rollout fallback. SQLite error/fallback policy is unchanged.
- Gemini retains Toki's bucket sum `input + output + tool + cached + thoughts`;
  `tool` remains in output and `thoughts` remains reasoning. The upstream
  cache-subtraction/tool-input convention is not adopted. Known models use the
  existing dated price lookup; unknown models have `costIsKnown: false`.
- Gemini's explicit session + message ID selects the last line within a file,
  including downward revisions. Across files it selects newest event timestamp,
  then JSONL on a tie, then lexical path. Selection happens before `[start,end)`
  filtering. Id-less entries remain file/line scoped. Legacy `usageMetadata` keeps
  file-mtime dating and unattributed model rows. Unrelated JSON metadata outside
  chat locations is ignored. JSONL non-usage `init/user/gemini/info/error/warning`
  records and explicit session headers are accepted; unsupported schemas fail.
- GJC uses the existing Pi-compatible parser/cache/pricing/alias merge within each
  independent canonical root. New roots use `gjc:<root SHA256>:<sessionID>` for
  token attribution and activity identity. The legacy root and old single-root
  initializer keep their existing IDs. A digest avoids placing the raw new root
  path in that namespace; it is not a persistent identity across root moves. Shared
  Pi/OMP files are streamed through the actual owning parser and GJC parser; GJC
  keeps only records the owner rejects. All observed GJC records consume budgets,
  including filtered common rows. Owner-specific selection identities invalidate
  signatures when aliases retarget even if GJC file membership is unchanged.

Claude/Gemini/GJC discovery reuses bounded readers: 50,000 files, 500,000 visited
entries, 256 MiB per file, 4 MiB per JSONL line, existing protocol event limits and
cancellation checks. Gemini's two extension walks share the visit budget. Claude
and Gemini now inspect history by event date rather than skip old-mtime files;
cold-scan cost and memory are measured separately from correctness. Nested symlink entries are
excluded; explicitly selected root symlinks are canonicalized at read time.

## Explicit new-client deferral

Each of these 35 IDs has its own `planned` / `deferred-new-client` row, empty
reader list and stated limitation in the JSON manifest:

```text
roocode kilocode mux kilo crush goose codebuff antigravity zed kiro trae warp
cline jcode commandcode micode antigravity-cli junie zcode opencodereview
codebuddy workbuddy devin-cli devin-desktop augment reasonix prime-agent freebuff
cherrystudio dsh mcode fx lmstudio unsloth hindsight
```

## Evidence and remaining gates

The macOS candidate passed 549 core, 700 native app and 25 hub tests, plus release
builds, SwiftFormat and strict SwiftLint. Linux Swift 5.9.2 passed 549 core tests.
The Hermes partial source view was rendered and inspected using synthetic usage.
The bounded independent review completed three rounds; all actionable findings
were reproduced and fixed, without a fourth-round or blanket approval claim.
See [the execution record](verification-20260908.md) for exact evidence, limitations
and the separate final Linux release/CLI/mutation results.

Collector revision 1 changes local agent signatures once for changed collectors;
Claude parser cache version 4 invalidates old parsed entries. Unchanged parser
caches, Hermes accounting ledgers and the snapshot wire schema are preserved.
Mount validation refreshes canonical selected paths on each check and compares
late paths to the original mount table, including nearest ancestor mounts.

Performance measurements completed 72 successful subprocesses / 216 samples.
OpenCode warm runtime increased 217.9%, OpenClaw 23.1%, and aggregate snapshot 14.0%;
all modes and memory figures are in the execution record. Baseline equality fails
for OpenClaw's corrected overlapping-session wall time (10,640 → 665 seconds).
Independent arithmetic validates all 108 candidate samples. These are measured
limitations, not performance acceptance or complete parity. All fixtures are
synthetic/source-derived, never production evidence.
