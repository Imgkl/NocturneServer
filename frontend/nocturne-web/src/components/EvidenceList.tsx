import type { MoodBuckets, SuggestionItem } from '../lib/types';

interface EvidenceListProps {
  items: SuggestionItem[];
  moods: MoodBuckets;
  // When set, rows are buttons that toggle the mood in the caller's selection.
  onToggle?: (slug: string) => void;
  isSelected?: (slug: string) => boolean;
}

// The reader's evidence phrase per mood, under a suggestion. Applied moods carry a tick; moods the
// policy held back show the reason instead.
export function EvidenceList({ items, moods, onToggle, isSelected }: EvidenceListProps) {
  const adds = items.filter((i) => i.kind === 'add');
  if (adds.length === 0) return null;
  return (
    <div className="border border-border bg-bg">
      {adds.map((item) => {
        const title = moods[item.slug]?.title || item.slug;
        const pct = `${Math.round(item.probability * 100)}%`;
        const selected = isSelected ? isSelected(item.slug) : item.applied;
        const body = (
          <>
            <span className={`w-3 text-center ${selected ? 'text-text' : 'text-muted'}`} aria-hidden>
              {selected ? '✓' : '·'}
            </span>
            <span className="text-[12px] text-text whitespace-nowrap">{title}</span>
            <span className="text-[11px] text-muted tabular-nums">{pct}</span>
            <span className="min-w-0 font-serif italic text-[13.5px] text-text-dim leading-snug">
              {item.evidence || 'no evidence phrase'}
              {!item.applied && item.reason && (
                <span className="not-italic font-sans text-[10.5px] text-muted"> · held back: {item.reason}</span>
              )}
            </span>
          </>
        );
        const cls =
          'grid grid-cols-[12px_auto_auto_1fr] items-baseline gap-x-2.5 px-3 py-2 border-t border-border first:border-t-0 text-left w-full';
        return onToggle ? (
          <button
            key={item.slug}
            type="button"
            onClick={() => onToggle(item.slug)}
            className={`${cls} cursor-pointer hover:bg-surface`}
            aria-pressed={selected}
          >
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
