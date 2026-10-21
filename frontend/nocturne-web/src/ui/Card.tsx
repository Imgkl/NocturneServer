import type { HTMLAttributes, ReactNode } from 'react';
import { cn } from '../lib/cn';

interface CardProps extends Omit<HTMLAttributes<HTMLElement>, 'title'> {
  padded?: boolean;
  title?: ReactNode;
  sub?: ReactNode;
  right?: ReactNode;
  // No padding on the body (lists that run edge to edge).
  flush?: boolean;
}

// A 24px white card with the ring shadow; the one container for settings and detail blocks.
export function Card({ padded = true, flush = false, title, sub, right, className = '', children, ...props }: CardProps) {
  const pad = flush ? '' : padded ? 'p-5 sm:p-7' : '';
  return (
    <section {...props} className={cn('scroll-mt-28 rounded-[24px] bg-white shadow-card', flush && 'overflow-hidden', pad, className)}>
      {(title || right) && (
        <div className={cn('flex flex-wrap items-start justify-between gap-x-4 gap-y-3', flush ? 'px-5 pb-4 pt-5 sm:px-7 sm:pt-6' : 'mb-5')}>
          <div className="min-w-0">
            {title && <h2 className="text-[17px] font-semibold leading-tight tracking-[-0.02em] text-ink">{title}</h2>}
            {sub && <p className="mt-1.5 max-w-[640px] text-[13.5px] leading-[1.5] text-mute">{sub}</p>}
          </div>
          {right && <div className="flex shrink-0 items-center gap-2">{right}</div>}
        </div>
      )}
      {children}
    </section>
  );
}
