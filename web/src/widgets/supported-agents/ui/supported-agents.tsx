import {
  Pill,
  Reveal,
  RevealList,
  RevealListItem,
  SectionShell,
} from '@/shared/ui';

const AGENT_TOOLS: readonly string[] = [
  'Claude Code',
  'Codex',
  'Hermes',
  'Cursor',
  'Gemini CLI',
  'GJC',
  'Factory Droid',
  'Amp',
  'Senpi',
  'Pi',
  'Oh My Pi',
  'Kimchi',
  'OpenCode',
  'OpenClaw',
  'Copilot CLI',
  'Kimi CLI',
  'Kimi Code',
  'Qwen CLI',
];

const MODEL_FAMILIES: readonly string[] = [
  'Claude',
  'GPT & Codex',
  'Gemini',
  'Grok',
  'GLM',
  'Kimi',
  'Qwen',
];

type SupportedAgentsProps = Readonly<{
  copy: Readonly<{
    description: string;
    listLabel: string;
    modelListLabel: string;
    modelSummary: string;
    pill: string;
    title: string;
  }>;
}>;

export function SupportedAgents({ copy }: SupportedAgentsProps) {
  return (
    <section id="agents">
      <SectionShell className="py-[6.375rem] lg:py-[8.5rem]">
        <div className="grid items-start gap-7 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] lg:gap-[5.25rem]">
          <Reveal>
            <Pill>{copy.pill}</Pill>
            <h2 className="mt-5 max-w-[43.125rem] text-[clamp(2.3125rem,4.2vw,3.4375rem)] leading-[1.01] font-semibold tracking-[-0.057em] text-balance">
              {copy.title}
            </h2>
            <p className="mt-5 max-w-[33.75rem] text-[17px] text-toki-mist">
              {copy.description}
            </p>
          </Reveal>
          <div>
            <RevealList
              aria-label={copy.listLabel}
              className="m-0 grid list-none grid-cols-1 border-t border-l border-toki-line p-0 sm:grid-cols-2"
            >
              {AGENT_TOOLS.map((tool) => (
                <RevealListItem
                  className="flex min-h-[3.625rem] items-center border-r border-b border-toki-line px-[1.125rem] font-mono text-[13px] tracking-[-0.025em] text-[#d8dfdc] transition-colors duration-200 hover:bg-[rgba(136,112,240,0.11)] hover:text-toki-purple sm:min-h-[4.5625rem]"
                  key={tool}
                >
                  {tool}
                </RevealListItem>
              ))}
            </RevealList>
            <p className="mt-6 max-w-[38rem] text-[15px] leading-6 text-toki-mist">
              {copy.modelSummary}
            </p>
            <RevealList
              aria-label={copy.modelListLabel}
              className="mt-4 m-0 grid list-none grid-cols-2 border-t border-l border-toki-line p-0 sm:grid-cols-4"
            >
              {MODEL_FAMILIES.map((family) => (
                <RevealListItem
                  className="flex min-h-[3.25rem] items-center border-r border-b border-toki-line px-[1.125rem] font-mono text-[12px] tracking-[-0.02em] text-toki-mist transition-colors duration-200 hover:bg-[rgba(136,112,240,0.11)] hover:text-toki-purple"
                  key={family}
                >
                  {family}
                </RevealListItem>
              ))}
            </RevealList>
          </div>
        </div>
      </SectionShell>
    </section>
  );
}
