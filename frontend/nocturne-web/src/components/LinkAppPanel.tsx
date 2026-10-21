import { useEffect, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { api } from '../lib/api';

// The "Link Nocturne app" panel: QR code, the URL, and how to scan it from the phone.
// The browser's own origin is the right answer whenever it is not loopback: that URL is
// reachable from the LAN by definition. The backend's guess is the fallback for localhost.
export function LinkAppPanel() {
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    const origin = window.location.origin;
    if (!isLoopbackOrigin(origin)) {
      setUrl(origin);
      return;
    }
    let cancelled = false;
    api.link
      .lanAddress()
      .then((res) => {
        if (!cancelled) setUrl(res.url ?? origin);
      })
      .catch(() => {
        if (!cancelled) setUrl(origin);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!url) return <p className="py-8 text-center text-[13px] text-mute">Resolving address…</p>;

  return (
    <div className="flex flex-col items-center gap-4 sm:flex-row sm:items-start sm:gap-8">
      <div className="rounded-2xl bg-white p-3 shadow-card">
        <QRCodeSVG value={url} size={176} level="M" />
      </div>
      <div className="min-w-0">
        <code className="block truncate rounded-lg bg-canvas px-2.5 py-1.5 text-[12.5px] text-ink">{url}</code>
        <ol className="mt-3 list-decimal space-y-1 pl-5 text-[13px] leading-relaxed text-mute">
          <li>Open the Nocturne app on your phone.</li>
          <li>
            Reach <span className="font-medium text-ink">step 04, Enrich</span>.
          </li>
          <li>
            Tap the <span className="font-medium text-ink">viewfinder</span> icon next to the URL field.
          </li>
          <li>Point the camera at this code.</li>
        </ol>
        <p className="mt-3 text-[12px] text-faint">The phone must be on the same network as this server.</p>
      </div>
    </div>
  );
}

function isLoopbackOrigin(origin: string): boolean {
  try {
    const u = new URL(origin);
    return u.hostname === 'localhost' || u.hostname === '127.0.0.1' || u.hostname === '[::1]';
  } catch {
    return false;
  }
}
