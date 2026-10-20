import { Spinner } from '../ui/Spinner';
import type { BackfillStatusApi, CoverageStatus } from '../lib/types';

interface RunBannerProps {
  title: string;
  subtitle: string;
  processed: number;
  total: number;
}

// The strip under the library header for any background run.
export function RunBanner({ title, subtitle, processed, total }: RunBannerProps) {
  const pct = total > 0 ? Math.min(100, (processed / total) * 100) : 0;
  return (
    <section className="px-5 lg:px-10 pt-5">
      <div className="flex items-center gap-4 border border-border bg-surface px-5 py-4">
        <Spinner size={14} className="text-text flex-shrink-0" />
        <div className="flex-1 min-w-0">
          <div className="text-[13px] text-text">{title}</div>
          <div className="text-[10px] uppercase tracking-widest text-muted mt-1">{subtitle}</div>
        </div>
        <div className="hidden md:block w-40 h-[2px] bg-border overflow-hidden">
          <div className="h-full bg-text transition-all" style={{ width: `${pct}%` }} />
        </div>
      </div>
    </section>
  );
}

export function BackfillProgress({ status }: { status: BackfillStatusApi | null }) {
  if (!status?.running) return null;
  return (
    <RunBanner
      title={`Auto-tagging ${status.processed} / ${status.total} untagged films…`}
      subtitle={status.cancelled ? 'Cancelling…' : 'Claude is working in the background.'}
      processed={status.processed}
      total={status.total}
    />
  );
}

export function CoverageProgress({ status }: { status: CoverageStatus | null }) {
  if (!status?.running) return null;
  return (
    <RunBanner
      title={`Fetching story sources ${status.processed} / ${status.total} films…`}
      subtitle={status.cancelRequested ? 'Cancelling…' : 'Wikidata and Wikipedia, two requests a second.'}
      processed={status.processed}
      total={status.total}
    />
  );
}
