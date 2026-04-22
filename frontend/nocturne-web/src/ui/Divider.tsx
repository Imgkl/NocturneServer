interface DividerProps {
  label?: string;
  className?: string;
}

export function Divider({ label, className = '' }: DividerProps) {
  if (label) {
    return (
      <div className={`flex items-center gap-3 ${className}`}>
        <div className="flex-1 h-px bg-border" />
        <span className="text-[10px] uppercase tracking-widest text-muted">{label}</span>
        <div className="flex-1 h-px bg-border" />
      </div>
    );
  }
  return <div className={`h-px bg-border ${className}`} />;
}
