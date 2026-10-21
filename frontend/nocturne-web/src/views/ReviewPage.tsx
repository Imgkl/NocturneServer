import { useEffect, useMemo, useState } from 'react';
import { Check, RotateCw } from 'lucide-react';
import { Button } from '../ui/Button';
import { Empty } from '../ui/Empty';
import { Segmented } from '../ui/Segmented';
import { ReviewRow } from '../components/ReviewRow';
import type { MoodBuckets, Movie, TagSuggestionApi } from '../lib/types';

type Scope = 'watched' | 'unwatched' | 'all';

interface ReviewPageProps {
  suggestions: TagSuggestionApi[];
  movieLookup: (jellyfinId: string) => Movie | undefined;
  moods: MoodBuckets;
  onApprove: (id: string, tags: string[] | undefined) => Promise<void>;
  onReject: (id: string) => Promise<void>;
  onOpenMovie: (movie: Movie) => void;
  onRefresh: () => Promise<void>;
  onRetryErrors?: () => Promise<void>;
}

// The queue: watched films first, one row per film, Approve or Reject with the pills as edited.
export function ReviewPage({ suggestions, movieLookup, moods, onApprove, onReject, onOpenMovie, onRefresh, onRetryErrors }: ReviewPageProps) {
  const [scope, setScope] = useState<Scope>('watched');
  const [edits, setEdits] = useState<Record<string, string[]>>({});
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState(0);

  const isWatched = (s: TagSuggestionApi) => movieLookup(s.jellyfinId)?.played === true;
  const counts = useMemo(() => {
    const w = suggestions.filter(isWatched).length;
    return { watched: w, unwatched: suggestions.length - w, all: suggestions.length };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [suggestions]);
  useEffect(() => {
    if (scope === 'watched' && counts.watched === 0 && counts.all > 0) setScope('all');
  }, [counts, scope]);

  const rows = useMemo(() => {
    const inScope = suggestions.filter((s) => (scope === 'all' ? true : scope === 'watched' ? isWatched(s) : !isWatched(s)));
    return [...inScope].sort((a, b) => Number(isWatched(b)) - Number(isWatched(a)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [suggestions, scope]);
  const errors = suggestions.filter((s) => (s.reasoning ?? '').startsWith('auto-tagger failed')).length;

  const selectedFor = (s: TagSuggestionApi) => edits[s.id] ?? s.suggestedTags;
  const act = async (s: TagSuggestionApi, kind: 'approve' | 'reject') => {
    setLeaving((l) => new Set(l).add(s.id));
    try {
      if (kind === 'approve') {
        const sel = selectedFor(s);
        const edited = edits[s.id] !== undefined && !sameSet(sel, s.suggestedTags);
        await onApprove(s.id, edited ? sel : undefined);
      } else await onReject(s.id);
      setEdits((e) => {
        const { [s.id]: _gone, ...rest } = e;
        return rest;
      });
    } finally {
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(s.id);
        return n;
      });
    }
  };

  // Keys: arrows move, A approves, R rejects, 1 to 5 toggle the nth pill of the focused row.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable) return;
      if (rows.length === 0) return;
      const row = rows[Math.min(focus, rows.length - 1)];
      if (e.key === 'ArrowDown' || e.key === 'j') {
        e.preventDefault();
        setFocus((f) => Math.min(rows.length - 1, f + 1));
      } else if (e.key === 'ArrowUp' || e.key === 'k') {
        e.preventDefault();
        setFocus((f) => Math.max(0, f - 1));
      } else if (e.key.toLowerCase() === 'a' && selectedFor(row).length > 0) {
        void act(row, 'approve');
      } else if (e.key.toLowerCase() === 'r') {
        void act(row, 'reject');
      } else if (/^[1-5]$/.test(e.key)) {
        const items = (row.items ?? []).filter((i) => i.kind === 'add');
        const slug = items[Number(e.key) - 1]?.slug;
        if (!slug) return;
        const sel = selectedFor(row);
        setEdits((ed) => ({ ...ed, [row.id]: sel.includes(slug) ? sel.filter((x) => x !== slug) : sel.length < 5 ? [...sel, slug] : sel }));
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, focus, edits]);

  useEffect(() => {
    const el = document.querySelector<HTMLElement>(`[data-row="${rows[focus]?.id}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [focus, rows]);

  return (
    <div className="mx-auto w-full max-w-[1080px] px-4 pb-28 pt-6 sm:px-8 sm:pt-10">
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
        <div className="min-w-0">
          <h1 className="rise text-[30px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">Review</h1>
          <p className="mt-3 text-[15px] leading-[1.55] text-mute">
            {suggestions.length === 0 ? 'Nothing waiting.' : `${suggestions.length} film${suggestions.length === 1 ? '' : 's'} the reader was not sure about · watched first`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Segmented<Scope>
            value={scope}
            onChange={setScope}
            label="Scope"
            options={[
              { value: 'watched', label: 'Watched', count: counts.watched },
              { value: 'unwatched', label: 'Unwatched', count: counts.unwatched },
              { value: 'all', label: 'All', count: counts.all },
            ]}
          />
          <Button variant="ghost" size="sm" onClick={() => void onRefresh()} aria-label="Refresh">
            <RotateCw size={14} />
          </Button>
        </div>
      </div>

      {errors > 0 && (
        <div className="mt-7 flex items-center justify-between gap-3 rounded-2xl px-4 py-3 text-[13px] text-mute ring-1 ring-line">
          <span>
            {errors} film{errors === 1 ? '' : 's'} could not be tagged (the reader failed).
          </span>
          {onRetryErrors && (
            <Button size="sm" variant="outline" onClick={() => void onRetryErrors()}>
              <RotateCw size={13} /> Retry
            </Button>
          )}
        </div>
      )}

      {rows.length === 0 ? (
        <div className="mt-8 rounded-[24px] bg-white shadow-card">
          <Empty icon={<Check size={20} />} title={suggestions.length === 0 ? 'All sorted' : 'Nothing in this scope'} sub={suggestions.length === 0 ? 'New films the reader is not sure about land here.' : 'Switch the scope above.'} />
        </div>
      ) : (
        <ul className="mt-6 divide-y divide-[#f0f0f0]">
          {rows.map((s, i) => (
            <ReviewRow
              key={s.id}
              suggestion={s}
              movie={movieLookup(s.jellyfinId)}
              moods={moods}
              selected={selectedFor(s)}
              onChange={(next) => setEdits((e) => ({ ...e, [s.id]: next }))}
              onApprove={() => void act(s, 'approve')}
              onReject={() => void act(s, 'reject')}
              onOpen={() => {
                const m = movieLookup(s.jellyfinId);
                if (m) onOpenMovie(m);
              }}
              focused={i === focus}
              leaving={leaving.has(s.id)}
            />
          ))}
        </ul>
      )}
      <p className="mt-8 text-[12px] text-faint">↑↓ move · A approve · R reject · 1 to 5 toggle a mood</p>
    </div>
  );
}

function sameSet(a: string[], b: string[]) {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((v, i) => v === sb[i]);
}
