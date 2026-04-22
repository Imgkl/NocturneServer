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
        // Transient; retry
      }
      pollRef.current = window.setTimeout(poll, 1000);
    };
    poll();

    return () => {
      cancelled = true;
      if (pollRef.current) window.clearTimeout(pollRef.current);
    };
  }, []);

  const syncing = status?.isRunning !== false;

  return (
    <div className="flex flex-col items-center text-center max-w-xl">
      <p className="text-[10px] uppercase tracking-widest text-muted mb-6">Step 3 of 3</p>
      <h2 className="font-serif italic text-5xl text-text mb-3">
        {syncing ? 'Syncing your library…' : "You're in."}
      </h2>
      {syncing ? (
        <>
          <div className="flex items-center gap-3 text-[14px] text-text-dim mb-10">
            <Spinner size={14} />
            {status && status.moviesFound > 0
              ? `${status.moviesFound.toLocaleString()} films scanned`
              : 'Scanning Jellyfin catalog'}
          </div>
          <Button variant="line" onClick={onOpenLibrary}>
            Open library anyway
          </Button>
        </>
      ) : (
        <>
          <p className="text-[14px] text-text-dim mb-2">
            {movieCount !== null && <>{movieCount.toLocaleString()} films in your catalog</>}
          </p>
          <p className="text-[12px] text-muted max-w-md mb-10 leading-relaxed">
            Add your Anthropic and OMDb keys from Settings when you're ready. Auto-tagging and
            richer metadata unlock once they're set.
          </p>
          <Button variant="primary" onClick={onOpenLibrary}>
            Open library
          </Button>
        </>
      )}
    </div>
  );
}
