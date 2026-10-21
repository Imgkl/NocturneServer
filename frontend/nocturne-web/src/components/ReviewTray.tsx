import { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown, Plus, RotateCw, X } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { Button } from '../ui/Button';
import { Empty } from '../ui/Empty';
import { Segmented } from '../ui/Segmented';
import { MoodPicker } from './MoodPicker';
import type { MoodBuckets, Movie, SuggestionItem, TagSuggestionApi } from '../lib/types';

const MAX_TAGS = 5;
type Scope = 'watched' | 'unwatched' | 'all';

interface ReviewTrayProps {
  open: boolean;
  onClose: () => void;
  suggestions: TagSuggestionApi[];
  movieLookup: (jellyfinId: string) => Movie | undefined;
  moods: MoodBuckets;
  covers?: Record<string, string | undefined>;
  onApprove: (id: string, tags: string[] | undefined) => Promise<void>;
  onReject: (id: string) => Promise<void>;
  onOpenMovie: (movie: Movie) => void;
  onRefresh: () => Promise<void>;
  onRetryErrors?: () => Promise<void>;
}

// X-Cache's To sort tray, for films: a right-side sheet (a bottom sheet on phones), one row per
// film with the reader's moods as pills, Approve or Reject with the pills as edited.
export function ReviewTray({ open, onClose, suggestions, movieLookup, moods, covers, onApprove, onReject, onOpenMovie, onRefresh, onRetryErrors }: ReviewTrayProps) {
  const [scope, setScope] = useState<Scope>('watched');
  const [edits, setEdits] = useState<Record<string, string[]>>({});
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState(0);

  useEffect(() => {
    if (open) void onRefresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

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

  // Applied moods start selected; with none applied, the reader's top candidate does (X-Cache's first pill).
  const defaultFor = (s: TagSuggestionApi) => {
    if (s.suggestedTags.length > 0) return s.suggestedTags;
    const top = (s.items ?? []).filter((i) => i.kind === 'add').sort((a, b) => b.probability - a.probability)[0];
    return top ? [top.slug] : [];
  };
  const selectedFor = (s: TagSuggestionApi) => edits[s.id] ?? defaultFor(s);
  const act = async (s: TagSuggestionApi, kind: 'approve' | 'reject') => {
    setLeaving((l) => new Set(l).add(s.id));
    try {
      if (kind === 'approve') {
        const sel = selectedFor(s);
        const edited = !sameSet(sel, s.suggestedTags);
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

  // Keys: Escape closes, arrows move, A approves, R rejects, 1 to 5 toggle the nth pill of the focused row.
  useEffect(() => {
    if (!open) return;
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable) return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
        return;
      }
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
        setEdits((ed) => ({ ...ed, [row.id]: sel.includes(slug) ? sel.filter((x) => x !== slug) : sel.length < MAX_TAGS ? [...sel, slug] : sel }));
      }
    };
    window.addEventListener('keydown', k, true);
    return () => window.removeEventListener('keydown', k, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, rows, focus, edits, onClose]);

  useEffect(() => {
    if (!open) return;
    const el = document.querySelector<HTMLElement>(`[data-row="${rows[focus]?.id}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [open, focus, rows]);

  if (!open) return null;

  return createPortal(
    <div className="fixed inset-0 z-[60] flex items-end justify-end sm:items-stretch" role="dialog" aria-modal="true" aria-label="Review">
      <div className="fade-in absolute inset-0 bg-black/30" onClick={onClose} />
      <aside className="sheet-in relative flex max-h-[88vh] w-full flex-col rounded-t-[24px] bg-white shadow-[0_40px_100px_-24px_rgba(0,0,0,.45)] sm:max-h-none sm:w-[460px] sm:rounded-none sm:rounded-l-[24px]">
        <div className="flex items-center justify-between border-b border-[#f2f2f2] px-5 pb-4 pt-5 sm:px-7 sm:pt-7">
          <div>
            <h2 className="text-[24px] font-semibold leading-tight tracking-[-0.03em] text-ink">Review</h2>
            <p className="mt-0.5 text-[13px] text-mute">{suggestions.length === 0 ? 'Nothing waiting.' : `${suggestions.length} film${suggestions.length === 1 ? '' : 's'} AI was not sure about`}</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close" className="grid h-9 w-9 place-items-center rounded-full hover:bg-[#f3f3f3] cursor-pointer">
            <X size={18} />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-8 pt-2 sm:px-7">
          {suggestions.length > 0 && (
            <div className="mb-3 mt-2 flex items-center justify-between gap-3">
              <Segmented<Scope>
                value={scope}
                onChange={setScope}
                label="Scope"
                size="sm"
                options={[
                  { value: 'watched', label: 'Watched', count: counts.watched },
                  { value: 'unwatched', label: 'Unwatched', count: counts.unwatched },
                  { value: 'all', label: 'All', count: counts.all },
                ]}
              />
              <span className="hidden whitespace-nowrap text-[12px] text-faint sm:inline">A approve · R reject</span>
            </div>
          )}
          {errors > 0 && (
            <div className="mb-3 flex items-center justify-between gap-3 rounded-2xl border border-[#ededed] px-4 py-3 text-[13px] text-mute">
              <span>
                {errors} film{errors === 1 ? '' : 's'} could not be tagged (AI failed).
              </span>
              {onRetryErrors && (
                <Button size="sm" variant="outline" onClick={() => void onRetryErrors()}>
                  <RotateCw size={13} /> Retry
                </Button>
              )}
            </div>
          )}
          {rows.length === 0 && (
            <Empty icon={<Check size={20} />} title={suggestions.length === 0 ? 'All sorted' : 'Nothing in this scope'} sub={suggestions.length === 0 ? 'New films AI is not sure about land here.' : 'Switch the scope above.'} />
          )}
          <ul className="divide-y divide-[#f0f0f0]">
            {rows.map((s, i) => (
              <TrayRow
                key={s.id}
                suggestion={s}
                movie={movieLookup(s.jellyfinId)}
                moods={moods}
                covers={covers}
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
        </div>
      </aside>
    </div>,
    document.body,
  );
}

interface TrayRowProps {
  suggestion: TagSuggestionApi;
  movie?: Movie;
  moods: MoodBuckets;
  covers?: Record<string, string | undefined>;
  selected: string[];
  onChange: (next: string[]) => void;
  onApprove: () => void;
  onReject: () => void;
  onOpen: () => void;
  focused?: boolean;
  leaving?: boolean;
}

// The reader's moods as pills in probability order: solid when selected, grey when held back.
function TrayRow({ suggestion: s, movie, moods, covers, selected, onChange, onApprove, onReject, onOpen, focused, leaving }: TrayRowProps) {
  const [pick, setPick] = useState(false);
  const items: SuggestionItem[] = (s.items ?? []).filter((i) => i.kind === 'add');
  // AI's maybes: considered, not defended. Outline pills, one tap adds them.
  const maybes: SuggestionItem[] = (s.items ?? []).filter((i) => i.kind === 'maybe' && !items.some((a) => a.slug === i.slug));
  // Moods AI did not name but the admin added through the picker still show as pills.
  const extra = selected.filter((slug) => !items.some((i) => i.slug === slug) && !maybes.some((i) => i.slug === slug));
  const title = (slug: string) => moods[slug]?.title || slug;
  const toggle = (slug: string) => {
    if (selected.includes(slug)) onChange(selected.filter((x) => x !== slug));
    else if (selected.length < MAX_TAGS) onChange([...selected, slug]);
  };
  const why = items.find((i) => i.evidence)?.evidence;
  const failure = s.reasoning && (s.reasoning.startsWith('auto-tagger failed') || s.reasoning.startsWith('budget cap')) ? s.reasoning : null;
  const residue = s.reasoning && !failure ? s.reasoning : null;

  return (
    <li className={cn('py-5', focused && '-mx-3 rounded-2xl bg-[#fafafa] px-3', leaving && 'row-out')} data-row={s.id}>
      <div className="flex items-start gap-4">
        <button type="button" onClick={onOpen} className="shrink-0 cursor-pointer" aria-label={`Open ${movie?.title ?? 'film'}`}>
          <img src={posterUrl(s.jellyfinId, 'thumb')} alt="" loading="lazy" className="h-20 w-20 rounded-2xl bg-[#f2f2f2] object-cover transition hover:opacity-90" />
        </button>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5 text-[13px]">
            <button type="button" onClick={onOpen} className="truncate font-semibold text-ink cursor-pointer">
              {movie?.title || s.jellyfinId}
            </button>
            {movie?.year && <span className="shrink-0 tabular-nums text-faint">{movie.year}</span>}
            {movie?.played && <span className="shrink-0 text-faint">· Watched</span>}
            {s.source === 'model' && <span className="shrink-0 rounded-full bg-ink px-2 py-[3px] text-[11px] font-semibold leading-none text-white">unverified</span>}
          </div>
          {residue && <p className="mt-1 line-clamp-2 text-[13px] leading-[1.4] text-[#4a4a4a]">{residue}</p>}
          {failure && <p className="mt-1 text-[12px] text-bad">{failure}</p>}
          {why && <p className="mt-1.5 line-clamp-2 text-[12px] text-mute">Why: {why}</p>}
        </div>
      </div>
      <div className="mt-3.5 flex flex-wrap items-center gap-1.5">
        {items.map((i) => {
          const on = selected.includes(i.slug);
          return (
            <button
              key={i.slug}
              type="button"
              onClick={() => toggle(i.slug)}
              title={i.evidence || undefined}
              aria-pressed={on}
              disabled={!on && selected.length >= MAX_TAGS}
              className={cn(
                'inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-[13px] font-medium transition cursor-pointer disabled:opacity-40',
                on ? 'bg-ink text-white hover:bg-black' : 'bg-[#f3f3f3] text-ink hover:bg-[#e9e9e9]',
              )}
            >
              {title(i.slug)}
              <span className={cn('tabular-nums', on ? 'text-white/55' : 'text-faint')}>{Math.round(i.probability * 100)}%</span>
            </button>
          );
        })}
        {maybes.map((i) => {
          const on = selected.includes(i.slug);
          return (
            <button
              key={i.slug}
              type="button"
              onClick={() => toggle(i.slug)}
              aria-pressed={on}
              disabled={!on && selected.length >= MAX_TAGS}
              title="AI considered this mood but would not defend it"
              className={cn(
                'inline-flex h-8 items-center gap-1 rounded-full px-3 text-[13px] font-medium transition cursor-pointer disabled:opacity-40',
                on ? 'bg-ink text-white hover:bg-black' : 'text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7]',
              )}
            >
              {!on && <Plus size={13} strokeWidth={2.4} className="-ml-0.5 text-faint" />}
              {title(i.slug)}
            </button>
          );
        })}
        {extra.map((slug) => (
          <button key={slug} type="button" onClick={() => toggle(slug)} aria-pressed className="inline-flex h-8 items-center gap-1.5 rounded-full bg-ink px-3 text-[13px] font-medium text-white hover:bg-black cursor-pointer">
            {title(slug)}
          </button>
        ))}
        <div className="relative">
          <button
            type="button"
            onClick={() => setPick((v) => !v)}
            disabled={selected.length >= MAX_TAGS}
            className="inline-flex h-8 items-center gap-1 rounded-full px-3 text-[13px] font-medium text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7] disabled:opacity-40 cursor-pointer"
          >
            Other mood… <ChevronDown size={13} />
          </button>
          {pick && (
            <MoodPicker
              moods={moods}
              exclude={selected}
              covers={covers}
              onPick={(slug) => {
                setPick(false);
                toggle(slug);
              }}
              onClose={() => setPick(false)}
            />
          )}
        </div>
      </div>
      <div className="mt-2.5 flex items-center gap-1.5">
        <Button variant="primary" size="sm" onClick={onApprove} disabled={selected.length === 0} reason={selected.length === 0 ? 'Pick at least one mood, or reject' : null} reasonInline={false}>
          Approve
        </Button>
        <Button variant="outline" size="sm" onClick={onReject}>
          Reject
        </Button>
        <span className="ml-auto text-[12px] tabular-nums text-faint">
          {selected.length} of {MAX_TAGS}
        </span>
      </div>
    </li>
  );
}

function sameSet(a: string[], b: string[]) {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((v, i) => v === sb[i]);
}
