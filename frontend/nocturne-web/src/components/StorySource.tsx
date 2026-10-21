import { useEffect, useState } from 'react';
import { Check } from 'lucide-react';
import { api } from '../lib/api';
import { WIKI_LANGUAGES, awardsSummary, isVerified, siteCode, sourceLine, timeAgo, wordCount } from '../lib/enrichment';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { Field, inputCls } from '../ui/Input';
import { Select } from '../ui/Select';
import { Toggle } from '../ui/Toggle';
import type { EnrichmentRow } from '../lib/types';

interface StorySourceProps {
  jellyfinId: string;
  title: string;
  year?: number;
}

type Busy = 'refresh' | 'override' | 'synopsis' | null;

// The film's story source: which page the plot came from, whether a human can trust it, and the
// levers to fix it (link a page, refresh, or ask the strong model to write a synopsis).
export function StorySource({ jellyfinId, title, year }: StorySourceProps) {
  const [row, setRow] = useState<EnrichmentRow | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [overrideOpen, setOverrideOpen] = useState(false);
  const [site, setSite] = useState('en');
  const [pageTitle, setPageTitle] = useState('');
  const [spoilersOpen, setSpoilersOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setRow(undefined);
    setError(null);
    setSpoilersOpen(false);
    setOverrideOpen(false);
    api.enrichment
      .get(jellyfinId)
      .then((r) => {
        if (cancelled) return;
        setRow(r);
        setSite(siteCode(r?.wikiSite));
        setPageTitle(r?.wikiTitleOverride || r?.wikiTitle || title);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setRow(null);
        setError(e instanceof Error ? e.message : 'Failed to load the story source');
      });
    return () => {
      cancelled = true;
    };
  }, [jellyfinId, title]);

  async function run(kind: Exclude<Busy, null>, action: () => Promise<EnrichmentRow>) {
    setBusy(kind);
    setError(null);
    try {
      const next = await action();
      setRow(next);
      setSite(siteCode(next.wikiSite));
      setPageTitle(next.wikiTitleOverride || next.wikiTitle || title);
      setOverrideOpen(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Request failed');
    } finally {
      setBusy(null);
    }
  }

  const generateSynopsis = () => {
    if (!confirm('Ask the strong model to write a spoiler synopsis with web search? About $0.05 to $0.10. The text is marked unverified and its moods always go to review.')) return;
    void run('synopsis', () => api.enrichment.synopsis(jellyfinId));
  };

  const loading = row === undefined;
  const plotWords = wordCount(row?.plotText);
  const fetched = timeAgo(row?.fetchedAt);
  const awards = row ? awardsSummary(row) : null;
  const canGenerate = !!row && !row.plotFound;

  return (
    <section className="rounded-[20px] bg-white p-4 shadow-card sm:p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-[14.5px] font-semibold tracking-[-0.015em] text-ink">Story source</h3>
        <div className="flex flex-wrap gap-1.5">
          {loading && <Badge tone="muted">loading</Badge>}
          {row === null && !loading && <Badge tone="muted">not fetched</Badge>}
          {row?.unverified && <Badge tone="warn">unverified source</Badge>}
          {row && !row.unverified && isVerified(row.source) && (
            <Badge tone="good">
              <Check size={11} strokeWidth={3} /> verified
            </Badge>
          )}
          {row && (row.plotFound ? <Badge>plot found</Badge> : <Badge tone="muted">no plot</Badge>)}
          {row?.error && <Badge tone="muted">error</Badge>}
        </div>
      </div>

      {!loading && (
        <>
          <p className="mt-2 text-[13.5px] text-ink">{sourceLine(row, title, year)}</p>
          <p className="mt-0.5 text-[12.5px] text-mute">
            {[fetched ? `Fetched ${fetched}` : null, awards ? `Awards: ${awards}` : null].filter(Boolean).join(' · ')}
            {row?.unverified && <span>{fetched || awards ? ' · ' : ''}Moods from this text always go to review. Link a Wikipedia page to replace it.</span>}
          </p>
          {row?.error && <p className="mt-1 break-words text-[12.5px] text-bad">{row.error}</p>}
          {error && <p className="mt-1 break-words text-[12.5px] text-bad">{error}</p>}

          <div className="mt-3 flex flex-wrap items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => setOverrideOpen((v) => !v)} disabled={busy !== null}>
              {overrideOpen ? 'Cancel' : 'Change page'}
            </Button>
            <Button variant="outline" size="sm" onClick={() => void run('refresh', () => api.enrichment.refresh(jellyfinId))} disabled={busy !== null}>
              {busy === 'refresh' ? 'Refreshing…' : 'Refresh'}
            </Button>
            {canGenerate && (
              <Button variant="outline" size="sm" onClick={generateSynopsis} disabled={busy !== null} title="Strong model with web search, about $0.05 to $0.10. Marked unverified.">
                {busy === 'synopsis' ? 'Writing…' : 'Generate synopsis'}
              </Button>
            )}
            {plotWords > 0 && (
              <label className="ml-auto inline-flex cursor-pointer items-center gap-2 text-[12.5px] font-medium text-mute">
                Show spoilers
                <Toggle active={spoilersOpen} onChange={setSpoilersOpen} label="Show spoilers" />
              </label>
            )}
          </div>

          {overrideOpen && (
            <form
              className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-[96px_1fr_auto] sm:items-end"
              onSubmit={(e) => {
                e.preventDefault();
                const t = pageTitle.trim();
                if (!t) return;
                void run('override', () => api.enrichment.overridePage(jellyfinId, `${site}wiki`, t));
              }}
            >
              <Field label="Site">
                <Select value={site} onChange={setSite} label="Wikipedia language" block options={(WIKI_LANGUAGES.includes(site) ? WIKI_LANGUAGES : [site, ...WIKI_LANGUAGES]).map((c) => [c, c])} />
              </Field>
              <Field label="Page title">
                <input value={pageTitle} onChange={(e) => setPageTitle(e.target.value)} placeholder="Heat (1995 film)" className={inputCls} />
              </Field>
              <Button type="submit" variant="primary" size="sm" disabled={busy !== null || !pageTitle.trim()} className="sm:mb-0">
                {busy === 'override' ? 'Applying…' : 'Apply'}
              </Button>
            </form>
          )}

          {spoilersOpen && row?.plotText && (
            <div className="mt-3 max-h-56 overflow-y-auto overscroll-contain rounded-2xl bg-canvas px-4 py-3">
              {row.leadText && (
                <>
                  <div className="mb-1 text-[12px] font-semibold text-mute">Lead</div>
                  <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-ink-2">{row.leadText}</pre>
                  <div className="mb-1 mt-4 text-[12px] font-semibold text-mute">Plot</div>
                </>
              )}
              <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-ink-2">{row.plotText}</pre>
              {row.receptionText && (
                <>
                  <div className="mb-1 mt-4 text-[12px] font-semibold text-mute">Reception</div>
                  <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-ink-2">{row.receptionText}</pre>
                </>
              )}
            </div>
          )}
        </>
      )}
    </section>
  );
}
