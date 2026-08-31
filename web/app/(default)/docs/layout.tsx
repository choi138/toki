import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import type { ReactNode } from 'react';

import { docsLayoutOptions, docsSource } from '@/_pages/docs';

type DocsLayoutPageProps = Readonly<{
  children: ReactNode;
}>;

export default function DocsLayoutPage({ children }: DocsLayoutPageProps) {
  return (
    <DocsLayout tree={docsSource.getPageTree()} {...docsLayoutOptions}>
      {children}
    </DocsLayout>
  );
}
