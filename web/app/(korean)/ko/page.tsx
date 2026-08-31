import type { Metadata } from 'next';

import { LandingPage } from '@/_pages/landing';
import { getTokiReleaseData } from '@/entities/release';

const description =
  'Toki로 AI 코딩의 토큰, 비용, 프로젝트별 사용량과 실제 작업 시간을 macOS 메뉴 막대에서 확인하세요.';

export const metadata: Metadata = {
  alternates: {
    canonical: '/ko',
    languages: {
      en: '/',
      ko: '/ko',
    },
  },
  description,
  openGraph: {
    alternateLocale: ['en_US'],
    description,
    locale: 'ko_KR',
    siteName: 'Toki',
    title: 'Toki',
    type: 'website',
    url: '/ko',
  },
};

export const revalidate = 3600;

export default async function KoreanHomePage() {
  const { latest } = await getTokiReleaseData();

  return <LandingPage latestRelease={latest} locale="ko" />;
}
