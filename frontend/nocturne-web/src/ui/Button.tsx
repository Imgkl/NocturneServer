import type { ButtonHTMLAttributes } from 'react';
import { cn } from '../lib/cn';

// `line` and `destructive` are the older names for outline and danger; both keep working.
type Variant = 'primary' | 'secondary' | 'outline' | 'line' | 'ghost' | 'danger' | 'destructive';
type Size = 'sm' | 'md' | 'lg';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  // Why a disabled button is disabled: shown as a tooltip and, when `reasonInline`, under it.
  reason?: string | null;
  reasonInline?: boolean;
}

const base =
  'inline-flex shrink-0 items-center justify-center gap-1.5 rounded-full font-medium tracking-[-0.005em] transition disabled:cursor-not-allowed disabled:opacity-40 cursor-pointer select-none whitespace-nowrap';

const sizes: Record<Size, string> = {
  sm: 'h-8 px-3 text-[13px]',
  md: 'h-9 px-4 text-[13.5px]',
  lg: 'h-12 px-7 text-[15px]',
};

const variants: Record<Variant, string> = {
  primary: 'bg-ink text-white hover:bg-black',
  secondary: 'bg-canvas text-ink hover:bg-canvas-2',
  outline: 'bg-transparent text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7]',
  line: 'bg-transparent text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7]',
  ghost: 'bg-transparent text-ink hover:bg-canvas',
  danger: 'bg-transparent text-bad ring-1 ring-inset ring-[#f0d6cc] hover:bg-[#fff6f2]',
  destructive: 'bg-transparent text-bad ring-1 ring-inset ring-[#f0d6cc] hover:bg-[#fff6f2]',
};

export function Button({ variant = 'primary', size = 'md', className = '', reason, reasonInline = true, children, ...props }: ButtonProps) {
  const why = props.disabled && reason ? reason : null;
  const button = (
    <button
      type={props.type ?? 'button'}
      {...props}
      title={why ?? props.title}
      className={cn(base, sizes[size], variants[variant], !why && className)}
    >
      {children}
    </button>
  );
  if (!why) return button;
  return (
    <span className={cn('inline-flex flex-col items-start gap-1', className)} title={why}>
      {button}
      {reasonInline && <span className="max-w-[260px] pl-1 text-[11.5px] leading-snug text-mute">{why}</span>}
    </span>
  );
}
