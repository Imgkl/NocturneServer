import { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { ArrowUpRight, ChevronLeft, ChevronRight, Sparkles, X } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { EvidenceList } from './EvidenceList';
import { MoodPicker } from './MoodPicker';
import { StorySource } from './StorySource';
import type { MoodBuckets, Movie, TagSuggestionApi } from '../lib/types';

const MAX_TAGS = 5;

interface FilmModalProps {
  movie: Movie | null;
  moods: MoodBuckets;
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

// X-Cache's post modal, for a film: the poster on a dark stage, the moods as pills, the story
// source card, the reader's evidence, Previous and Next along the list it was opened from.
export function FilmModal({ movie, moods, position, suggestion, jellyfinUrl, onClose, onPrev, onNext, onSaveTags, onRetag }: FilmModalProps) {
  useEffect(() => {
    if (!movie) return;
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA') return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
      if (e.key === 'ArrowLeft' && onPrev) onPrev();
      if (e.key === 'ArrowRight' && onNext) onNext();
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
    <div className="fixed inset-0 z-[70] flex items-end justify-center sm:items-center sm:p-6" role="dialog" aria-modal="true" aria-label={movie.title}>
      <div className="fade-in absolute inset-0 bg-black/40 backdrop-blur-[2px]" onClick={onClose} />
      <Body key={movie.jellyfinId} movie={movie} moods={moods} position={position} suggestion={suggestion} jellyfinUrl={jellyfinUrl} onClose={onClose} onPrev={onPrev} onNext={onNext} onSaveTags={onSaveTags} onRetag={onRetag} />
    </div>,
    document.body,
  );
}

function Body({ movie, moods, position, suggestion, jellyfinUrl, onClose, onPrev, onNext, onSaveTags, onRetag }: FilmModalProps & { movie: Movie }) {
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
    <div className="modal-in relative grid max-h-[94vh] w-full overflow-hidden rounded-t-[24px] bg-white shadow-modal sm:max-h-[88vh] sm:max-w-[1040px] sm:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] sm:rounded-[24px]">
      <div className="hidden min-h-[320px] place-items-center bg-[#0b0b0b] p-7 sm:grid">
        {failed ? (
          <span className="text-center text-[18px] font-semibold text-white/80">{movie.title}</span>
        ) : (
          <img src={posterUrl(movie.jellyfinId, 'full')} alt="" onError={() => setFailed(true)} className="max-h-[72vh] w-auto max-w-full rounded-[14px] shadow-[0_30px_60px_-20px_rgba(0,0,0,.8)]" />
        )}
      </div>
      <div className="flex min-h-0 flex-col overflow-y-auto overscroll-contain px-5 pb-5 pt-5 sm:px-6">
        <div className="flex items-center justify-between gap-3">
          <span className="text-[12.5px] tabular-nums text-faint">{position ? `${position.index + 1} of ${position.total}` : ''}</span>
          <div className="flex items-center gap-1.5">
            {openUrl && (
              <a href={openUrl} target="_blank" rel="noreferrer" className="inline-flex h-8 items-center gap-1.5 rounded-full bg-ink px-3 text-[13px] font-medium text-white hover:bg-black">
                Open in Jellyfin <ArrowUpRight size={14} />
              </a>
            )}
            <button type="button" onClick={onClose} aria-label="Close" className="grid h-9 w-9 place-items-center rounded-full hover:bg-canvas cursor-pointer">
              <X size={17} />
            </button>
          </div>
        </div>
        <div className="mt-3 flex items-start gap-4">
          <img src={posterUrl(movie.jellyfinId, 'thumb')} alt="" className="h-[84px] w-14 shrink-0 rounded-[10px] bg-canvas object-cover sm:hidden" />
          <div className="min-w-0">
            <h2 className="text-[22px] font-semibold leading-[1.15] tracking-[-0.025em] text-ink">{movie.title}</h2>
            <div className="mt-1 flex flex-wrap items-center gap-2 text-[12.5px] text-faint">
              {movie.year && <span className="tabular-nums">{movie.year}</span>}
              {movie.played && <Badge>Watched</Badge>}
              {movie.needsReview && <Badge tone="warn">Review</Badge>}
            </div>
          </div>
        </div>

        <div className="mt-5">
          <div className="mb-2 flex items-center justify-between">
            <span className="text-[12px] font-semibold text-mute">
              Moods · {selected.length} of {MAX_TAGS}
            </span>
            {dirty && (
              <span className="flex gap-1.5">
                <Button variant="ghost" size="sm" onClick={() => setSelected(original)} disabled={saving}>
                  Reset
                </Button>
                <Button variant="primary" size="sm" onClick={() => void save()} disabled={saving}>
                  {saving ? 'Saving…' : 'Save'}
                </Button>
              </span>
            )}
          </div>
          <div className="flex flex-wrap gap-1.5">
            {selected.map((slug) => (
              <span key={slug} className="inline-flex h-8 items-center gap-1 rounded-full bg-canvas pl-3 pr-1.5 text-[13px] font-medium text-ink">
                {title(slug)}
                <button type="button" onClick={() => setSelected((s) => s.filter((x) => x !== slug))} aria-label={`Remove ${title(slug)}`} className="grid h-5 w-5 place-items-center rounded-full text-mute hover:bg-white hover:text-ink cursor-pointer">
                  <X size={11} strokeWidth={2.6} />
                </button>
              </span>
            ))}
            <span className="relative">
              <button
                type="button"
                onClick={() => setPick((v) => !v)}
                disabled={selected.length >= MAX_TAGS}
                className="inline-flex h-8 items-center rounded-full px-3 text-[13px] font-medium text-mute ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7] hover:text-ink disabled:opacity-40 cursor-pointer"
              >
                + Add
              </button>
              {pick && (
                <MoodPicker
                  moods={moods}
                  exclude={selected}
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
                <Sparkles size={13} /> {retagging ? 'Reading the story…' : 'Ask the reader'}
              </Button>
            )}
          </div>
        </div>

        <div className="mt-5">
          <StorySource jellyfinId={movie.jellyfinId} title={movie.title} year={movie.year} />
        </div>

        {items.length > 0 && (
          <section className="mt-4 rounded-[20px] bg-white p-4 shadow-card sm:p-5">
            <div className="flex items-center justify-between gap-3">
              <h3 className="text-[14.5px] font-semibold tracking-[-0.015em] text-ink">Why these moods?</h3>
              <span className="text-[12px] text-faint">{suggestion?.source === 'model' ? 'unverified source' : 'from the plot'}</span>
            </div>
            {suggestion?.reasoning && <p className="mt-1.5 text-[13px] leading-[1.45] text-mute">{suggestion.reasoning}</p>}
            <div className="mt-2">
              <EvidenceList items={items} moods={moods} onToggle={(slug) => setSelected((s) => (s.includes(slug) ? s.filter((x) => x !== slug) : s.length < MAX_TAGS ? [...s, slug] : s))} isSelected={(slug) => selected.includes(slug)} />
            </div>
          </section>
        )}

        <div className="mt-auto flex items-center justify-between border-t border-line pt-3 text-[12.5px] text-faint" style={{ marginTop: 'auto' }}>
          <button type="button" onClick={onPrev} disabled={!onPrev} className={cn('inline-flex h-8 items-center gap-1 rounded-full px-2.5 text-[13px] font-medium text-ink hover:bg-canvas disabled:opacity-30 cursor-pointer')}>
            <ChevronLeft size={15} /> Previous
          </button>
          <span className="hidden sm:inline">← → browse · esc close</span>
          <button type="button" onClick={onNext} disabled={!onNext} className={cn('inline-flex h-8 items-center gap-1 rounded-full px-2.5 text-[13px] font-medium text-ink hover:bg-canvas disabled:opacity-30 cursor-pointer')}>
            Next <ChevronRight size={15} />
          </button>
        </div>
      </div>
    </div>
  );
}

function sameSet(a: string[], b: string[]) {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((v, i) => v === sb[i]);
}
