import type { Metadata } from 'next';

import { DownloadPage } from '@/_pages/download';
import { getTokiReleaseData } from '@/entities/release';

export const metadata: Metadata = {
  title: 'Download',
  description: 'Download the latest Toki release for macOS.',
};

export const revalidate = 3600;

export default async function DownloadRoutePage() {
  const { latest, releases } = await getTokiReleaseData();

  return <DownloadPage latestRelease={latest} releases={releases} />;
}
