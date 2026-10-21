import type { ButtonHTMLAttributes, ReactNode } from 'react';
import { cn } from '../lib/cn';

interface ChipProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  active?: boolean;
  // A count in faint tabular numerals after the label.
  count?: number | string;
  // A 20px round thumbnail before the label (the collapsed mood band uses it).
  thumb?: ReactNode;
}

export function Chip({ active = false, count, thumb, className = '', children, ...props }: ChipProps) {
  return (
    <button
      type="button"
      {...props}
      className={cn(
        'inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full h-9 px-3.5 text-[13px] font-medium transition cursor-pointer select-none',
        active ? 'bg-ink text-white' : 'bg-canvas text-ink hover:bg-canvas-2',
        className,
      )}
    >
      {thumb}
      {children}
      {count != null && <span className={cn('tabular-nums', active ? 'text-white/55' : 'text-faint')}>{count}</span>}
    </button>
  );
}
