import { useCallback, useEffect, useRef, useState } from 'react';
import { cn } from '../lib/cn';

export type ToastMessage = { text: string; tone: 'ok' | 'error' } | null;

// A pill at the bottom of the viewport: ink for good news, white with an oxblood ring for errors.
export function Toast({ toast }: { toast: ToastMessage }) {
  if (!toast) return null;
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-6 z-[80] flex justify-center px-4" style={{ bottom: 'calc(24px + env(safe-area-inset-bottom, 0px))' }}>
      <div
        role="status"
        className={cn(
          'rise pointer-events-auto max-w-[560px] rounded-full px-4 py-2.5 text-[13.5px] font-medium shadow-[0_12px_40px_-12px_rgba(0,0,0,.35)]',
          toast.tone === 'error' ? 'bg-white text-bad ring-1 ring-[#f0d6cc]' : 'bg-ink text-white',
        )}
      >
        {toast.text}
      </div>
    </div>
  );
}

// `say(text, tone)` shows a toast for a few seconds; errors stay a little longer.
export function useToast() {
  const [toast, setToast] = useState<ToastMessage>(null);
  const timer = useRef<number | null>(null);
  const say = useCallback((text: string, tone: 'ok' | 'error' = 'ok') => {
    setToast({ text, tone });
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setToast(null), tone === 'error' ? 6000 : 3200);
  }, []);
  useEffect(() => () => {
    if (timer.current) window.clearTimeout(timer.current);
  }, []);
  return { toast, say };
}
