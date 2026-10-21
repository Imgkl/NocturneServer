import { useEffect, useMemo, useState } from 'react';
import { ArrowUpDown, Film } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { Chip } from '../ui/Chip';
import { Empty } from '../ui/Empty';
import { Select } from '../ui/Select';
import { MoodBand, bandMoods } from '../components/MoodBand';
import { PosterCard } from '../components/PosterCard';
import type { MoodBuckets, Movie } from '../lib/types';

export type LibraryFilter = 'watched' | 'unwatched' | 'untagged' | 'review';
export type LibrarySort = 'az' | 'year-desc' | 'year-asc';

interface LibraryPageProps {
  movies: Movie[];
  moods: MoodBuckets;
  selectedMood: string;
  onMoodChange: (slug: string) => void;
  filters: LibraryFilter[];
  onFiltersChange: (f: LibraryFilter[]) => void;
  sort: LibrarySort;
  onSortChange: (s: LibrarySort) => void;
  onOpenMovie: (movie: Movie, list: Movie[]) => void;
  loading: boolean;
}

const SORT_LABEL: Record<LibrarySort, string> = { az: 'A to Z', 'year-desc': 'Newest year', 'year-asc': 'Oldest year' };

// The library: the mood band, a heading for the selection, filter chips, the poster grid.
export function LibraryPage({ movies, moods, selectedMood, onMoodChange, filters, onFiltersChange, sort, onSortChange, onOpenMovie, loading }: LibraryPageProps) {
  const [collapsed, setCollapsed] = useState(false);
  useEffect(() => {
    const f = () => setCollapsed(window.scrollY > 240);
    f();
    window.addEventListener('scroll', f, { passive: true });
    return () => window.removeEventListener('scroll', f);
  }, []);

  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    movies.forEach((m) => (m.tags || []).forEach((t) => (c[t.slug] = (c[t.slug] || 0) + 1)));
    return c;
  }, [movies]);
  const covers = useMemo(() => {
    const c: Record<string, string[]> = {};
    for (const m of movies) {
      for (const t of m.tags || []) {
        const list = (c[t.slug] ||= []);
        if (list.length < 3) list.push(posterUrl(m.jellyfinId, 'thumb'));
      }
    }
    return c;
  }, [movies]);
  const band = useMemo(() => bandMoods(moods, counts, covers), [moods, counts, covers]);
  const allCovers = useMemo(() => {
    const watched = movies.filter((m) => m.played);
    return (watched.length >= 3 ? watched : movies).slice(0, 3).map((m) => posterUrl(m.jellyfinId, 'thumb'));
  }, [movies]);

  const stats = useMemo(() => {
    const watched = movies.filter((m) => m.played).length;
    const untagged = movies.filter((m) => !(m.tags || []).length).length;
    const review = movies.filter((m) => m.needsReview).length;
    return { total: movies.length, watched, unwatched: movies.length - watched, untagged, review };
  }, [movies]);

  const shown = useMemo(() => {
    let list = movies.filter((m) => (!selectedMood || (m.tags || []).some((t) => t.slug === selectedMood)));
    if (filters.includes('watched')) list = list.filter((m) => m.played);
    if (filters.includes('unwatched')) list = list.filter((m) => !m.played);
    if (filters.includes('untagged')) list = list.filter((m) => !(m.tags || []).length);
    if (filters.includes('review')) list = list.filter((m) => m.needsReview);
    const byTitle = (a: Movie, b: Movie) => a.title.localeCompare(b.title);
    if (sort === 'az') list = [...list].sort(byTitle);
    if (sort === 'year-desc') list = [...list].sort((a, b) => (b.year ?? 0) - (a.year ?? 0) || byTitle(a, b));
    if (sort === 'year-asc') list = [...list].sort((a, b) => (a.year ?? 9999) - (b.year ?? 9999) || byTitle(a, b));
    return list;
  }, [movies, selectedMood, filters, sort]);

  const mood = selectedMood ? moods[selectedMood] : undefined;
  const toggle = (f: LibraryFilter) => {
    const exclusive: LibraryFilter[][] = [['watched', 'unwatched']];
    let next = filters.includes(f) ? filters.filter((x) => x !== f) : [...filters, f];
    for (const pair of exclusive) if (pair.includes(f)) next = next.filter((x) => x === f || !pair.includes(x));
    onFiltersChange(next);
  };

  return (
    <div className="mx-auto w-full max-w-[1480px] px-4 pb-28 pt-5 sm:px-8">
      <div
        className={cn('sticky z-30 -mx-4 bg-white/[.92] px-4 backdrop-blur-xl transition-[padding] sm:-mx-8 sm:px-8', collapsed ? 'py-2 shadow-[0_1px_0_#ededed]' : 'py-1')}
        style={{ top: 'calc(64px + 2px + 44px + env(safe-area-inset-top, 0px))' }}
      >
        <MoodBand moods={band} all={{ count: movies.length, covers: allCovers }} selected={selectedMood} onSelect={onMoodChange} collapsed={collapsed} />
      </div>

      <div className="mt-7 flex flex-wrap items-end justify-between gap-x-8 gap-y-3">
        <div className="min-w-0 max-w-[760px]">
          <h1 key={selectedMood} className="rise text-[32px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">
            {mood ? mood.title : 'Everything'}
          </h1>
          <p className="mt-2.5 text-[15px] leading-[1.55] text-mute">
            {mood ? mood.description : `All your films from Jellyfin, sorted into ${Object.keys(moods).length} moods`}
            <span className="text-faint">
              {' '}· {shown.length.toLocaleString()} film{shown.length === 1 ? '' : 's'}
              {!mood && ` · ${stats.watched} watched`}
            </span>
          </p>
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-center gap-2">
        <Chip active={filters.includes('watched')} onClick={() => toggle('watched')} count={stats.watched}>
          Watched
        </Chip>
        <Chip active={filters.includes('unwatched')} onClick={() => toggle('unwatched')} count={stats.unwatched}>
          Unwatched
        </Chip>
        <Chip active={filters.includes('untagged')} onClick={() => toggle('untagged')} count={stats.untagged}>
          Untagged
        </Chip>
        <Chip active={filters.includes('review')} onClick={() => toggle('review')} count={stats.review}>
          Needs review
        </Chip>
        <div className="ml-auto flex items-center gap-2">
          <ArrowUpDown size={14} className="text-faint" />
          <Select<LibrarySort> value={sort} onChange={onSortChange} label="Sort" options={(Object.keys(SORT_LABEL) as LibrarySort[]).map((k) => [k, SORT_LABEL[k]])} />
        </div>
      </div>

      {shown.length === 0 ? (
        <div className="mt-8 rounded-[24px] bg-white shadow-card">
          <Empty icon={<Film size={20} />} title={loading ? 'Loading your films' : 'No films match'} sub={loading ? 'Talking to Jellyfin.' : 'Clear a filter or pick another mood.'} />
        </div>
      ) : (
        <div className="mt-6 grid grid-cols-[repeat(auto-fill,minmax(148px,1fr))] gap-x-4 gap-y-6">
          {shown.map((m) => (
            <PosterCard key={m.jellyfinId} movie={m} moods={moods} onOpen={() => onOpenMovie(m, shown)} />
          ))}
        </div>
      )}
    </div>
  );
}
