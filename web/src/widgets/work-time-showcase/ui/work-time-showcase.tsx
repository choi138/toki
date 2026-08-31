import {
  Pill,
  Reveal,
  RevealList,
  RevealListItem,
  SectionShell,
} from '@/shared/ui';

const METRICS = [
  { id: 'workTime', valueClassName: 'text-toki-green' },
  { id: 'parallel', valueClassName: 'text-toki-purple' },
  { id: 'main', valueClassName: 'text-toki-pink' },
  { id: 'subagent', valueClassName: 'text-[#e7eceb]' },
] as const;

type WorkTimeCopy = Readonly<{
  description: string;
  metrics: Readonly<
    Record<
      (typeof METRICS)[number]['id'],
      Readonly<{ detail: string; label: string; value: string }>
    >
  >;
  metricsLabel: string;
  pill: string;
  title: string;
}>;

type WorkTimeShowcaseProps = Readonly<{
  copy: WorkTimeCopy;
}>;

export function WorkTimeShowcase({ copy }: WorkTimeShowcaseProps) {
  return (
    <section id="time">
      <SectionShell className="py-[6.375rem] lg:py-[8.5rem]">
        <div className="grid items-end gap-9 lg:grid-cols-[minmax(0,0.82fr)_minmax(0,1.18fr)] lg:gap-[3.125rem]">
          <Reveal>
            <Pill>{copy.pill}</Pill>
            <h2 className="mt-5 max-w-[43.125rem] text-[clamp(2.4375rem,4.6vw,3.8125rem)] leading-[1.01] font-semibold tracking-[-0.057em] text-balance">
              {copy.title}
            </h2>
            <p className="mt-5 max-w-[33.75rem] text-[17px] text-toki-mist">
              {copy.description}
            </p>
          </Reveal>
          <RevealList
            aria-label={copy.metricsLabel}
            className="m-0 grid list-none gap-2.5 p-0 sm:grid-cols-2 sm:gap-3.5"
          >
            {METRICS.map((metric) => {
              const metricCopy = copy.metrics[metric.id];

              return (
                <RevealListItem
                  className="glass-panel min-h-[8.875rem] rounded-2xl p-5 transition-[border-color,transform] duration-200 hover:-translate-y-[3px] hover:border-[rgba(136,112,240,0.4)] sm:min-h-[11.125rem] sm:p-6"
                  key={metric.id}
                >
                  <b
                    data-localized-value
                    className={`block font-mono text-[clamp(1.75rem,3vw,2.75rem)] font-medium tracking-[-0.07em] tabular-nums ${metric.valueClassName}`}
                  >
                    {metricCopy.value}
                  </b>
                  <span className="mt-3 block text-sm font-semibold text-[#d6dcda] sm:mt-[1.1875rem]">
                    {metricCopy.label}
                  </span>
                  <p className="mt-[5px] text-xs leading-[1.45] text-[#8e9895]">
                    {metricCopy.detail}
                  </p>
                </RevealListItem>
              );
            })}
          </RevealList>
        </div>
      </SectionShell>
    </section>
  );
}
