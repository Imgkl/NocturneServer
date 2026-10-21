import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { ChevronDown } from 'lucide-react';
import { cn } from '../lib/cn';
import { GRADER_LABEL, policyLabel } from '../lib/policy';
import { Button } from '../ui/Button';
import { Segmented } from '../ui/Segmented';
import { Toggle } from '../ui/Toggle';
import { ApiKeyForm } from '../components/ApiKeyForm';
import { EnrichmentCoverageCard } from '../components/EnrichmentCoverageCard';
import { FloorsTable } from '../components/FloorsTable';
import { GuideEditor } from '../components/GuideEditor';
import { JellyfinConnectForm } from '../components/JellyfinConnectForm';
import { LinkAppPanel } from '../components/LinkAppPanel';
import { ModelSettings } from '../components/ModelSettings';
import type { BackfillScope, BackfillStatusApi, CoverageStatus, EnrichmentSummary, JevTestResult, ModelSettings as ModelSettingsApi, ModelSettingsUpdate, MoodBuckets, Movie } from '../lib/types';

type SectionId = 'tagger' | 'connections' | 'sources' | 'link' | 'data' | 'about';

interface SettingsPageProps {
  movieCount: number;
  untaggedCount: number;
  untaggedWatchedCount: number;
  reviewCount: number;
  backfillStatus: BackfillStatusApi | null;
  coverageStatus: CoverageStatus | null;
  enrichmentSummary: EnrichmentSummary | null;
  modelSettings: ModelSettingsApi | null;
  moods: MoodBuckets;
  anthKeySet: boolean;
  omdbKeySet: boolean;
  jevKeySet: boolean;
  jellyfinUrl?: string;
  autoTagEnabled: boolean;
  syncing: boolean;
  lastSyncLabel: string;
  version?: string;
  onSync: () => void;
  onStartBackfill: (scope: BackfillScope) => Promise<void>;
  onCancelBackfill: () => Promise<void>;
  onReprocessAll: (scope: BackfillScope) => Promise<void>;
  onStartCoverage: () => Promise<void>;
  onCancelCoverage: () => Promise<void>;
  onSaveModels: (update: ModelSettingsUpdate) => Promise<void>;
  onOpenMovie: (jellyfinId: string) => void;
  movieLookup: (jellyfinId: string) => Movie | undefined;
  onSaveAnthKey: (key: string) => Promise<void>;
  onSaveOmdbKey: (key: string) => Promise<void>;
  onSaveJevKey: (key: string) => Promise<void>;
  onTestJev: () => Promise<JevTestResult>;
  onRegrade: (scope: BackfillScope) => Promise<void>;
  say: (text: string, tone?: 'ok' | 'error') => void;
  onToggleAutoTag: (next: boolean) => Promise<void>;
  onClearMovies: () => Promise<void>;
  onImportFile: (file: File) => Promise<void>;
  onExportTags: () => Promise<void>;
}

// X-Cache's settings page: a section nav on the left, accordion cards with a one-line summary.
// The section that needs attention starts open; the rest start closed.
export function SettingsPage(props: SettingsPageProps) {
  const {
    movieCount, untaggedCount, untaggedWatchedCount, reviewCount, backfillStatus, coverageStatus, enrichmentSummary, modelSettings, moods,
    anthKeySet, omdbKeySet, jevKeySet, jellyfinUrl, autoTagEnabled, syncing, lastSyncLabel, version, onSync, onStartBackfill, onCancelBackfill, onReprocessAll,
    onStartCoverage, onCancelCoverage, onSaveModels, onOpenMovie, movieLookup, onSaveAnthKey, onSaveOmdbKey, onSaveJevKey, onTestJev, onRegrade, say, onToggleAutoTag, onClearMovies, onImportFile, onExportTags,
  } = props;

  const importRef = useRef<HTMLInputElement | null>(null);
  const [scope, setScope] = useState<BackfillScope>('watched');
  const [jevTest, setJevTest] = useState<JevTestResult | 'running' | null>(null);
  const graderOn = modelSettings?.classifier_provider === 'jev';
  const backfillRunning = backfillStatus?.running === true;
  const coverageRunning = coverageStatus?.running === true;
  const anyRunActive = backfillRunning || coverageRunning;
  const scopedUntagged = scope === 'watched' ? untaggedWatchedCount : scope === 'unwatched' ? untaggedCount - untaggedWatchedCount : untaggedCount;
  const attention: SectionId | null = !anthKeySet ? 'connections' : null;
  const [open, setOpen] = useState<Set<SectionId>>(() => new Set<SectionId>([attention ?? 'tagger']));
  useEffect(() => {
    if (attention) setOpen((o) => new Set(o).add(attention));
  }, [attention]);
  const toggle = (id: SectionId) =>
    setOpen((o) => {
      const n = new Set(o);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const jump = (id: SectionId) => {
    setOpen((o) => new Set(o).add(id));
    document.getElementById(`s-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const spend = modelSettings ? `$${modelSettings.budget_spent_usd.toFixed(2)} of $${modelSettings.monthly_budget_usd ?? 0} this month` : '';
  const sum = enrichmentSummary;
  const sections: { id: SectionId; title: string; summary: string; attention?: boolean; body: ReactNode }[] = [
    {
      id: 'tagger',
      title: 'Tagger',
      summary: [
        modelSettings?.reader_model?.replace('claude-', ''),
        modelSettings ? (graderOn ? `graded by ${GRADER_LABEL.jev}` : 'no grader') : '',
        modelSettings ? `${policyLabel(modelSettings.policy_version)} (${modelSettings.policy_version})` : '',
        modelSettings ? `guide v${modelSettings.guide_version}` : '',
        spend,
        autoTagEnabled ? 'auto-tag on sync' : 'auto-tag on sync off',
      ]
        .filter(Boolean)
        .join(' · '),
      body: (
        <div className="space-y-5">
          <ModelSettings settings={modelSettings} onSave={onSaveModels} />
          <Row title="Auto-tag on sync" help={anthKeySet ? 'New films from sync get tagged in the background. Low-confidence moods go to review.' : 'Requires an Anthropic API key.'}>
            <Toggle active={autoTagEnabled} disabled={!anthKeySet} onChange={(next) => void onToggleAutoTag(next)} label="Auto-tag on sync" />
          </Row>
          <Row
            title="Start auto-tag"
            help={!anthKeySet ? 'Requires an Anthropic API key.' : backfillRunning ? `Running: ${backfillStatus?.processed ?? 0} of ${backfillStatus?.total ?? 0}` : `${scopedUntagged} untagged in scope · ${reviewCount} in review`}
            below={
              !backfillRunning ? (
                <Segmented<BackfillScope>
                  value={scope}
                  onChange={setScope}
                  size="sm"
                  label="Films"
                  options={[
                    { value: 'watched', label: 'Watched', count: untaggedWatchedCount },
                    { value: 'unwatched', label: 'Unwatched', count: untaggedCount - untaggedWatchedCount },
                    { value: 'all', label: 'All', count: untaggedCount },
                  ]}
                />
              ) : (
                <Button variant="ghost" size="sm" onClick={() => void onCancelBackfill()} disabled={!!backfillStatus?.cancelled}>
                  {backfillStatus?.cancelled ? 'Cancelling…' : 'Cancel'}
                </Button>
              )
            }
          >
            <Button variant="primary" onClick={() => void onStartBackfill(scope)} disabled={!anthKeySet || anyRunActive || scopedUntagged + reviewCount === 0}>
              {backfillRunning ? 'Running…' : 'Start auto-tag'}
            </Button>
          </Row>
          <Row title="Reprocess" help={`Clear the tagger's own tags on the ${scope === 'all' ? 'whole library' : `${scope} films`} (never yours) and re-run it. Uses the Anthropic API per film.`}>
            <Button
              variant="danger"
              onClick={async () => {
                if (!confirm(`Clear the tagger's tags on the ${scope} films and re-tag them? Your own tags stay.`)) return;
                await onReprocessAll(scope);
              }}
              disabled={!anthKeySet || anyRunActive || movieCount === 0}
            >
              Reprocess…
            </Button>
          </Row>
          <Row title="Regrade" help={`Jev and the policy again over the ${scope === 'all' ? 'whole library' : `${scope} films`} that have a stored AI answer. AI is not called; about $0.001 per film. Changed films land in Review.`}>
            <Button
              variant="outline"
              onClick={async () => {
                if (!confirm(`Regrade the ${scope} films with Jev and the current policy? AI is not called.`)) return;
                await onRegrade(scope);
              }}
              disabled={!graderOn || !jevKeySet || anyRunActive || movieCount === 0}
              reason={!graderOn ? 'Pick Jev as the grader first' : !jevKeySet ? 'Needs the TypeSafe key' : anyRunActive ? 'A run is in progress' : null}
              reasonInline={false}
            >
              Regrade
            </Button>
          </Row>
          {modelSettings && (
            <Details label="Floors per mood" hint="The grader probability each mood has to clear.">
              <FloorsTable moods={moods} floors={modelSettings.floors} high={modelSettings.high} onSave={(floors, high) => onSaveModels({ floors, high })} />
            </Details>
          )}
          <Details label="Guide" hint={modelSettings ? `What AI reads on every film · v${modelSettings.guide_version}` : 'What AI reads on every film'}>
            <GuideEditor moods={moods} say={say} />
          </Details>
        </div>
      ),
    },
    {
      id: 'connections',
      title: 'Connections',
      summary: [jellyfinUrl ? 'Jellyfin connected' : 'Jellyfin not set', anthKeySet ? 'Anthropic key set' : 'Anthropic key missing', jevKeySet ? 'TypeSafe key set' : 'TypeSafe key missing', omdbKeySet ? 'OMDb key set' : 'OMDb optional'].join(' · '),
      attention: !anthKeySet,
      body: (
        <div className="space-y-6">
          <div>
            <div className="mb-3 text-[12px] font-semibold text-mute">Jellyfin</div>
            <JellyfinConnectForm loadExisting />
          </div>
          <div className="space-y-4 border-t border-line pt-5">
            <ApiKeyForm label="Anthropic API key" placeholder="sk-ant-…" helpText="Required for auto-tagging." isSet={anthKeySet} onSave={onSaveAnthKey} />
            <ApiKeyForm label="OMDb API key" placeholder="omdb api key" helpText="Optional: IMDb, Rotten Tomatoes and Metacritic scores, plus awards." isSet={omdbKeySet} onSave={onSaveOmdbKey} />
            <div>
              <ApiKeyForm label="TypeSafe API key" placeholder="typesafe api key" helpText="For Jev, the grader: one question per mood on every film, about $0.001 per film. Keys at console.typesafe.ai." isSet={jevKeySet} onSave={async (key) => { await onSaveJevKey(key); setJevTest(null); }} />
              {jevKeySet && (
                <div className="mt-2 flex flex-wrap items-center gap-3">
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={jevTest === 'running'}
                    onClick={async () => {
                      setJevTest('running');
                      try {
                        setJevTest(await onTestJev());
                      } catch (e) {
                        setJevTest({ ok: false, error: e instanceof Error ? e.message : 'The test failed' });
                      }
                    }}
                  >
                    {jevTest === 'running' ? 'Testing…' : 'Test the key'}
                  </Button>
                  {jevTest && jevTest !== 'running' && (
                    <span className={cn('text-[12.5px]', jevTest.ok ? 'text-good' : 'text-bad')}>{jevTest.ok ? `Jev ${jevTest.model ?? ''} answered ${jevTest.answered ?? 0} questions.` : jevTest.error ?? 'The test failed'}</span>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>
      ),
    },
    {
      id: 'sources',
      title: 'Story sources',
      summary: sum ? `${sum.english_plot ?? 0} English plots · ${sum.no_plot ?? 0} no plot · ${sum.unresolved ?? 0} unresolved${(sum.error ?? 0) > 0 ? ` · ${sum.error} errors` : ''}` : 'Not fetched yet',
      body: <EnrichmentCoverageCard summary={enrichmentSummary} status={coverageStatus} otherRunActive={backfillRunning} onStart={onStartCoverage} onCancel={onCancelCoverage} onOpenMovie={onOpenMovie} movieLookup={movieLookup} />,
    },
    { id: 'link', title: 'Link app', summary: 'QR code for the iPhone onboarding', body: <LinkAppPanel /> },
    {
      id: 'data',
      title: 'Data',
      summary: `${movieCount} films · ${lastSyncLabel.toLowerCase()}`,
      body: (
        <div className="space-y-5">
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
          <Row title="Sync library" help={`Pull the latest films from Jellyfin. ${movieCount} in the local catalog.`}>
            <Button variant="primary" onClick={onSync} disabled={syncing}>
              {syncing ? 'Syncing…' : 'Sync now'}
            </Button>
          </Row>
          <Row title="Backups" help="Your mood tags as JSON. Import replaces the tags of the films it names.">
            <span className="flex gap-2">
              <Button variant="outline" onClick={() => importRef.current?.click()}>
                Import
              </Button>
              <Button variant="outline" onClick={() => void onExportTags()}>
                Export
              </Button>
            </span>
          </Row>
          <Row title="Clear local films" help="Deletes the local catalog and every tag row, and resets usage counts. Jellyfin and the story sources are untouched.">
            <Button
              variant="danger"
              onClick={async () => {
                if (!confirm('Delete all films from Nocturne (not Jellyfin) and every tag row?')) return;
                await onClearMovies();
              }}
            >
              Clear…
            </Button>
          </Row>
        </div>
      ),
    },
    { id: 'about', title: 'About', summary: version ? `NocturneServer ${version}` : 'NocturneServer', body: <p className="text-[13.5px] text-mute">The mood layer for Jellyfin. Story sources from Wikipedia, moods from AI, your decisions as the ground truth.</p> },
  ];

  return (
    <div className="mx-auto w-full max-w-[1080px] px-4 pb-28 pt-6 sm:px-8 sm:pt-10">
      <h1 className="rise text-[30px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">Settings</h1>
      <div className="mt-8 grid gap-10 lg:grid-cols-[188px_minmax(0,1fr)]">
        <aside className="hidden lg:block">
          <nav className="sticky top-32">
            <div className="mb-2.5 ml-3 text-[11px] font-semibold tracking-[.02em] text-faint">SECTIONS</div>
            {sections.map((s) => (
              <button key={s.id} type="button" onClick={() => jump(s.id)} className={cn('block w-full rounded-full px-3 py-2 text-left text-[13.5px] font-medium cursor-pointer', open.has(s.id) ? 'bg-canvas text-ink' : 'text-mute hover:text-ink')}>
                {s.title}
              </button>
            ))}
          </nav>
        </aside>
        <div className="min-w-0 space-y-3.5">
          {sections.map((s) => {
            const isOpen = open.has(s.id);
            return (
              <section key={s.id} id={`s-${s.id}`} className="scroll-mt-32 rounded-[24px] bg-white shadow-card">
                <button type="button" onClick={() => toggle(s.id)} aria-expanded={isOpen} className="flex w-full items-center justify-between gap-4 px-5 py-5 text-left sm:px-7 cursor-pointer">
                  <span className="min-w-0">
                    <span className="block text-[17px] font-semibold tracking-[-0.02em] text-ink">{s.title}</span>
                    <span className={cn('mt-1 block truncate text-[13.5px]', s.attention ? 'text-bad' : 'text-mute')}>{s.summary}</span>
                  </span>
                  <ChevronDown size={18} className={cn('shrink-0 text-mute transition-transform duration-300', isOpen && 'rotate-180')} />
                </button>
                {isOpen && <div className="px-5 pb-6 sm:px-7">{s.body}</div>}
              </section>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// A collapsed block under a row title: the floors table, the guide editor.
function Details({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <details className="group border-t border-line pt-4">
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 [&::-webkit-details-marker]:hidden">
        <span className="min-w-0">
          <span className="block text-[14px] font-semibold text-ink">{label}</span>
          {hint && <span className="mt-1 block text-[13px] leading-snug text-mute">{hint}</span>}
        </span>
        <ChevronDown size={16} className="shrink-0 text-mute transition-transform duration-300 group-open:rotate-180" />
      </summary>
      <div className="mt-4">{children}</div>
    </details>
  );
}

function Row({ title, help, children, below }: { title: string; help: string; children: ReactNode; below?: ReactNode }) {
  return (
    <div className="border-t border-line pt-4 first:border-t-0 first:pt-0">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="text-[14px] font-semibold text-ink">{title}</div>
          <p className="mt-1 text-[13px] leading-snug text-mute">{help}</p>
          {below && <div className="mt-2.5">{below}</div>}
        </div>
        <div className="shrink-0">{children}</div>
      </div>
    </div>
  );
}
