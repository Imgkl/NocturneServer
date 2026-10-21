import type { ReactNode } from 'react';
import { cn } from '../lib/cn';

interface StatProps {
  label: ReactNode;
  value: ReactNode;
  sub?: ReactNode;
  tone?: 'good' | 'bad';
  className?: string;
}

// A big number with a small label: the one KPI unit.
export function Stat({ label, value, sub, tone, className = '' }: StatProps) {
  return (
    <div className={cn('min-w-0', className)}>
      <div className="text-[12.5px] font-medium text-mute">{label}</div>
      <div className={cn('mt-1 truncate text-[26px] font-semibold leading-none tracking-[-0.035em] tabular-nums sm:text-[30px]', tone === 'good' ? 'text-good' : tone === 'bad' ? 'text-bad' : 'text-ink')}>{value}</div>
      {sub && <div className="mt-1.5 text-[12.5px] leading-snug text-faint">{sub}</div>}
    </div>
  );
}

// A thin progress pill.
export function Bar({ value, tone = 'ink', className = '' }: { value: number; tone?: 'ink' | 'faint'; className?: string }) {
  const pct = Math.max(0, Math.min(1, value)) * 100;
  return (
    <span className={cn('relative block h-1.5 w-full overflow-hidden rounded-full bg-[#efefef]', className)}>
      <span className={cn('absolute inset-y-0 left-0 rounded-full transition-[width]', tone === 'ink' ? 'bg-ink' : 'bg-[#bdbdbd]')} style={{ width: `${pct}%` }} />
    </span>
  );
}
