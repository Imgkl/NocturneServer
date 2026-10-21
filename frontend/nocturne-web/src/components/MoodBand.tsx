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
      style={{ top: 'calc(50% - 32px)' }}
    >
      {dir < 0 ? <ChevronLeft size={18} strokeWidth={2.2} /> : <ChevronRight size={18} strokeWidth={2.2} />}
    </button>
  );
}

// Collage cover: one hero poster and two stacked.
function Cover({ covers, className }: { covers: string[]; className?: string }) {
  const [a, b, c] = covers;
  return (
    <div className={cn('grid h-full w-full grid-cols-[1.55fr_1fr] grid-rows-2 gap-[3px] bg-white', className)}>
      <CoverImg src={a} className="row-span-2" />
      <CoverImg src={b || a} />
      <CoverImg src={c || b || a} />
    </div>
  );
}

function CoverImg({ src, className }: { src?: string; className?: string }) {
  return (
    <div className={cn('overflow-hidden bg-[#f2f2f2]', className)}>
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

interface MoodBandProps {
  moods: BandMood[];
  total: { count: number; covers: string[] };
  selected: string;
  onPick: (slug: string) => void;
  onAll: () => void;
}

// X-Cache's folder band: a rail of collage tiles, All first, the active one outlined.
export function MoodBand({ moods, total, selected, onPick, onAll }: MoodBandProps) {
  const rail = useRail();
  const first = useRef(true);

  // Keep the active tile in view when it changes from elsewhere (palette, URL); only scrolls the rail.
  useEffect(() => {
    const r = rail.ref.current;
    const el = r?.querySelector<HTMLElement>(`[data-slug="${selected || '__all'}"]`);
    if (!r || !el) return;
    const l = el.offsetLeft;
    const right = l + el.offsetWidth;
    if (l < r.scrollLeft + 40 || right > r.scrollLeft + r.clientWidth - 40) {
      r.scrollTo({ left: Math.max(0, l - r.clientWidth / 2 + el.offsetWidth / 2), behavior: first.current ? 'auto' : 'smooth' });
    }
    first.current = false;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected]);

  return (
    <div className="relative">
      <Arrow dir={-1} onClick={() => rail.by(-1)} hidden={rail.edge.start} />
      <div ref={rail.ref} className={cn('no-scrollbar relative -mx-2 flex snap-x snap-proximity scroll-px-2 gap-3 overflow-x-auto px-2 pb-1 pt-2 sm:gap-4', rail.mask)}>
        <Tile slug="__all" name="All" count={total.count} covers={total.covers} active={!selected} onClick={onAll} />
        {moods.map((m) => (
          <Tile key={m.slug} slug={m.slug} name={m.title} count={m.count} covers={m.covers} active={selected === m.slug} onClick={() => onPick(m.slug)} />
        ))}
      </div>
      <Arrow dir={1} onClick={() => rail.by(1)} hidden={rail.edge.end} />
    </div>
  );
}

function Tile({ slug, name, count, covers, active, onClick }: { slug: string; name: string; count: number; covers: string[]; active: boolean; onClick: () => void }) {
  // The count pops when it changes (a film moved in or out), not on first render.
  const seen = useRef(count);
  useEffect(() => {
    const t = setTimeout(() => {
      seen.current = count;
    }, 700);
    return () => clearTimeout(t);
  }, [count]);
  return (
    <div data-slug={slug} className="group relative w-[148px] shrink-0 snap-start sm:w-[184px]">
      <button type="button" onClick={onClick} aria-pressed={active} title={name} className="block w-full text-left outline-none cursor-pointer">
        <div
          data-cover
          className={cn(
            'relative h-[96px] overflow-hidden rounded-2xl transition duration-300 sm:h-[118px]',
            active ? 'outline-2 outline-offset-[3px] outline-ink' : 'group-hover:opacity-[.92]',
            count === 0 && !active && 'opacity-40',
          )}
        >
          <Cover covers={covers} />
        </div>
        <div className="mt-2.5 flex items-baseline gap-1.5 px-0.5">
          <span className={cn('truncate text-[13.5px] leading-tight tracking-[-0.01em] text-ink', active ? 'font-semibold' : 'font-medium')}>{name}</span>
          <span key={count} className={cn('shrink-0 text-[12px] tabular-nums text-faint', seen.current !== count && 'count-pop')}>
            {count}
          </span>
        </div>
      </button>
    </div>
  );
}

// Compact sticky version: thumb and name chips, shown in the header once the band has scrolled away.
export function MoodChips({ moods, total, selected, onPick, onAll }: MoodBandProps) {
  const rail = useRail();
  useEffect(() => {
    const r = rail.ref.current;
    const el = r?.querySelector<HTMLElement>(`[data-slug="${selected || '__all'}"]`);
    if (r && el) r.scrollLeft = Math.max(0, el.offsetLeft - r.clientWidth / 2 + el.offsetWidth / 2);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const chip = (slug: string, name: string, cover: string | undefined, active: boolean, onClick: () => void) => (
    <button
      key={slug}
      data-slug={slug}
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        'inline-flex h-9 shrink-0 items-center gap-2 rounded-full pl-1 pr-3.5 text-[13px] font-medium outline-none transition focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink/40 cursor-pointer',
        active ? 'bg-ink text-white' : 'bg-[#f3f3f3] text-ink hover:bg-[#e9e9e9]',
      )}
    >
      <span className="h-7 w-7 overflow-hidden rounded-full bg-[#e6e6e6]">{cover && <img src={cover} alt="" className="h-full w-full object-cover" />}</span>
      {name}
    </button>
  );
  return (
    <div className="relative min-w-0 flex-1">
      <div ref={rail.ref} className={cn('no-scrollbar relative -mx-1.5 -my-1 flex gap-2 overflow-x-auto px-1.5 py-1', rail.mask)}>
        {chip('__all', 'All', total.covers[0], !selected, onAll)}
        {moods.map((m) => chip(m.slug, m.title, m.covers[0], selected === m.slug, () => onPick(m.slug)))}
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
