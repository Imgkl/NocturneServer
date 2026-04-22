import type { ButtonHTMLAttributes, ReactNode } from 'react';

interface SidebarProps {
  onSettingsClick: () => void;
  version?: string;
}

export function Sidebar({ onSettingsClick, version }: SidebarProps) {
  return (
    <aside className="hidden lg:flex sticky top-0 h-screen w-[72px] flex-col items-center py-6 bg-bg border-r border-border">
      <span
        aria-label="Nocturne"
        className="font-serif italic text-2xl text-text select-none"
      >
        N
      </span>
      <div className="flex-1" />
      <SidebarButton label="Settings" onClick={onSettingsClick}>
        <GearIcon />
      </SidebarButton>
      {version && (
        <span className="text-[8px] uppercase tracking-widest text-muted mt-3">
          v{version}
        </span>
      )}
    </aside>
  );
}

interface SidebarButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  label: string;
  children: ReactNode;
}

function SidebarButton({ label, children, className = '', ...props }: SidebarButtonProps) {
  return (
    <button
      {...props}
      title={label}
      aria-label={label}
      className={`w-10 h-10 flex items-center justify-center text-muted hover:text-text transition-colors cursor-pointer ${className}`}
    >
      {children}
    </button>
  );
}

export function GearIcon({ size = 18 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 0 0-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 0 0-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 0 0-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 0 0-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 0 0 1.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  );
}
