import type { InputHTMLAttributes } from 'react';

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string;
}

export function Input({ label, className = '', id, ...props }: InputProps) {
  const inputId = id ?? (label ? label.toLowerCase().replace(/\s+/g, '-') : undefined);
  return (
    <div className="flex flex-col gap-1.5 w-full">
      {label && (
        <label
          htmlFor={inputId}
          className="text-[10px] uppercase tracking-widest text-muted"
        >
          {label}
        </label>
      )}
      <input
        id={inputId}
        {...props}
        className={`bg-transparent border-0 border-b border-border focus:border-text outline-none text-text placeholder:text-muted text-[14px] py-2 transition-colors ${className}`}
      />
    </div>
  );
}
