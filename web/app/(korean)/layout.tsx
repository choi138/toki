import type { ReactNode } from 'react';

import {
  RootDocument,
  rootMetadata,
  rootViewport,
} from '@/_app/layout/root-document';
import '@/_app/styles/globals.css';

export const metadata = rootMetadata;
export const viewport = rootViewport;

type KoreanRootLayoutProps = Readonly<{
  children: ReactNode;
}>;

export default function KoreanRootLayout({ children }: KoreanRootLayoutProps) {
  return <RootDocument lang="ko">{children}</RootDocument>;
}
