# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.2] - 2026-06-29

### Added

- GJC usage reader for local JSONL sessions, including assistant and delegated
  task token usage plus recorded cost.
- Output token-per-second tracking across supported agents.
- Menu bar velocity behavior driven by live token activity.
- Toki agent configuration.
- Pricing for zai-org/GLM-5.2 models.

### Changed

- Refreshed README screenshots and supported-agent documentation.
- Usage panel now surfaces other and untracked project usage.
- Panel totals include aggregate TPS.
- Bundle version properties are managed through XcodeGen.

### Fixed

- Cancel in-flight security audit scans before starting a new scan.
- Prevent persistent menu bar highlight after closing the panel.

## [1.1.1] - 2026-06-04

### Fixed

- Show days with no previous usage as a neutral comparison instead of a
  misleading negative trend.

## [1.1.0] - 2026-06-01

### Added

- Development conventions documenting the SwiftFormat, SwiftLint, SwiftUI, and test expectations for ongoing refactors.
- GitHub Actions release workflow for manual and tag-triggered macOS release artifact builds.
- Release documentation covering workflow usage and required signing/notarization secrets.
- Sources tab with per-agent totals, reader status diagnostics, and CSV/JSON copy export.
- Local security audit sheet for scanning AI agent logs for masked API keys, tokens, cloud credentials, JWTs, private key markers, and environment secrets.
- Settings panel for refresh interval, reader enablement, zero-row display, and Launch at Login.
- Pricing lookup diagnostics for exact, prefix, and missing model price matches.

## [1.0.0] - 2026-04-08

### Added

- **Multi-tool support**: Read token usage from Claude Code, Codex, OpenCode, and Gemini CLI local databases
- **Date picker**: Browse and compare usage statistics by any specific date
- **Cache efficiency metric**: Displays the percentage of input-side tokens served from cache, helping users understand prompt caching effectiveness
- **Per-model breakdown**: View token usage and cost split by individual model (e.g., claude-opus-4, gemini-2.5-pro)
- **Menu bar integration**: Lightweight macOS menu bar app — always one click away with no Dock icon
- **Cost tracking**: Accumulated cost display per day in USD, aggregated across all supported tools
- **Token formatting**: Smart K/M suffix formatting for large token counts (e.g., 112.6M)
- **SQLite readers**: Native SQLite-based readers for each supported CLI tool with zero external dependencies
- **macOS 13+ support**: Minimum deployment target macOS 13 Ventura
- **Dark/Light mode**: Full support for both macOS appearance modes via SwiftUI

[Unreleased]: https://github.com/choi138/toki/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/choi138/toki/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/choi138/toki/releases/tag/v1.1.1
[1.1.0]: https://github.com/choi138/toki/releases/tag/v1.1.0
[1.0.0]: https://github.com/choi138/toki/releases/tag/v1.0.0
