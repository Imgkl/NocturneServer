import { useEffect, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { api } from '../lib/api';

/// Shared "Link Nocturne app" panel — QR code + URL + scan instructions.
/// Used inside the Settings dialog and the toolbar dialog. Resolves the
/// LAN URL from the backend on mount; falls back to `window.location.origin`.
export function LinkAppPanel() {
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api.link
      .lanAddress()
      .then((res) => {
        if (cancelled) return;
        setUrl(res.url ?? window.location.origin);
      })
      .catch(() => {
        if (!cancelled) setUrl(window.location.origin);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!url) {
    return <p className="text-[12px] text-muted text-center py-8">Resolving address…</p>;
  }

  return (
    <div className="flex flex-col items-center gap-4">
      <div className="bg-white p-4 border border-border">
        <QRCodeSVG value={url} size={224} level="M" />
      </div>

      <code className="text-[12px] text-text">{url}</code>

      <ol className="text-[12px] text-text-dim leading-relaxed list-decimal pl-5 space-y-1 max-w-[320px]">
        <li>Open the Nocturne app on your phone.</li>
        <li>
          Reach <span className="text-text">step 04 — Enrich</span>.
        </li>
        <li>
          Tap the <span className="text-text">viewfinder</span> icon next to the URL field.
        </li>
        <li>Point the camera at this QR code.</li>
      </ol>

      <p className="text-[11px] text-muted text-center max-w-[280px] leading-snug">
        Your phone must be on the same network as this server.
      </p>
    </div>
  );
}
