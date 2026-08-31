import type { ReactNode } from 'react';

import {
  RootDocument,
  rootMetadata,
  rootViewport,
} from '@/_app/layout/root-document';
import '@/_app/styles/globals.css';

export const metadata = rootMetadata;
export const viewport = rootViewport;

type EnglishRootLayoutProps = Readonly<{
  children: ReactNode;
}>;

export default function EnglishRootLayout({
  children,
}: EnglishRootLayoutProps) {
  return <RootDocument lang="en">{children}</RootDocument>;
}
