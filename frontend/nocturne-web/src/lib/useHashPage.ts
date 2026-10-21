import { useEffect, useState } from 'react';

export type Page = '' | 'review' | 'settings';

const PAGES: Page[] = ['', 'review', 'settings'];

function read(): Page {
  const p = location.hash.replace(/^#/, '').split(/[/?]/)[0];
  return (PAGES as string[]).includes(p) ? (p as Page) : '';
}

// The page comes from the hash (`#review`, `#settings`); the library is the empty hash.
export function useHashPage(): Page {
  const [page, setPage] = useState<Page>(read);
  useEffect(() => {
    const f = () => setPage(read());
    window.addEventListener('hashchange', f);
    return () => window.removeEventListener('hashchange', f);
  }, []);
  return page;
}

export function goTo(page: Page) {
  const next = page ? `#${page}` : '#';
  if (location.hash === next || (!page && !location.hash)) return;
  if (document.startViewTransition) document.startViewTransition(() => { location.hash = next; });
  else location.hash = next;
}
