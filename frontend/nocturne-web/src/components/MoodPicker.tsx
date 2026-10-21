import { useEffect, useRef, useState } from 'react';
import { cn } from '../lib/cn';
import type { MoodBuckets } from '../lib/types';

interface MoodPickerProps {
  moods: MoodBuckets;
  exclude?: string[];
  onPick: (slug: string) => void;
  onClose: () => void;
  align?: 'left' | 'right';
}

// A searchable popover of moods, like X-Cache's folder picker.
export function MoodPicker({ moods, exclude = [], onPick, onClose, align = 'left' }: MoodPickerProps) {
  const [q, setQ] = useState('');
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const down = (e: PointerEvent) => {
      if (!(e.target as HTMLElement).closest('[data-picker]')) onClose();
    };
    const t = window.setTimeout(() => document.addEventListener('pointerdown', down), 0);
    input.current?.focus();
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
    <div data-picker className={cn('pop-menu absolute top-10 z-50 w-64 overflow-hidden rounded-2xl bg-white shadow-pop', align === 'right' ? 'right-0' : 'left-0')}>
      <div className="border-b border-line p-2">
        <input
          ref={input}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') onClose();
            if (e.key === 'Enter' && list[0]) onPick(list[0][0]);
          }}
          placeholder="Find a mood"
          className="h-8 w-full rounded-lg bg-canvas px-2.5 text-[13px] text-ink outline-none placeholder:text-faint"
        />
      </div>
      <ul className="max-h-64 overflow-y-auto p-1.5">
        {list.length === 0 && <li className="px-3 py-3 text-[12.5px] text-faint">No mood matches.</li>}
        {list.map(([slug, m]) => (
          <li key={slug}>
            <button type="button" onClick={() => onPick(slug)} className="block w-full truncate rounded-lg px-3 py-1.5 text-left text-[13px] text-ink hover:bg-[#f5f5f5] cursor-pointer">
              {m.title}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
