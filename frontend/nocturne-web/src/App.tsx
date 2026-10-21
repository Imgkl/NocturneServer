import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { FolderSearch, QrCode, RefreshCw, Settings as SettingsIcon, Sparkles } from 'lucide-react';
import { api, ApiError, fetchVersion as fetchVersionApi } from './lib/api';
import { timeAgo } from './lib/enrichment';
import { goTo, useHashPage } from './lib/useHashPage';
import type {
  BackfillScope,
  BackfillStatusApi,
  CoverageStatus,
  EnrichmentSummary,
  ModelSettings as ModelSettingsApi,
  ModelSettingsUpdate,
  MoodBuckets,
  Movie,
  OnboardingStatus,
  TagSuggestionApi,
} from './lib/types';
import { AppHeader, type MenuItem } from './components/Header';
import { CommandPalette } from './components/CommandPalette';
import { FilmModal } from './components/FilmModal';
import { LinkAppPanel } from './components/LinkAppPanel';
import { LibraryPage, type LibraryFilter, type LibrarySort } from './views/LibraryPage';
import { ReviewPage } from './views/ReviewPage';
import { SettingsPage } from './views/SettingsPage';
import { OnboardingView } from './views/onboarding/OnboardingView';
import { Dialog } from './ui/Dialog';
import { Spinner } from './ui/Spinner';
import { Toast, useToast } from './ui/Toast';

export default function App() {
  const page = useHashPage();
  const { toast, say } = useToast();

  const [onboardingStatus, setOnboardingStatus] = useState<OnboardingStatus | null>(null);
  const [bootstrapping, setBootstrapping] = useState(true);
  const [movies, setMovies] = useState<Movie[]>([]);
  const [loading, setLoading] = useState(false);
  const [moods, setMoods] = useState<MoodBuckets>({});
  const [selectedMood, setSelectedMood] = useState('');
  const [filters, setFilters] = useState<LibraryFilter[]>([]);
  const [sort, setSort] = useState<LibrarySort>(() => (localStorage.getItem('nocturne.sort') as LibrarySort) || 'az');
  useEffect(() => localStorage.setItem('nocturne.sort', sort), [sort]);
  const [pendingSuggestions, setPendingSuggestions] = useState<TagSuggestionApi[]>([]);
  const [version, setVersion] = useState('');
  const [anthKeySet, setAnthKeySet] = useState(false);
  const [omdbKeySet, setOmdbKeySet] = useState(false);
  const [autoTagEnabled, setAutoTagEnabled] = useState(false);
  const [jellyfinUrl, setJellyfinUrl] = useState<string | undefined>(undefined);
  const [lastSyncAt, setLastSyncAt] = useState<string | undefined>(undefined);
  const [syncActive, setSyncActive] = useState(false);
  const syncTimerRef = useRef<number | null>(null);
  const syncStartTsRef = useRef<number | null>(null);
  const [backfillStatus, setBackfillStatus] = useState<BackfillStatusApi | null>(null);
  const backfillPollRef = useRef<number | null>(null);
  const [coverageStatus, setCoverageStatus] = useState<CoverageStatus | null>(null);
  const coveragePollRef = useRef<number | null>(null);
  const [enrichmentSummary, setEnrichmentSummary] = useState<EnrichmentSummary | null>(null);
  const [modelSettings, setModelSettings] = useState<ModelSettingsApi | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [linkOpen, setLinkOpen] = useState(false);
  const [openFilm, setOpenFilm] = useState<{ id: string; list: string[] } | null>(null);

  // ---- data ------------------------------------------------------------------------------

  async function fetchMoods() {
    const data = await api.moods.list();
    setMoods(data.moods);
  }

  const fetchAllMovies = useCallback(async () => {
    setLoading(true);
    try {
      const data = await api.movies.listAll();
      setMovies(
        data.items.map((it) => ({
          jellyfinId: it.jellyfinId,
          title: it.title,
          year: it.year,
          posterUrl: it.posterUrl,
          needsReview: it.needsReview,
          played: it.played,
          tags: it.tags.map((slug) => ({ slug, title: slug })),
        })),
      );
    } catch (error) {
      console.error('Failed to fetch movies:', error);
    } finally {
      setLoading(false);
    }
  }, []);

  async function fetchPendingSuggestions() {
    try {
      const resp = await api.suggestions.listPending();
      setPendingSuggestions(resp.items);
    } catch (e) {
      console.error('Failed to fetch pending suggestions:', e);
    }
  }

  async function fetchSettingsInfo() {
    try {
      const info = await api.settings.info();
      setAnthKeySet(!!info.anthropic_key_set);
      setOmdbKeySet(!!info.omdb_key_set);
      setAutoTagEnabled(!!info.enable_auto_tagging);
      setJellyfinUrl(info.jellyfin_url || undefined);
    } catch {
      // the page still renders
    }
  }

  async function fetchModelSettings() {
    try {
      const settings = await api.settings.models();
      setModelSettings(settings);
      setEnrichmentSummary(settings.enrichment);
    } catch (e) {
      console.error('Failed to fetch model settings:', e);
    }
  }

  async function fetchEnrichmentSummary() {
    try {
      setEnrichmentSummary(await api.enrichment.summary());
    } catch {
      // optional
    }
  }

  async function fetchSyncStamp() {
    try {
      const s = await api.sync.status();
      if (s.lastSyncAt) setLastSyncAt(s.lastSyncAt);
    } catch {
      // optional
    }
  }

  async function bootstrap() {
    try {
      const status = await api.onboarding.status();
      setOnboardingStatus(status);
      if (status.configured) {
        await Promise.all([fetchMoods(), fetchAllMovies(), fetchVersionApi().then((v) => v && setVersion(v)), fetchPendingSuggestions(), fetchSettingsInfo(), fetchModelSettings(), fetchSyncStamp()]);
      } else {
        await Promise.all([fetchMoods(), fetchVersionApi().then((v) => v && setVersion(v))]);
      }
    } catch (e) {
      console.error('Bootstrap failed', e);
    } finally {
      setBootstrapping(false);
    }
  }

  useEffect(() => {
    void bootstrap();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (page === 'settings') {
      void fetchSettingsInfo();
      void fetchModelSettings();
    }
    if (page === 'review') void fetchPendingSuggestions();
  }, [page]);

  // ---- sync ------------------------------------------------------------------------------

  async function pollSyncStatusOnce() {
    try {
      const status = await api.sync.status();
      const startedAt = syncStartTsRef.current || 0;
      const withinGrace = Date.now() - startedAt < 12000;
      setSyncActive(status.isRunning || withinGrace);
      if (!status.isRunning && !withinGrace) {
        if (status.lastSyncAt) setLastSyncAt(status.lastSyncAt);
        await fetchAllMovies();
        await fetchPendingSuggestions();
        say(`Synced · ${status.moviesFound} films`);
        return;
      }
    } catch {
      // keep polling on transient errors
    }
    syncTimerRef.current = window.setTimeout(pollSyncStatusOnce, 1000);
  }

  function syncAll() {
    setSyncActive(true);
    syncStartTsRef.current = Date.now();
    api.sync.trigger();
    if (syncTimerRef.current) window.clearTimeout(syncTimerRef.current);
    void pollSyncStatusOnce();
  }

  // ---- runs ------------------------------------------------------------------------------

  function schedulePollBackfill() {
    if (backfillPollRef.current) window.clearTimeout(backfillPollRef.current);
    backfillPollRef.current = window.setTimeout(pollBackfillOnce, 3000);
  }

  async function pollBackfillOnce() {
    try {
      const status = await api.backfill.status();
      setBackfillStatus(status);
      await fetchAllMovies();
      await fetchPendingSuggestions();
      if (status.running) schedulePollBackfill();
      else say(status.cancelled ? 'Auto-tagging stopped' : `Auto-tagging done · ${status.processed} films`);
    } catch {
      schedulePollBackfill();
    }
  }

  async function startBackfill(scope: BackfillScope) {
    try {
      const status = await api.backfill.start(scope);
      setBackfillStatus(status);
      schedulePollBackfill();
      say(`Auto-tagging ${status.total} ${scope === 'all' ? '' : scope + ' '}films`);
    } catch (e) {
      say(e instanceof ApiError && e.status === 409 ? 'Another run is in progress' : 'Failed to start auto-tagging. Check the Anthropic key.', 'error');
    }
  }

  async function startReprocessAll(scope: BackfillScope) {
    try {
      const status = await api.backfill.reprocessAll(scope);
      setBackfillStatus(status);
      schedulePollBackfill();
      say(`Re-tagging ${status.total} films`);
    } catch (e) {
      say(e instanceof ApiError && e.status === 409 ? 'Another run is in progress' : 'Failed to start. Check the Anthropic key.', 'error');
    }
  }

  async function cancelBackfill() {
    if (!confirm('Stop the auto-tagger? The current film will finish, but no more will be processed.')) return;
    try {
      setBackfillStatus(await api.backfill.cancel());
    } catch {
      say('Failed to cancel', 'error');
    }
  }

  function schedulePollCoverage() {
    if (coveragePollRef.current) window.clearTimeout(coveragePollRef.current);
    coveragePollRef.current = window.setTimeout(pollCoverageOnce, 2000);
  }

  async function pollCoverageOnce() {
    try {
      const status = await api.enrichment.coverageStatus();
      setCoverageStatus(status);
      if (status.running) schedulePollCoverage();
      else {
        await fetchEnrichmentSummary();
        say(status.status === 'cancelled' ? 'Coverage run stopped' : `Story sources done · ${status.processed} films`);
      }
    } catch {
      schedulePollCoverage();
    }
  }

  async function startCoverage() {
    try {
      const status = await api.enrichment.coverageStart();
      setCoverageStatus(status);
      schedulePollCoverage();
      say(`Fetching story sources for ${status.total} films`);
    } catch (e) {
      const msg = e instanceof ApiError && e.status === 409 ? 'Another run is in progress' : 'Failed to start the coverage run';
      say(msg, 'error');
      throw new Error(msg);
    }
  }

  async function cancelCoverage() {
    if (!confirm('Stop the coverage run? The current film will finish, but no more will be fetched.')) return;
    try {
      setCoverageStatus(await api.enrichment.coverageCancel());
    } catch {
      say('Failed to cancel', 'error');
    }
  }

  // Pick up runs still going from a previous session.
  useEffect(() => {
    (async () => {
      try {
        const status = await api.backfill.status();
        if (status.running) {
          setBackfillStatus(status);
          schedulePollBackfill();
        }
      } catch {
        // none
      }
      try {
        const coverage = await api.enrichment.coverageStatus();
        if (coverage.running) {
          setCoverageStatus(coverage);
          schedulePollCoverage();
        }
      } catch {
        // none
      }
    })();
    return () => {
      if (backfillPollRef.current) window.clearTimeout(backfillPollRef.current);
      if (coveragePollRef.current) window.clearTimeout(coveragePollRef.current);
      if (syncTimerRef.current) window.clearTimeout(syncTimerRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---- tags and review ---------------------------------------------------------------------

  const moviesById = useMemo(() => {
    const map = new Map<string, Movie>();
    movies.forEach((m) => map.set(m.jellyfinId, m));
    return map;
  }, [movies]);

  async function saveTags(movie: Movie, selectedTags: string[]) {
    try {
      await api.movies.updateTags(movie.jellyfinId, selectedTags, true);
      await Promise.all([fetchAllMovies(), fetchPendingSuggestions()]);
      say(`Saved · ${movie.title}`);
    } catch {
      say('Failed to save tags', 'error');
    }
  }

  async function retag(movie: Movie) {
    try {
      await api.movies.autoTag(movie.jellyfinId);
      await Promise.all([fetchAllMovies(), fetchPendingSuggestions()]);
      say(`The reader has an answer for ${movie.title}`);
    } catch (e) {
      say(e instanceof Error ? e.message : 'The reader failed', 'error');
    }
  }

  async function approveSuggestion(id: string, overrideTags?: string[]) {
    const s = pendingSuggestions.find((x) => x.id === id);
    try {
      await api.suggestions.approve(id, overrideTags);
      await Promise.all([fetchPendingSuggestions(), fetchAllMovies()]);
      say(`Approved${s ? ` · ${moviesById.get(s.jellyfinId)?.title ?? ''}` : ''}`);
    } catch {
      say('Failed to approve', 'error');
    }
  }

  async function rejectSuggestion(id: string) {
    try {
      await api.suggestions.reject(id);
      await Promise.all([fetchPendingSuggestions(), fetchAllMovies()]);
      say('Rejected');
    } catch {
      say('Failed to reject', 'error');
    }
  }

  // ---- settings ------------------------------------------------------------------------------

  async function saveModels(update: ModelSettingsUpdate) {
    const settings = await api.settings.saveModels(update);
    setModelSettings(settings);
    setEnrichmentSummary(settings.enrichment);
    say('Settings saved');
  }

  async function saveAnthropicKey(key: string) {
    try {
      await api.settings.saveAnthropicKey(key);
      setAnthKeySet(true);
      say('Anthropic key saved');
    } catch {
      say('Failed to save the key', 'error');
    }
  }

  async function saveOmdbKey(key: string) {
    try {
      await api.settings.saveOmdbKey(key);
      setOmdbKeySet(true);
      say('OMDb key saved');
    } catch {
      say('Failed to save the key', 'error');
    }
  }

  async function toggleAutoTagging(next: boolean) {
    const prev = autoTagEnabled;
    setAutoTagEnabled(next);
    try {
      await api.settings.setAutoTagging(next);
    } catch {
      setAutoTagEnabled(prev);
      say('Failed to update the setting', 'error');
    }
  }

  async function exportTags() {
    try {
      const data = await api.data.export();
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'nocturne-tags.json';
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch {
      say('Failed to export', 'error');
    }
  }

  async function importTagsFile(file: File) {
    try {
      const map = JSON.parse(await file.text());
      const keys = Object.keys(map || {});
      const batchSize = 10;
      let success = 0;
      let fail = 0;
      say(`Importing ${keys.length} films…`);
      for (let i = 0; i < keys.length; i += batchSize) {
        const chunkKeys = keys.slice(i, i + batchSize);
        const chunk: Record<string, unknown> = {};
        for (const k of chunkKeys) chunk[k] = map[k];
        try {
          await api.data.import(chunk, true);
          success += chunkKeys.length;
        } catch {
          fail += chunkKeys.length;
        }
      }
      await fetchAllMovies();
      say(`Imported ${success} films${fail ? `, ${fail} failed` : ''}`, fail ? 'error' : 'ok');
    } catch {
      say('Import failed: not a valid JSON export', 'error');
    }
  }

  async function clearMovies() {
    try {
      await api.settings.clearMovies();
      await Promise.all([fetchAllMovies(), fetchPendingSuggestions()]);
      say('Local films cleared');
    } catch {
      say('Failed to clear films', 'error');
    }
  }

  // ---- derived --------------------------------------------------------------------------------

  const moviesWithTitles = useMemo(() => movies.map((m) => ({ ...m, tags: (m.tags || []).map((t) => ({ slug: t.slug, title: moods[t.slug]?.title || t.slug })) })), [movies, moods]);
  const lookup = useCallback((id: string) => moviesById.get(id), [moviesById]);

  const running = syncActive || backfillStatus?.running === true || coverageStatus?.running === true;
  const syncLabel = syncActive
    ? 'Syncing'
    : backfillStatus?.running
      ? `Auto-tagging ${backfillStatus.processed} of ${backfillStatus.total}`
      : coverageStatus?.running
        ? `Story sources ${coverageStatus.processed} of ${coverageStatus.total}`
        : lastSyncAt
          ? `Synced ${timeAgo(lastSyncAt) ?? ''}`
          : 'Never synced';

  const menu: MenuItem[] = [
    { icon: <RefreshCw size={15} />, label: 'Sync library', disabled: running, reason: 'A run is in progress', onClick: syncAll },
    { icon: <FolderSearch size={15} />, label: 'Run coverage', hint: 'free', disabled: running, reason: 'A run is in progress', onClick: () => void startCoverage().catch(() => {}) },
    { icon: <Sparkles size={15} />, label: 'Start auto-tag…', disabled: !anthKeySet, reason: 'Needs an Anthropic key', onClick: () => goTo('settings') },
    { icon: <QrCode size={15} />, label: 'Link Nocturne app', onClick: () => setLinkOpen(true) },
    { icon: <SettingsIcon size={15} />, label: 'Settings', onClick: () => goTo('settings') },
  ];

  const film = openFilm ? (moviesWithTitles.find((m) => m.jellyfinId === openFilm.id) ?? null) : null;
  const filmIndex = openFilm ? openFilm.list.indexOf(openFilm.id) : -1;
  const openMovieIn = (movie: Movie, list: Movie[]) => setOpenFilm({ id: movie.jellyfinId, list: list.map((m) => m.jellyfinId) });
  const step = (dir: 1 | -1) => {
    if (!openFilm || filmIndex < 0) return;
    const next = openFilm.list[filmIndex + dir];
    if (next) setOpenFilm({ id: next, list: openFilm.list });
  };

  // ---- render ---------------------------------------------------------------------------------

  if (bootstrapping) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-white">
        <Spinner size={20} className="text-mute" />
      </div>
    );
  }

  if (!onboardingStatus?.configured) {
    return <OnboardingView onFinished={() => void bootstrap()} />;
  }

  return (
    <div className="min-h-screen bg-white text-ink">
      <AppHeader page={page} syncLabel={syncLabel} running={running} onSync={syncAll} menu={menu} reviewCount={pendingSuggestions.length} onSearch={() => setPaletteOpen(true)} />

      {page === '' && (
        <LibraryPage
          movies={moviesWithTitles}
          moods={moods}
          selectedMood={selectedMood}
          onMoodChange={(slug) => setSelectedMood((cur) => (cur === slug ? '' : slug))}
          filters={filters}
          onFiltersChange={setFilters}
          sort={sort}
          onSortChange={setSort}
          onOpenMovie={openMovieIn}
          loading={loading}
        />
      )}
      {page === 'review' && (
        <ReviewPage
          suggestions={pendingSuggestions}
          movieLookup={lookup}
          moods={moods}
          onApprove={approveSuggestion}
          onReject={rejectSuggestion}
          onOpenMovie={(m) => openMovieIn(m, pendingSuggestions.map((s) => moviesById.get(s.jellyfinId)).filter((x): x is Movie => !!x))}
          onRefresh={fetchPendingSuggestions}
        />
      )}
      {page === 'settings' && (
        <SettingsPage
          movieCount={movies.length}
          untaggedCount={movies.filter((m) => !(m.tags || []).length && !m.needsReview).length}
          untaggedWatchedCount={movies.filter((m) => !(m.tags || []).length && !m.needsReview && m.played).length}
          reviewCount={pendingSuggestions.length}
          backfillStatus={backfillStatus}
          coverageStatus={coverageStatus}
          enrichmentSummary={enrichmentSummary}
          modelSettings={modelSettings}
          anthKeySet={anthKeySet}
          omdbKeySet={omdbKeySet}
          jellyfinUrl={jellyfinUrl}
          autoTagEnabled={autoTagEnabled}
          syncing={syncActive}
          lastSyncLabel={lastSyncAt ? `Synced ${timeAgo(lastSyncAt) ?? ''}` : 'Never synced'}
          version={version}
          onSync={syncAll}
          onStartBackfill={startBackfill}
          onCancelBackfill={cancelBackfill}
          onReprocessAll={startReprocessAll}
          onStartCoverage={startCoverage}
          onCancelCoverage={cancelCoverage}
          onSaveModels={saveModels}
          onOpenMovie={(id) => {
            const m = moviesById.get(id);
            if (m) openMovieIn(m, [m]);
          }}
          movieLookup={lookup}
          onSaveAnthKey={saveAnthropicKey}
          onSaveOmdbKey={saveOmdbKey}
          onToggleAutoTag={toggleAutoTagging}
          onClearMovies={clearMovies}
          onImportFile={importTagsFile}
          onExportTags={exportTags}
        />
      )}

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        movies={moviesWithTitles}
        moods={moods}
        onPickMovie={(m) => openMovieIn(m, moviesWithTitles)}
        onPickMood={(slug) => {
          setSelectedMood(slug);
          goTo('');
        }}
      />

      <FilmModal
        movie={film}
        moods={moods}
        position={film ? { index: Math.max(0, filmIndex), total: openFilm?.list.length ?? 1 } : undefined}
        suggestion={film ? pendingSuggestions.find((s) => s.jellyfinId === film.jellyfinId) : undefined}
        jellyfinUrl={jellyfinUrl}
        onClose={() => setOpenFilm(null)}
        onPrev={filmIndex > 0 ? () => step(-1) : undefined}
        onNext={openFilm && filmIndex >= 0 && filmIndex < openFilm.list.length - 1 ? () => step(1) : undefined}
        onSaveTags={saveTags}
        onRetag={retag}
      />

      <Dialog open={linkOpen} onClose={() => setLinkOpen(false)} title="Link Nocturne app" sub="Scan from the iPhone onboarding, step 04." size="md">
        <LinkAppPanel />
      </Dialog>

      <Toast toast={toast} />
    </div>
  );
}
