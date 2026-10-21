import { useCallback, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { cn } from '../lib/cn';
import type { MoodBuckets } from '../lib/types';

export type BandMood = { slug: string; title: string; count: number; covers: string[] };

function useRail() {
  const ref = useRef<HTMLDivElement>(null);
  const [edge, setEdge] = useState({ start: true, end: false });
  const update = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    setEdge({ start: el.scrollLeft < 4, end: el.scrollLeft + el.clientWidth >= el.scrollWidth - 4 });
  }, []);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    update();
    el.addEventListener('scroll', update, { passive: true });
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => {
      el.removeEventListener('scroll', update);
      ro.disconnect();
    };
  }, [update]);
  const by = (dir: number) => {
    const el = ref.current;
    if (el) el.scrollBy({ left: dir * el.clientWidth * 0.8, behavior: 'smooth' });
  };
  const mask = edge.start && edge.end ? '' : edge.start ? 'rail-mask-end' : edge.end ? 'rail-mask-start' : 'rail-mask-both';
  return { ref, edge, by, mask };
}

function Arrow({ dir, onClick, hidden }: { dir: -1 | 1; onClick: () => void; hidden: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={dir < 0 ? 'Scroll left' : 'Scroll right'}
      tabIndex={-1}
      className={cn(
        'absolute z-10 hidden h-10 w-10 place-items-center rounded-full bg-white text-ink shadow-[0_1px_2px_rgba(0,0,0,.08),0_6px_18px_-4px_rgba(0,0,0,.18)] transition duration-200 hover:scale-105 md:grid cursor-pointer',
        dir < 0 ? '-left-3' : '-right-3',
        hidden && 'pointer-events-none opacity-0',
      )}
      style={{ top: 'calc(50% - 34px)' }}
    >
      {dir < 0 ? <ChevronLeft size={18} strokeWidth={2.2} /> : <ChevronRight size={18} strokeWidth={2.2} />}
    </button>
  );
}

function CoverImg({ src, className }: { src?: string; className?: string }) {
  return (
    <div className={cn('overflow-hidden bg-canvas', className)}>
      {src && (
        <img
          key={src}
          src={src}
          alt=""
          loading="lazy"
          decoding="async"
          draggable={false}
          className="img-fade h-full w-full object-cover transition-transform duration-[900ms] ease-[cubic-bezier(.2,.75,.2,1)] group-hover:scale-[1.04]"
          onLoad={(e) => e.currentTarget.classList.add('loaded')}
        />
      )}
    </div>
  );
}

// Collage cover: one hero poster and two stacked.
function Cover({ covers }: { covers: string[] }) {
  const [a, b, c] = covers;
  return (
    <div className="grid h-full w-full grid-cols-[1.55fr_1fr] grid-rows-2 gap-[3px] bg-white">
      <CoverImg src={a} className="row-span-2" />
      <CoverImg src={b || a} />
      <CoverImg src={c || b || a} />
    </div>
  );
}

interface MoodBandProps {
  moods: BandMood[];
  all: { count: number; covers: string[] };
  selected: string;
  onSelect: (slug: string) => void;
  // Folded into a chip row once the page has scrolled.
  collapsed: boolean;
}

export function MoodBand({ moods, all, selected, onSelect, collapsed }: MoodBandProps) {
  const rail = useRail();
  // Keep the active tile in view when it changes from elsewhere (palette, URL).
  useEffect(() => {
    const el = rail.ref.current?.querySelector<HTMLElement>(`[data-slug="${selected || '__all'}"]`);
    const r = rail.ref.current;
    if (!r || !el) return;
    const l = el.offsetLeft;
    const right = l + el.offsetWidth;
    if (l < r.scrollLeft + 40 || right > r.scrollLeft + r.clientWidth - 40) r.scrollTo({ left: Math.max(0, l - r.clientWidth / 2 + el.offsetWidth / 2), behavior: 'smooth' });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected, collapsed]);

  const items: BandMood[] = [{ slug: '', title: 'All', count: all.count, covers: all.covers }, ...moods];

  if (collapsed) {
    return (
      <div className="relative">
        <div ref={rail.ref} className={cn('no-scrollbar flex gap-2 overflow-x-auto py-1', rail.mask)}>
          {items.map((m) => {
            const active = selected === m.slug;
            return (
              <button
                key={m.slug || '__all'}
                data-slug={m.slug || '__all'}
                type="button"
                onClick={() => onSelect(m.slug)}
                className={cn(
                  'inline-flex h-9 shrink-0 items-center gap-2 whitespace-nowrap rounded-full pl-1.5 pr-3.5 text-[13px] font-medium transition cursor-pointer',
                  active ? 'bg-ink text-white' : 'bg-canvas text-ink hover:bg-canvas-2',
                )}
              >
                {m.covers[0] ? (
                  <img src={m.covers[0]} alt="" className="h-6 w-6 rounded-full object-cover" />
                ) : (
                  <span className={cn('grid h-6 w-6 place-items-center rounded-full text-[11px] font-semibold', active ? 'bg-white/20' : 'bg-white')}>{m.title[0]}</span>
                )}
                {m.title}
                <span className={cn('tabular-nums', active ? 'text-white/55' : 'text-faint')}>{m.count}</span>
              </button>
            );
          })}
        </div>
      </div>
    );
  }

  return (
    <div className="relative">
      <Arrow dir={-1} onClick={() => rail.by(-1)} hidden={rail.edge.start} />
      <Arrow dir={1} onClick={() => rail.by(1)} hidden={rail.edge.end} />
      <div ref={rail.ref} className={cn('no-scrollbar flex gap-3.5 overflow-x-auto px-0.5 pb-2 pt-1', rail.mask)}>
        {items.map((m) => {
          const active = selected === m.slug;
          return (
            <button
              key={m.slug || '__all'}
              data-slug={m.slug || '__all'}
              type="button"
              onClick={() => onSelect(m.slug)}
              className="group w-[196px] shrink-0 text-left cursor-pointer"
            >
              <div
                className={cn(
                  'h-[132px] overflow-hidden rounded-[18px] border-[3px] bg-canvas transition duration-300 ease-[cubic-bezier(.2,.75,.2,1)] group-hover:-translate-y-[2px]',
                  active ? 'border-ink shadow-[inset_0_0_0_2px_#fff]' : 'border-transparent',
                )}
              >
                <Cover covers={m.covers} />
              </div>
              <div className="mt-2.5 flex items-baseline gap-2 px-0.5">
                <span className="truncate text-[15px] font-semibold tracking-[-0.01em] text-ink">{m.title}</span>
                <span className="shrink-0 text-[13px] tabular-nums text-faint">{m.count}</span>
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}

// Moods with at least one film, biggest first, with up to three poster covers each.
export function bandMoods(moods: MoodBuckets, counts: Record<string, number>, covers: Record<string, string[]>): BandMood[] {
  return Object.entries(moods)
    .filter(([slug]) => (counts[slug] ?? 0) > 0)
    .map(([slug, m]) => ({ slug, title: m.title, count: counts[slug] ?? 0, covers: covers[slug] ?? [] }))
    .sort((a, b) => b.count - a.count || a.title.localeCompare(b.title));
}
