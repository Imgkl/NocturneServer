import { useEffect, useState } from 'react';

/**
 * Collapses a sticky header on "scroll down", expands on "scroll up".
 *
 * Uses direct input events (touch on mobile, wheel on desktop) — **not**
 * the scroll event — because scroll events:
 *   - fire continuously during momentum decay (the tail can flip direction)
 *   - have sub-pixel jitter near momentum stop
 *   - have no natural "end of one gesture" boundary the way touch does
 *
 * Mobile: `touchstart` captures the origin finger Y; `touchmove` compares
 * against it to infer gesture direction; state can flip at most once per
 * touch gesture (a single zig-zag of the finger cannot flap open-close).
 * `touchend` / `touchcancel` resets for the next gesture.
 *
 * Desktop: `wheel` events accumulate into a burst that commits after 150ms
 * of idle — again at most once per burst.
 *
 * No scroll listener at all, so momentum / rubber-band / iOS bounce can't
 * affect the state.
 */
export function useHeaderCollapsed(threshold = 80, flipDelta = 50): boolean {
  const [collapsed, setCollapsed] = useState(false);

  useEffect(() => {
    // ---- Mobile: touch-based ------------------------------------------
    let touchStartY: number | null = null;
    let flippedThisTouch = false;

    const onTouchStart = (e: TouchEvent) => {
      const t = e.touches[0];
      if (!t) return;
      touchStartY = t.clientY;
      flippedThisTouch = false;
    };

    const onTouchMove = (e: TouchEvent) => {
      if (touchStartY === null || flippedThisTouch) return;
      const t = e.touches[0];
      if (!t) return;
      // Finger moved up → user is scrolling the page down.
      const fingerUp = touchStartY - t.clientY;
      if (fingerUp > flipDelta && window.scrollY > threshold) {
        setCollapsed(true);
        flippedThisTouch = true;
      } else if (fingerUp < -flipDelta) {
        setCollapsed(false);
        flippedThisTouch = true;
      }
    };

    const onTouchEnd = () => {
      touchStartY = null;
      flippedThisTouch = false;
    };

    // ---- Desktop: wheel-based -----------------------------------------
    let wheelAccum = 0;
    let wheelTimer: number | null = null;
    const onWheel = (e: WheelEvent) => {
      wheelAccum += e.deltaY;
      if (wheelTimer !== null) window.clearTimeout(wheelTimer);
      wheelTimer = window.setTimeout(() => {
        if (wheelAccum > flipDelta && window.scrollY > threshold) {
          setCollapsed(true);
        } else if (wheelAccum < -flipDelta) {
          setCollapsed(false);
        }
        wheelAccum = 0;
        wheelTimer = null;
      }, 150);
    };

    window.addEventListener('touchstart', onTouchStart, { passive: true });
    window.addEventListener('touchmove', onTouchMove, { passive: true });
    window.addEventListener('touchend', onTouchEnd, { passive: true });
    window.addEventListener('touchcancel', onTouchEnd, { passive: true });
    window.addEventListener('wheel', onWheel, { passive: true });

    return () => {
      window.removeEventListener('touchstart', onTouchStart);
      window.removeEventListener('touchmove', onTouchMove);
      window.removeEventListener('touchend', onTouchEnd);
      window.removeEventListener('touchcancel', onTouchEnd);
      window.removeEventListener('wheel', onWheel);
      if (wheelTimer !== null) window.clearTimeout(wheelTimer);
    };
  }, [threshold, flipDelta]);

  return collapsed;
}
