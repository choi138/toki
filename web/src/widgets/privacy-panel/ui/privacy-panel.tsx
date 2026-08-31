import { Pill, Reveal, SectionShell } from '@/shared/ui';

type PrivacyPanelProps = Readonly<{
  copy: Readonly<{
    description: string;
    pill: string;
    title: string;
  }>;
}>;

export function PrivacyPanel({ copy }: PrivacyPanelProps) {
  return (
    <section
      className="relative overflow-hidden py-[4.875rem] lg:py-[7.4375rem]"
      id="privacy"
    >
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 bg-[radial-gradient(55%_55%_at_74%_50%,rgba(136,112,240,0.12),transparent_70%)]"
      />
      <SectionShell className="relative border-y border-toki-line py-[1.125rem] pb-[2.125rem] lg:py-[2.8125rem]">
        <Reveal className="grid items-center gap-9 lg:grid-cols-[minmax(0,1fr)_minmax(17.5rem,0.78fr)] lg:gap-20">
          <div>
            <Pill>{copy.pill}</Pill>
            <h2 className="mt-5 mb-[1.125rem] max-w-[36.25rem] text-[clamp(2.375rem,4.4vw,3.625rem)] leading-[1.02] font-semibold tracking-[-0.055em] text-balance">
              {copy.title}
            </h2>
            <p className="max-w-[32.5rem] text-base text-toki-mist lg:text-[17px]">
              {copy.description}
            </p>
          </div>
          <div
            aria-hidden="true"
            className="grid aspect-square w-[8.25rem] place-items-center justify-self-center rounded-full border border-[rgba(136,112,240,0.3)] bg-[rgba(136,112,240,0.05)] shadow-[inset_0_0_50px_rgba(136,112,240,0.09),0_0_80px_rgba(136,112,240,0.09)] lg:w-[13.75rem] lg:justify-self-end"
          >
            <svg
              className="w-[3.6rem] fill-none lg:w-[5.25rem]"
              role="presentation"
              viewBox="0 0 80 80"
            >
              <defs>
                <linearGradient
                  gradientUnits="userSpaceOnUse"
                  id="privacy-device"
                  x1="18"
                  x2="62"
                  y1="24"
                  y2="56"
                >
                  <stop stopColor="#bcaaff" />
                  <stop offset="1" stopColor="#7a63e8" />
                </linearGradient>
              </defs>
              <rect
                fill="rgba(136,112,240,0.12)"
                height="26"
                rx="4"
                stroke="url(#privacy-device)"
                strokeWidth="1.8"
                width="40"
                x="20"
                y="24"
              />
              <path
                d="M14 56h52"
                stroke="url(#privacy-device)"
                strokeLinecap="round"
                strokeWidth="2.2"
              />
              <circle cx="34" cy="37" fill="#a894ff" r="2.6" />
              <circle cx="42" cy="37" fill="#efeaff" r="2.6" />
              <circle cx="50" cy="37" fill="#7f6ae0" r="2.6" />
            </svg>
          </div>
        </Reveal>
      </SectionShell>
    </section>
  );
}
