import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from 'fumadocs-ui/layouts/docs/page';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { docsSource } from '@/_pages/docs';

type DocsPageRouteProps = Readonly<{
  params: Promise<{ slug?: string[] }>;
}>;

export function generateStaticParams() {
  return docsSource.generateParams();
}

export async function generateMetadata({
  params,
}: DocsPageRouteProps): Promise<Metadata> {
  const page = docsSource.getPage((await params).slug);

  if (!page) {
    notFound();
  }

  return {
    title: page.data.title,
    description: page.data.description,
  };
}

export default async function Page({ params }: DocsPageRouteProps) {
  const page = docsSource.getPage((await params).slug);

  if (!page) {
    notFound();
  }

  const MDX = page.data.body;

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      <DocsTitle>{page.data.title}</DocsTitle>
      {page.data.description ? (
        <DocsDescription>{page.data.description}</DocsDescription>
      ) : null}
      <DocsBody>
        <MDX />
      </DocsBody>
    </DocsPage>
  );
}
