import type { InputHTMLAttributes, ReactNode } from 'react';
import { cn } from '../lib/cn';

// The one input look: soft grey at rest, white with a hairline ring when focused.
export const inputCls =
  'h-9 w-full rounded-xl bg-canvas px-3 text-[13.5px] text-ink outline-none ring-1 ring-inset ring-transparent transition placeholder:text-faint focus:bg-white focus:ring-line-2 disabled:opacity-50';

export function Field({ label, hint, htmlFor, children }: { label: ReactNode; hint?: ReactNode; htmlFor?: string; children: ReactNode }) {
  return (
    <label className="block" htmlFor={htmlFor}>
      <span className="mb-1.5 block text-[12px] font-semibold text-mute">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-[12px] text-faint">{hint}</span>}
    </label>
  );
}

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  hint?: ReactNode;
}

export function Input({ label, hint, className = '', id, ...props }: InputProps) {
  const inputId = id ?? (label ? label.toLowerCase().replace(/\s+/g, '-') : undefined);
  const input = <input id={inputId} {...props} className={cn(inputCls, className)} />;
  if (!label) return input;
  return (
    <Field label={label} hint={hint} htmlFor={inputId}>
      {input}
    </Field>
  );
}
