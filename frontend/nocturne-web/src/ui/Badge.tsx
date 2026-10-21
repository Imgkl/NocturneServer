import type { HTMLAttributes } from 'react';
import { cn } from '../lib/cn';

// `warn` is the solid ink pill for the one state nobody may miss (a model-written story).
type Tone = 'default' | 'muted' | 'warn' | 'good' | 'new';

interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: Tone;
}

const tones: Record<Tone, string> = {
  default: 'bg-white text-ink shadow-[0_0_0_1px_rgba(0,0,0,.08)]',
  muted: 'bg-canvas text-mute',
  warn: 'bg-ink text-white',
  good: 'bg-white text-good shadow-[0_0_0_1px_rgba(0,0,0,.08)]',
  new: 'bg-white text-ink shadow-[0_0_0_1px_rgba(0,0,0,.08)]',
};

export function Badge({ tone = 'default', className = '', children, ...props }: BadgeProps) {
  return (
    <span
      {...props}
      className={cn('inline-flex h-[22px] shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2 text-[11px] font-semibold leading-none', tones[tone], className)}
    >
      {tone === 'new' && <i className="inline-block h-[7px] w-[7px] rounded-full bg-new" aria-hidden />}
      {children}
    </span>
  );
}
