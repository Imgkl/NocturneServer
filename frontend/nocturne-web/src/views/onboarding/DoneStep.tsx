import { useEffect, useRef, useState } from 'react';
import { api } from '../../lib/api';
import { Button } from '../../ui/Button';
import { Spinner } from '../../ui/Spinner';
import type { SyncStatus } from '../../lib/types';

interface DoneStepProps {
  onOpenLibrary: () => void;
}

export function DoneStep({ onOpenLibrary }: DoneStepProps) {
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [movieCount, setMovieCount] = useState<number | null>(null);
  const pollRef = useRef<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    const poll = async () => {
      try {
        const s = await api.sync.status();
        if (cancelled) return;
        setStatus(s);
        if (!s.isRunning) {
          const r = await api.movies.listAll(1, 0);
          if (!cancelled) setMovieCount(r.totalCount);
          return;
        }
      } catch {
        // transient; retry
      }
      pollRef.current = window.setTimeout(poll, 1000);
    };
    void poll();
    return () => {
      cancelled = true;
      if (pollRef.current) window.clearTimeout(pollRef.current);
    };
  }, []);

  const syncing = status?.isRunning !== false;

  return (
    <div className="flex max-w-[440px] flex-col items-center text-center">
      <p className="text-[12px] font-semibold text-faint">Step 3 of 3</p>
      <h2 className="mt-3 text-[32px] font-semibold leading-[1.05] tracking-[-0.035em] text-ink">{syncing ? 'Syncing your library' : 'You are in.'}</h2>
      {syncing ? (
        <>
          <div className="mt-4 flex items-center gap-2.5 text-[14px] text-mute">
            <Spinner size={14} />
            {status && status.moviesFound > 0 ? `${status.moviesFound.toLocaleString()} films scanned` : 'Scanning the Jellyfin catalog'}
          </div>
          <Button variant="outline" onClick={onOpenLibrary} className="mt-8">
            Open the library anyway
          </Button>
        </>
      ) : (
        <>
          <p className="mt-3 text-[15px] text-mute">{movieCount !== null && <>{movieCount.toLocaleString()} films in your catalog.</>}</p>
          <p className="mt-2 max-w-[380px] text-[13.5px] leading-relaxed text-faint">Add your Anthropic and OMDb keys in Settings when you are ready. Auto-tagging and ratings unlock once they are set.</p>
          <Button variant="primary" size="lg" onClick={onOpenLibrary} className="mt-8">
            Open the library
          </Button>
        </>
      )}
    </div>
  );
}
