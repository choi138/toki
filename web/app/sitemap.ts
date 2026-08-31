import type { MetadataRoute } from 'next';

import { siteConfig } from '@/shared/config';

export default function sitemap(): MetadataRoute.Sitemap {
  return ['/', '/ko', '/download', '/docs'].map((pathname) => ({
    changeFrequency:
      pathname === '/' || pathname === '/ko' ? 'weekly' : 'monthly',
    priority: pathname === '/' || pathname === '/ko' ? 1 : 0.8,
    url: new URL(pathname, `${siteConfig.url}/`).toString(),
  }));
}
