interface DividerProps {
  label?: string;
  className?: string;
}

export function Divider({ label, className = '' }: DividerProps) {
  if (label) {
    return (
      <div className={`flex items-center gap-3 ${className}`}>
        <div className="h-px flex-1 bg-line" />
        <span className="text-[12px] font-semibold text-faint">{label}</span>
        <div className="h-px flex-1 bg-line" />
      </div>
    );
  }
  return <div className={`h-px bg-line ${className}`} />;
}
