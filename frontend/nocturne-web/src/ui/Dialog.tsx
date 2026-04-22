import { useEffect } from 'react';
import type { ReactNode } from 'react';

type Size = 'sm' | 'md' | 'lg';

interface DialogProps {
  open: boolean;
  onClose: () => void;
  size?: Size;
  title?: string;
  children: ReactNode;
}

const maxWidths: Record<Size, string> = {
  sm: 'lg:max-w-md',
  md: 'lg:max-w-lg',
  lg: 'lg:max-w-2xl',
};

export function Dialog({ open, onClose, size = 'md', title, children }: DialogProps) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex lg:items-center lg:justify-center bg-black/60"
      onClick={onClose}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(e) => e.stopPropagation()}
        className={`relative w-full h-full lg:h-auto ${maxWidths[size]} bg-surface border-0 lg:border border-border flex flex-col max-h-screen lg:max-h-[85vh]`}
      >
        {title && (
          <div className="flex items-center justify-between px-5 lg:px-6 py-4 border-b border-border">
            <h2 className="font-serif italic text-lg lg:text-xl text-text">{title}</h2>
            <button
              onClick={onClose}
              aria-label="Close"
              className="text-muted hover:text-text text-xl leading-none cursor-pointer"
            >
              ×
            </button>
          </div>
        )}
        <div className="flex-1 overflow-y-auto px-5 lg:px-6 py-5">{children}</div>
      </div>
    </div>
  );
}
