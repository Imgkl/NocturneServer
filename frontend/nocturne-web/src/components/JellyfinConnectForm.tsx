import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { Button } from '../ui/Button';
import { Input } from '../ui/Input';
import { Divider } from '../ui/Divider';

interface JellyfinConnectFormProps {
  /** Called on successful connection. Wizard uses this to advance. */
  onConnected?: (info: { serverName?: string; version?: string; localAddress?: string }) => void;
  /** If true, pre-fills URL + username from server (used in Settings). */
  loadExisting?: boolean;
}

export function JellyfinConnectForm({ onConnected, loadExisting = false }: JellyfinConnectFormProps) {
  const [url, setUrl] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [serverInfo, setServerInfo] = useState<{ serverName?: string; version?: string; localAddress?: string } | null>(null);

  useEffect(() => {
    if (!loadExisting) return;
    api.settings
      .info()
      .then((info) => {
        if (info.jellyfin_url) setUrl(info.jellyfin_url);
        if (info.jellyfin_username) setUsername(info.jellyfin_username);
      })
      .catch(() => {});
  }, [loadExisting]);

  async function testConnection() {
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const r = await api.sync.testConnection();
      if (r.success) {
        setStatus('Connection OK');
        setServerInfo({ serverName: r.serverName, version: r.version, localAddress: r.localAddress });
      } else {
        setError(r.error || 'Connection failed');
        setServerInfo(null);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection test failed');
    } finally {
      setBusy(false);
    }
  }

  async function save() {
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const r = await api.settings.saveJellyfin(url.trim(), username.trim(), password);
      if (r.success) {
        setStatus('Saved & authenticated');
        setServerInfo({ serverName: r.serverName, version: r.version, localAddress: r.localAddress });
        setPassword('');
        onConnected?.({ serverName: r.serverName, version: r.version, localAddress: r.localAddress });
      } else {
        setError(r.error || 'Save failed');
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Save failed');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-5">
      <Input label="Jellyfin URL" placeholder="http://192.168.1.24:8096" value={url} onChange={(e) => setUrl(e.target.value)} />
      <Input label="Username" placeholder="admin" value={username} onChange={(e) => setUsername(e.target.value)} />
      <Input
        label={loadExisting ? 'Password (blank to keep existing)' : 'Password'}
        type="password"
        placeholder="••••••••"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />

      {status && (
        <div className="text-[11px] uppercase tracking-widest text-text-dim">{status}</div>
      )}
      {error && (
        <div className="text-[13px] text-text border border-border bg-surface px-3 py-2">{error}</div>
      )}
      {serverInfo && (
        <>
          <Divider />
          <div className="text-[11px] uppercase tracking-widest text-muted">Server</div>
          <div className="text-[13px] text-text-dim">
            {serverInfo.serverName}
            {serverInfo.version && <> · Jellyfin {serverInfo.version}</>}
            {serverInfo.localAddress && <> · {serverInfo.localAddress}</>}
          </div>
        </>
      )}

      <div className="flex gap-2 justify-end pt-2">
        <Button variant="line" onClick={testConnection} disabled={busy} size="sm">
          {busy ? 'Testing…' : 'Test connection'}
        </Button>
        <Button variant="primary" onClick={save} disabled={busy || !url || !username} size="sm">
          {busy ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </div>
  );
}
