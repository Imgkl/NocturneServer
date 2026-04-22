import { Spinner } from '../ui/Spinner';
import type { BackfillStatusApi } from '../lib/types';

interface BackfillProgressProps {
  status: BackfillStatusApi | null;
}

export function BackfillProgress({ status }: BackfillProgressProps) {
  if (!status?.running) return null;
  const pct = status.total > 0 ? Math.min(100, (status.processed / status.total) * 100) : 0;
  return (
    <section className="px-5 lg:px-10 pt-5">
      <div className="flex items-center gap-4 border border-border bg-surface px-5 py-4">
        <Spinner size={14} className="text-text flex-shrink-0" />
        <div className="flex-1 min-w-0">
          <div className="text-[13px] text-text">
            Auto-tagging {status.processed} / {status.total} untagged films…
          </div>
          <div className="text-[10px] uppercase tracking-widest text-muted mt-1">
            {status.cancelled ? 'Cancelling…' : 'Claude is working in the background.'}
          </div>
        </div>
        <div className="hidden md:block w-40 h-[2px] bg-border overflow-hidden">
          <div className="h-full bg-text transition-all" style={{ width: `${pct}%` }} />
        </div>
      </div>
    </section>
  );
}
