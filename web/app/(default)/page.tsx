import type { Metadata } from 'next';

import { getTokiReleaseData } from '@/entities/release';
import { LandingPage } from '@/_pages/landing';
import { siteConfig } from '@/shared/config';

export const metadata: Metadata = {
  alternates: {
    canonical: '/',
    languages: {
      en: '/',
      ko: '/ko',
    },
  },
  openGraph: {
    alternateLocale: ['ko_KR'],
    description: siteConfig.description,
    locale: 'en_US',
    siteName: siteConfig.name,
    title: siteConfig.name,
    type: 'website',
    url: siteConfig.url,
  },
};

export const revalidate = 3600;

export default async function HomePage() {
  const { latest } = await getTokiReleaseData();

  return <LandingPage latestRelease={latest} locale="en" />;
}
