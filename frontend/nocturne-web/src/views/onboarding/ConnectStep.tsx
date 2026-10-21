import { useEffect, useState } from 'react';
import { Check, RotateCw } from 'lucide-react';
import { api } from '../../lib/api';
import { cn } from '../../lib/cn';
import { Button } from '../../ui/Button';
import { Divider } from '../../ui/Divider';
import { Field, inputCls } from '../../ui/Input';
import { Spinner } from '../../ui/Spinner';
import type { DiscoveredServer } from '../../lib/types';

interface ConnectStepProps {
  onConnected: () => void;
}

export function ConnectStep({ onConnected }: ConnectStepProps) {
  const [discovering, setDiscovering] = useState(false);
  const [servers, setServers] = useState<DiscoveredServer[]>([]);
  const [url, setUrl] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runDiscovery() {
    setDiscovering(true);
    setError(null);
    try {
      const { servers: found } = await api.jellyfin.discover();
      setServers(found);
    } catch {
      // Non-fatal: the manual URL is always available.
    } finally {
      setDiscovering(false);
    }
  }

  useEffect(() => {
    void runDiscovery();
  }, []);

  async function connect() {
    if (!url || !username) return;
    setBusy(true);
    setError(null);
    try {
      const r = await api.settings.saveJellyfin(url.trim(), username.trim(), password);
      if (r.success) {
        // Kick off the first sync so the library is filling while the last step shows progress.
        api.sync.trigger();
        onConnected();
      } else {
        setError(r.error || 'Connection failed');
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection failed');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="w-full max-w-[480px]">
      <p className="text-[12px] font-semibold text-faint">Step 2 of 3</p>
      <h2 className="mt-3 text-[30px] font-semibold leading-[1.05] tracking-[-0.035em] text-ink">Find your Jellyfin server</h2>
      <p className="mt-2 text-[14px] leading-[1.5] text-mute">We ask the local network and list any Jellyfin server that answers.</p>

      <div className="mt-7">
        <div className="mb-2.5 flex items-center justify-between">
          <span className="text-[12px] font-semibold text-mute">On your network</span>
          <button type="button" onClick={() => void runDiscovery()} disabled={discovering} className="inline-flex items-center gap-1 text-[12.5px] font-medium text-mute hover:text-ink disabled:opacity-40 cursor-pointer">
            <RotateCw size={12} className={cn(discovering && 'animate-spin')} /> {discovering ? 'Searching' : 'Search again'}
          </button>
        </div>
        {discovering && servers.length === 0 && (
          <div className="flex items-center gap-3 rounded-2xl bg-canvas px-4 py-3.5 text-[13.5px] text-mute">
            <Spinner size={12} /> Searching…
          </div>
        )}
        {!discovering && servers.length === 0 && <div className="rounded-2xl bg-canvas px-4 py-3.5 text-[13.5px] text-mute">No server answered. Enter the URL below.</div>}
        {servers.length > 0 && (
          <div className="overflow-hidden rounded-2xl ring-1 ring-line">
            {servers.map((s) => {
              const picked = url === s.address;
              return (
                <button key={s.id} type="button" onClick={() => setUrl(s.address)} className={cn('flex w-full items-center justify-between gap-3 border-t border-line px-4 py-3.5 text-left first:border-t-0 cursor-pointer', picked ? 'bg-canvas' : 'bg-white hover:bg-[#f7f7f7]')}>
                  <span className="min-w-0">
                    <span className="block text-[14px] font-medium text-ink">{s.name}</span>
                    <span className="mt-0.5 block truncate text-[12px] text-faint">
                      {s.address}
                      {s.version && ` · Jellyfin ${s.version}`}
                    </span>
                  </span>
                  {picked ? (
                    <span className="inline-flex items-center gap-1 text-[12.5px] font-medium text-ink">
                      <Check size={13} strokeWidth={3} /> Selected
                    </span>
                  ) : (
                    <span className="text-[12.5px] font-medium text-mute">Select</span>
                  )}
                </button>
              );
            })}
          </div>
        )}
      </div>

      <Divider label="or enter it yourself" className="my-6" />

      <div className="space-y-4">
        <Field label="Jellyfin URL">
          <input className={inputCls} placeholder="http://192.168.1.24:8096" value={url} onChange={(e) => setUrl(e.target.value)} />
        </Field>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label="Username">
            <input className={inputCls} placeholder="admin" value={username} onChange={(e) => setUsername(e.target.value)} />
          </Field>
          <Field label="Password">
            <input className={inputCls} type="password" placeholder="••••••••" value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
        </div>
      </div>

      {error && <p className="mt-4 rounded-xl bg-[#fff6f2] px-3 py-2 text-[13px] text-bad ring-1 ring-[#f0d6cc]">{error}</p>}

      <div className="mt-7 flex justify-end">
        <Button variant="primary" size="lg" onClick={() => void connect()} disabled={busy || !url || !username}>
          {busy ? 'Connecting…' : 'Connect'}
        </Button>
      </div>
    </div>
  );
}
