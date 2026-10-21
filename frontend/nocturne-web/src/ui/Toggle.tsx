import { cn } from '../lib/cn';

interface ToggleProps {
  active: boolean;
  disabled?: boolean;
  onChange: (next: boolean) => void;
  label?: string;
}

// A round switch: ink track when on, white thumb.
export function Toggle({ active, disabled, onChange, label }: ToggleProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={active}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!active)}
      className={cn(
        'relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors cursor-pointer',
        active ? 'bg-ink' : 'bg-line-2',
        disabled && 'opacity-40 cursor-not-allowed',
      )}
    >
      <span
        className={cn(
          'absolute left-[2px] top-[2px] h-4 w-4 rounded-full bg-white shadow-[0_1px_2px_rgba(0,0,0,.25)] transition-transform',
          active ? 'translate-x-4' : 'translate-x-0',
        )}
      />
    </button>
  );
}
