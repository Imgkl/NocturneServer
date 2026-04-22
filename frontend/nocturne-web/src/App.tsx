import { useEffect, useMemo, useRef, useState } from 'react';
import { api, fetchVersion as fetchVersionApi } from './lib/api';
import type {
  BackfillStatusApi,
  ImportProgress,
  MoodBuckets,
  Movie,
  OnboardingStatus,
  TagSuggestionApi,
} from './lib/types';
import { Sidebar } from './components/Sidebar';
import { MobileHeader } from './components/MobileHeader';
import { LibraryView } from './views/LibraryView';
import { MovieDetailPanel } from './components/MovieDetailPanel';
import { AutoTagQueue } from './components/AutoTagQueue';
import { BackfillProgress } from './components/BackfillProgress';
import { SettingsView } from './views/SettingsView';
import { OnboardingView } from './views/onboarding/OnboardingView';
import { Spinner } from './ui/Spinner';

export default function App() {
  const [onboardingStatus, setOnboardingStatus] = useState<OnboardingStatus | null>(null)
  const [bootstrapping, setBootstrapping] = useState(true)
  const [movies, setMovies] = useState<Movie[]>([])
  const [loading, setLoading] = useState(false)
  const [q, setQ] = useState('')
  const [mood, setMood] = useState('')
  const [moods, setMoods] = useState<MoodBuckets>({})
  const [editingMovie, setEditingMovie] = useState<Movie | null>(null)
  const [autoTaggerOpen, setAutoTaggerOpen] = useState(false)
  const [pendingSuggestions, setPendingSuggestions] = useState<TagSuggestionApi[]>([])
  const [autoQueue, setAutoQueue] = useState<string[]>([])
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [syncActive, setSyncActive] = useState(false)
  const syncTimerRef = useRef<number | null>(null)
  const syncStartTsRef = useRef<number | null>(null)
  const [importProg, setImportProg] = useState<ImportProgress | null>(null)
  // Removed old batch tagging flow to simplify UI
  const [version, setVersion] = useState<string>("")
  const [anthKeySet, setAnthKeySet] = useState(false)
  const [omdbKeySet, setOmdbKeySet] = useState(false)
  const [autoTagEnabled, setAutoTagEnabled] = useState(false)
  const [viewMode, setViewMode] = useState<'tile' | 'list'>(() => {
    const stored = typeof window !== 'undefined' ? window.localStorage.getItem('nocturne.viewMode') : null
    return stored === 'list' ? 'list' : 'tile'
  })
  useEffect(() => {
    if (typeof window !== 'undefined') window.localStorage.setItem('nocturne.viewMode', viewMode)
  }, [viewMode])
  const [backfillStatus, setBackfillStatus] = useState<BackfillStatusApi | null>(null)
  const backfillPollRef = useRef<number | null>(null)

  // Per-row edited tag sets for the pending-review list. Undefined = use original suggestion.
  const [editedPendingTags, setEditedPendingTags] = useState<Record<string, string[]>>({})
  const [pendingPickerId, setPendingPickerId] = useState<string | null>(null)

  async function bootstrap() {
    try {
      const status = await api.onboarding.status()
      setOnboardingStatus(status)
      if (status.configured) {
        await Promise.all([fetchMoods(), fetchAllMovies(), fetchVersion(), fetchPendingSuggestions()])
      } else {
        // Still fetch mood taxonomy + version so the wizard has them if needed
        await Promise.all([fetchMoods(), fetchVersion()])
      }
    } catch (e) {
      console.error('Bootstrap failed', e)
    } finally {
      setBootstrapping(false)
    }
  }

  useEffect(() => { bootstrap() }, [])

  async function fetchSettingsInfo() {
    try {
      const info = await api.settings.info()
      setAnthKeySet(!!info.anthropic_key_set)
      setOmdbKeySet(!!info.omdb_key_set)
      setAutoTagEnabled(!!info.enable_auto_tagging)
    } catch {}
  }

  useEffect(() => { if (settingsOpen) fetchSettingsInfo() }, [settingsOpen])

  async function fetchMoods() {
    const data = await api.moods.list()
    setMoods(data.moods)
  }

  async function fetchAllMovies() {
    setLoading(true)
    try {
      // Admin proxy: live Jellyfin fetch enriched with local tags + needs-review flag.
      const data = await api.movies.listAll()
      const mapped: Movie[] = data.items.map(it => ({
        jellyfinId: it.jellyfinId,
        title: it.title,
        year: it.year,
        posterUrl: it.posterUrl,
        needsReview: it.needsReview,
        tags: it.tags.map(slug => ({ slug, title: moods[slug]?.title || slug })),
      }))
      setMovies(mapped)
    } catch (error) {
      console.error('Failed to fetch movies:', error)
    } finally {
      setLoading(false)
    }
  }

  async function fetchVersion() {
    const v = await fetchVersionApi()
    if (v) setVersion(v)
  }

  async function pollSyncStatusOnce() {
    try {
      const status = await api.sync.status();
      // setSyncStatus(status);

      const startedAt = syncStartTsRef.current || 0;
      const withinGrace = Date.now() - startedAt < 12000; // 12s grace

      // Drive visibility directly from status/grace
      setSyncActive(status.isRunning || withinGrace);

      if (!status.isRunning && !withinGrace) {
        setLoading(false);
        if (syncTimerRef.current) {
          window.clearTimeout(syncTimerRef.current);
          syncTimerRef.current = null;
        }
        await fetchAllMovies();
        return;
      }
    } catch {
      // keep polling on transient errors
    }
    // schedule next tick
    syncTimerRef.current = window.setTimeout(pollSyncStatusOnce, 1000);
  }

  async function syncAll() {
    try {
      setSyncActive(true)
      syncStartTsRef.current = Date.now()
      // fire-and-forget start; show banner immediately and poll
      api.sync.trigger()
      if (syncTimerRef.current) window.clearTimeout(syncTimerRef.current)
      pollSyncStatusOnce()
    } catch (error) {
      console.error('Failed to sync:', error)
      setSyncActive(false)
    }
  }

  async function saveTags(movie: Movie, selectedTags: string[]) {
    try {
      await api.movies.updateTags(movie.jellyfinId, selectedTags, true)
      await fetchAllMovies()
      setEditingMovie(null)
    } catch (error: any) {
      console.error('Failed to save tags:', error)
      alert('Failed to save tags. Please try again.')
    }
  }

  async function removeTag(movie: Movie, tagSlug: string) {
    try {
      const remainingTags = (movie.tags || []).filter(t => t.slug !== tagSlug).map(t => t.slug)
      await api.movies.updateTags(movie.jellyfinId, remainingTags, true)
      await fetchAllMovies()
    } catch (error: any) {
      console.error('Failed to remove tag:', error)
      alert('Failed to remove tag. Please try again.')
    }
  }

  async function fetchPendingSuggestions() {
    try {
      const resp = await api.suggestions.listPending()
      setPendingSuggestions(resp.items)
    } catch (e) {
      console.error('Failed to fetch pending suggestions:', e)
    }
  }

  async function approveSuggestion(id: string, overrideTags?: string[]) {
    try {
      await api.suggestions.approve(id, overrideTags)
      setEditedPendingTags(prev => {
        const { [id]: _removed, ...rest } = prev
        return rest
      })
      await fetchPendingSuggestions()
      await fetchAllMovies()
    } catch (e) {
      console.error('Failed to approve:', e)
      alert('Failed to approve suggestion')
    }
  }

  async function rejectSuggestion(id: string) {
    try {
      await api.suggestions.reject(id)
      setEditedPendingTags(prev => {
        const { [id]: _removed, ...rest } = prev
        return rest
      })
      await fetchPendingSuggestions()
    } catch (e) {
      console.error('Failed to reject:', e)
      alert('Failed to reject suggestion')
    }
  }

  // NOTE: Batch tagging action removed in this version

  async function exportTags() {
    try {
      const data = await api.data.export()
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = 'nocturne-tags.json'
      document.body.appendChild(a)
      a.click()
      a.remove()
      URL.revokeObjectURL(url)
    } catch (e) {
      alert('Failed to export tags')
    }
  }

  async function importTagsFile(file: File) {
    try {
      // Close settings so the unified progress banner is visible
      setSettingsOpen(false)
      const text = await file.text()
      const map = JSON.parse(text)
      const keys = Object.keys(map || {})
      const total = keys.length
      const batchSize = 10
      let processed = 0
      let success = 0
      let fail = 0
      setImportProg({ total, processed, success, fail, running: true })
      for (let i = 0; i < keys.length; i += batchSize) {
        const chunkKeys = keys.slice(i, i + batchSize)
        const chunk: Record<string, any> = {}
        for (const k of chunkKeys) chunk[k] = map[k]
        try {
          await api.data.import(chunk, true)
          success += chunkKeys.length
        } catch {
          fail += chunkKeys.length
        }
        processed += chunkKeys.length
        setImportProg({ total, processed, success, fail, running: true })
      }
      setImportProg(p => p ? { ...p, running: false } : { total, processed, success, fail, running: false })
      await fetchAllMovies()
      setTimeout(() => setImportProg(null), 1500)
    } catch (e) {
      setImportProg(null)
      alert('Import failed – ensure it is a valid JSON export')
    }
  }

  async function saveOpenAIKey(key: string) {
    try {
      await api.settings.saveAnthropicKey(key)
      setAnthKeySet(true)
    } catch (error) {
      console.error('Failed to save API key:', error)
      alert('Failed to save API key')
    }
  }

  async function saveOmdbKey(key: string) {
    try {
      await api.settings.saveOmdbKey(key)
      setOmdbKeySet(true)
    } catch (error) {
      console.error('Failed to save OMDb API key:', error)
      alert('Failed to save OMDb API key')
    }
  }

  async function toggleAutoTagging(next: boolean) {
    const prev = autoTagEnabled
    setAutoTagEnabled(next)
    try {
      await api.settings.setAutoTagging(next)
    } catch (error) {
      console.error('Failed to toggle auto-tagging:', error)
      setAutoTagEnabled(prev)
      alert('Failed to update auto-tagging setting')
    }
  }

  async function startBackfill() {
    try {
      const status = await api.backfill.start()
      setBackfillStatus(status)
      schedulePollBackfill()
    } catch (error) {
      console.error('Failed to start backfill:', error)
      alert('Failed to start auto-tag backfill. Check that the Anthropic API key is set.')
    }
  }

  async function startReprocessAll() {
    try {
      const status = await api.backfill.reprocessAll()
      setBackfillStatus(status)
      schedulePollBackfill()
    } catch (error) {
      console.error('Failed to start reprocess-all:', error)
      alert('Failed to start reprocess. Check that the Anthropic API key is set.')
    }
  }

  async function cancelBackfill() {
    if (!confirm('Stop the auto-tagger? The current movie will finish, but no more will be processed.')) return
    try {
      const status = await api.backfill.cancel()
      setBackfillStatus(status)
    } catch (error) {
      console.error('Failed to cancel:', error)
      alert('Failed to cancel auto-tagger.')
    }
  }

  function schedulePollBackfill() {
    if (backfillPollRef.current) window.clearTimeout(backfillPollRef.current)
    backfillPollRef.current = window.setTimeout(pollBackfillOnce, 3000)
  }

  async function pollBackfillOnce() {
    try {
      const status = await api.backfill.status()
      setBackfillStatus(status)
      if (status.running) {
        // Refresh the movie list periodically so newly-tagged rows appear without waiting for done.
        await fetchAllMovies()
        await fetchPendingSuggestions()
        schedulePollBackfill()
      } else {
        // Final refresh so the grid reflects the finished run.
        await fetchAllMovies()
        await fetchPendingSuggestions()
      }
    } catch {
      // Transient errors — keep trying until status says done.
      schedulePollBackfill()
    }
  }

  // On mount, pick up a backfill that's still running from a previous session.
  useEffect(() => {
    (async () => {
      try {
        const status = await api.backfill.status()
        if (status.running) {
          setBackfillStatus(status)
          schedulePollBackfill()
        }
      } catch {}
    })()
    return () => {
      if (backfillPollRef.current) window.clearTimeout(backfillPollRef.current)
    }
  }, [])

  const filtered = useMemo(() => {
    return movies.filter(m => (
      (!q || m.title.toLowerCase().includes(q.toLowerCase())) &&
      (!mood || (m.tags||[]).some(t => t.slug === mood))
    ))
  }, [movies, q, mood])

  const stats = useMemo(() => {
    const total = movies.length
    const tagged = movies.filter(m => (m.tags || []).length > 0).length
    const untagged = total - tagged
    return { total, tagged, untagged }
  }, [movies])

  // Needs review first, then untagged, then tagged — all alphabetical within their bucket.
  const ordered = useMemo(() => {
    const needsReview = filtered.filter(m => m.needsReview).sort((a,b)=>a.title.localeCompare(b.title))
    const rest = filtered.filter(m => !m.needsReview)
    const untagged = rest.filter(m => (m.tags||[]).length === 0).sort((a,b)=>a.title.localeCompare(b.title))
    const tagged = rest.filter(m => (m.tags||[]).length > 0).sort((a,b)=>a.title.localeCompare(b.title))
    return [...needsReview, ...untagged, ...tagged]
  }, [filtered])
  
  const moviesById = useMemo(() => {
    const map = new Map<string, Movie>();
    movies.forEach(m => map.set(m.jellyfinId, m));
    return map;
  }, [movies]);
  const moodCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    movies.forEach(m => (m.tags||[]).forEach(t => { counts[t.slug] = (counts[t.slug]||0)+1 }))
    return counts
  }, [movies])

  const pendingSuggestionsPanel = pendingSuggestions.length > 0 ? (
    <section className="px-5 lg:px-10 pt-5">
      <div className="border border-border bg-bg">
        <div className="flex items-center justify-between px-5 py-4 border-b border-border">
          <div>
            <div className="text-[11px] uppercase tracking-widest text-muted">
              Tags needing review ({pendingSuggestions.length})
            </div>
            <div className="text-[12px] text-text-dim mt-1">
              Auto-tags are live. Approve to confirm, or reject to remove.
            </div>
          </div>
          <button
            onClick={() => fetchPendingSuggestions()}
            className="text-[10px] uppercase tracking-widest text-muted hover:text-text cursor-pointer"
          >
            Refresh
          </button>
        </div>
        <div>
          {pendingSuggestions.slice(0, 8).map((s) => {
            const movie = movies.find((m) => m.jellyfinId === s.jellyfinId);
            const currentTags = editedPendingTags[s.id] ?? s.suggestedTags;
            const isEdited = editedPendingTags[s.id] !== undefined;
            const addableTags = Object.keys(moods)
              .filter((slug) => !currentTags.includes(slug))
              .sort((a, b) => (moods[a]?.title || a).localeCompare(moods[b]?.title || b));
            return (
              <div key={s.id} className="flex flex-col sm:flex-row sm:items-start gap-3 px-5 py-3 border-t border-border first:border-t-0">
                <div className="flex items-start gap-3 min-w-0 flex-1">
                  {movie?.posterUrl && (
                    <img src={movie.posterUrl} alt="" className="w-8 h-12 object-cover flex-shrink-0" />
                  )}
                  <div className="flex-1 min-w-0">
                    <div className="text-[13px] text-text truncate">{movie?.title || s.jellyfinId}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-1">
                      {currentTags.map((slug) => (
                        <span key={slug} className="inline-flex items-center gap-1 border border-border text-[10px] uppercase tracking-wider text-text-dim px-2 py-0.5">
                          {moods[slug]?.title || slug}
                          <button
                            className="text-muted hover:text-text leading-none"
                            onClick={() => setEditedPendingTags((prev) => ({ ...prev, [s.id]: currentTags.filter((t) => t !== slug) }))}
                            aria-label={`Remove ${moods[slug]?.title || slug}`}
                          >
                            ×
                          </button>
                        </span>
                      ))}
                      <div className="relative inline-block">
                        <button
                          className="text-[10px] uppercase tracking-wider px-2 py-0.5 border border-dashed border-border text-muted hover:text-text hover:border-border-hover cursor-pointer"
                          onClick={() => setPendingPickerId(pendingPickerId === s.id ? null : s.id)}
                        >
                          + Add
                        </button>
                        {pendingPickerId === s.id && addableTags.length > 0 && (
                          <div className="absolute z-20 mt-1 max-h-56 w-56 overflow-auto bg-bg border border-border py-1">
                            {addableTags.map((slug) => (
                              <button
                                key={slug}
                                className="block w-full text-left px-3 py-1.5 text-[12px] text-text hover:bg-surface cursor-pointer"
                                onClick={() => {
                                  setEditedPendingTags((prev) => ({ ...prev, [s.id]: [...currentTags, slug] }));
                                  setPendingPickerId(null);
                                }}
                              >
                                {moods[slug]?.title || slug}
                              </button>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="text-[10px] uppercase tracking-widest text-muted mt-1">
                      confidence {(s.confidence * 100).toFixed(0)}%
                      {isEdited && <span className="ml-2 text-text-dim">· edited</span>}
                    </div>
                  </div>
                </div>
                <div className="flex gap-2 sm:flex-shrink-0">
                  <button
                    className="text-[10px] uppercase tracking-widest px-3 py-1.5 bg-text text-bg hover:bg-text-dim cursor-pointer disabled:opacity-40"
                    onClick={() => approveSuggestion(s.id, isEdited ? currentTags : undefined)}
                    disabled={currentTags.length === 0}
                    title={currentTags.length === 0 ? 'Add at least one tag or reject instead' : undefined}
                  >
                    Approve
                  </button>
                  <button
                    className="text-[10px] uppercase tracking-widest px-3 py-1.5 border border-border hover:border-border-hover text-text cursor-pointer"
                    onClick={() => rejectSuggestion(s.id)}
                  >
                    Reject
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  ) : null;

  if (bootstrapping) {
    return (
      <div className="min-h-screen bg-bg flex items-center justify-center">
        <Spinner size={20} className="text-muted" />
      </div>
    );
  }

  if (!onboardingStatus?.configured) {
    return <OnboardingView onFinished={bootstrap} />;
  }

  return (
    <div className="min-h-screen bg-bg text-text font-sans">
      <MobileHeader onSettingsClick={() => setSettingsOpen(true)} />
      <div className="flex">
        <Sidebar onSettingsClick={() => setSettingsOpen(true)} version={version} />
        <div className="flex-1 min-w-0">
          <LibraryView
            movies={ordered}
            moods={moods}
            moodCounts={moodCounts}
            stats={stats}
            viewMode={viewMode}
            onViewModeChange={setViewMode}
            searchQuery={q}
            onSearchChange={setQ}
            selectedMood={mood}
            onMoodChange={setMood}
            loading={loading}
            onSync={syncAll}
            onEditMovie={setEditingMovie}
            backfillBanner={<BackfillProgress status={backfillStatus} />}
            pendingSuggestionsPanel={pendingSuggestionsPanel}
          />
        </div>
      </div>

      {/* Sync progress banner */}
      {syncActive && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-[9999]">
          <div className="flex items-center gap-3 border border-border bg-bg px-4 py-2.5 shadow-lg">
            <Spinner size={12} className="text-text" />
            <span className="text-[11px] uppercase tracking-widest text-text">Syncing Jellyfin</span>
          </div>
        </div>
      )}

      {importProg && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 w-[92%] sm:w-[640px] max-w-full border border-border bg-bg shadow-lg p-5">
          <div className="text-[11px] uppercase tracking-widest text-muted mb-3">Importing tags</div>
          <div className="text-[11px] uppercase tracking-wider text-text-dim mb-3 flex gap-4">
            <span>Total {importProg.total}</span>
            <span>Processed {importProg.processed}</span>
            <span>Success {importProg.success}</span>
            <span>Failed {importProg.fail}</span>
          </div>
          <div className="w-full h-[2px] bg-border overflow-hidden">
            <div
              className="h-full bg-text transition-all"
              style={{
                width: `${Math.min(
                  100,
                  Math.round((importProg.processed / Math.max(1, importProg.total)) * 100)
                )}%`,
              }}
            />
          </div>
          {!importProg.running && (
            <div className="mt-3 text-[10px] uppercase tracking-widest text-text-dim">Completed</div>
          )}
        </div>
      )}

      <SettingsView
        open={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        movieCount={movies.length}
        untaggedCount={movies.filter(m => (m.tags || []).length === 0 && !m.needsReview).length}
        reviewCount={pendingSuggestions.length}
        backfillStatus={backfillStatus}
        anthKeySet={anthKeySet}
        omdbKeySet={omdbKeySet}
        autoTagEnabled={autoTagEnabled}
        syncing={loading}
        version={version}
        onSync={() => { setSettingsOpen(false); syncAll(); }}
        onStartBackfill={startBackfill}
        onCancelBackfill={cancelBackfill}
        onReprocessAll={startReprocessAll}
        onSaveAnthKey={saveOpenAIKey}
        onSaveOmdbKey={saveOmdbKey}
        onToggleAutoTag={toggleAutoTagging}
        onClearMovies={async () => {
          try {
            await api.settings.clearMovies();
            setSettingsOpen(false);
            await fetchAllMovies();
          } catch {
            alert('Failed to clear movies');
          }
        }}
        onImportFile={importTagsFile}
        onExportTags={exportTags}
        onReviewUntaggedManually={() => {
          const queue = movies.filter(m => (m.tags || []).length === 0).map(m => m.jellyfinId);
          setAutoQueue(queue);
          setAutoTaggerOpen(true);
          setSettingsOpen(false);
        }}
      />

      <MovieDetailPanel
        movie={editingMovie}
        moods={moods}
        onSave={async (movie, selectedTags) => {
          await saveTags(movie, selectedTags);
        }}
        onCancel={() => setEditingMovie(null)}
      />

      <AutoTagQueue
        open={autoTaggerOpen}
        queue={autoQueue}
        movieLookup={(id) => moviesById.get(id)}
        moods={moods}
        onComplete={() => setAutoTaggerOpen(false)}
        onRefresh={async () => {
          await Promise.all([fetchAllMovies(), fetchPendingSuggestions()]);
        }}
      />


    </div>
  );
}
 
