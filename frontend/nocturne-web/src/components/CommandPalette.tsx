import { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Film, Search, Tag } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import type { MoodBuckets, Movie } from '../lib/types';

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  movies: Movie[];
  moods: MoodBuckets;
  onPickMovie: (movie: Movie) => void;
  onPickMood: (slug: string) => void;
}

type Hit = { kind: 'movie'; movie: Movie } | { kind: 'mood'; slug: string; title: string };

// ⌘K: type a few letters, pick a film or a mood.
export function CommandPalette({ open, onClose, movies, moods, onPickMovie, onPickMood }: CommandPaletteProps) {
  const [q, setQ] = useState('');
  const [cursor, setCursor] = useState(0);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    setQ('');
    setCursor(0);
    const t = window.setTimeout(() => input.current?.focus(), 10);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      window.clearTimeout(t);
      document.body.style.overflow = prev;
    };
  }, [open]);

  const hits = useMemo<Hit[]>(() => {
    const s = q.trim().toLowerCase();
    const moodHits: Hit[] = Object.entries(moods)
      .filter(([slug, m]) => !s || m.title.toLowerCase().includes(s) || slug.includes(s))
      .slice(0, s ? 4 : 0)
      .map(([slug, m]) => ({ kind: 'mood', slug, title: m.title }));
    const movieHits: Hit[] = (s ? movies.filter((m) => m.title.toLowerCase().includes(s)) : movies.slice(0, 8)).slice(0, 9).map((movie) => ({ kind: 'movie', movie }));
    return [...moodHits, ...movieHits];
  }, [q, movies, moods]);

  useEffect(() => setCursor(0), [q]);

  if (!open) return null;

  const pick = (h: Hit) => {
    onClose();
    if (h.kind === 'movie') onPickMovie(h.movie);
    else onPickMood(h.slug);
  };

  return createPortal(
    <div className="fixed inset-0 z-[75] flex items-start justify-center px-4 pt-[12vh]" role="dialog" aria-modal="true" aria-label="Search">
      <div className="fade-in absolute inset-0 bg-black/40 backdrop-blur-[2px]" onClick={onClose} />
      <div className="modal-in relative w-full max-w-[560px] overflow-hidden rounded-[24px] bg-white shadow-modal">
        <div className="flex items-center gap-3 border-b border-line px-5">
          <Search size={18} strokeWidth={2.2} className="text-mute" />
          <input
            ref={input}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Escape') onClose();
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setCursor((c) => Math.min(hits.length - 1, c + 1));
              }
              if (e.key === 'ArrowUp') {
                e.preventDefault();
                setCursor((c) => Math.max(0, c - 1));
              }
              if (e.key === 'Enter' && hits[cursor]) pick(hits[cursor]);
            }}
            placeholder="Search films, moods"
            className="h-14 w-full bg-transparent text-[15px] text-ink outline-none placeholder:text-faint"
          />
          <kbd className="hidden rounded-md bg-canvas px-1.5 py-0.5 text-[11px] font-medium text-mute sm:inline">esc</kbd>
        </div>
        <ul className="max-h-[52vh] overflow-y-auto p-2">
          {hits.length === 0 && <li className="px-4 py-8 text-center text-[13.5px] text-mute">Nothing matches.</li>}
          {hits.map((h, i) => (
            <li key={h.kind === 'movie' ? h.movie.jellyfinId : `mood-${h.slug}`}>
              <button
                type="button"
                onMouseEnter={() => setCursor(i)}
                onClick={() => pick(h)}
                className={cn('flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left cursor-pointer', i === cursor ? 'bg-canvas' : 'hover:bg-[#f7f7f7]')}
              >
                {h.kind === 'movie' ? (
                  <>
                    <img src={posterUrl(h.movie.jellyfinId, 'thumb')} alt="" className="h-10 w-7 shrink-0 rounded-md bg-canvas object-cover" />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[13.5px] font-medium text-ink">{h.movie.title}</span>
                      <span className="block truncate text-[12px] text-faint">
                        {h.movie.year ?? ''}
                        {h.movie.tags?.length ? ` · ${h.movie.tags.map((t) => moods[t.slug]?.title || t.title).join(', ')}` : ' · untagged'}
                      </span>
                    </span>
                    <Film size={14} className="shrink-0 text-faint" />
                  </>
                ) : (
                  <>
                    <span className="grid h-10 w-7 shrink-0 place-items-center rounded-md bg-canvas text-mute">
                      <Tag size={14} />
                    </span>
                    <span className="min-w-0 flex-1 truncate text-[13.5px] font-medium text-ink">{h.title}</span>
                    <span className="text-[12px] text-faint">mood</span>
                  </>
                )}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>,
    document.body,
  );
}
