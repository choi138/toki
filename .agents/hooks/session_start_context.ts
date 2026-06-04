import { readFileSync } from "node:fs";

type HookInput = {
  session_id?: string;
  source?: string;
};

const emitEvent = (..._args: unknown[]): void => {};

const ADDITIONAL_CONTEXT = [
  "Workspace policy: before editing `Toki/**/*.swift`, `TokiTests/**/*.swift`, resources, `project.yml`, `.swiftformat`, or `.swiftlint.yml`, apply the `project-conventions` skill and read `.agents/skills/project-conventions/conventions.md`.",
  "For project configuration changes, prefer editing `project.yml` and running `xcodegen generate` instead of hand-editing `Toki.xcodeproj`.",
  "Treat local usage logs, usage databases, security audit findings, and detected secrets as sensitive local data.",
  "This repository uses soft enforcement hooks for these reminders. Non-shell edits are not hard-blocked by hooks.",
].join(" ");

const main = (): void => {
  let inputData: HookInput;

  try {
    inputData = JSON.parse(readFileSync(0, "utf8")) as HookInput;
  } catch {
    process.exit(0);
  }

  emitEvent(inputData.session_id ?? "unknown", "hook.invoked", {
    hook: "session_start_context",
    trigger: "SessionStart",
    source: inputData.source ?? "unknown",
    exit_code: 0,
  });

  process.stdout.write(
    `${JSON.stringify(
      {
        hookSpecificOutput: {
          hookEventName: "SessionStart",
          additionalContext: ADDITIONAL_CONTEXT,
        },
      },
      null,
      2,
    )}\n`,
  );
  process.exit(0);
};

main();
