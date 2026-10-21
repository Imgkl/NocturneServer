import type { ReactNode } from 'react';
import { Plus, X } from 'lucide-react';
import { cn } from '../lib/cn';

interface ChipProps {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
  count?: number;
  title?: string;
}

// X-Cache's refine chip: a plus to add, a cross to remove, the count in faint numerals.
export function Chip({ active, onClick, children, count, title }: ChipProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      title={title}
      className={cn(
        'inline-flex h-9 shrink-0 items-center gap-1.5 rounded-full text-[13.5px] font-medium tracking-[-0.005em] transition duration-150 cursor-pointer',
        active ? 'bg-ink pl-3.5 pr-2.5 text-white' : 'bg-[#f3f3f3] pl-3 pr-3.5 text-ink hover:bg-[#e9e9e9]',
        !active && count === 0 && 'text-faint',
      )}
    >
      {!active && <Plus size={14} strokeWidth={2.4} className="-mr-0.5 text-ink/70" />}
      {children}
      {count != null && <span className={cn('tabular-nums', active ? 'text-white/60' : 'text-faint')}>{count}</span>}
      {active && <X size={14} strokeWidth={2.4} className="ml-0.5 text-white/80" />}
    </button>
  );
}
