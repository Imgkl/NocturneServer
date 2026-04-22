import { GearIcon } from './Sidebar';

interface MobileHeaderProps {
  onSettingsClick: () => void;
}

export function MobileHeader({ onSettingsClick }: MobileHeaderProps) {
  return (
    <header className="lg:hidden flex items-center justify-between px-5 h-14 border-b border-border bg-bg sticky top-0 z-30">
      <span className="font-serif italic text-2xl text-text">Nocturne</span>
      <button
        onClick={onSettingsClick}
        aria-label="Settings"
        className="w-10 h-10 flex items-center justify-center text-muted hover:text-text transition-colors cursor-pointer"
      >
        <GearIcon size={20} />
      </button>
    </header>
  );
}
