import { useEffect, useState } from 'react';
import { api, posterUrl } from '../lib/api';
import { Button } from '../ui/Button';
import { Dialog } from '../ui/Dialog';
import { Spinner } from '../ui/Spinner';
import type { MoodBuckets, Movie } from '../lib/types';

interface AutoTagQueueProps {
  open: boolean;
  queue: string[]; // ordered jellyfinIds to process
  movieLookup: (jellyfinId: string) => Movie | undefined;
  moods: MoodBuckets;
  onComplete: () => void;
  onRefresh: () => Promise<void>;
}

const MAX_TAGS = 5;

interface Suggestion {
  suggestionId: string;
  tags: string[];
  confidence: number;
  reasoning?: string;
}

export function AutoTagQueue({
  open,
  queue,
  movieLookup,
  moods,
  onComplete,
  onRefresh,
}: AutoTagQueueProps) {
  const [index, setIndex] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [suggestion, setSuggestion] = useState<Suggestion | null>(null);
  const [selected, setSelected] = useState<string[]>([]);

  const currentId = queue[index];
  const currentMovie = currentId ? movieLookup(currentId) : undefined;
  const [posterFailed, setPosterFailed] = useState(false);

  // Reset state when the modal opens or the target movie changes.
  useEffect(() => {
    if (!open || !currentId) return;
    let cancelled = false;
    setSuggestion(null);
    setSelected([]);
    setError(null);
    setPosterFailed(false);
    setLoading(true);
    api.movies
      .autoTag(currentId)
      .then((resp) => {
        if (cancelled) return;
        setSuggestion({
          suggestionId: resp.id,
          tags: resp.suggestedTags,
          confidence: resp.confidence,
          reasoning: resp.reasoning,
        });
        setSelected(resp.suggestedTags);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : 'Failed to get suggestions');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [open, currentId]);

  const toggle = (slug: string) => {
    setSelected((prev) => {
      if (prev.includes(slug)) return prev.filter((s) => s !== slug);
      if (prev.length >= MAX_TAGS) return prev;
      return [...prev, slug];
    });
  };

  const advance = () => {
    const next = index + 1;
    if (next >= queue.length) {
      onComplete();
      setIndex(0);
      return;
    }
    setIndex(next);
  };

  const applyAndAdvance = async () => {
    if (!currentMovie || !suggestion) return;
    try {
      const isEdited = !arrayEq(selected, suggestion.tags);
      if (isEdited) {
        await api.movies.updateTags(currentMovie.jellyfinId, selected, false);
      } else {
        await api.suggestions.approve(suggestion.suggestionId);
      }
      await onRefresh();
      advance();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to save');
    }
  };

  const regenerate = () => {
    if (!currentId) return;
    setSuggestion(null);
    setSelected([]);
    setError(null);
    setLoading(true);
    api.movies
      .autoTag(currentId)
      .then((resp) => {
        setSuggestion({
          suggestionId: resp.id,
          tags: resp.suggestedTags,
          confidence: resp.confidence,
          reasoning: resp.reasoning,
        });
        setSelected(resp.suggestedTags);
      })
      .catch((e) => setError(e instanceof Error ? e.message : 'Failed to regenerate'))
      .finally(() => setLoading(false));
  };

  if (!currentMovie) {
    return (
      <Dialog open={open} onClose={onComplete} title="Auto-tag queue" size="lg">
        <p className="text-[13px] text-text-dim">Queue empty.</p>
      </Dialog>
    );
  }

  return (
    <Dialog open={open} onClose={onComplete} title={currentMovie.title} size="lg">
      <div className="flex flex-col md:flex-row gap-6">
        <div className="md:w-48 flex-shrink-0">
          <div className="aspect-[2/3] bg-surface border border-border overflow-hidden">
            {posterFailed ? (
              <div className="w-full h-full flex items-center justify-center p-3 text-center">
                <span className="font-serif italic text-base text-text leading-tight">{currentMovie.title}</span>
              </div>
            ) : (
              <img
                src={posterUrl(currentMovie.jellyfinId, 'medium')}
                alt=""
                onError={() => setPosterFailed(true)}
                className="w-full h-full object-cover"
              />
            )}
          </div>
          <p className="text-[11px] uppercase tracking-widest text-muted mt-3">
            {index + 1} / {queue.length}
          </p>
        </div>

        <div className="flex-1 min-w-0">
          {loading && (
            <div className="flex items-center gap-3 text-muted text-[13px]">
              <Spinner size={14} />
              Generating suggestions…
            </div>
          )}

          {error && (
            <div className="border border-border bg-surface px-4 py-3 text-[13px] text-text">
              {error}
            </div>
          )}

          {!loading && suggestion && (
            <>
              <div className="text-[10px] uppercase tracking-widest text-muted mb-2">
                Suggestion · confidence {(suggestion.confidence * 100).toFixed(0)}%
              </div>
              {suggestion.reasoning && (
                <p className="text-[13px] text-text-dim italic mb-4 leading-snug">
                  {suggestion.reasoning}
                </p>
              )}

              <div className="text-[10px] uppercase tracking-widest text-muted mb-2">
                Edit selection ({selected.length} / {MAX_TAGS})
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-[1px] border border-border max-h-[40vh] overflow-y-auto">
                {Object.entries(moods).map(([slug, mood]) => {
                  const isSelected = selected.includes(slug);
                  const disabled = !isSelected && selected.length >= MAX_TAGS;
                  return (
                    <label
                      key={slug}
                      className={`flex items-center gap-3 px-3 py-2 bg-bg cursor-pointer transition-colors ${
                        isSelected ? 'bg-surface' : 'hover:bg-surface'
                      } ${disabled ? 'opacity-40 cursor-not-allowed' : ''}`}
                    >
                      <input
                        type="checkbox"
                        checked={isSelected}
                        disabled={disabled}
                        onChange={() => toggle(slug)}
                        className="accent-text cursor-pointer"
                      />
                      <span className="text-[13px] text-text truncate">{mood.title}</span>
                    </label>
                  );
                })}
              </div>
            </>
          )}

          <div className="mt-6 flex flex-wrap items-center justify-end gap-2">
            <Button variant="ghost" onClick={regenerate} size="sm" disabled={loading}>
              Regenerate
            </Button>
            <Button
              variant="ghost"
              onClick={() => suggestion && setSelected(suggestion.tags)}
              size="sm"
              disabled={!suggestion}
            >
              Reset
            </Button>
            <Button variant="line" onClick={advance} size="sm">
              Skip
            </Button>
            <Button
              variant="primary"
              size="sm"
              onClick={applyAndAdvance}
              disabled={!suggestion || selected.length === 0 || loading}
            >
              Apply & next
            </Button>
          </div>
        </div>
      </div>
    </Dialog>
  );
}

function arrayEq(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((v, i) => v === sb[i]);
}
