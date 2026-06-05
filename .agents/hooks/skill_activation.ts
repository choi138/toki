import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type SkillRule = {
  priority?: string;
  description?: string;
  additionalContext?: string;
  promptTriggers?: {
    keywords?: string[];
    intentPatterns?: string[];
  };
};

type SkillRulesFile = {
  skills?: Record<string, SkillRule>;
};

type HookInput = {
  prompt?: string;
  session_id?: string;
};

const __dirname = dirname(fileURLToPath(import.meta.url));

const emitEvent = (..._args: unknown[]): void => {};

const loadSkillRules = (): SkillRulesFile => {
  const rulesPath = join(__dirname, "..", "skills", "skill-rules.json");
  return JSON.parse(readFileSync(rulesPath, "utf8")) as SkillRulesFile;
};

const matchPromptTriggers = (
  prompt: string,
  triggers: NonNullable<SkillRule["promptTriggers"]>,
): boolean => {
  const promptLower = prompt.toLowerCase();

  const hasKeywordMatch = (triggers.keywords ?? []).some((keyword) => {
    return promptLower.includes(keyword.toLowerCase());
  });

  if (hasKeywordMatch) {
    return true;
  }

  return (triggers.intentPatterns ?? []).some((pattern) => {
    return new RegExp(pattern, "i").test(prompt);
  });
};

const main = (): void => {
  let inputData: HookInput;

  try {
    inputData = JSON.parse(readFileSync(0, "utf8")) as HookInput;
  } catch {
    process.exit(0);
  }

  const prompt = inputData.prompt ?? "";
  const isPromptEmpty = prompt.trim().length === 0;

  if (isPromptEmpty) {
    process.exit(0);
  }

  let rules: SkillRulesFile;

  try {
    rules = loadSkillRules();
  } catch {
    process.exit(0);
  }

  const skills = rules.skills ?? {};

  const matched = Object.entries(skills).flatMap(([name, rule]) => {
    const triggers = rule.promptTriggers;
    const hasTriggers = triggers !== undefined;

    if (!hasTriggers) {
      return [];
    }

    const isMatched = matchPromptTriggers(prompt, triggers);

    if (!isMatched) {
      return [];
    }

    return [
      {
        name,
        priority: rule.priority ?? "medium",
        description: rule.description ?? "",
        additionalContext: rule.additionalContext ?? "",
      },
    ];
  });

  if (matched.length === 0) {
    emitEvent(inputData.session_id ?? "unknown", "hook.invoked", {
      hook: "skill_activation",
      trigger: "UserPromptSubmit",
      outcome: "no_match",
      matched_count: 0,
      exit_code: 0,
    });
    process.exit(0);
  }

  const additionalContext = matched
    .map((skill) => {
      const hasAdditionalContext = skill.additionalContext.trim().length > 0;

      if (hasAdditionalContext) {
        return skill.additionalContext.trim();
      }

      return `Apply the \`${skill.name}\` skill before editing if this task falls within its scope.`;
    })
    .filter((value, index, values) => {
      return values.indexOf(value) === index;
    })
    .join("\n\n");

  emitEvent(inputData.session_id ?? "unknown", "hook.invoked", {
    hook: "skill_activation",
    trigger: "UserPromptSubmit",
    outcome: "matched",
    matched_count: matched.length,
    exit_code: 0,
  });

  process.stdout.write(
    `${JSON.stringify(
      {
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext,
        },
      },
      null,
      2,
    )}\n`,
  );
  process.exit(0);
};

main();
