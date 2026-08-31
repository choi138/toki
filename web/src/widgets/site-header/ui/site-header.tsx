import { ArrowDownToLine } from 'lucide-react';
import Image from 'next/image';
import Link from 'next/link';

import { siteConfig } from '@/shared/config';
import { cn } from '@/shared/lib/cn';
import { Button, SectionShell } from '@/shared/ui';

type HeaderCopy = Readonly<{
  download: string;
  downloadLabel: string;
  homeLabel: string;
  languageLabel: string;
  nav: Readonly<{
    agents: string;
    docs: string;
    privacy: string;
    time: string;
  }>;
  primaryLabel: string;
}>;

const DEFAULT_COPY: HeaderCopy = {
  download: 'Download Toki',
  downloadLabel: 'Download the latest Toki release',
  homeLabel: 'Toki home',
  languageLabel: 'Language',
  nav: {
    agents: 'Agents',
    docs: 'Docs',
    privacy: 'Privacy',
    time: 'Work time',
  },
  primaryLabel: 'Primary',
};

type SiteHeaderProps = Readonly<{
  copy?: HeaderCopy;
  locale?: 'en' | 'ko';
}>;

export function SiteHeader({
  copy = DEFAULT_COPY,
  locale = 'en',
}: SiteHeaderProps) {
  const landingPath = locale === 'ko' ? '/ko' : '/';
  const navLinks = [
    { href: `${landingPath}#time`, label: copy.nav.time },
    { href: `${landingPath}#agents`, label: copy.nav.agents },
    { href: `${landingPath}#privacy`, label: copy.nav.privacy },
    { href: '/docs', label: copy.nav.docs },
  ] as const;

  return (
    <header>
      <SectionShell className="flex h-[4.1875rem] items-center justify-between gap-4 sm:h-[4.75rem] lg:gap-6">
        <Link
          aria-label={copy.homeLabel}
          className="inline-flex shrink-0 items-center gap-2.5 font-semibold tracking-[-0.035em]"
          href={landingPath}
        >
          <Image
            alt=""
            className="size-[1.8125rem] rounded-lg shadow-[0_0_20px_rgba(136,112,240,0.3)]"
            height={29}
            src="/icon.png"
            width={29}
          />
          {siteConfig.name}
        </Link>
        <nav
          aria-label={copy.primaryLabel}
          className="flex min-w-0 items-center gap-2 text-[13px] text-[#cdd3d1] sm:gap-3 lg:gap-5"
        >
          {navLinks.map((link) => (
            <Link
              className="hidden transition-colors hover:text-toki-purple lg:inline"
              href={link.href}
              key={link.href}
            >
              {link.label}
            </Link>
          ))}
          <div className="flex shrink-0 items-center gap-1.5 font-mono text-[10px] tracking-[0.04em]">
            <span className="sr-only">{copy.languageLabel}</span>
            <Link
              aria-current={locale === 'en' ? 'page' : undefined}
              className={cn(
                'px-1.5 py-2 transition-colors hover:text-toki-purple',
                locale === 'en' ? 'text-toki-ink' : 'text-[#7f8986]',
              )}
              href="/"
              hrefLang="en"
              lang="en"
            >
              EN
            </Link>
            <span aria-hidden="true" className="h-3 w-px bg-toki-line" />
            <Link
              aria-current={locale === 'ko' ? 'page' : undefined}
              className={cn(
                'px-1.5 py-2 transition-colors hover:text-toki-purple',
                locale === 'ko' ? 'text-toki-ink' : 'text-[#7f8986]',
              )}
              href="/ko"
              hrefLang="ko"
              lang="ko"
            >
              한국어
            </Link>
          </div>
          <Button asChild className="sm:hidden" size="icon" variant="glow">
            <a
              aria-label={copy.downloadLabel}
              href={siteConfig.links.latestRelease}
            >
              <ArrowDownToLine aria-hidden="true" />
            </a>
          </Button>
          <Button asChild className="hidden sm:inline-flex" variant="glow">
            <a href={siteConfig.links.latestRelease}>
              {copy.download}
              <ArrowDownToLine aria-hidden="true" />
            </a>
          </Button>
        </nav>
      </SectionShell>
    </header>
  );
}
