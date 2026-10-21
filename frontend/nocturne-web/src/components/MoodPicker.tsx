import { useEffect, useState } from 'react';
import { Check, Search } from 'lucide-react';
import { cn } from '../lib/cn';
import type { MoodBuckets } from '../lib/types';

interface MoodPickerProps {
  moods: MoodBuckets;
  exclude?: string[];
  current?: string;
  // One poster per mood for the thumbnail, when the caller has them.
  covers?: Record<string, string | undefined>;
  onPick: (slug: string) => void;
  onClose: () => void;
  align?: 'left' | 'right';
}

// X-Cache's folder picker: a search field in a grey pill, then the list with small covers.
export function MoodPicker({ moods, exclude = [], current, covers = {}, onPick, onClose, align = 'left' }: MoodPickerProps) {
  const [q, setQ] = useState('');
  useEffect(() => {
    const down = (e: PointerEvent) => {
      if (!(e.target as HTMLElement).closest('[data-picker]')) onClose();
    };
    const t = window.setTimeout(() => document.addEventListener('pointerdown', down), 0);
    return () => {
      window.clearTimeout(t);
      document.removeEventListener('pointerdown', down);
    };
  }, [onClose]);
  const s = q.trim().toLowerCase();
  const list = Object.entries(moods)
    .filter(([slug, m]) => !exclude.includes(slug) && (!s || m.title.toLowerCase().includes(s) || slug.includes(s)))
    .sort((a, b) => a[1].title.localeCompare(b[1].title));
  return (
    <div data-picker className={cn('pop-menu absolute top-10 z-50 w-64 overflow-hidden rounded-2xl bg-white shadow-[0_0_0_1px_rgba(0,0,0,.06),0_24px_60px_-16px_rgba(0,0,0,.25)]', align === 'right' ? 'right-0' : 'left-0')}>
      <div className="p-2">
        <label className="flex h-9 items-center gap-2 rounded-full bg-[#f3f3f3] px-3 text-[13px]">
          <Search size={14} className="text-faint" />
          <input
            autoFocus
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Escape') onClose();
              if (e.key === 'Enter' && list[0]) onPick(list[0][0]);
            }}
            placeholder="Find a mood"
            className="no-ring w-full bg-transparent outline-none placeholder:text-faint"
          />
        </label>
      </div>
      <ul className="max-h-72 overflow-y-auto px-1.5 pb-1.5">
        {list.length === 0 && <li className="px-2 py-3 text-[12.5px] text-faint">No mood matches.</li>}
        {list.map(([slug, m]) => (
          <li key={slug}>
            <button type="button" onClick={() => onPick(slug)} className="flex w-full items-center gap-2.5 rounded-xl px-2 py-1.5 text-left text-[13.5px] font-medium text-ink hover:bg-[#f5f5f5] cursor-pointer">
              {covers[slug] ? <img src={covers[slug]} alt="" className="h-6 w-6 rounded-md object-cover" /> : <span className="h-6 w-6 rounded-md bg-[#f0f0f0]" />}
              <span className="flex-1 truncate">{m.title}</span>
              {slug === current && <Check size={14} />}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
