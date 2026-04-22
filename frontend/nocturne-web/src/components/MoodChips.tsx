import { Chip } from '../ui/Chip';
import type { MoodBuckets } from '../lib/types';

interface MoodChipsProps {
  moods: MoodBuckets;
  counts: Record<string, number>;
  selected: string; // '' = All
  onSelect: (slug: string) => void;
}

export function MoodChips({ moods, counts, selected, onSelect }: MoodChipsProps) {
  return (
    <div className="fade-mask-x">
      <div className="flex gap-2 overflow-x-auto no-scrollbar py-1 px-1">
        <Chip active={selected === ''} onClick={() => onSelect('')}>
          All
        </Chip>
        {Object.entries(moods).map(([slug, info]) => (
          <Chip key={slug} active={selected === slug} onClick={() => onSelect(slug)}>
            <span>{info.title}</span>
            <span className="ml-1.5 opacity-50 tabular-nums">{counts[slug] || 0}</span>
          </Chip>
        ))}
      </div>
    </div>
  );
}
