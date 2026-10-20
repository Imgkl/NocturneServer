import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { worklistReason } from '../lib/enrichment';
import { Button } from '../ui/Button';
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

export function EnrichmentCoverageCard({
  summary,
  status,
  otherRunActive,
  onStart,
  onCancel,
  onOpenMovie,
  movieLookup,
}: EnrichmentCoverageCardProps) {
  const [filter, setFilter] = useState<PillKey>('no_plot');
  const [rows, setRows] = useState<EnrichmentRow[]>([]);
  const [loadingRows, setLoadingRows] = useState(false);
  const [showAll, setShowAll] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);

  const running = status?.running === true;
  const total = summary?.total ?? 0;

  // Reload the list when the filter changes or a run finishes (the summary refreshes then).
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

  useEffect(() => {
    setShowAll(false);
  }, [filter]);

  const activeLabel = PILLS.find((p) => p.key === filter)?.label ?? '';
  const activeCount = summary?.[PILLS.find((p) => p.key === filter)?.count ?? 'no_plot'] ?? 0;
  const visible = showAll ? rows : rows.slice(0, PREVIEW_ROWS);
  const pct = status && status.total > 0 ? Math.min(100, Math.round((status.processed / status.total) * 100)) : 0;

  async function start() {
    setStartError(null);
    try {
      await onStart();
    } catch (e) {
      setStartError(e instanceof Error ? e.message : 'Failed to start the coverage run.');
    }
  }

  return (
    <div className="border border-border p-5">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0 flex-1">
          <div className="text-[14px] text-text">Story sources</div>
          <p className="text-[12px] text-text-dim mt-1 leading-snug">
            {running
              ? 'Running in background. Wikidata and Wikipedia, two requests a second.'
              : 'Wikipedia plots, reception and awards for every film. The tagger reads these, not the Jellyfin blurb.'}
          </p>
        </div>
        <div className="flex-shrink-0">
          <Button
            variant="primary"
            size="sm"
            onClick={start}
            disabled={running || otherRunActive}
            title={otherRunActive ? 'Another run is in progress' : undefined}
          >
            {running ? 'Running…' : 'Run coverage'}
          </Button>
        </div>
      </div>

      {running && status && (
        <div className="mt-3 space-y-2">
          <div className="h-[2px] bg-border overflow-hidden">
            <div className="h-full bg-text transition-all" style={{ width: `${pct}%` }} />
          </div>
          <div className="flex items-center justify-between gap-3">
            <span className="text-[10px] uppercase tracking-widest text-muted">
              {status.processed} / {status.total}
              {statsLine(status.stats)}
              {status.cancelRequested && <span className="ml-2">· cancelling</span>}
            </span>
            {!status.cancelRequested && (
              <button
                onClick={onCancel}
                className="text-[10px] uppercase tracking-widest text-text-dim hover:text-text underline decoration-dotted underline-offset-2 cursor-pointer"
              >
                Cancel
              </button>
            )}
          </div>
        </div>
      )}
      {!running && status?.error && (
        <p className="mt-3 text-[11px] text-danger">Last run stopped: {status.error}</p>
      )}
      {startError && <p className="mt-3 text-[11px] text-danger">{startError}</p>}

      <div className="mt-4 flex flex-wrap items-center gap-1.5">
        {PILLS.map((p) => {
          const active = p.key === filter;
          return (
            <button
              key={p.key}
              type="button"
              onClick={() => setFilter(p.key)}
              aria-pressed={active}
              className={`inline-flex items-baseline gap-1.5 border px-2.5 py-1 cursor-pointer transition-colors ${
                active ? 'bg-text border-text text-bg' : 'border-border text-text-dim hover:border-border-hover hover:text-text'
              }`}
            >
              <span className={`text-[14px] tabular-nums ${active ? 'text-bg' : 'text-text'}`}>
                {summary?.[p.count] ?? 0}
              </span>
              <span className="text-[10px] uppercase tracking-wider">{p.label}</span>
            </button>
          );
        })}
        <span className="text-[10px] uppercase tracking-wider text-muted pl-1">
          · {total} total · {summary?.unverified ?? 0} unverified
        </span>
      </div>

      <div className="mt-3 border border-border">
        <div className="flex items-center justify-between gap-3 px-3 py-2 border-b border-border">
          <span className="text-[10px] uppercase tracking-widest text-muted">
            {activeLabel} · {activeCount} {activeCount === 1 ? 'film' : 'films'}
          </span>
          {rows.length > 0 && (
            <span className="text-[10px] uppercase tracking-widest text-muted">tap a film to open it</span>
          )}
        </div>
        {filter === 'english_plot' ? (
          <div className="px-3 py-3 text-[12px] text-muted">
            {activeCount > 0
              ? `${activeCount} films have a full English plot. Nothing to fix here.`
              : 'No film has an English plot yet. Run coverage to fetch them.'}
          </div>
        ) : loadingRows && rows.length === 0 ? (
          <div className="px-3 py-3 text-[12px] text-muted">Loading…</div>
        ) : rows.length === 0 ? (
          <div className="px-3 py-3 text-[12px] text-muted">
            {total === 0 ? 'Nothing fetched yet. Run coverage to build the story sources.' : 'Nothing in this bucket.'}
          </div>
        ) : (
          <>
            {visible.map((row) => {
              const movie = movieLookup(row.jellyfinId);
              return (
                <button
                  key={row.jellyfinId}
                  type="button"
                  onClick={() => onOpenMovie(row.jellyfinId)}
                  className="flex w-full items-center gap-2.5 px-3 py-2 border-t border-border first:border-t-0 text-left hover:bg-surface cursor-pointer"
                >
                  <span className="w-6 h-9 flex-shrink-0 bg-surface border border-border overflow-hidden flex items-center justify-center font-serif italic text-[12px] text-muted">
                    {movie?.posterUrl ? (
                      <img src={movie.posterUrl} alt="" className="w-full h-full object-cover" />
                    ) : (
                      (movie?.title || row.jellyfinId).charAt(0).toUpperCase()
                    )}
                  </span>
                  <span className="min-w-0 flex-1 truncate text-[13px] text-text">
                    {movie?.title || row.jellyfinId}
                    {movie?.year && <span className="ml-1.5 text-[11px] text-muted">{movie.year}</span>}
                  </span>
                  <span className="hidden sm:block max-w-[45%] truncate text-[11px] text-muted">{worklistReason(row)}</span>
                  <span className="text-muted" aria-hidden>
                    →
                  </span>
                </button>
              );
            })}
            {rows.length > PREVIEW_ROWS && (
              <div className="px-3 py-2 border-t border-border">
                <button
                  type="button"
                  onClick={() => setShowAll((v) => !v)}
                  className="text-[10px] uppercase tracking-widest text-text-dim hover:text-text underline decoration-dotted underline-offset-2 cursor-pointer"
                >
                  {showAll ? 'Show fewer' : `Show all ${rows.length}`}
                </button>
              </div>
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
