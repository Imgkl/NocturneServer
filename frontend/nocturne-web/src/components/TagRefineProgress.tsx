import { Spinner } from '../ui/Spinner';
import type { MoodBuckets, TagRefinementStatusApi } from '../lib/types';

interface TagRefineProgressProps {
  status: TagRefinementStatusApi | null;
  moods: MoodBuckets;
  onCancel?: () => void;
}

export function TagRefineProgress({ status, moods, onCancel }: TagRefineProgressProps) {
  if (!status) return null;

  // Show a short completion summary the first poll after the worker finishes so the user sees
  // what changed. `running=false` with total>0 means a run just wrapped; the parent clears
  // the state a few seconds later.
  const finished = !status.running && status.total > 0;
  if (!status.running && !finished) return null;

  const pct = status.total > 0 ? Math.min(100, (status.processed / status.total) * 100) : 0;
  const tagTitle = status.tagSlug ? (moods[status.tagSlug]?.title ?? status.tagSlug) : 'tag';

  return (
    <section className="px-5 lg:px-10 pt-5">
      <div className="flex items-center gap-4 border border-border bg-surface px-5 py-4">
        {status.running && <Spinner size={14} className="text-text flex-shrink-0" />}
        <div className="flex-1 min-w-0">
          <div className="text-[13px] text-text">
            {status.running
              ? `Refining "${tagTitle}" ${status.processed} / ${status.total}…`
              : `Refined "${tagTitle}": ${status.removed} removed · ${status.addSuggestions + status.removeSuggestions} for review`}
          </div>
          <div className="text-[10px] uppercase tracking-widest text-muted mt-1">
            {status.running && status.cancelled
              ? 'Cancelling…'
              : status.running
                ? `Claude is verifying each film — ${status.removed} removed, ${status.removeSuggestions} removal suggestions, ${status.addSuggestions} additions`
                : 'Complete'}
          </div>
        </div>
        {status.running && (
          <>
            <div className="hidden md:block w-40 h-[2px] bg-border overflow-hidden">
              <div className="h-full bg-text transition-all" style={{ width: `${pct}%` }} />
            </div>
            {onCancel && (
              <button
                onClick={onCancel}
                disabled={!!status.cancelled}
                className="text-[10px] uppercase tracking-widest text-muted hover:text-text cursor-pointer disabled:opacity-40"
              >
                Cancel
              </button>
            )}
          </>
        )}
      </div>
    </section>
  );
}
