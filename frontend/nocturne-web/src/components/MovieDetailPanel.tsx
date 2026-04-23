import { useMemo, useState } from 'react';
import { Button } from '../ui/Button';
import { Dialog } from '../ui/Dialog';
import { Input } from '../ui/Input';
import type { MoodBuckets, Movie } from '../lib/types';

interface MovieDetailPanelProps {
  movie: Movie | null;
  moods: MoodBuckets;
  onSave: (movie: Movie, selectedTags: string[]) => void;
  onCancel: () => void;
}

const MAX_TAGS = 5;

export function MovieDetailPanel({ movie, moods, onSave, onCancel }: MovieDetailPanelProps) {
  return (
    <Dialog open={!!movie} onClose={onCancel} title={movie?.title} size="lg">
      {movie && <EditForm key={movie.jellyfinId} movie={movie} moods={moods} onSave={onSave} onCancel={onCancel} />}
    </Dialog>
  );
}

function EditForm({
  movie,
  moods,
  onSave,
  onCancel,
}: {
  movie: Movie;
  moods: MoodBuckets;
  onSave: (movie: Movie, selectedTags: string[]) => void;
  onCancel: () => void;
}) {
  const originalTags = useMemo(() => new Set((movie.tags || []).map((t) => t.slug)), [movie]);
  const [selected, setSelected] = useState<Set<string>>(() => new Set(originalTags));
  const [filter, setFilter] = useState('');
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());

  const toggle = (slug: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(slug)) {
        next.delete(slug);
      } else if (next.size < MAX_TAGS) {
        next.add(slug);
      }
      return next;
    });
  };

  const toggleExpanded = (slug: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(slug)) next.delete(slug); else next.add(slug);
      return next;
    });
  };

  const filtered = useMemo(() => {
    const q = filter.toLowerCase().trim();
    return Object.entries(moods).filter(([slug, mood]) => {
      if (!q) return true;
      return (
        slug.toLowerCase().includes(q) ||
        mood.title.toLowerCase().includes(q) ||
        (mood.description || '').toLowerCase().includes(q)
      );
    });
  }, [moods, filter]);

  return (
    <div>
      {movie.year && (
        <p className="text-[11px] uppercase tracking-widest text-muted mb-4">
          {movie.year} · up to {MAX_TAGS} mood tags
        </p>
      )}

      <Input
        placeholder="Filter moods…"
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
      />

      <div className="mt-5 flex flex-col border border-border max-h-[50vh] overflow-y-auto">
        {filtered.length === 0 && (
          <div className="px-4 py-8 text-center text-muted text-[13px]">No moods match.</div>
        )}
        {filtered.map(([slug, mood]) => {
          const isSelected = selected.has(slug);
          const wasOriginal = originalTags.has(slug);
          const atCap = selected.size >= MAX_TAGS;
          const disabled = !isSelected && atCap;
          const willAdd = isSelected && !wasOriginal;
          const willRemove = !isSelected && wasOriginal;
          return (
            <label
              key={slug}
              className={`flex items-start gap-3 px-4 py-3 border-b border-border last:border-b-0 cursor-pointer transition-colors ${
                isSelected ? 'bg-surface' : 'bg-bg hover:bg-surface'
              } ${disabled ? 'opacity-40 cursor-not-allowed' : ''}`}
            >
              <input
                type="checkbox"
                checked={isSelected}
                disabled={disabled}
                onChange={() => toggle(slug)}
                className="mt-[3px] accent-text cursor-pointer"
              />
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-[14px] text-text">{mood.title}</span>
                  {willAdd && (
                    <span className="text-[9px] uppercase tracking-widest text-text-dim">
                      + Add
                    </span>
                  )}
                  {willRemove && (
                    <span className="text-[9px] uppercase tracking-widest text-muted">
                      − Remove
                    </span>
                  )}
                </div>
                {mood.description && (() => {
                  // ~140-char heuristic maps roughly to the 2-line clamp at this container
                  // width; shorter descriptions render whole without a toggle.
                  const needsToggle = mood.description.length > 140;
                  const isExpanded = expanded.has(slug);
                  return (
                    <div className="mt-1">
                      <p
                        className={`text-[12px] text-text-dim leading-snug ${
                          needsToggle && !isExpanded ? 'line-clamp-2' : ''
                        }`}
                      >
                        {mood.description}
                      </p>
                      {needsToggle && (
                        <button
                          type="button"
                          onClick={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                            toggleExpanded(slug);
                          }}
                          className="mt-1 text-[10px] uppercase tracking-widest text-muted hover:text-text cursor-pointer"
                        >
                          {isExpanded ? 'Show less' : 'Read more'}
                        </button>
                      )}
                    </div>
                  );
                })()}
              </div>
            </label>
          );
        })}
      </div>

      <div className="mt-5 flex items-center justify-between">
        <span className="text-[10px] uppercase tracking-widest text-muted">
          {selected.size} / {MAX_TAGS} selected
        </span>
        <div className="flex gap-2">
          <Button variant="ghost" onClick={() => setSelected(new Set())} size="sm">
            Clear all
          </Button>
          <Button variant="line" onClick={onCancel} size="sm">
            Cancel
          </Button>
          <Button variant="primary" onClick={() => onSave(movie, Array.from(selected))} size="sm">
            Save
          </Button>
        </div>
      </div>
    </div>
  );
}
