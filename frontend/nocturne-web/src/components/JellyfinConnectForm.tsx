import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { Button } from '../ui/Button';
import { Field, inputCls } from '../ui/Input';

interface JellyfinConnectFormProps {
  /** Called on successful connection. The wizard uses this to advance. */
  onConnected?: (info: { serverName?: string; version?: string; localAddress?: string }) => void;
  /** Pre-fill URL and username from the server (Settings). */
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
        setStatus('Saved and signed in');
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
    <div className="space-y-4">
      <Field label="Jellyfin URL">
        <input className={inputCls} placeholder="http://192.168.1.24:8096" value={url} onChange={(e) => setUrl(e.target.value)} />
      </Field>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Username">
          <input className={inputCls} placeholder="admin" value={username} onChange={(e) => setUsername(e.target.value)} />
        </Field>
        <Field label={loadExisting ? 'Password (blank keeps the current one)' : 'Password'}>
          <input className={inputCls} type="password" placeholder="••••••••" value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
      </div>

      {status && <p className="text-[13px] font-medium text-good">{status}</p>}
      {error && <p className="rounded-xl bg-[#fff6f2] px-3 py-2 text-[13px] text-bad ring-1 ring-[#f0d6cc]">{error}</p>}
      {serverInfo && (
        <p className="text-[13px] text-mute">
          {serverInfo.serverName}
          {serverInfo.version && <> · Jellyfin {serverInfo.version}</>}
          {serverInfo.localAddress && <> · {serverInfo.localAddress}</>}
        </p>
      )}

      <div className="flex justify-end gap-2 pt-1">
        <Button variant="outline" onClick={() => void testConnection()} disabled={busy}>
          {busy ? 'Testing…' : 'Test connection'}
        </Button>
        <Button variant="primary" onClick={() => void save()} disabled={busy || !url || !username}>
          {busy ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </div>
  );
}
