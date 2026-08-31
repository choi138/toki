import Link from 'next/link';

import { siteConfig } from '@/shared/config';
import { SectionShell } from '@/shared/ui';

type SiteFooterProps = Readonly<{
  copy?: Readonly<{
    copyright: string;
    download: string;
    docs: string;
    label: string;
  }>;
}>;

const DEFAULT_COPY = {
  copyright: '© TOKI · LOCAL-FIRST OBSERVABILITY',
  download: 'DOWNLOAD',
  docs: 'DOCS',
  label: 'Footer',
} as const;

export function SiteFooter({ copy = DEFAULT_COPY }: SiteFooterProps) {
  return (
    <footer>
      <SectionShell className="flex flex-col gap-1.5 border-t border-toki-line py-[1.625rem] pb-9 font-mono text-[10px] text-[#74807b] sm:flex-row sm:justify-between sm:gap-[1.125rem]">
        <span>{copy.copyright}</span>
        <nav aria-label={copy.label} className="flex flex-wrap gap-x-4 gap-y-2">
          <Link
            className="transition-colors hover:text-toki-purple"
            href="/docs"
          >
            {copy.docs}
          </Link>
          <Link
            className="transition-colors hover:text-toki-purple"
            href="/download"
          >
            {copy.download}
          </Link>
          <a
            className="transition-colors hover:text-toki-purple"
            href={siteConfig.links.github}
            rel="noreferrer"
            target="_blank"
          >
            github.com/choi138/toki
          </a>
        </nav>
      </SectionShell>
    </footer>
  );
}
