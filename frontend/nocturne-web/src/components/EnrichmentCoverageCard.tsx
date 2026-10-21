import { useEffect, useState } from 'react';
import { ChevronRight } from 'lucide-react';
import { api, posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { worklistReason } from '../lib/enrichment';
import { Button } from '../ui/Button';
import { Chip } from '../ui/Chip';
import { Bar } from '../ui/Stat';
import type { CoverageStatus, EnrichmentRow, EnrichmentSummary, Movie, WorklistFilter } from '../lib/types';

interface EnrichmentCoverageCardProps {
  summary: EnrichmentSummary | null;
  status: CoverageStatus | null;
  // Another run (the auto-tagger) holds the single run slot.
  otherRunActive: boolean;
  onStart: () => Promise<void>;
  onCancel: () => Promise<void>;
  onOpenMovie: (jellyfinId: string) => void;
  movieLookup: (jellyfinId: string) => Movie | undefined;
}

type PillKey = WorklistFilter | 'english_plot';

// The counts are the filters: tapping one lists the films in that bucket.
const PILLS: { key: PillKey; count: keyof EnrichmentSummary; label: string }[] = [
  { key: 'english_plot', count: 'english_plot', label: 'English plot' },
  { key: 'other_lang', count: 'other_lang_plot', label: 'Other language' },
  { key: 'unverified', count: 'model_synopsis', label: 'Model synopsis' },
  { key: 'no_plot', count: 'no_plot', label: 'No plot' },
  { key: 'unresolved', count: 'unresolved', label: 'Unresolved' },
  { key: 'error', count: 'error', label: 'Errors' },
];

const PREVIEW_ROWS = 8;

export function EnrichmentCoverageCard({ summary, status, otherRunActive, onStart, onCancel, onOpenMovie, movieLookup }: EnrichmentCoverageCardProps) {
  const [filter, setFilter] = useState<PillKey>('no_plot');
  const [rows, setRows] = useState<EnrichmentRow[]>([]);
  const [loadingRows, setLoadingRows] = useState(false);
  const [showAll, setShowAll] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);

  const running = status?.running === true;
  const total = summary?.total ?? 0;

  useEffect(() => {
    if (filter === 'english_plot') {
      setRows([]);
      return;
    }
    let cancelled = false;
    setLoadingRows(true);
    api.enrichment
      .worklist(filter)
      .then((r) => {
        if (!cancelled) setRows(r.items);
      })
      .catch(() => {
        if (!cancelled) setRows([]);
      })
      .finally(() => {
        if (!cancelled) setLoadingRows(false);
      });
    return () => {
      cancelled = true;
    };
  }, [filter, summary]);

  useEffect(() => setShowAll(false), [filter]);

  const active = PILLS.find((p) => p.key === filter);
  const activeCount = summary?.[active?.count ?? 'no_plot'] ?? 0;
  const visible = showAll ? rows : rows.slice(0, PREVIEW_ROWS);

  async function start() {
    setStartError(null);
    try {
      await onStart();
    } catch (e) {
      setStartError(e instanceof Error ? e.message : 'Failed to start the coverage run.');
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-[560px] text-[13.5px] leading-[1.5] text-mute">
          {running ? 'Running in background. Wikidata and Wikipedia, two requests a second.' : 'Wikipedia plots, reception and awards for every film. The tagger reads these, not the Jellyfin blurb.'}
        </p>
        <Button variant="primary" onClick={() => void start()} disabled={running || otherRunActive} reason={otherRunActive ? 'Another run is in progress' : null} reasonInline={false}>
          {running ? 'Running…' : 'Run coverage'}
        </Button>
      </div>

      {running && status && (
        <div className="space-y-2">
          <Bar value={status.total > 0 ? status.processed / status.total : 0} />
          <div className="flex items-center justify-between gap-3 text-[12.5px] text-mute">
            <span className="tabular-nums">
              {status.processed} / {status.total}
              {statsLine(status.stats)}
              {status.cancelRequested && ' · cancelling'}
            </span>
            {!status.cancelRequested && (
              <Button variant="ghost" size="sm" onClick={() => void onCancel()}>
                Cancel
              </Button>
            )}
          </div>
        </div>
      )}
      {!running && status?.error && <p className="text-[12.5px] text-bad">Last run stopped: {status.error}</p>}
      {startError && <p className="text-[12.5px] text-bad">{startError}</p>}

      <div className="flex flex-wrap items-center gap-1.5">
        {PILLS.map((p) => (
          <Chip key={p.key} active={p.key === filter} onClick={() => setFilter(p.key)} count={summary?.[p.count] ?? 0}>
            {p.label}
          </Chip>
        ))}
        <span className="pl-1 text-[12.5px] text-faint">
          {total} total · {summary?.unverified ?? 0} unverified
        </span>
      </div>

      <div className="overflow-hidden rounded-2xl ring-1 ring-line">
        <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-2.5">
          <span className="text-[12.5px] font-medium text-mute">
            {active?.label} · {activeCount} {activeCount === 1 ? 'film' : 'films'}
          </span>
          {rows.length > 0 && <span className="text-[12px] text-faint">tap a film to open it</span>}
        </div>
        {filter === 'english_plot' ? (
          <p className="px-4 py-3 text-[13px] text-mute">{activeCount > 0 ? `${activeCount} films have a full English plot. Nothing to fix here.` : 'No film has an English plot yet. Run coverage to fetch them.'}</p>
        ) : loadingRows && rows.length === 0 ? (
          <p className="px-4 py-3 text-[13px] text-mute">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="px-4 py-3 text-[13px] text-mute">{total === 0 ? 'Nothing fetched yet. Run coverage to build the story sources.' : 'Nothing in this bucket.'}</p>
        ) : (
          <>
            <ul className="divide-y divide-[#f0f0f0]">
              {visible.map((row) => {
                const movie = movieLookup(row.jellyfinId);
                return (
                  <li key={row.jellyfinId}>
                    <button type="button" onClick={() => onOpenMovie(row.jellyfinId)} className="flex w-full items-center gap-3 px-4 py-2 text-left hover:bg-[#f7f7f7] cursor-pointer">
                      <img src={posterUrl(row.jellyfinId, 'thumb')} alt="" className="h-9 w-6 shrink-0 rounded-md bg-canvas object-cover" loading="lazy" />
                      <span className="min-w-0 flex-1 truncate text-[13.5px] font-medium text-ink">
                        {movie?.title || row.jellyfinId}
                        {movie?.year && <span className="ml-1.5 text-[12px] font-normal tabular-nums text-faint">{movie.year}</span>}
                      </span>
                      <span className="hidden max-w-[45%] truncate text-[12px] text-mute sm:block">{worklistReason(row)}</span>
                      <ChevronRight size={14} className="shrink-0 text-faint" />
                    </button>
                  </li>
                );
              })}
            </ul>
            {rows.length > PREVIEW_ROWS && (
              <button type="button" onClick={() => setShowAll((v) => !v)} className={cn('w-full border-t border-line px-4 py-2.5 text-left text-[12.5px] font-medium text-mute hover:text-ink cursor-pointer')}>
                {showAll ? 'Show fewer' : `Show all ${rows.length}`}
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function statsLine(stats: CoverageStatus['stats']): string {
  const parts: string[] = [];
  const push = (n: number | undefined, label: string) => {
    if (n) parts.push(`${n} ${label}`);
  };
  push(stats.english_plot, 'english');
  push(stats.other_lang_plot, 'other language');
  push(stats.model_synopsis, 'synopsis');
  push(stats.no_plot, 'no plot');
  push(stats.unresolved, 'unresolved');
  push(stats.error, 'errors');
  return parts.length ? ` · ${parts.join(' · ')}` : '';
}
