import { readFileSync } from "node:fs";

type HookInput = {
  session_id?: string;
  cwd?: string;
  tool_input?: {
    command?: string;
  };
};

const emitEvent = (..._args: unknown[]): void => {};

const ADDITIONAL_CONTEXT =
  "This Bash command appears to modify Toki source, tests, resources, or project configuration. " +
  "Workspace policy reminder: apply `project-conventions`, read `.agents/skills/project-conventions/conventions.md`, " +
  "and use the relevant architecture, Swift style, or testing reference before continuing.";

const hasTokiTarget = (value: string): boolean => {
  const targetPatterns = [
    /(?:^|[\s"'`/])(?:\.\/)?Toki(?:\/[^\s"'`]*)?(?=$|[\s"'`])/,
    /(?:^|[\s"'`/])(?:\.\/)?TokiTests(?:\/[^\s"'`]*)?(?=$|[\s"'`])/,
    /(?:^|[\s"'`/])(?:\.\/)?Toki\.xcodeproj(?:\/[^\s"'`]*)?(?=$|[\s"'`])/,
    /(?:^|[\s"'`/])(?:\.\/)?project\.yml(?=$|[\s"'`])/,
    /(?:^|[\s"'`/])(?:\.\/)?\.swiftformat(?=$|[\s"'`])/,
    /(?:^|[\s"'`/])(?:\.\/)?\.swiftlint\.yml(?=$|[\s"'`])/,
  ];

  return targetPatterns.some((pattern) => {
    return pattern.test(value);
  });
};

const hasLikelyMutation = (command: string): boolean => {
  const mutationPatterns = [
    /\bcp\b/,
    /\bmv\b/,
    /\brm\b/,
    /\brsync\b/,
    /\btee\b/,
    /\btouch\b/,
    /\btruncate\b/,
    /\bdd\b/,
    /\binstall\b/,
    /\bmkdir\b/,
    /--write\b/,
    /(^|\s)-i\b/,
    />>?/,
    /\bswiftformat\b(?![^\n]*\s--lint\b)/,
    /\bxcodegen\s+generate\b/,
  ];

  return mutationPatterns.some((pattern) => {
    return pattern.test(command);
  });
};

const main = (): void => {
  let inputData: HookInput;

  try {
    inputData = JSON.parse(readFileSync(0, "utf8")) as HookInput;
  } catch {
    process.exit(0);
  }

  const command = inputData.tool_input?.command ?? "";
  const cwd = inputData.cwd ?? "";
  const shouldWarn = hasLikelyMutation(command) && (hasTokiTarget(command) || hasTokiTarget(cwd));

  if (!shouldWarn) {
    process.exit(0);
  }

  emitEvent(inputData.session_id ?? "unknown", "hook.invoked", {
    hook: "bash_guard",
    trigger: "PreToolUse",
    outcome: "warned",
    exit_code: 0,
  });

  process.stdout.write(
    `${JSON.stringify(
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
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
