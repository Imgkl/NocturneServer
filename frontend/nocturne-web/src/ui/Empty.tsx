import type { ReactNode } from 'react';
import { cn } from '../lib/cn';

interface EmptyProps {
  icon?: ReactNode;
  title: ReactNode;
  sub?: ReactNode;
  action?: ReactNode;
  className?: string;
}

// Empty state: a soft circle icon, a title and a sentence.
export function Empty({ icon, title, sub, action, className = '' }: EmptyProps) {
  return (
    <div className={cn('flex flex-col items-center px-6 py-14 text-center', className)}>
      {icon && <div className="grid h-12 w-12 place-items-center rounded-full bg-[#f4f4f4] text-mute">{icon}</div>}
      <div className={cn('text-[15.5px] font-semibold tracking-[-0.015em] text-ink', !!icon && 'mt-4')}>{title}</div>
      {sub && <p className="mt-1.5 max-w-[420px] text-[13.5px] leading-[1.5] text-mute">{sub}</p>}
      {action && <div className="mt-5">{action}</div>}
    </div>
  );
}
