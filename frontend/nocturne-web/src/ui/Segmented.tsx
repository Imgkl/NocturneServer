import type { ReactNode } from 'react';
import { cn } from '../lib/cn';

interface SegmentedProps<T extends string> {
  value: T;
  options: { value: T; label: ReactNode; count?: number; disabled?: boolean }[];
  onChange: (v: T) => void;
  size?: 'sm' | 'md';
  label?: string;
  className?: string;
}

// A soft grey track with a white thumb, for a handful of mutually exclusive views.
export function Segmented<T extends string>({ value, options, onChange, size = 'md', label, className = '' }: SegmentedProps<T>) {
  return (
    <div role="radiogroup" aria-label={label} className={cn('no-scrollbar inline-flex max-w-full gap-0.5 overflow-x-auto rounded-full bg-canvas p-1', className)}>
      {options.map((o) => {
        const on = value === o.value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={on}
            disabled={o.disabled}
            onClick={() => onChange(o.value)}
            className={cn(
              'inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full font-medium transition cursor-pointer disabled:cursor-default disabled:opacity-40',
              size === 'sm' ? 'h-7 px-3 text-[12.5px]' : 'h-8 px-3.5 text-[13px]',
              on ? 'bg-white text-ink shadow-[0_1px_2px_rgba(0,0,0,.08),0_0_0_1px_rgba(0,0,0,.03)]' : 'text-mute hover:text-ink',
            )}
          >
            {o.label}
            {o.count != null && <span className={cn('tabular-nums', on ? 'text-faint' : 'text-[#b4b4b4]')}>{o.count}</span>}
          </button>
        );
      })}
    </div>
  );
}
