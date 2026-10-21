import { useEffect, useRef, useState } from 'react';
import { ArrowDownUp, Check, ChevronDown } from 'lucide-react';
import { cn } from '../lib/cn';
import { Chip } from '../ui/Chip';

export type LibraryFilter = 'watched' | 'unwatched' | 'untagged' | 'review';
export type LibrarySort = 'az' | 'year-desc' | 'year-asc';

export const SORT_LABEL: Record<LibrarySort, string> = { az: 'A to Z', 'year-desc': 'Newest year', 'year-asc': 'Oldest year' };

function usePopover() {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (e: PointerEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        setOpen(false);
      }
    };
    document.addEventListener('pointerdown', down);
    window.addEventListener('keydown', key, true);
    return () => {
      document.removeEventListener('pointerdown', down);
      window.removeEventListener('keydown', key, true);
    };
  }, [open]);
  return { open, setOpen, ref };
}

interface RefineRowProps {
  counts: { watched: number; unwatched: number; untagged: number; review: number };
  filters: LibraryFilter[];
  onToggle: (f: LibraryFilter) => void;
  onClear: () => void;
  sort: LibrarySort;
  onSort: (s: LibrarySort) => void;
  // Films waiting in the review tray, and the tray itself.
  toReview: number;
  onReview: () => void;
}

// X-Cache's refine row: the tray pill, the unsure pill, the chips rail, Clear and the sort menu.
export function RefineRow({ counts, filters, onToggle, onClear, sort, onSort, toReview, onReview }: RefineRowProps) {
  const needsReview = filters.includes('review');
  return (
    <div className="flex items-center gap-3">
      {toReview > 0 && (
        <button
          type="button"
          onClick={onReview}
          title="Films AI was not sure about"
          className="inline-flex h-9 shrink-0 items-center gap-2 rounded-full bg-white pl-3 pr-3.5 text-[13.5px] font-medium text-ink ring-1 ring-inset ring-[#dcdcdc] transition hover:bg-[#f7f7f7] cursor-pointer"
        >
          <span className="h-1.5 w-1.5 rounded-full bg-[#16B364]" />
          Review
          <span className="tabular-nums text-faint">· {toReview}</span>
        </button>
      )}
      {counts.review > 0 && (
        <button
          type="button"
          onClick={() => onToggle('review')}
          aria-pressed={needsReview}
          title="Best guesses, not confirmed"
          className={cn(
            'inline-flex h-9 shrink-0 items-center gap-2 rounded-full pl-3 pr-3.5 text-[13.5px] font-medium transition cursor-pointer',
            needsReview ? 'bg-ink text-white' : 'bg-white text-ink ring-1 ring-inset ring-[#dcdcdc] hover:bg-[#f7f7f7]',
          )}
        >
          <span className="h-1.5 w-1.5 rounded-full bg-[#f5a524]" />
          Unsure
          <span className={cn('tabular-nums', needsReview ? 'text-white/60' : 'text-faint')}>· {counts.review}</span>
        </button>
      )}
      <div className="no-scrollbar rail-mask-end -my-1 flex min-w-0 flex-1 items-center gap-2 overflow-x-auto py-1 pr-10">
        <Chip active={filters.includes('watched')} count={counts.watched} onClick={() => onToggle('watched')}>
          Watched
        </Chip>
        <Chip active={filters.includes('unwatched')} count={counts.unwatched} onClick={() => onToggle('unwatched')}>
          Unwatched
        </Chip>
        <span className="mx-1 h-5 w-px shrink-0 bg-[#e6e6e6]" />
        <Chip active={filters.includes('untagged')} count={counts.untagged} onClick={() => onToggle('untagged')}>
          Untagged
        </Chip>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {filters.length > 0 && (
          <button type="button" onClick={onClear} className="hidden h-9 items-center rounded-full px-3 text-[13.5px] font-medium text-mute transition hover:bg-[#f3f3f3] hover:text-ink sm:inline-flex cursor-pointer">
            Clear
          </button>
        )}
        <SortMenu sort={sort} onSort={onSort} />
      </div>
    </div>
  );
}

function SortMenu({ sort, onSort }: { sort: LibrarySort; onSort: (s: LibrarySort) => void }) {
  const { open, setOpen, ref } = usePopover();
  return (
    <div ref={ref} className="relative hidden sm:block">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="inline-flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[13.5px] font-medium text-ink ring-1 ring-inset ring-[#e6e6e6] transition hover:bg-[#f7f7f7] cursor-pointer"
      >
        <ArrowDownUp size={14} strokeWidth={2.2} className="text-mute" /> {SORT_LABEL[sort]} <ChevronDown size={14} className="text-mute" />
      </button>
      {open && (
        <div className="pop-menu absolute right-0 top-11 z-50 w-48 rounded-2xl bg-white p-1.5 shadow-[0_0_0_1px_rgba(0,0,0,.06),0_24px_60px_-16px_rgba(0,0,0,.25)]">
          {(Object.keys(SORT_LABEL) as LibrarySort[]).map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => {
                onSort(s);
                setOpen(false);
              }}
              className="flex w-full items-center justify-between rounded-xl px-3 py-2 text-left text-[13.5px] font-medium text-ink hover:bg-[#f5f5f5] cursor-pointer"
            >
              {SORT_LABEL[s]} {s === sort && <Check size={14} strokeWidth={2.6} />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
