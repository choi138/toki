import Image from 'next/image';

import {
  GlassCard,
  Pill,
  Reveal,
  RevealGroup,
  RevealItem,
  SectionShell,
} from '@/shared/ui';

const SHOTS = [
  { id: 'time', src: '/screenshots/screenshot_time.png' },
  { id: 'projects', src: '/screenshots/screenshot_projects.png' },
  { id: 'models', src: '/screenshots/screenshot_models.png' },
] as const;

type ScreenshotCopy = Readonly<{
  aside: Readonly<{ first: string; second: string }>;
  pill: string;
  shots: Readonly<
    Record<
      (typeof SHOTS)[number]['id'],
      Readonly<{ alt: string; caption: string }>
    >
  >;
  title: string;
}>;

type ScreenshotStripProps = Readonly<{
  copy: ScreenshotCopy;
}>;

export function ScreenshotStrip({ copy }: ScreenshotStripProps) {
  return (
    <section aria-labelledby="screens-title">
      <SectionShell className="py-[6.375rem] lg:py-[8.5rem]">
        <Reveal className="mb-[1.875rem] gap-5 sm:flex sm:items-end sm:justify-between lg:mb-[2.875rem]">
          <div>
            <Pill>{copy.pill}</Pill>
            <h2
              className="mt-5 max-w-[31.875rem] text-[clamp(2.4375rem,4.6vw,3.8125rem)] leading-[1.01] font-semibold tracking-[-0.057em] text-balance"
              id="screens-title"
            >
              {copy.title}
            </h2>
          </div>
          <p className="mt-3.5 max-w-[16.25rem] font-mono text-[11px] leading-[1.6] text-[#8d9693] sm:mt-0 sm:text-right">
            {copy.aside.first}
            <br />
            {copy.aside.second}
          </p>
        </Reveal>
        <RevealGroup className="grid items-end gap-3 md:grid-cols-[0.95fr_0.78fr_0.78fr] md:gap-[1.125rem]">
          {SHOTS.map((shot, index) => (
            <RevealItem key={shot.src}>
              <GlassCard
                className={`rounded-[19px] p-2 shadow-[inset_0_1px_rgba(255,255,255,0.06),0_22px_38px_rgba(0,0,0,0.25)] sm:p-2.5 ${
                  index === 0 ? 'md:-translate-y-[1.8125rem]' : ''
                }`}
              >
                <figure className="m-0">
                  <Image
                    alt={copy.shots[shot.id].alt}
                    className="w-full rounded-[11px]"
                    height={840}
                    sizes="(max-width: 767px) 92vw, 30vw"
                    src={shot.src}
                    width={640}
                  />
                  <figcaption className="px-1 pt-3 pb-[3px] font-mono text-[10px] tracking-[0.045em] text-[#99a29f]">
                    {copy.shots[shot.id].caption}
                  </figcaption>
                </figure>
              </GlassCard>
            </RevealItem>
          ))}
        </RevealGroup>
      </SectionShell>
    </section>
  );
}
