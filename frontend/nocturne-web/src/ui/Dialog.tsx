import { useEffect } from 'react';
import type { ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { cn } from '../lib/cn';

type Size = 'sm' | 'md' | 'lg' | 'xl';

interface DialogProps {
  open: boolean;
  onClose: () => void;
  size?: Size;
  title?: ReactNode;
  sub?: ReactNode;
  children: ReactNode;
  // Buttons rendered bottom-right, under the body.
  actions?: ReactNode;
  // No padding around the body (for content that lays itself out).
  flush?: boolean;
}

const maxWidths: Record<Size, string> = {
  sm: 'sm:max-w-[440px]',
  md: 'sm:max-w-[560px]',
  lg: 'sm:max-w-[760px]',
  xl: 'sm:max-w-[1040px]',
};

// A bottom sheet on phones, a centred 24px card on larger screens. Portalled to body so a
// blurred sticky header never clips it.
export function Dialog({ open, onClose, size = 'md', title, sub, children, actions, flush = false }: DialogProps) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey, true);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      window.removeEventListener('keydown', onKey, true);
      document.body.style.overflow = prev;
    };
  }, [open, onClose]);

  if (!open) return null;

  return createPortal(
    <div className="fixed inset-0 z-[70] flex items-end justify-center sm:items-center sm:p-6" role="dialog" aria-modal="true">
      <div className="fade-in absolute inset-0 bg-black/40 backdrop-blur-[2px]" onClick={onClose} />
      <div
        className={cn(
          'modal-in relative flex w-full max-h-[92vh] flex-col rounded-t-[24px] bg-white shadow-modal sm:max-h-[88vh] sm:rounded-[24px]',
          maxWidths[size],
        )}
      >
        {(title || sub) && (
          <div className="flex items-start justify-between gap-3 px-6 pt-6 pb-2">
            <div className="min-w-0">
              {title && <h3 className="text-[18px] font-semibold tracking-[-0.02em] text-ink">{title}</h3>}
              {sub && <p className="mt-1 text-[13.5px] leading-[1.5] text-mute">{sub}</p>}
            </div>
            <button type="button" onClick={onClose} aria-label="Close" className="-mr-2 -mt-1 grid h-9 w-9 shrink-0 place-items-center rounded-full hover:bg-canvas cursor-pointer">
              <X size={17} />
            </button>
          </div>
        )}
        {!title && !sub && (
          <button type="button" onClick={onClose} aria-label="Close" className="absolute right-4 top-4 z-10 grid h-9 w-9 place-items-center rounded-full bg-white/90 hover:bg-canvas cursor-pointer">
            <X size={17} />
          </button>
        )}
        <div className={cn('min-h-0 flex-1 overflow-y-auto overscroll-contain', !flush && 'px-6 pb-6 pt-2')}>{children}</div>
        {actions && <div className="flex flex-wrap justify-end gap-2 px-6 pb-6 pt-2">{actions}</div>}
      </div>
    </div>,
    document.body,
  );
}
