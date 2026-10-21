import { useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { MoodPicker } from './MoodPicker';
import type { MoodBuckets, Movie, SuggestionItem, TagSuggestionApi } from '../lib/types';

const MAX_TAGS = 5;

interface ReviewRowProps {
  suggestion: TagSuggestionApi;
  movie?: Movie;
  moods: MoodBuckets;
  selected: string[];
  onChange: (next: string[]) => void;
  onApprove: () => void;
  onReject: () => void;
  onOpen: () => void;
  focused?: boolean;
  leaving?: boolean;
}

// The reader's moods as pills in probability order: solid when selected, grey when held back.
export function ReviewRow({ suggestion: s, movie, moods, selected, onChange, onApprove, onReject, onOpen, focused, leaving }: ReviewRowProps) {
  const [pick, setPick] = useState(false);
  const [showAll, setShowAll] = useState(false);
  const items: SuggestionItem[] = (s.items ?? []).filter((i) => i.kind === 'add');
  // Moods the reader did not name but the admin added through the picker still show as pills.
  const extra = selected.filter((slug) => !items.some((i) => i.slug === slug));
  const title = (slug: string) => moods[slug]?.title || slug;
  const toggle = (slug: string) => {
    if (selected.includes(slug)) onChange(selected.filter((x) => x !== slug));
    else if (selected.length < MAX_TAGS) onChange([...selected, slug]);
  };
  const why = items.find((i) => i.evidence)?.evidence;
  const unverified = s.source === 'model';
  const noSource = s.source === 'none';
  const residue = s.reasoning && !s.reasoning.startsWith('auto-tagger failed') && !s.reasoning.startsWith('budget cap') ? s.reasoning : null;
  const failure = s.reasoning && (s.reasoning.startsWith('auto-tagger failed') || s.reasoning.startsWith('budget cap')) ? s.reasoning : null;

  return (
    <li className={cn('py-5 transition-colors', focused && 'rounded-2xl bg-[#fafafa] -mx-4 px-4', leaving && 'row-out')} data-row={s.id}>
      <div className="flex items-start gap-4">
        <button type="button" onClick={onOpen} className="shrink-0 cursor-pointer" aria-label={`Open ${movie?.title ?? 'film'}`}>
          <img src={posterUrl(s.jellyfinId, 'thumb')} alt="" className="h-24 w-16 rounded-[14px] bg-canvas object-cover transition hover:opacity-90" loading="lazy" />
        </button>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[14px]">
            <button type="button" onClick={onOpen} className="truncate font-semibold tracking-[-0.01em] text-ink cursor-pointer">
              {movie?.title || s.jellyfinId}
            </button>
            {movie?.year && <span className="tabular-nums text-faint">{movie.year}</span>}
            {movie?.played && <Badge>Watched</Badge>}
            {unverified && <Badge tone="warn">unverified source</Badge>}
            {noSource && <Badge tone="muted">no story source</Badge>}
          </div>
          {residue && <p className="mt-1 line-clamp-2 text-[13.5px] leading-[1.4] text-[#4a4a4a]">{residue}</p>}
          {failure && <p className="mt-1 text-[13px] text-bad">{failure}</p>}
          {why && !showAll && (
            <p className="mt-1.5 text-[12.5px] text-mute">
              Why: {why}
              {items.length > 1 && (
                <button type="button" onClick={() => setShowAll(true)} className="ml-1.5 text-faint hover:text-ink cursor-pointer">
                  more
                </button>
              )}
            </p>
          )}
          {showAll && (
            <div className="mt-2 divide-y divide-[#f0f0f0] rounded-xl bg-white text-[12.5px] ring-1 ring-line">
              {items.map((i) => (
                <div key={i.slug} className="flex items-baseline gap-2.5 px-3 py-1.5">
                  <span className="font-medium text-ink">{title(i.slug)}</span>
                  <span className="tabular-nums text-faint">{Math.round(i.probability * 100)}%</span>
                  <span className="min-w-0 text-mute">{i.evidence || 'no evidence phrase'}{!i.applied && i.reason ? ` · held back: ${i.reason}` : ''}</span>
                </div>
              ))}
              <button type="button" onClick={() => setShowAll(false)} className="w-full px-3 py-1.5 text-left text-faint hover:text-ink cursor-pointer">
                less
              </button>
            </div>
          )}
        </div>
        <div className="flex shrink-0 gap-1.5">
          <Button variant="primary" size="sm" onClick={onApprove} disabled={selected.length === 0} reason={selected.length === 0 ? 'Pick at least one mood, or reject' : null} reasonInline={false}>
            Approve
          </Button>
          <Button variant="outline" size="sm" onClick={onReject}>
            Reject
          </Button>
        </div>
      </div>
      <div className="mt-3.5 flex flex-wrap items-center gap-1.5 pl-20">
        {items.map((i) => {
          const on = selected.includes(i.slug);
          return (
            <button
              key={i.slug}
              type="button"
              onClick={() => toggle(i.slug)}
              title={i.evidence || undefined}
              aria-pressed={on}
              className={cn(
                'inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-[13px] font-medium transition cursor-pointer disabled:opacity-40',
                on ? 'bg-ink text-white hover:bg-black' : 'bg-canvas text-ink hover:bg-canvas-2',
              )}
              disabled={!on && selected.length >= MAX_TAGS}
            >
              {title(i.slug)}
              <span className={cn('tabular-nums', on ? 'text-white/55' : 'text-faint')}>{Math.round(i.probability * 100)}%</span>
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
            Other
            <ChevronDown size={13} />
          </button>
          {pick && (
            <MoodPicker
              moods={moods}
              exclude={selected}
              onPick={(slug) => {
                setPick(false);
                toggle(slug);
              }}
              onClose={() => setPick(false)}
            />
          )}
        </div>
        <span className="ml-auto text-[12px] tabular-nums text-faint">{selected.length} of {MAX_TAGS}</span>
      </div>
    </li>
  );
}
