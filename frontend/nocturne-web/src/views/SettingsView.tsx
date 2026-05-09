import { useRef, useState } from 'react';
import { Button } from '../ui/Button';
import { Dialog } from '../ui/Dialog';
import { Divider } from '../ui/Divider';
import { JellyfinConnectForm } from '../components/JellyfinConnectForm';
import { ApiKeyForm } from '../components/ApiKeyForm';
import { LinkAppPanel } from '../components/LinkAppPanel';
import type { BackfillStatusApi } from '../lib/types';

interface SettingsViewProps {
  open: boolean;
  onClose: () => void;
  // Data
  movieCount: number;
  untaggedCount: number;
  reviewCount: number;
  backfillStatus: BackfillStatusApi | null;
  anthKeySet: boolean;
  omdbKeySet: boolean;
  autoTagEnabled: boolean;
  syncing: boolean;
  version?: string;
  // Callbacks
  onSync: () => void;
  onStartBackfill: () => Promise<void>;
  onCancelBackfill: () => Promise<void>;
  onReprocessAll: () => Promise<void>;
  onSaveAnthKey: (key: string) => Promise<void>;
  onSaveOmdbKey: (key: string) => Promise<void>;
  onToggleAutoTag: (next: boolean) => Promise<void>;
  onClearMovies: () => Promise<void>;
  onImportFile: (file: File) => Promise<void>;
  onExportTags: () => Promise<void>;
  onReviewUntaggedManually: () => void;
}

export function SettingsView(props: SettingsViewProps) {
  const {
    open,
    onClose,
    movieCount,
    untaggedCount,
    reviewCount,
    backfillStatus,
    anthKeySet,
    omdbKeySet,
    autoTagEnabled,
    syncing,
    version,
    onSync,
    onStartBackfill,
    onCancelBackfill,
    onReprocessAll,
    onSaveAnthKey,
    onSaveOmdbKey,
    onToggleAutoTag,
    onClearMovies,
    onImportFile,
    onExportTags,
    onReviewUntaggedManually,
  } = props;

  const importRef = useRef<HTMLInputElement | null>(null);
  const backfillRunning = backfillStatus?.running === true;
  const backfillPct = backfillStatus && backfillStatus.total > 0
    ? Math.min(100, Math.round((backfillStatus.processed / backfillStatus.total) * 100))
    : 0;
  const queueSize = untaggedCount + reviewCount;

  return (
    <Dialog open={open} onClose={onClose} title="Settings" size="lg">
      <input
        ref={importRef}
        type="file"
        accept="application/json"
        hidden
        onChange={async (e) => {
          const file = e.target.files?.[0];
          if (file) await onImportFile(file);
          if (e.target) e.target.value = '';
        }}
      />

      <div className="space-y-10">
        {/* ACTIONS */}
        <Section label="Actions">
          <Row
            title="Sync library"
            help={`Pull the latest movies from Jellyfin.${movieCount > 0 ? ` ${movieCount} in local catalog.` : ''}`}
            action={
              <Button variant="primary" size="sm" onClick={onSync} disabled={syncing}>
                {syncing ? 'Syncing…' : 'Sync now'}
              </Button>
            }
          />
          <Row
            title="AI auto-tagger"
            help={
              !anthKeySet
                ? 'Requires an Anthropic API key.'
                : backfillRunning
                ? 'Running in background.'
                : `${untaggedCount} untagged · ${reviewCount} in review`
            }
            action={
              <Button
                variant="primary"
                size="sm"
                onClick={onStartBackfill}
                disabled={!anthKeySet || backfillRunning || queueSize === 0}
              >
                {backfillRunning ? 'Running…' : 'Start auto-tag'}
              </Button>
            }
          >
            {backfillRunning && (
              <div className="mt-3 space-y-2">
                <div className="h-[2px] bg-border overflow-hidden">
                  <div className="h-full bg-text transition-all" style={{ width: `${backfillPct}%` }} />
                </div>
                <div className="flex items-center justify-between gap-3">
                  <span className="text-[10px] uppercase tracking-widest text-muted">
                    {backfillStatus?.processed ?? 0} / {backfillStatus?.total ?? 0}
                    {backfillStatus?.cancelled && <span className="ml-2">· cancelling</span>}
                  </span>
                  {!backfillStatus?.cancelled && (
                    <button
                      onClick={onCancelBackfill}
                      className="text-[10px] uppercase tracking-widest text-text-dim hover:text-text underline decoration-dotted underline-offset-2 cursor-pointer"
                    >
                      Cancel
                    </button>
                  )}
                </div>
              </div>
            )}
            <div className="mt-3">
              <button
                onClick={onReviewUntaggedManually}
                className="text-[11px] text-muted hover:text-text underline decoration-dotted underline-offset-2 cursor-pointer"
              >
                Review untagged manually →
              </button>
            </div>
          </Row>
          <Row
            title="Reprocess all tagged films"
            help="Clear every movie's tags and re-run the tagger against the whole library. Uses the Anthropic API per movie."
            action={
              <Button
                variant="destructive"
                size="sm"
                onClick={async () => {
                  if (!confirm(`Clear tags on all ${movieCount} films and re-tag them with Claude?`)) return;
                  await onReprocessAll();
                }}
                disabled={!anthKeySet || backfillRunning || movieCount === 0}
              >
                Reprocess all
              </Button>
            }
          />
        </Section>

        {/* CONFIGURATION */}
        <Section label="Configuration">
          <div className="border border-border p-5">
            <div className="text-[11px] uppercase tracking-widest text-muted mb-4">Jellyfin</div>
            <JellyfinConnectForm loadExisting />
          </div>

          <div className="border border-border p-5 space-y-5">
            <div className="text-[11px] uppercase tracking-widest text-muted">API keys</div>
            <ApiKeyForm
              label="Anthropic API key"
              placeholder="sk-ant-…"
              helpText="Required for AI auto-tagging."
              isSet={anthKeySet}
              onSave={onSaveAnthKey}
            />
            <Divider />
            <ApiKeyForm
              label="OMDb API key"
              placeholder="omdb api key"
              helpText="Optional: IMDb, Rotten Tomatoes & Metacritic scores."
              isSet={omdbKeySet}
              onSave={onSaveOmdbKey}
            />
          </div>

          <Row
            title="Auto-tag on sync"
            help={
              !anthKeySet
                ? 'Requires an Anthropic API key.'
                : 'New films from sync get tagged automatically. Low-confidence suggestions go to review.'
            }
            action={
              <Toggle
                active={autoTagEnabled}
                disabled={!anthKeySet}
                onChange={(next) => onToggleAutoTag(next)}
              />
            }
          />
        </Section>

        {/* LINK MOBILE APP */}
        <Section label="Link mobile app">
          <LinkMobileAppRow />
        </Section>

        {/* DATA */}
        <Section label="Data & maintenance">
          <div className="border border-border p-5 flex flex-wrap items-center gap-2">
            <Button variant="line" size="sm" onClick={() => importRef.current?.click()}>
              Import tags (JSON)
            </Button>
            <Button variant="line" size="sm" onClick={onExportTags}>
              Export tags (JSON)
            </Button>
          </div>
          <div className="border border-border p-5">
            <div className="text-[11px] uppercase tracking-widest text-muted mb-3">Danger zone</div>
            <Button
              variant="destructive"
              size="sm"
              onClick={async () => {
                if (!confirm('Delete all films from Nocturne (not Jellyfin) and reset tag usage counts?')) return;
                await onClearMovies();
              }}
            >
              Clear local films
            </Button>
            <p className="mt-2 text-[11px] text-muted">Deletes the local catalog and resets usage. Jellyfin untouched.</p>
          </div>
        </Section>

        {version && (
          <div className="text-center text-[10px] uppercase tracking-widest text-muted pt-2 border-t border-border">
            {version}
          </div>
        )}
      </div>
    </Dialog>
  );
}

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <section>
      <div className="text-[10px] uppercase tracking-widest text-muted mb-3">{label}</div>
      <div className="space-y-3">{children}</div>
    </section>
  );
}

function Row({
  title,
  help,
  action,
  children,
}: {
  title: string;
  help: string;
  action: React.ReactNode;
  children?: React.ReactNode;
}) {
  return (
    <div className="border border-border p-5">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0 flex-1">
          <div className="text-[14px] text-text">{title}</div>
          <p className="text-[12px] text-text-dim mt-1 leading-snug">{help}</p>
        </div>
        <div className="flex-shrink-0">{action}</div>
      </div>
      {children}
    </div>
  );
}

function LinkMobileAppRow() {
  const [open, setOpen] = useState(false);
  return (
    <Row
      title="Link Nocturne app"
      help="Show a QR code your iPhone can scan during onboarding step 04."
      action={
        <Button variant="line" size="sm" onClick={() => setOpen((v) => !v)}>
          {open ? 'Hide' : 'Show QR code'}
        </Button>
      }
    >
      {open && (
        <div className="mt-4">
          <LinkAppPanel />
        </div>
      )}
    </Row>
  );
}

function Toggle({ active, disabled, onChange }: { active: boolean; disabled?: boolean; onChange: (next: boolean) => void }) {
  return (
    <button
      role="switch"
      aria-checked={active}
      disabled={disabled}
      onClick={() => onChange(!active)}
      className={`inline-flex h-5 w-9 items-center border transition-colors cursor-pointer ${
        active ? 'bg-text border-text' : 'bg-bg border-border'
      } ${disabled ? 'opacity-40 cursor-not-allowed' : ''}`}
    >
      <span
        className={`inline-block h-3 w-3 bg-bg transition-transform ${
          active ? 'translate-x-[18px]' : 'translate-x-[3px]'
        } ${active ? 'bg-bg' : 'bg-muted'}`}
      />
    </button>
  );
}
