import { cn } from '../lib/cn';

// The wordmark: a square ink mark with an N, then "Nocturne" in Geist.
export function Wordmark({ className = '', compact = false }: { className?: string; compact?: boolean }) {
  return (
    <span className={cn('inline-flex items-center gap-2.5 text-[19px] font-bold tracking-[-0.03em] text-ink', className)}>
      <span className="grid h-6 w-6 place-items-center rounded-[7px] bg-ink text-[14px] font-bold leading-none text-white" aria-hidden>
        N
      </span>
      {!compact && <span>Nocturne</span>}
    </span>
  );
}
