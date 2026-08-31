import type { Metadata, Viewport } from 'next';
import { Geist_Mono, Inter } from 'next/font/google';
import type { ReactNode } from 'react';

import { AppProviders } from '@/_app/providers';
import { siteConfig } from '@/shared/config';

const inter = Inter({
  display: 'swap',
  subsets: ['latin'],
  variable: '--font-inter',
});

const geistMono = Geist_Mono({
  display: 'swap',
  subsets: ['latin'],
  variable: '--font-geist-mono',
});

export const rootMetadata: Metadata = {
  metadataBase: new URL(siteConfig.url),
  title: {
    default: siteConfig.name,
    template: `%s | ${siteConfig.name}`,
  },
  description: siteConfig.description,
  openGraph: {
    description: siteConfig.description,
    siteName: siteConfig.name,
    title: siteConfig.name,
    type: 'website',
    url: siteConfig.url,
  },
};

export const rootViewport: Viewport = {
  colorScheme: 'dark light',
  initialScale: 1,
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#fafafa' },
    { media: '(prefers-color-scheme: dark)', color: '#0a0a0c' },
  ],
  width: 'device-width',
};

type RootDocumentProps = Readonly<{
  children: ReactNode;
  lang: 'en' | 'ko';
}>;

export function RootDocument({ children, lang }: RootDocumentProps) {
  return (
    <html
      lang={lang}
      suppressHydrationWarning
      data-scroll-behavior="smooth"
      className={`${inter.variable} ${geistMono.variable}`}
    >
      <body>
        <noscript>
          <style>{`[data-reveal],[data-reveal-group],[data-reveal-item]{opacity:1!important;transform:none!important}`}</style>
        </noscript>
        <AppProviders>{children}</AppProviders>
      </body>
    </html>
  );
}
