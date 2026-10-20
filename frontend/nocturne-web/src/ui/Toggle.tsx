interface ToggleProps {
  active: boolean;
  disabled?: boolean;
  onChange: (next: boolean) => void;
  label?: string;
}

export function Toggle({ active, disabled, onChange, label }: ToggleProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={active}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!active)}
      className={`inline-flex h-5 w-9 items-center border transition-colors cursor-pointer ${
        active ? 'bg-text border-text' : 'bg-bg border-border'
      } ${disabled ? 'opacity-40 cursor-not-allowed' : ''}`}
    >
      <span
        className={`inline-block h-3 w-3 transition-transform ${
          active ? 'translate-x-[18px] bg-bg' : 'translate-x-[3px] bg-muted'
        }`}
      />
    </button>
  );
}
