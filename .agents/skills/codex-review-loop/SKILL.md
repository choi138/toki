---
name: codex-review-loop
description: Review Toki uncommitted changes, branches, or commits with path- and semantic-routed specialist lanes, normalize P0-P3 findings, and optionally fix only findings the user explicitly approves. Use when the user asks for a local code review, review loop, review-and-fix pass, re-review, or approved finding remediation in the Toki repository. Keep GitHub review submission, PR comments, push, merge, and other remote writes outside this skill.
---

# Toki Codex Review Loop

Run an rvw-compatible lane review, then apply the codex-lb-style approval,
atomic-fix, verification, and bounded re-review loop.

## Core Contract

- Treat every review request as read-only until the user explicitly approves a
  write mode.
- Never infer permission to edit or commit from phrases such as "review this"
  or from a GitHub `@codex review` request.
- Never push, submit a GitHub review, comment, resolve threads, label, merge, or
  otherwise mutate remote state from this skill.
- Preserve unrelated staged, unstaged, and untracked changes. Never use
  `git reset`, `git checkout`, or broad restoration to undo a finding fix.
- Treat local usage logs, databases, audit findings, prompts, transcripts, and
  credentials as sensitive. Do not print raw matched diff content.
- Apply `project-conventions` and read its task-specific references before
  fixing Toki source, tests, resources, or project configuration.
- Apply `.agents/conventions/git-workflow.md` before any commit. A commit
  requires explicit user authorization separate from review authorization.

## Trust Boundary

Scope resolution runs before any review and must survive a hostile repository.
Treat this section as the contract a finding is measured against: report a
finding when it breaks an invariant below, and classify it `wont_fix` with this
section as the reason when it only restates a non-goal.

### Untrusted Inputs

- Repository file contents and tree layout, including untracked and ignored
  paths.
- Repository Git configuration: `.git/config`, `.gitattributes`, `.gitmodules`,
  and any configured hook or helper program.
- The inherited `PATH` and every `GIT_*` environment variable.
- Lane result JSON, including every path and line number it reports.

### Enforced Invariants

1. Only trusted executables run. `git` and the review binary resolve from the
   platform default path, never from an inherited `PATH`, and the runner narrows
   `PATH` before invoking any external command.
2. No repository-configured program executes. Content filters, `textconv`,
   external diff, `core.fsmonitor`, `core.hooksPath`, and lazy fetch are
   overridden to inert values or the scope is refused.
3. Workspace confinement is derived from the filesystem, not from Git. The
   inventory walks the real tree from the repository root and validates every
   symbolic link target, so ignore rules and index modes cannot hide a path.
4. Every scope fails closed. A submodule, embedded repository, escaping symlink,
   non-UTF-8 path, or unbounded inventory marks the scope unsafe and stops before
   Codex is invoked.
5. Paths keep byte fidelity across process boundaries. Roots and path lists cross
   as NUL-terminated data and are never trimmed.
6. Reported findings are untrusted data. A finding path must be
   repository-relative, free of NUL, and free of empty, current, or parent
   segments before it is used.
7. The baseline lane is always on. A registry that marks it otherwise is
   rejected.

Add a regression test with every change that touches an invariant, and name the
invariant in the test.

### Non-Goals

- Sandboxing the host. This skill reduces what executes during review; it does
  not isolate a repository the user already chose to open.
- Restricting native review to the reviewed diff. `codex exec review` may read
  other in-repository files by design, so confinement is to the repository root,
  not to `changedPaths`.
- Content-level secret detection inside reviewed changes. Exclusion is by path
  pattern only.
- Supporting attacker-chosen repository root paths, such as sibling names that
  differ only by trailing whitespace. Exact roots are preserved, but the user is
  assumed to name their own repository.
- Byte-exact handling of non-UTF-8 paths. Such scopes are refused, not
  supported.

## Workflow

### 1. Resolve One Review Scope

Choose exactly one scope:

- Use `--uncommitted` for staged, unstaged, and untracked changes.
- Use `--base <branch>` for the current branch relative to a base branch.
- Use `--commit <sha>` for one commit.

Prefer an exact scope named by the user. Do not fetch or change branches merely
to infer a scope.

Run the resolver:

~~~bash
python3 .agents/skills/codex-review-loop/scripts/resolve_review_scope.py \
  --repo . \
  --uncommitted \
  --pretty
~~~

Stop before invoking Codex when `safeToReview` is false or `hasChanges` is
false. Excluded sensitive paths make the scope unsafe because
`codex exec review --uncommitted` cannot exclude individual paths.

### 2. Load Only Activated Review Rules

Always read the common reviewer prompt and baseline lane. Read only the
specialist lane files named by `activatedLanes`. Also read the finding schema
and verification reference before reporting or fixing findings.

Treat lane activation as additive. Never disable baseline correctness or
security reasoning merely because a path pattern did not match.

### 3. Run One Pass Per Activated Lane

Run the baseline lane and every activated specialist lane:

~~~bash
.agents/skills/codex-review-loop/scripts/run_review_lane.sh \
  --repo . \
  --lane baseline \
  --base main
~~~

The runner passes bounded lane instructions through Codex
`developer_instructions`, uses the structured-output schema, requests an
ephemeral Codex session, and refuses inactive or unsafe lanes. Run lanes
sequentially by default. Do not add replicated reviewers or an adjudicator
unless the user explicitly expands the workflow.

### 4. Validate And Merge Findings

Capture each lane's JSON result in a temporary directory, then merge:

~~~bash
python3 .agents/skills/codex-review-loop/scripts/merge_findings.py merge \
  /tmp/toki-review/baseline.json \
  /tmp/toki-review/remote-sync.json
~~~

Reject malformed results. Conservatively merge overlapping findings with a
similar root cause, retain every contributing lane, use the highest priority,
and surface materially conflicting priority opinions.

### 5. Report Before Writing

Present the normalized findings with ID, priority, confidence, location, impact,
suggested fix, and verification plan. Then request one explicit mode:

1. Report only.
2. Fix selected findings without commits.
3. Fix all actionable findings without commits.
4. Fix selected findings and create one verified commit per finding.
5. Fix all actionable findings and create one verified commit per finding.

Treat "Fix P0/P1 only" as a valid selection. For a P0/P1 fix that changes
existing product behavior rather than restoring clearly intended behavior,
describe that behavior change and obtain a second confirmation.

### 6. Fix One Finding At A Time

Before each fix:

1. Re-read the affected code and relevant `project-conventions` references.
2. Inspect `git status` and the affected diff.
3. Record the pre-fix state of only the files or hunks that will change.
4. Use `apply_patch` for the narrow fix.
5. Run the smallest verification profile that can prove the finding fixed.

If verification fails, reverse only the patch introduced for that finding. If
that boundary cannot be proven, stop and report the failure instead of risking
the user's work.

For `--uncommitted` reviews, default to no commits. Create atomic commits only
when the user explicitly selects a commit mode and the new fix can be separated
from pre-existing changes without staging unrelated hunks.

### 7. Re-review With A Bound

After approved fixes, rerun baseline plus only lanes affected by the fix. Stop
after three total review rounds. If the same root cause returns in two
consecutive rounds, mark it `wont_fix` with the reason instead of looping.

Count externally triggered rounds against the same bound. A pushed branch can
re-request review automatically, so a GitHub `@codex review` round is a round
here too.

Fix at the invariant, not at the reported case. When a finding names one variant
of an invariant in the trust boundary, audit every other variant of that same
invariant locally and fix them together in one change. Repairing only the
reported case is what turns one finding into a new round, because the next round
reports the next variant. Before pushing, state which invariant each fix
restores and which adjacent variants were checked.

### 8. Finish With A Local Report

Report:

- Review scope and activated lanes.
- Findings fixed, skipped, `wont_fix`, or left for reporting only.
- Verification commands and outcomes.
- Commits created, if explicitly authorized.
- Remaining risks or unverified checks.

State explicitly that no push or GitHub write occurred.

## Reference Map

- Common contract: [reviewer.md](references/prompts/reviewer.md)
- Lane registry: [lane-registry.json](references/lane-registry.json)
- Finding schema: [review-findings.schema.json](references/schemas/review-findings.schema.json)
- Verification profiles: [verification.md](references/verification.md)
- Baseline: [baseline.md](references/lanes/baseline.md)
- Usage and pricing: [usage-pricing.md](references/lanes/usage-pricing.md)
- Privacy and security: [privacy-security.md](references/lanes/privacy-security.md)
- Remote sync: [remote-sync.md](references/lanes/remote-sync.md)
- Concurrency and lifecycle: [concurrency-lifecycle.md](references/lanes/concurrency-lifecycle.md)
- SwiftUI architecture: [swiftui-architecture.md](references/lanes/swiftui-architecture.md)
- Build and portability: [build-portability.md](references/lanes/build-portability.md)
- Testing: [testing.md](references/lanes/testing.md)
