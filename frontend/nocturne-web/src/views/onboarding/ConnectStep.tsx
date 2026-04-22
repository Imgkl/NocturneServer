import { useEffect, useState } from 'react';
import { api } from '../../lib/api';
import { Button } from '../../ui/Button';
import { Input } from '../../ui/Input';
import { Divider } from '../../ui/Divider';
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
      // Non-fatal — manual URL is always available.
    } finally {
      setDiscovering(false);
    }
  }

  useEffect(() => {
    runDiscovery();
  }, []);

  function pickServer(s: DiscoveredServer) {
    setUrl(s.address);
  }

  async function connect() {
    if (!url || !username) return;
    setBusy(true);
    setError(null);
    try {
      const r = await api.settings.saveJellyfin(url.trim(), username.trim(), password);
      if (r.success) {
        // Kick off an initial sync so the local DB is populated before the user
        // hits the library. DoneStep polls /sync/status and shows progress.
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
    <div className="w-full max-w-xl">
      <p className="text-[10px] uppercase tracking-widest text-muted mb-3">Step 2 of 3 · Connect</p>
      <h2 className="font-serif italic text-3xl lg:text-4xl text-text mb-2">Find your Jellyfin server</h2>
      <p className="text-[13px] text-text-dim mb-8">
        We broadcast on your local network and show any Jellyfin servers that respond.
      </p>

      {/* Discovered */}
      <div className="mb-6">
        <div className="flex items-center justify-between mb-3">
          <span className="text-[10px] uppercase tracking-widest text-muted">Discovered on your network</span>
          <button
            onClick={runDiscovery}
            disabled={discovering}
            className="text-[10px] uppercase tracking-widest text-muted hover:text-text cursor-pointer disabled:opacity-40"
          >
            {discovering ? 'Searching…' : 'Refresh'}
          </button>
        </div>
        {discovering && servers.length === 0 && (
          <div className="flex items-center gap-3 px-4 py-4 border border-border bg-surface text-[13px] text-text-dim">
            <Spinner size={12} />
            Searching…
          </div>
        )}
        {!discovering && servers.length === 0 && (
          <div className="px-4 py-4 border border-border text-[13px] text-text-dim">
            No servers found. Enter your URL manually below.
          </div>
        )}
        {servers.length > 0 && (
          <div className="flex flex-col">
            {servers.map((s) => (
              <button
                key={s.id}
                onClick={() => pickServer(s)}
                className={`flex items-center justify-between px-4 py-4 border border-border hover:border-border-hover text-left cursor-pointer ${
                  url === s.address ? 'bg-surface' : 'bg-bg'
                } [&:not(:first-child)]:border-t-0`}
              >
                <div>
                  <div className="text-[14px] text-text">{s.name}</div>
                  <div className="text-[11px] text-muted mt-0.5">
                    {s.address}
                    {s.version && ` · Jellyfin ${s.version}`}
                  </div>
                </div>
                <span className="text-[10px] uppercase tracking-widest text-muted">
                  {url === s.address ? 'Selected' : 'Select →'}
                </span>
              </button>
            ))}
          </div>
        )}
      </div>

      <Divider label="Or enter manually" />

      <div className="mt-6 space-y-5">
        <Input
          label="Jellyfin URL"
          placeholder="http://192.168.1.24:8096"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
        <Input
          label="Username"
          placeholder="admin"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
        />
        <Input
          label="Password"
          type="password"
          placeholder="••••••••"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </div>

      {error && (
        <div className="mt-5 border border-border bg-surface px-4 py-3 text-[13px] text-text">
          {error}
        </div>
      )}

      <div className="mt-8 flex justify-end">
        <Button variant="primary" onClick={connect} disabled={busy || !url || !username}>
          {busy ? 'Connecting…' : 'Connect'}
        </Button>
      </div>
    </div>
  );
}
