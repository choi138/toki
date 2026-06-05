import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

type HookInput = {
  session_id?: string;
  cwd?: string;
  hook_event_name?: string;
  turn_id?: string;
  last_assistant_message?: string | null;
};

type NotifyState = {
  started_at: string;
  started_at_ms: number;
  turn_id?: string;
  cwd?: string;
  notified_keys: string[];
};

const __dirname = dirname(fileURLToPath(import.meta.url));

const DEFAULT_MIN_SECONDS = 20;
const MAX_BODY_LENGTH = 160;
const MAX_NOTIFIED_KEYS = 20;
const NOTIFY_DISABLED_VALUES = new Set(["0", "false", "no", "off"]);

const readStdin = (): string => {
  try {
    return readFileSync(0, "utf8");
  } catch {
    return "";
  }
};

const parseInput = (): HookInput | undefined => {
  const rawInput = readStdin();
  const hasInput = rawInput.trim().length > 0;

  if (!hasInput) {
    return undefined;
  }

  try {
    return JSON.parse(rawInput) as HookInput;
  } catch {
    return undefined;
  }
};

const sanitizeFilePart = (value: string): string => {
  const sanitizedValue = value.replace(/[^a-zA-Z0-9._-]/g, "_");

  if (sanitizedValue.length > 0) {
    return sanitizedValue;
  }

  return "unknown";
};

const getStatePath = (sessionId: string): string => {
  const stateDir = join(__dirname, "state");
  mkdirSync(stateDir, { recursive: true });

  return join(stateDir, `notify-${sanitizeFilePart(sessionId)}.json`);
};

const loadState = (statePath: string): NotifyState | undefined => {
  if (!existsSync(statePath)) {
    return undefined;
  }

  try {
    return JSON.parse(readFileSync(statePath, "utf8")) as NotifyState;
  } catch {
    return undefined;
  }
};

const saveState = (statePath: string, state: NotifyState): void => {
  writeFileSync(statePath, JSON.stringify(state, null, 2));
};

const getMinSeconds = (): number => {
  const rawValue = process.env.CODEX_NOTIFY_MIN_SECONDS;
  const parsedValue = Number(rawValue);
  const hasConfiguredValue = Number.isFinite(parsedValue) && parsedValue >= 0;

  if (hasConfiguredValue) {
    return parsedValue;
  }

  return DEFAULT_MIN_SECONDS;
};

const shouldForceNotify = (): boolean => {
  return process.argv.includes("--force");
};

const isNotificationDisabled = (): boolean => {
  const envValue = process.env.CODEX_NOTIFY_ENABLED?.trim().toLowerCase();

  return envValue !== undefined && NOTIFY_DISABLED_VALUES.has(envValue);
};

const normalizeWhitespace = (value: string): string => {
  return value.replace(/\s+/g, " ").trim();
};

const truncateText = (value: string, maxLength: number): string => {
  const normalizedValue = normalizeWhitespace(value);

  if (normalizedValue.length <= maxLength) {
    return normalizedValue;
  }

  return `${normalizedValue.slice(0, maxLength - 3)}...`;
};

const escapeAppleScriptString = (value: string): string => {
  return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
};

const sendMacNotification = (title: string, body: string): void => {
  const script = `display notification "${escapeAppleScriptString(body)}" with title "${escapeAppleScriptString(title)}"`;

  spawnSync("osascript", ["-e", script], {
    stdio: "ignore",
  });
};

const markStart = (inputData: HookInput, statePath: string): void => {
  const state: NotifyState = {
    started_at: new Date().toISOString(),
    started_at_ms: Date.now(),
    turn_id: inputData.turn_id,
    cwd: inputData.cwd,
    notified_keys: [],
  };

  saveState(statePath, state);
};

const notifyIfNeeded = (inputData: HookInput, statePath: string): void => {
  if (isNotificationDisabled()) {
    return;
  }

  const state = loadState(statePath);

  if (state === undefined) {
    return;
  }

  const elapsedSeconds = (Date.now() - state.started_at_ms) / 1000;
  const shouldNotify = shouldForceNotify() || elapsedSeconds >= getMinSeconds();

  if (!shouldNotify) {
    return;
  }

  const notifyKey = inputData.turn_id ?? inputData.hook_event_name ?? "stop";
  const hasAlreadyNotified = state.notified_keys.includes(notifyKey);

  if (hasAlreadyNotified) {
    return;
  }

  const body = truncateText(inputData.last_assistant_message ?? "Work completed.", MAX_BODY_LENGTH);
  const title = "Toki agent work complete";

  sendMacNotification(title, body.length > 0 ? body : "Work completed.");

  const notifiedKeys = [...state.notified_keys, notifyKey].slice(-MAX_NOTIFIED_KEYS);
  saveState(statePath, {
    ...state,
    notified_keys: notifiedKeys,
  });
};

const main = (): void => {
  const inputData = parseInput();

  if (inputData === undefined) {
    process.exit(0);
  }

  const sessionId = inputData.session_id ?? "unknown";
  const statePath = getStatePath(sessionId);

  if (process.argv.includes("--mark-start")) {
    markStart(inputData, statePath);
    process.exit(0);
  }

  notifyIfNeeded(inputData, statePath);
  process.exit(0);
};

main();
