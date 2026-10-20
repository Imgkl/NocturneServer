import type { HTMLAttributes } from 'react';

type Tone = 'default' | 'muted' | 'warn';

interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: Tone;
}

const tones: Record<Tone, string> = {
  default: 'border-border text-text-dim',
  muted: 'border-border text-muted',
  // Filled: the one state that must not be missed (model-written story text).
  warn: 'border-text bg-text text-bg',
};

export function Badge({ tone = 'default', className = '', ...props }: BadgeProps) {
  return (
    <span
      {...props}
      className={`inline-flex items-center gap-1 whitespace-nowrap border text-[10px] uppercase tracking-wider px-2 py-0.5 ${tones[tone]} ${className}`}
    />
  );
}
