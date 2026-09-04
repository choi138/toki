<p align="center">
  <img src="web/public/icon.png" width="96" alt="Toki app icon" />
</p>

<h1 align="center">Toki</h1>

<p align="center"><strong>The work beneath the output.</strong></p>

<p align="center">
  A local-first macOS menu bar app for tokens, cost, project attribution,<br />
  and the time your AI coding agents actually spend working.
</p>

<p align="center">
  <a href="https://github.com/choi138/toki/releases/latest"><strong>Download</strong></a>
  · <a href="#features">Features</a>
  · <a href="#supported-agents-and-models">Supported agents &amp; models</a>
  · <a href="https://toki.choi138.com">Website</a>
  · <a href="#contributing">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/choi138/toki/actions/workflows/ci.yml"><img src="https://github.com/choi138/toki/actions/workflows/ci.yml/badge.svg" alt="CI status" /></a>
  <a href="https://github.com/choi138/toki/releases/latest"><img src="https://img.shields.io/github/v/release/choi138/toki" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013.0%2B%20%7C%20Linux%20Agent-blue" alt="macOS 13 or later and Linux Agent" />
  <img src="https://img.shields.io/badge/Swift-5.9.2-orange" alt="Swift 5.9.2" />
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/choi138/toki" alt="MIT license" /></a>
  <a href="https://github.com/choi138/toki/stargazers"><img src="https://img.shields.io/github/stars/choi138/toki?style=social" alt="GitHub stars" /></a>
</p>

Toki reads each supported tool's local usage store and turns it into six focused
views for daily totals, date ranges, projects, models, sources, work time, hourly
usage, exports, and security checks. Optional end-to-end encrypted remote sync
can add the same local sources from Linux/Ubuntu or other Macs without giving
Toki SSH or filesystem access.

> **Beyond token counting:** Toki measures direct main-agent work, delegated
> subagent work, wall-clock overlap, and a parallel multiplier, so you can see
> how long your agents actually worked—not only how many tokens they spent.

---

## Install

### Download the app

1. Download `Toki-macOS.zip` from the
   [latest release](https://github.com/choi138/toki/releases/latest).
2. Unzip it and move `Toki.app` into `/Applications`.
3. Toki is **not yet signed with an Apple Developer ID**, so macOS blocks it on
   first launch with a "damaged and can't be opened" or "unidentified developer"
   message. Clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Toki.app
   ```

   Add `sudo` if you get a permission error. Then open Toki normally.

<details>
<summary>Prefer not to use the terminal?</summary>

On macOS 15 (Sequoia) and later, the Control-click → Open shortcut no longer
works. Instead:

1. Try to open Toki, then dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll to the bottom, and
   click **Open Anyway** next to Toki (within one hour of the warning).
3. Enter your admin password, then open Toki again and confirm.

Run Toki from `/Applications` rather than `~/Downloads`, otherwise macOS App
Translocation runs it from a hidden read-only copy.

</details>

> **Why the extra step?** Notarizing a macOS app requires a paid Apple Developer
> account. Toki does not have one yet. Every release is built in public by the
> [Release workflow](.github/workflows/release.yml) from the tagged commit, and
> the full source is in this repository — you can also build it yourself below.

### Build from source

```bash
git clone https://github.com/choi138/toki.git
cd toki
brew install xcodegen swiftlint swiftformat
cd menubar && xcodegen generate && open ./Toki.xcodeproj
```

Then build and run the `Toki` scheme in Xcode. Locally built apps are not
quarantined, so no `xattr` step is needed.

### Uninstall

```bash
rm -rf /Applications/Toki.app
rm -rf ~/Library/Application\ Support/Toki
defaults delete com.toki.app 2>/dev/null
```

Toki never writes to your agents' data directories, so removing it leaves every
tracked tool untouched.

---

## Screenshots

| Overview | Projects | Models |
| --- | --- | --- |
| <img src="menubar/Screenshots/screenshot_overview.png" width="220" alt="Overview tab showing total tokens and seven-day, thirty-day, and all-time totals" /> | <img src="menubar/Screenshots/screenshot_projects.png" width="220" alt="Projects tab showing attribution summary and top project usage" /> | <img src="menubar/Screenshots/screenshot_models.png" width="220" alt="Models tab showing token and cost breakdown with relative token-share bars" /> |

| Sources | Time | Hourly | Settings |
| --- | --- | --- | --- |
| <img src="menubar/Screenshots/screenshot_sources.png" width="220" alt="Sources tab with CSV and JSON export controls, per-tool usage, and reader status" /> | <img src="menubar/Screenshots/screenshot_time.png" width="220" alt="Time tab comparing direct, delegated, wall-clock, and parallel work time" /> | <img src="menubar/Screenshots/screenshot_hourly.png" width="220" alt="Hourly tab with usage chart and peak-hour summary" /> | <img src="menubar/Screenshots/screenshot_settings.png" width="220" alt="Settings display controls for zero rows, menu bar cost, pricing updates, and launch at login" /> |

---

## Features

- **Daily and ranged usage**: total, input, output, cache read/write, reasoning
  tokens, cache hit rate, and estimated cost.
- **Six focused views**: Overview, Projects, Models, Sources, Time, and Hourly
  stay one click away in the compact tab bar.
- **Projects and sessions**: cost and token attribution with expandable project
  and session lists when logs expose enough context.
- **Models**: per-model token totals, cost estimates, active time, and
  proportional token-share bars, plus unpriced/context-only rows.
- **Sources**: per-agent totals, reader status diagnostics, and CSV/JSON copy
  exports. Reader failures also surface as a header badge that opens Sources.
- **Work time**: direct main-agent time, delegated subagent time, wall-clock
  overlap, stream counts, and parallel multiplier.
- **Hourly usage**: active hours, peak hour, average active hour, and top-hour
  rows.
- **Local security audit**: masked findings for API keys, access tokens, cloud
  credentials, JWTs, private key blocks, and secret assignments.

## Supported Agents And Models

Toki auto-detects the default local data locations below. No account login or
remote service is required for local readers.

| Agent | Usage data source | Notes |
| --- | --- | --- |
| **Claude Code** | `~/.claude/projects/**/*.jsonl` | Deduplicates request/message usage and caches parsed logs locally. |
| **Codex** | `~/.codex/state_5.sqlite` plus discovered rollout JSONL files | Reconstructs ranged usage from rollout token-count snapshots. |
| **Hermes** | `~/.hermes/state.db` | Reads per-session token totals, model, cost, and activity from SQLite. |
| **Cursor** | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | Exact token rows are counted when present; context-window metrics are shown separately when exact tokens are unavailable. |
| **Gemini CLI** | `~/.gemini/tmp/*/chats/**/*.json` | Reads current and legacy Gemini chat history formats. |
| **GJC** | `~/.gjc/agent/sessions/**/*.jsonl` | Reads local JSONL sessions, including assistant and delegated task token usage plus recorded cost. |
| **Factory Droid** | `~/.factory/sessions/**/*.{json,jsonl}` | Reads local Factory session records. |
| **Amp** | `$XDG_DATA_HOME/amp/threads/**/*.json` | Reads local thread and ledger usage records. |
| **Senpi** | `~/.senpi/agent/sessions/**/*.jsonl` and OMO session directories | Includes delegated task sessions when they are present. |
| **Pi** | `~/.pi/agent/sessions/**/*.jsonl` | Reads local Pi coding-agent sessions. |
| **Oh My Pi** | Its configured local session directories | Shares a source with Pi when both tools use the same store. |
| **Kimchi** | `$XDG_CONFIG_HOME/kimchi/harness/sessions/**/*.jsonl` | Reads Kimchi harness sessions. |
| **OpenCode** | `~/.local/share/opencode/opencode.db` | Reads assistant message token rows from SQLite. |
| **OpenClaw** | `~/.openclaw/agents/**/*.jsonl` | Reads assistant usage records from local agent logs. |
| **Copilot CLI** | `~/.copilot/otel/**/*.jsonl` | Reads OpenTelemetry usage records, including an optional file-exporter path. |
| **Kimi CLI** | `~/.kimi/sessions/**/*.jsonl` | Reads local Kimi CLI sessions. |
| **Kimi Code** | `~/.kimi-code/**/*.jsonl` | Reads local Kimi Code sessions. |
| **Qwen CLI** | `~/.qwen/**/*.jsonl` | Reads local Qwen CLI project sessions. |
| **Remote Toki Agent** | The supported stores above under the remote user's home/XDG directories | Optional outbound-only Linux/macOS Agent uses the same local reader registry and uploads per-device encrypted usage snapshots through a Hub. |

### Model Coverage

Toki preserves every model ID emitted by its supported readers, so a model does
not disappear merely because it is new or lacks a bundled price. Curated pricing
covers Claude, GPT/Codex, Gemini, Grok, GLM, and Kimi families—including
`claude-fable-5-1`—and the optional daily LiteLLM catalog fills in more known
models. Models without a known price remain visible as unpriced rows instead of
being silently omitted from token totals.

## Remote Devices

Remote sync consists of an outbound-only `toki-agent`, a ciphertext-only
`toki-hub`, and the macOS Remote Devices reader. It is not tied to SSH and does
not transmit prompts, responses, local paths, project/session attribution, raw
database rows, or security-audit findings.

See [Remote Usage Sync](docs/remote-sync.md) for Ubuntu installation, systemd
services, TLS reverse-proxy configuration, pairing, capacity limits, key
rotation, and the full threat model.

## Privacy And Data Notes

- Local usage collection stays on-device. Automatic model-pricing updates
  (enabled by default) download LiteLLM's public pricing catalog at most once
  every 24 hours; no usage data is sent. Remote sync remains opt-in.
- Remote sync uploads only authenticated encrypted usage snapshots; raw logs,
  databases, prompts/responses, paths, and audit findings remain on the source
  computer.
- Security audit evidence is masked in the UI.
- Cost estimates prefer curated bundled prices and use downloaded prices only
  as a fallback for otherwise unknown models.
- Unknown prices remain visible as unpriced rows instead of being silently
  folded into totals.
- Project/session attribution depends on what each agent records locally; rows
  with weaker attribution are marked as inferred or unknown.

## Controls

- Click the menu bar icon to open the usage popover; right-click it for
  **Open Usage Panel** and **Quit Toki**.
- Enable `Show today's cost in menu bar` to keep the estimated daily cost beside
  the icon. Hover it for today's token total and pricing/reader caveats.
- Switch among Overview, Projects, Models, Sources, Time, and Hourly from the
  six-tab navigation bar.
- Use the date picker for a single day or custom date range.
- Use the shield button to run the local security audit.
- Use the amber reader-failure badge to jump directly to Sources diagnostics.
- Use settings to choose a refresh interval, enable or disable readers, show
  zero-value source rows, and launch Toki at login. Keep
  `Update model pricing automatically` enabled to refresh fallback pricing once
  per day.
- Use the Remote Sync settings to connect a Hub, provision/revoke devices, and
  choose each Agent's retention and interval.
- Use the refresh button for an immediate read; otherwise Toki refreshes on the
  configured interval.

---

## Troubleshooting

**"Toki.app is damaged and can't be opened" / "unidentified developer"**
Toki is unsigned. Run `xattr -dr com.apple.quarantine /Applications/Toki.app`,
or follow the System Settings route in [Install](#install).

**A tool I use shows zero usage**
Open the **Sources** tab and check its reader status. A disabled reader, a
missing data directory, or a non-default install location all show up there. If
the reader reports a failure, the header shows an amber badge that jumps
straight to the diagnostics.

**My tool isn't listed at all**
Only the agents in [Supported Agents And Models](#supported-agents-and-models) are read today. Open an
issue with your tool's local data path and a redacted log sample, or add a
reader yourself — see [Contributing](#contributing).

**Costs look wrong or a model shows no cost**
Toki prefers curated bundled prices and falls back to LiteLLM's public catalog.
Models it has no price for stay visible as unpriced rows rather than being
folded into the total, so a missing price never silently inflates or deflates
your spend. Open an issue with the model ID if you hit one.

**Cursor shows context-window numbers instead of tokens**
Cursor does not always record exact token counts locally. Toki shows exact rows
when they exist and reports context-window metrics separately when they do not.

---

## Requirements

**To run Toki**

- macOS 13.0 or later

**To build from source**

- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`brew install swiftformat`)
- Apple Developer account only when producing signed/notarized release builds
- Optional Linux Agent/Hub: Swift 5.9.2 or later and `libsqlite3-dev`

Remote Agent and Hub builds use SwiftPM:

```bash
swift test --package-path core
swift test --package-path hub
swift build --package-path core -c release --product toki-agent
swift build --package-path hub -c release --product toki-hub
```

## Development

### Repository layout

| Folder | Contents |
| --- | --- |
| `core/` | Cross-platform SwiftPM packages for usage models, local readers, encrypted sync, durable storage, and the Linux-compatible `toki-agent`. |
| `menubar/` | The macOS menu bar app (`Toki.app`), its tests, and screenshots. |
| `hub/` | `toki-hub`, the ciphertext-only Vapor server for remote usage sync. |
| `web/` | The official landing, docs, and download experience built with Next.js and Feature-Sliced Design. |
| `ios/` | Placeholder for the upcoming iPhone app. Not started yet. |

### macOS app and Swift packages

Toki is organized by responsibility:

- `menubar/Toki/App`: menu bar lifecycle and app entry points.
- `menubar/Toki/Domain`: app-level usage/security models, report builders, formatting,
  and export payloads.
- `menubar/Toki/Infrastructure`: app-specific aggregation, remote sync, activity
  monitoring, and security scanning.
- `menubar/Toki/Features`: SwiftUI panels, settings, view models, exports, and audit UI.
- `menubar/TokiTests`: focused unit tests for readers, aggregation, formatting,
  settings, security audit behavior, and view-model logic.
- `core/Sources/TokiUsageCore`: reusable token usage values, active-time estimation,
  date parsing, and the base reader protocol.
- `core/Sources/TokiUsageReaders`: reusable local readers, pricing, parse caches, and
  the Hermes usage ledger.
- `core/Sources/TokiSyncProtocol`: versioned encrypted remote-sync protocol.
- `core/Sources/TokiDurableStorage`: durable private-file primitives shared by sync
  components.
- `core/Sources/TokiAgentCore` and `core/Sources/TokiAgent`: optional Linux-compatible
  outbound collector.
- `hub/Sources/TokiHubCore` and `hub/Sources/TokiHub`:
  dependency-isolated optional Linux-compatible Hub.

The `core` Swift package exposes `TokiUsageCore`, `TokiUsageReaders`,
`TokiSyncProtocol`, `TokiDurableStorage`, and `toki-agent`, with no Vapor
dependency. Importing a library product does not start collection or networking;
callers choose which readers or sync components to run. Server dependencies are
resolved only when the `hub` package is built, so core library users do not pull
in or start Hub code. The nested packages are intended for repository clones,
source/container builds, or distributed binaries; a SwiftPM dependency on this
repository's root URL cannot select `core/Package.swift` or `hub/Package.swift`
directly.

Required checks before opening a PR:

```bash
swiftformat . --lint --disable wrapIfStatementBodies
swiftlint lint --strict --quiet
cd menubar
xcodegen generate
xcodebuild test \
  -project Toki.xcodeproj \
  -scheme Toki \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

CI runs formatting, linting, XcodeGen, build, and tests on macOS, plus SwiftPM
tests and release builds for the Agent and Hub on Ubuntu.

### Website

Visit the public site at [toki.choi138.com](https://toki.choi138.com). The landing
page, docs, and release-aware download page live in [`web/`](./web/). To run
them locally, use Node.js 22.19.0 and pnpm 11.24.0:

```bash
cd web
corepack enable
pnpm install --frozen-lockfile
pnpm dev
```

Then open <http://localhost:3000>. Set `NEXT_PUBLIC_SITE_URL` to the canonical
production URL when deploying so metadata, the sitemap, and robots directives
use the public origin.

## Contributing

Issues and pull requests are welcome. **Issues in languages other than English
are fine** — write in whatever you are comfortable with.

Good places to start are labelled
[`good first issue`](https://github.com/choi138/toki/labels/good%20first%20issue).

### Add support for a new agent

This is the most useful contribution, and it is smaller than it looks — a
minimal reader is around 130 lines. Readers live in the `TokiUsageReaders`
SwiftPM package, so `swift build --package-path core` works without Xcode.

1. Find where your tool stores usage locally (JSONL logs or a SQLite database).
2. Copy the closest existing reader as a starting point:
   - JSONL logs → `core/Sources/TokiUsageReaders/OpenClawReader.swift` (131 lines,
     the simplest one)
   - SQLite → `core/Sources/TokiUsageReaders/OpenCodeReader.swift`
3. Conform to `TokenReader` (`core/Sources/TokiUsageCore/TokenReader.swift`). Only
   `name` and `readUsage(from:to:)` are required; token and output totals have
   default implementations.
4. Register it in `core/Sources/TokiUsageReaders/LocalUsageReaderRegistry.swift`
   (see the existing `LocalUsageReaderDescriptor` list), adding a path override
   so tests can point at a fixture directory.
5. Add a test next to the others in `menubar/TokiTests/`, modelled on
   `menubar/TokiTests/OpenClawReaderTests.swift`.
6. Add a row to [Supported Agents And Models](#supported-agents-and-models).

**No sample logs? Open an issue instead.** A redacted snippet of your tool's
local usage file plus its path is genuinely useful on its own — it is the part
that cannot be written without access to the tool.

### Add or fix model pricing

The lowest-barrier contribution: `core/Sources/TokiUsageReaders/ModelPricing.swift`
is a table of per-model rates. Adding a model is a few lines and CI validates
it, so you can edit it straight from the GitHub web editor. Include a link to
the provider's public pricing page in the PR.

### Before opening a PR

Run the checks listed under [Development](#development). If you changed date,
cost, token, reader status, attribution, or security audit behavior, add or
update a focused test — see
[`.agents/skills/project-conventions/`](.agents/skills/project-conventions/)
for the full conventions.

## Release

Releases are built by the GitHub Actions **Release** workflow. Run it manually
with `workflow_dispatch` to produce workflow artifacts, or push a version tag
such as `v1.1.2` to publish a GitHub Release.

The workflow regenerates the Xcode project, archives the Release configuration,
exports `Toki.app`, packages the app and dSYM ZIPs, and can optionally sign and
notarize the app.

Required signing secrets are `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
`KEYCHAIN_PASSWORD`, `DEVELOPMENT_TEAM`, and `CODE_SIGN_IDENTITY`. Optional
secrets are `PROVISIONING_PROFILE_BASE64`, `NOTARY_APPLE_ID`,
`NOTARY_PASSWORD`, and `NOTARY_TEAM_ID`.

## Tech Stack

- Swift 5.9.2
- SwiftUI and Charts
- SQLite3
- CryptoKit/swift-crypto and Vapor for optional remote sync
- XcodeGen
- SwiftFormat and SwiftLint
- macOS 13.0+

## License

MIT — see [LICENSE](./LICENSE) for details.
