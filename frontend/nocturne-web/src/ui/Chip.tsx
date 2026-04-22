import type { ButtonHTMLAttributes } from 'react';

interface ChipProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  active?: boolean;
}

export function Chip({ active = false, className = '', ...props }: ChipProps) {
  const activeCls = active
    ? 'bg-text text-bg border-text'
    : 'bg-transparent text-text-dim border-border hover:border-border-hover hover:text-text';
  return (
    <button
      {...props}
      className={`whitespace-nowrap uppercase tracking-wider text-[10px] px-3 py-1 border transition-colors cursor-pointer select-none ${activeCls} ${className}`}
    />
  );
}
