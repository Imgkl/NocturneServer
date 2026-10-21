import { cn } from '../lib/cn';

interface SelectProps<T extends string> {
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
  label: string;
  className?: string;
  // A full-width input-shaped select (settings forms) instead of the compact pill.
  block?: boolean;
  id?: string;
}

// A quiet native select: a pill with a chevron, or an input-shaped block in forms.
export function Select<T extends string>({ value, options, onChange, label, className = '', block = false, id }: SelectProps<T>) {
  return (
    <label className={cn('relative inline-flex', block && 'w-full', className)}>
      <span className="sr-only">{label}</span>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
        className={cn(
          'cursor-pointer appearance-none bg-canvas text-[13.5px] font-medium text-ink outline-none transition hover:bg-[#ececec] focus-visible:ring-2 focus-visible:ring-ink',
          block ? 'h-9 w-full rounded-xl pl-3 pr-9' : 'h-9 rounded-full pl-3.5 pr-9',
        )}
      >
        {options.map(([v, l]) => (
          <option key={v} value={v}>
            {l}
          </option>
        ))}
      </select>
      <svg aria-hidden viewBox="0 0 16 16" className="pointer-events-none absolute right-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-mute">
        <path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </label>
  );
}
