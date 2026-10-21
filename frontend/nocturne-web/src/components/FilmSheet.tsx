import { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { ArrowUpRight, ChevronDown, ChevronLeft, ChevronRight, Sparkles, X } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { Button } from '../ui/Button';
import { EvidenceList } from './EvidenceList';
import { MoodPicker } from './MoodPicker';
import { StorySource } from './StorySource';
import type { MoodBuckets, Movie, TagSuggestionApi } from '../lib/types';

const MAX_TAGS = 5;

interface FilmSheetProps {
  movie: Movie | null;
  moods: MoodBuckets;
  covers?: Record<string, string | undefined>;
  position?: { index: number; total: number };
  // The film's open review row, when it has one: its evidence shows under "Why these moods".
  suggestion?: TagSuggestionApi;
  jellyfinUrl?: string;
  onClose: () => void;
  onPrev?: () => void;
  onNext?: () => void;
  onSaveTags: (movie: Movie, slugs: string[]) => Promise<void>;
  onRetag: (movie: Movie) => Promise<void>;
}

// The film panel as X-Cache's right-side sheet: the poster on its stage, the moods as pills,
// the reader's evidence, the story source, Previous and Next along the list it was opened from.
export function FilmSheet({ movie, moods, covers, position, suggestion, jellyfinUrl, onClose, onPrev, onNext, onSaveTags, onRetag }: FilmSheetProps) {
  useEffect(() => {
    if (!movie) return;
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable) return;
      if (e.metaKey || e.ctrlKey) return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
      if ((e.key === 'ArrowLeft' || e.key === 'k') && onPrev) onPrev();
      if ((e.key === 'ArrowRight' || e.key === 'j') && onNext) onNext();
    };
    window.addEventListener('keydown', k, true);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      window.removeEventListener('keydown', k, true);
      document.body.style.overflow = prev;
    };
  }, [movie, onClose, onPrev, onNext]);

  if (!movie) return null;
  return createPortal(
    <div className="fixed inset-0 z-[60] flex items-end justify-end sm:items-stretch" role="dialog" aria-modal="true" aria-label={movie.title}>
      <div className="fade-in absolute inset-0 bg-black/30" onClick={onClose} />
      <Body key={movie.jellyfinId} movie={movie} moods={moods} covers={covers} position={position} suggestion={suggestion} jellyfinUrl={jellyfinUrl} onClose={onClose} onPrev={onPrev} onNext={onNext} onSaveTags={onSaveTags} onRetag={onRetag} />
    </div>,
    document.body,
  );
}

function Body({ movie, moods, covers, position, suggestion, jellyfinUrl, onClose, onPrev, onNext, onSaveTags, onRetag }: FilmSheetProps & { movie: Movie }) {
  const original = useMemo(() => (movie.tags || []).map((t) => t.slug), [movie]);
  const [selected, setSelected] = useState<string[]>(original);
  const [pick, setPick] = useState(false);
  const [saving, setSaving] = useState(false);
  const [retagging, setRetagging] = useState(false);
  const [failed, setFailed] = useState(false);
  const dirty = !sameSet(selected, original);
  const title = (slug: string) => moods[slug]?.title || slug;
  const items = (suggestion?.items ?? []).filter((i) => i.kind === 'add');
  const openUrl = jellyfinUrl ? `${jellyfinUrl.replace(/\/$/, '')}/web/index.html#!/details?id=${movie.jellyfinId}` : null;
  const meta = [movie.year ? String(movie.year) : null, movie.played ? 'Watched' : 'Unwatched', movie.needsReview ? 'in review' : null].filter(Boolean).join(' · ');

  const save = async () => {
    setSaving(true);
    try {
      await onSaveTags(movie, selected);
    } finally {
      setSaving(false);
    }
  };
  const retag = async () => {
    setRetagging(true);
    try {
      await onRetag(movie);
    } finally {
      setRetagging(false);
    }
  };

  return (
    <aside className="sheet-in relative flex max-h-[92vh] w-full flex-col rounded-t-[24px] bg-white shadow-[0_40px_100px_-24px_rgba(0,0,0,.45)] sm:max-h-none sm:w-[480px] sm:rounded-none sm:rounded-l-[24px]">
      <div className="flex items-center justify-between gap-2 px-5 pb-2 pt-4 sm:px-6">
        <div className="text-[12.5px] tabular-nums text-faint">{position ? `${position.index + 1} of ${position.total}` : ''}</div>
        <button type="button" onClick={onClose} aria-label="Close" className="grid h-9 w-9 place-items-center rounded-full text-ink transition hover:bg-[#f3f3f3] cursor-pointer">
          <X size={18} />
        </button>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-6 pt-1 sm:px-6">
        <h2 className="text-[24px] font-semibold leading-tight tracking-[-0.03em] text-ink">{movie.title}</h2>
        <div className="mt-1.5 flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
          <p className="text-[13px] tabular-nums text-mute">{meta}</p>
          {openUrl && (
            <a href={openUrl} target="_blank" rel="noreferrer" className="inline-flex h-8 items-center gap-1.5 rounded-full bg-ink px-3.5 text-[13px] font-medium text-white transition hover:bg-black">
              Open in Jellyfin <ArrowUpRight size={14} />
            </a>
          )}
        </div>
        <div className="relative mt-4 flex items-center justify-center overflow-hidden rounded-2xl bg-[#f6f6f6] p-5">
          {failed ? (
            <span className="py-16 text-center text-[16px] font-semibold text-mute">{movie.title}</span>
          ) : (
            <img src={posterUrl(movie.jellyfinId, 'full')} alt="" onError={() => setFailed(true)} className="max-h-[300px] max-w-full rounded-xl object-contain shadow-[0_12px_32px_-12px_rgba(0,0,0,.35)]" />
          )}
        </div>

        <div className="mt-6 border-t border-[#efefef] pt-5">
          <div className="mb-2.5 flex items-center justify-between">
            <span className="text-[12px] font-semibold text-mute">{selected.length === 0 ? 'No moods yet' : 'Moods'}</span>
            <span className="flex items-center gap-1.5">
              {dirty ? (
                <>
                  <Button variant="ghost" size="sm" onClick={() => setSelected(original)} disabled={saving}>
                    Reset
                  </Button>
                  <Button variant="primary" size="sm" onClick={() => void save()} disabled={saving}>
                    {saving ? 'Saving…' : 'Save'}
                  </Button>
                </>
              ) : (
                <span className="text-[12px] tabular-nums text-faint">
                  {selected.length} of {MAX_TAGS}
                </span>
              )}
            </span>
          </div>
          <div className="flex flex-wrap gap-1.5">
            {selected.map((slug) => (
              <span key={slug} className="inline-flex h-8 items-center gap-1 rounded-full bg-ink pl-3 pr-1.5 text-[13px] font-medium text-white">
                {title(slug)}
                <button type="button" onClick={() => setSelected((s) => s.filter((x) => x !== slug))} aria-label={`Remove ${title(slug)}`} className="grid h-5 w-5 place-items-center rounded-full text-white/70 hover:bg-white/15 hover:text-white cursor-pointer">
                  <X size={11} strokeWidth={2.6} />
                </button>
              </span>
            ))}
            <span className="relative">
              <button
                type="button"
                onClick={() => setPick((v) => !v)}
                disabled={selected.length >= MAX_TAGS}
                className="inline-flex h-8 items-center gap-1 rounded-full px-3 text-[13px] font-medium text-ink ring-1 ring-inset ring-[#e6e6e6] transition hover:bg-[#f7f7f7] disabled:opacity-40 cursor-pointer"
              >
                {selected.length === 0 ? 'Pick a mood…' : 'Other mood…'} <ChevronDown size={13} />
              </button>
              {pick && (
                <MoodPicker
                  moods={moods}
                  exclude={selected}
                  covers={covers}
                  onPick={(slug) => {
                    setPick(false);
                    setSelected((s) => (s.length < MAX_TAGS ? [...s, slug] : s));
                  }}
                  onClose={() => setPick(false)}
                />
              )}
            </span>
            {selected.length === 0 && !pick && (
              <Button variant="outline" size="sm" onClick={() => void retag()} disabled={retagging}>
                <Sparkles size={13} /> {retagging ? 'Asking AI…' : 'Ask AI'}
              </Button>
            )}
          </div>
        </div>

        {items.length > 0 && (
          <div className="mt-6 border-t border-[#efefef] pt-5">
            <div className="mb-1.5 flex items-center justify-between gap-3">
              <span className="text-[12px] font-semibold text-mute">Why these moods</span>
              <span className="text-[12px] text-faint">{suggestion?.source === 'model' ? 'unverified source' : 'from the plot'}</span>
            </div>
            {suggestion?.reasoning && <p className="mb-1 text-[13px] leading-[1.45] text-[#4a4a4a]">{suggestion.reasoning}</p>}
            <EvidenceList items={items} moods={moods} onToggle={(slug) => setSelected((s) => (s.includes(slug) ? s.filter((x) => x !== slug) : s.length < MAX_TAGS ? [...s, slug] : s))} isSelected={(slug) => selected.includes(slug)} />
          </div>
        )}

        <div className="mt-6">
          <StorySource jellyfinId={movie.jellyfinId} title={movie.title} year={movie.year} />
        </div>
      </div>

      <div className="flex items-center justify-between border-t border-[#efefef] px-3 py-2.5 text-[12px] text-faint">
        <button type="button" disabled={!onPrev} onClick={onPrev} className={cn('inline-flex h-9 items-center gap-1 rounded-full px-3 text-[13px] font-medium text-ink transition hover:bg-[#f3f3f3] disabled:opacity-30 cursor-pointer')}>
          <ChevronLeft size={16} /> Previous
        </button>
        <span className="hidden sm:inline">← → browse · esc close</span>
        <button type="button" disabled={!onNext} onClick={onNext} className={cn('inline-flex h-9 items-center gap-1 rounded-full px-3 text-[13px] font-medium text-ink transition hover:bg-[#f3f3f3] disabled:opacity-30 cursor-pointer')}>
          Next <ChevronRight size={16} />
        </button>
      </div>
    </aside>
  );
}

function sameSet(a: string[], b: string[]) {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((v, i) => v === sb[i]);
}
