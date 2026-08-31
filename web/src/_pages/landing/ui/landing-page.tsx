import type { TokiRelease } from '@/entities/release';
import { DownloadCta } from '@/widgets/download-cta';
import { Hero3D } from '@/widgets/hero-3d';
import { PrivacyPanel } from '@/widgets/privacy-panel';
import { ScreenshotStrip } from '@/widgets/screenshot-strip';
import { SiteFooter } from '@/widgets/site-footer';
import { SiteHeader } from '@/widgets/site-header';
import { SupportedAgents } from '@/widgets/supported-agents';
import { WorkTimeShowcase } from '@/widgets/work-time-showcase';
import { SectionShell } from '@/shared/ui';

import { getLandingCopy, type LandingLocale } from '../model/landing-copy';

type LandingPageProps = Readonly<{
  latestRelease: TokiRelease;
  locale: LandingLocale;
}>;

export function LandingPage({ latestRelease, locale }: LandingPageProps) {
  const copy = getLandingCopy(locale);

  return (
    <div
      className="luminous flex min-h-dvh flex-col"
      data-locale={locale}
      lang={locale}
    >
      <SiteHeader copy={copy.header} locale={locale} />
      <main className="flex-1">
        <Hero3D
          copy={copy.hero}
          latestRelease={latestRelease}
          locale={locale}
        />
        <SectionShell>
          <div className="h-px bg-toki-line" />
        </SectionShell>
        <WorkTimeShowcase copy={copy.workTime} />
        <ScreenshotStrip copy={copy.screenshots} />
        <SupportedAgents copy={copy.agents} />
        <PrivacyPanel copy={copy.privacy} />
        <DownloadCta copy={copy.download} latestRelease={latestRelease} />
      </main>
      <SiteFooter copy={copy.footer} />
    </div>
  );
}
