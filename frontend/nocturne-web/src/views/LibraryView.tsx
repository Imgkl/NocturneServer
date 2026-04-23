import type { ReactNode } from 'react';
import { Button } from '../ui/Button';
import { Input } from '../ui/Input';
import { Spinner } from '../ui/Spinner';
import { MoodChips } from '../components/MoodChips';
import { MovieGrid } from '../components/MovieGrid';
import type { ViewMode } from '../components/MovieGrid';
import type { MoodBuckets, Movie } from '../lib/types';
import { useHeaderCollapsed } from '../lib/useHeaderCollapsed';

interface LibraryViewProps {
  movies: Movie[];
  moods: MoodBuckets;
  moodCounts: Record<string, number>;
  stats: { total: number; tagged: number; untagged: number };
  viewMode: ViewMode;
  onViewModeChange: (v: ViewMode) => void;
  searchQuery: string;
  onSearchChange: (q: string) => void;
  selectedMood: string;
  onMoodChange: (slug: string) => void;
  loading: boolean;
  refineRunning?: boolean;
  onSync: () => void;
  onEditMovie: (movie: Movie) => void;
  onRefineTag?: (slug: string) => void;
  // Render slots (stay in App.tsx for now; extracted later)
  backfillBanner?: ReactNode;
  pendingSuggestionsPanel?: ReactNode;
}

export function LibraryView({
  movies,
  moods,
  moodCounts,
  stats,
  viewMode,
  onViewModeChange,
  searchQuery,
  onSearchChange,
  selectedMood,
  onMoodChange,
  loading,
  refineRunning,
  onSync,
  onEditMovie,
  onRefineTag,
  backfillBanner,
  pendingSuggestionsPanel,
}: LibraryViewProps) {
  const collapsed = useHeaderCollapsed();
  const focusedMood = selectedMood ? moods[selectedMood] : undefined;

  return (
    <>
      <header className="border-b border-border bg-bg sticky top-14 lg:top-0 z-20">
        {/* Collapsible top: title + stats + actions + search.
            `grid-rows-[1fr → 0fr]` gives a smooth height transition without
            hard-coding a max-height. The inner div clips overflow so the
            content doesn't bleed while animating. */}
        <div
          className={`grid transition-[grid-template-rows] duration-300 ease-out ${
            collapsed ? 'grid-rows-[0fr]' : 'grid-rows-[1fr]'
          }`}
          aria-hidden={collapsed}
        >
          <div className="overflow-hidden min-h-0">
            <div className="px-5 lg:px-10 pt-6 lg:pt-8 pb-5 flex flex-col gap-6">
              <div className="flex flex-col lg:flex-row lg:items-start lg:justify-between gap-4">
                <div className="min-w-0 flex-1">
                  {focusedMood ? (
                    <>
                      <h1 className="font-serif italic text-3xl lg:text-4xl text-text">
                        {focusedMood.title}
                      </h1>
                      <p className="text-[13px] lg:text-[14px] text-text-dim mt-3 max-w-3xl leading-relaxed">
                        {focusedMood.description}
                      </p>
                      <p className="text-[11px] uppercase tracking-widest text-muted mt-3">
                        {movies.length.toLocaleString()} in this mood
                      </p>
                    </>
                  ) : (
                    <>
                      <h1 className="font-serif italic text-3xl lg:text-4xl text-text">Library</h1>
                      <p className="text-[11px] uppercase tracking-widest text-muted mt-2">
                        {movies.length.toLocaleString()} shown · {stats.tagged} tagged · {stats.untagged} untagged
                      </p>
                    </>
                  )}
                </div>
                <div className="flex items-center gap-2 flex-shrink-0">
                  {focusedMood && onRefineTag && (
                    <Button
                      variant="line"
                      onClick={() => onRefineTag(selectedMood)}
                      disabled={!!refineRunning}
                      title="Ask Claude to verify every movie in this bucket still fits the tag"
                    >
                      {refineRunning ? 'Refining…' : 'Refine tag'}
                    </Button>
                  )}
                  <ViewModeToggle value={viewMode} onChange={onViewModeChange} />
                  <Button variant="primary" onClick={onSync} disabled={loading}>
                    {loading ? 'Syncing…' : 'Sync library'}
                  </Button>
                </div>
              </div>

              <div className="max-w-md">
                <Input
                  placeholder="Search films…"
                  value={searchQuery}
                  onChange={(e) => onSearchChange(e.target.value)}
                />
              </div>
            </div>
          </div>
        </div>

        {/* Always-visible strip: mood chips */}
        <div className="px-5 lg:px-10 py-3">
          <MoodChips
            moods={moods}
            counts={moodCounts}
            selected={selectedMood}
            onSelect={onMoodChange}
          />
        </div>
      </header>

      {backfillBanner}
      {pendingSuggestionsPanel}

      <main className="px-5 lg:px-10 py-8">
        {movies.length === 0 && !loading ? (
          <EmptyState />
        ) : (
          <MovieGrid movies={movies} viewMode={viewMode} onEditMovie={onEditMovie} />
        )}
      </main>
    </>
  );
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center py-20 text-center">
      <Spinner size={28} className="text-muted" />
      <p className="mt-5 font-serif italic text-2xl text-text">No films match.</p>
      <p className="mt-1 text-[13px] text-text-dim">Clear the search or pick a different mood.</p>
    </div>
  );
}

interface ViewModeToggleProps {
  value: ViewMode;
  onChange: (v: ViewMode) => void;
}

function ViewModeToggle({ value, onChange }: ViewModeToggleProps) {
  return (
    <div className="inline-flex border border-border" role="group" aria-label="View mode">
      <button
        type="button"
        onClick={() => onChange('tile')}
        aria-pressed={value === 'tile'}
        aria-label="Grid view"
        className={`p-2 transition-colors cursor-pointer ${
          value === 'tile' ? 'bg-text text-bg' : 'bg-bg text-muted hover:text-text'
        }`}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
          <rect x="3" y="3" width="7" height="7" />
          <rect x="14" y="3" width="7" height="7" />
          <rect x="3" y="14" width="7" height="7" />
          <rect x="14" y="14" width="7" height="7" />
        </svg>
      </button>
      <button
        type="button"
        onClick={() => onChange('list')}
        aria-pressed={value === 'list'}
        aria-label="List view"
        className={`p-2 transition-colors cursor-pointer border-l border-border ${
          value === 'list' ? 'bg-text text-bg' : 'bg-bg text-muted hover:text-text'
        }`}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
          <path d="M3 6h18M3 12h18M3 18h18" />
        </svg>
      </button>
    </div>
  );
}
