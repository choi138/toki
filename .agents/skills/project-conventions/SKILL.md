---
name: "project-conventions"
description: |
  Apply this before changing Toki source, tests, app resources, XcodeGen
  configuration, SwiftFormat/SwiftLint settings, usage readers, security audit
  logic, SwiftUI feature screens, view models, or macOS app entry code.
metadata:
  author: codex
  version: "1.0.0"
---

# Project Conventions

Review these rules before editing Toki code or project configuration.

## When To Activate

- Before editing `Toki/**/*.swift`
- Before editing `TokiTests/**/*.swift`
- Before changing `project.yml`, `Toki.xcodeproj`, `.swiftformat`, or
  `.swiftlint.yml`
- When working on usage readers, pricing, aggregation, security audit scanning,
  SwiftUI feature screens, app launch/menu bar behavior, or tests

## Read First

Open the shared conventions entry point first:

```text
Read: .agents/skills/project-conventions/conventions.md
```

Then load only the reference files that match the current task.

## Reference Map

- `references/architecture.md`: app directory ownership, data flow, reader and
  security audit boundaries, SwiftUI feature boundaries.
- `references/swift-style.md`: Swift style, SwiftUI guidance, sensitive local
  data handling, formatter/linter expectations.
- `references/testing-verification.md`: focused and full validation commands.

## Workflow

1. Read `conventions.md`.
2. Read the relevant task-specific reference.
3. Inspect the existing pattern in the nearest files.
4. Implement with narrowly scoped changes.
5. Run focused checks or explain why they could not be run.

Use `AGENTS.md` for repo-level policy and `.agents/conventions/git-workflow.md`
for commit and PR workflow rules.
