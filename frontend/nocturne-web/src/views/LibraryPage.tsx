import { useEffect, useMemo, useRef } from 'react';
import { MoodBand, type BandMood } from '../components/MoodBand';
import { PosterCard } from '../components/PosterCard';
import { RefineRow, type LibraryFilter, type LibrarySort } from '../components/RefineRow';
import type { MoodBuckets, Movie } from '../lib/types';

export type { LibraryFilter, LibrarySort } from '../components/RefineRow';

interface LibraryPageProps {
  movies: Movie[];
  moods: MoodBuckets;
  band: BandMood[];
  total: { count: number; covers: string[] };
  selectedMood: string;
  onPickMood: (slug: string) => void;
  onAllMoods: () => void;
  filters: LibraryFilter[];
  onFiltersChange: (f: LibraryFilter[]) => void;
  sort: LibrarySort;
  onSortChange: (s: LibrarySort) => void;
  toReview: number;
  onReview: () => void;
  onOpenMovie: (movie: Movie, list: Movie[]) => void;
  // The band has scrolled off: the header folds the chips in.
  onCondensed: (condensed: boolean) => void;
  jellyfinUrl?: string;
  loading: boolean;
}

// X-Cache's wall, for films: the mood band, the heading for the selection, the refine row, the grid.
export function LibraryPage({ movies, moods, band, total, selectedMood, onPickMood, onAllMoods, filters, onFiltersChange, sort, onSortChange, toReview, onReview, onOpenMovie, onCondensed, jellyfinUrl, loading }: LibraryPageProps) {
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => onCondensed(!e.isIntersecting && e.boundingClientRect.top < 80), { rootMargin: '-64px 0px 0px 0px' });
    io.observe(el);
    return () => {
      io.disconnect();
      onCondensed(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const inMood = useMemo(() => movies.filter((m) => !selectedMood || (m.tags || []).some((t) => t.slug === selectedMood)), [movies, selectedMood]);
  const counts = useMemo(() => {
    const watched = inMood.filter((m) => m.played).length;
    const untagged = inMood.filter((m) => !(m.tags || []).length).length;
    const review = inMood.filter((m) => m.needsReview).length;
    return { watched, unwatched: inMood.length - watched, untagged, review };
  }, [inMood]);

  const shown = useMemo(() => {
    let list = inMood;
    if (filters.includes('watched')) list = list.filter((m) => m.played);
    if (filters.includes('unwatched')) list = list.filter((m) => !m.played);
    if (filters.includes('untagged')) list = list.filter((m) => !(m.tags || []).length);
    if (filters.includes('review')) list = list.filter((m) => m.needsReview);
    const byTitle = (a: Movie, b: Movie) => a.title.localeCompare(b.title);
    if (sort === 'az') list = [...list].sort(byTitle);
    if (sort === 'year-desc') list = [...list].sort((a, b) => (b.year ?? 0) - (a.year ?? 0) || byTitle(a, b));
    if (sort === 'year-asc') list = [...list].sort((a, b) => (a.year ?? 9999) - (b.year ?? 9999) || byTitle(a, b));
    return list;
  }, [inMood, filters, sort]);

  const mood = selectedMood ? moods[selectedMood] : undefined;
  const title = mood ? mood.title : 'Everything';
  const sub = mood ? mood.description : `All your films from Jellyfin, sorted into ${Object.keys(moods).length} moods`;
  const toggle = (f: LibraryFilter) => {
    const exclusive: LibraryFilter[][] = [['watched', 'unwatched']];
    let next = filters.includes(f) ? filters.filter((x) => x !== f) : [...filters, f];
    for (const pair of exclusive) if (pair.includes(f)) next = next.filter((x) => x === f || !pair.includes(x));
    onFiltersChange(next);
  };
  const jellyfinHref = (m: Movie) => (jellyfinUrl ? `${jellyfinUrl.replace(/\/$/, '')}/web/index.html#!/details?id=${m.jellyfinId}` : undefined);

  // When the mood changes while scrolled down, bring the wall's top into view.
  const wallTop = useRef<HTMLDivElement>(null);
  const firstMood = useRef(true);
  useEffect(() => {
    if (firstMood.current) {
      firstMood.current = false;
      return;
    }
    const el = wallTop.current;
    if (!el) return;
    const y = el.getBoundingClientRect().top + window.scrollY - 130;
    if (window.scrollY > y) window.scrollTo({ top: y, behavior: 'smooth' });
  }, [selectedMood]);

  return (
    <div className="pb-24">
      <section className="px-4 pt-2 sm:px-8 sm:pt-3">
        <MoodBand moods={band} total={total} selected={selectedMood} onPick={onPickMood} onAll={onAllMoods} />
      </section>
      <div ref={sentinel} className="h-px" />

      <section className="px-4 pb-6 pt-8 sm:px-8 sm:pt-10">
        <div className="flex flex-wrap items-end justify-between gap-x-6 gap-y-2">
          <div className="min-w-0">
            <h1 key={title} className="rise text-[28px] font-semibold leading-[1.05] tracking-[-0.035em] text-ink sm:text-[38px]">
              {title}
            </h1>
            <p className="mt-2 text-[14.5px] text-mute">
              {sub}
              <span className="text-faint"> · {filters.length ? `${shown.length} of ${inMood.length}` : `${shown.length} film${shown.length === 1 ? '' : 's'}`}</span>
            </p>
          </div>
        </div>
        <div className="mt-6">
          <RefineRow counts={counts} filters={filters} onToggle={toggle} onClear={() => onFiltersChange([])} sort={sort} onSort={onSortChange} toReview={toReview} onReview={onReview} />
        </div>
      </section>

      <main className="px-4 sm:px-8" ref={wallTop}>
        {shown.length === 0 ? (
          <div className="mx-auto max-w-md py-24 text-center">
            <div className="text-[18px] font-semibold tracking-[-0.02em] text-ink">{loading ? 'Loading your films' : 'Nothing matches all of these'}</div>
            <p className="mt-1.5 text-[14px] text-mute">{loading ? 'Talking to Jellyfin.' : 'Clear a chip or pick another mood.'}</p>
            {!loading && filters.length > 0 && (
              <button type="button" onClick={() => onFiltersChange([])} className="mt-5 h-10 rounded-full bg-ink px-5 text-[14px] font-medium text-white cursor-pointer">
                Clear filters
              </button>
            )}
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-x-2.5 gap-y-[22px] sm:grid-cols-[repeat(auto-fill,minmax(190px,1fr))] sm:gap-x-3 sm:gap-y-6 2xl:grid-cols-8">
            {shown.map((m) => (
              <PosterCard key={m.jellyfinId} movie={m} moods={moods} onOpen={() => onOpenMovie(m, shown)} jellyfinHref={jellyfinHref(m)} />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}
