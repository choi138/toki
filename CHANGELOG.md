# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/choegeun-won/Toki/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/choegeun-won/Toki/releases/tag/v1.0.0
