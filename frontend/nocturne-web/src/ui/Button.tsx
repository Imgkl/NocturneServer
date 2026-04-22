import type { ButtonHTMLAttributes } from 'react';

type Variant = 'primary' | 'line' | 'ghost';
type Size = 'sm' | 'md';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
}

const base =
  'inline-flex items-center justify-center font-medium uppercase tracking-wider transition-colors disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer select-none';

const sizes: Record<Size, string> = {
  sm: 'text-[10.5px] px-3 py-1.5',
  md: 'text-[11.5px] px-4 py-2',
};

const variants: Record<Variant, string> = {
  primary: 'bg-text text-bg hover:bg-text-dim',
  line: 'bg-transparent text-text border border-border hover:border-border-hover',
  ghost: 'bg-transparent text-muted hover:text-text',
};

export function Button({ variant = 'primary', size = 'md', className = '', ...props }: ButtonProps) {
  return <button {...props} className={`${base} ${sizes[size]} ${variants[variant]} ${className}`} />;
}
