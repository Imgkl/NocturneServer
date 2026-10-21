import { useEffect, useState } from 'react';

export type Page = '' | 'settings';

const PAGES: Page[] = ['', 'settings'];

function read(): Page {
  const p = location.hash.replace(/^#/, '').split(/[/?]/)[0];
  return (PAGES as string[]).includes(p) ? (p as Page) : '';
}

// The page comes from the hash (`#settings`); the library is the empty hash. Review is a tray
// over the library, not a page.
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
