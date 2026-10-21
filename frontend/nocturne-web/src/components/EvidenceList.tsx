import { cn } from '../lib/cn';
import type { MoodBuckets, SuggestionItem } from '../lib/types';

interface EvidenceListProps {
  items: SuggestionItem[];
  moods: MoodBuckets;
  // When set, rows are buttons that toggle the mood in the caller's selection.
  onToggle?: (slug: string) => void;
  isSelected?: (slug: string) => boolean;
}

// The reader's evidence phrase per mood: a tick for applied moods, the reason for held-back ones.
export function EvidenceList({ items, moods, onToggle, isSelected }: EvidenceListProps) {
  const adds = items.filter((i) => i.kind === 'add');
  if (adds.length === 0) return null;
  return (
    <div className="divide-y divide-[#f0f0f0]">
      {adds.map((item) => {
        const title = moods[item.slug]?.title || item.slug;
        const pct = `${Math.round(item.probability * 100)}%`;
        const selected = isSelected ? isSelected(item.slug) : item.applied;
        const body = (
          <>
            <span className={cn('w-3.5 text-center text-[12px]', selected ? 'text-ink' : 'text-faint')} aria-hidden>
              {selected ? '✓' : '·'}
            </span>
            <span className="whitespace-nowrap text-[13px] font-medium text-ink">{title}</span>
            <span className="text-[12px] tabular-nums text-faint">{pct}</span>
            <span className="min-w-0 text-[13px] leading-snug text-mute">
              {item.evidence || 'no evidence phrase'}
              {!item.applied && item.reason && <span className="text-faint"> · held back: {item.reason}</span>}
            </span>
          </>
        );
        const cls = 'grid w-full grid-cols-[14px_auto_auto_1fr] items-baseline gap-x-2.5 py-2 text-left';
        return onToggle ? (
          <button key={item.slug} type="button" onClick={() => onToggle(item.slug)} className={cn(cls, 'cursor-pointer rounded-lg px-1 hover:bg-[#f7f7f7]')} aria-pressed={selected}>
            {body}
          </button>
        ) : (
          <div key={item.slug} className={cls}>
            {body}
          </div>
        );
      })}
    </div>
  );
}
