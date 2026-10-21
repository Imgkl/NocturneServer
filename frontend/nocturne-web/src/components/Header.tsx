import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { ChevronDown, Command, RefreshCw, Search } from 'lucide-react';
import { cn } from '../lib/cn';
import { goTo, type Page } from '../lib/useHashPage';
import { Wordmark } from './Logo';

export type MenuItem = { icon?: ReactNode; label: string; hint?: string; disabled?: boolean; reason?: string | null; onClick: () => void; danger?: boolean };

function useScrolled(px = 4) {
  const [s, setS] = useState(false);
  useEffect(() => {
    const f = () => setS(window.scrollY > px);
    f();
    window.addEventListener('scroll', f, { passive: true });
    return () => window.removeEventListener('scroll', f);
  }, [px]);
  return s;
}

export function SearchPill({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="hidden h-11 w-full items-center gap-3 rounded-full bg-canvas px-4 text-left text-[14.5px] text-faint transition hover:bg-[#ececec] sm:flex cursor-pointer"
    >
      <Search size={17} strokeWidth={2.2} className="text-mute" />
      <span className="flex-1 truncate">Search films, moods</span>
      <kbd className="inline-flex h-6 items-center gap-0.5 rounded-md bg-white px-1.5 font-sans text-[11.5px] font-medium text-mute shadow-[0_0_0_1px_rgba(0,0,0,.06)]">
        <Command size={11} />K
      </kbd>
    </button>
  );
}

interface AppHeaderProps {
  page: Page;
  // The label beside Sync when idle ("Synced 2 h ago") and the stage text while a run is on.
  syncLabel: string;
  running: boolean;
  onSync: () => void;
  syncDisabledReason?: string | null;
  menu: MenuItem[];
  reviewCount: number;
  onSearch: () => void;
}

// One header on every page: wordmark, the search pill, Sync with its menu, the Review pill;
// a thin progress line while a run is on; the centred page tabs.
export function AppHeader({ page, syncLabel, running, onSync, syncDisabledReason, menu, reviewCount, onSearch }: AppHeaderProps) {
  const scrolled = useScrolled();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (e: PointerEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', down);
    return () => document.removeEventListener('pointerdown', down);
  }, [open]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        onSearch();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onSearch]);

  return (
    <header
      className={cn('sticky top-0 z-40 bg-white/[.92] backdrop-blur-xl backdrop-saturate-150 transition-shadow duration-300', scrolled && 'shadow-[0_1px_0_#ededed]')}
      style={{ top: 'env(safe-area-inset-top, 0px)' }}
    >
      <div className="grid h-16 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3 px-4 sm:gap-6 sm:px-8 md:grid-cols-[minmax(0,1fr)_minmax(0,560px)_minmax(0,1fr)]">
        <a
          href="#"
          onClick={(e) => {
            e.preventDefault();
            goTo('');
            window.scrollTo({ top: 0 });
          }}
          aria-label="Nocturne home"
          className="justify-self-start"
        >
          <Wordmark />
        </a>
        <div className="min-w-0">
          <SearchPill onClick={onSearch} />
        </div>
        <div className="flex items-center justify-end gap-1 justify-self-end">
          <button type="button" onClick={onSearch} aria-label="Search" className="grid h-10 w-10 place-items-center rounded-full text-ink transition hover:bg-canvas sm:hidden cursor-pointer">
            <Search size={18} strokeWidth={2.2} />
          </button>
          <div ref={ref} className="relative flex items-center">
            <button
              type="button"
              onClick={onSync}
              disabled={running || !!syncDisabledReason}
              title={syncDisabledReason ?? 'Sync the library from Jellyfin'}
              className="inline-flex h-10 items-center gap-2 rounded-l-full pl-3 pr-2 text-[13.5px] font-medium text-ink transition hover:bg-canvas disabled:cursor-default disabled:hover:bg-transparent cursor-pointer"
            >
              <RefreshCw size={16} strokeWidth={2.2} className={cn(running && 'animate-spin [animation-duration:1.1s]')} />
              <span className="hidden lg:inline">Sync</span>
            </button>
            <span className="hidden whitespace-nowrap pr-1 text-[12.5px] tabular-nums text-faint xl:inline">{syncLabel}</span>
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              aria-label="Sync menu"
              aria-expanded={open}
              className="grid h-10 w-8 place-items-center rounded-r-full text-mute transition hover:bg-canvas hover:text-ink cursor-pointer"
            >
              <ChevronDown size={15} />
            </button>
            {open && (
              <div className="pop-menu absolute right-0 top-12 z-50 w-64 rounded-2xl bg-white p-1.5 shadow-pop">
                <div className="px-3 pb-2 pt-1.5 text-[12px] text-faint">{syncLabel}</div>
                {menu.map((m) => (
                  <button
                    key={m.label}
                    type="button"
                    disabled={m.disabled}
                    title={m.disabled && m.reason ? m.reason : undefined}
                    onClick={() => {
                      setOpen(false);
                      m.onClick();
                    }}
                    className={cn(
                      'flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-[13.5px] font-medium hover:bg-[#f5f5f5] disabled:cursor-not-allowed disabled:opacity-35 disabled:hover:bg-transparent cursor-pointer',
                      m.danger ? 'text-bad' : 'text-ink',
                    )}
                  >
                    {m.icon && <span className="text-mute">{m.icon}</span>}
                    <span className="min-w-0 flex-1">{m.label}</span>
                    {m.hint && <span className="text-[12px] text-faint">{m.hint}</span>}
                  </button>
                ))}
              </div>
            )}
          </div>
          <button
            type="button"
            onClick={() => goTo('review')}
            className={cn(
              'ml-1.5 inline-flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[13.5px] font-medium transition cursor-pointer',
              reviewCount > 0 ? 'bg-ink text-white hover:bg-black' : 'bg-canvas text-mute hover:bg-canvas-2',
            )}
          >
            Review
            <span className={cn('tabular-nums', reviewCount > 0 ? 'text-white/55' : 'text-faint')}>{reviewCount}</span>
          </button>
        </div>
      </div>
      <ProgressLine active={running} />
      <PageTabs page={page} />
    </header>
  );
}

export function ProgressLine({ active }: { active: boolean }) {
  return (
    <div className="relative h-[2px] overflow-hidden bg-transparent" aria-hidden>
      {active && <div className="indeterminate absolute inset-y-0 left-0 w-[30%] rounded-full bg-ink" />}
    </div>
  );
}

const TABS: { id: Page; label: string }[] = [
  { id: '', label: 'Library' },
  { id: 'review', label: 'Review' },
  { id: 'settings', label: 'Settings' },
];

// The page tabs, centred, one underline that slides to the current tab.
export function PageTabs({ page }: { page: Page }) {
  const inner = useRef<HTMLDivElement>(null);
  const [bar, setBar] = useState<{ x: number; w: number } | null>(null);
  useEffect(() => {
    const measure = () => {
      const a = inner.current?.querySelector<HTMLElement>('[aria-current="page"]');
      if (!a || !inner.current) return;
      const base = inner.current.getBoundingClientRect().left;
      const r = a.getBoundingClientRect();
      setBar({ x: r.left - base + 12, w: r.width - 24 });
    };
    measure();
    const ro = new ResizeObserver(measure);
    if (inner.current) ro.observe(inner.current);
    void document.fonts?.ready.then(measure);
    return () => ro.disconnect();
  }, [page]);
  return (
    <nav aria-label="Pages" className="px-2 sm:px-8">
      <div className="no-scrollbar flex overflow-x-auto">
        <div ref={inner} className="relative mx-auto flex w-max items-center sm:gap-1.5">
          {TABS.map((t) => {
            const active = page === t.id;
            return (
              <a
                key={t.id || 'library'}
                href={t.id ? `#${t.id}` : '#'}
                onClick={(e) => {
                  e.preventDefault();
                  goTo(t.id);
                }}
                aria-current={active ? 'page' : undefined}
                className={cn('relative inline-flex h-11 items-center whitespace-nowrap px-3 text-[14px] font-medium tracking-[-0.01em] transition-colors duration-200', active ? 'text-ink' : 'text-mute hover:text-ink')}
              >
                {t.label}
              </a>
            );
          })}
          {bar && (
            // A fixed 100px bar moved and stretched with a transform, so the slide never relayouts.
            <span
              aria-hidden
              className="pointer-events-none absolute bottom-1 left-0 h-[2px] w-[100px] origin-left rounded-full bg-ink"
              style={{ transform: `translateX(${bar.x}px) scaleX(${bar.w / 100})`, transition: 'transform 380ms cubic-bezier(.2,.8,.2,1)' }}
            />
          )}
        </div>
      </div>
    </nav>
  );
}
