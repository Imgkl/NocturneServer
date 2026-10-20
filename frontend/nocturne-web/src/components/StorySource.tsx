import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { WIKI_LANGUAGES, awardsSummary, isVerified, siteCode, sourceLine, timeAgo, wordCount } from '../lib/enrichment';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { Toggle } from '../ui/Toggle';
import type { EnrichmentRow } from '../lib/types';

interface StorySourceProps {
  jellyfinId: string;
  title: string;
  year?: number;
}

type Busy = 'refresh' | 'override' | 'synopsis' | null;

const linkCls =
  'text-[11px] text-text-dim hover:text-text underline decoration-dotted underline-offset-2 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed';

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
    if (
      !confirm(
        'Ask the strong model to write a spoiler synopsis with web search? About $0.05 to $0.10. The text is marked unverified and its moods always go to review.',
      )
    )
      return;
    void run('synopsis', () => api.enrichment.synopsis(jellyfinId));
  };

  const loading = row === undefined;
  const plotWords = wordCount(row?.plotText);
  const fetched = timeAgo(row?.fetchedAt);
  const awards = row ? awardsSummary(row) : null;
  const canGenerate = !!row && !row.plotFound;

  return (
    <div className="border border-border bg-bg p-4">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <span className="text-[11px] uppercase tracking-widest text-muted">Story source</span>
        <div className="flex flex-wrap gap-1">
          {loading && <Badge tone="muted">loading</Badge>}
          {row === null && !loading && <Badge tone="muted">not fetched</Badge>}
          {row && row.unverified && <Badge tone="warn">unverified source</Badge>}
          {row && !row.unverified && isVerified(row.source) && <Badge>verified</Badge>}
          {row && (row.plotFound ? <Badge tone="muted">plot found</Badge> : <Badge tone="muted">no plot</Badge>)}
          {row?.error && <Badge tone="muted">error</Badge>}
        </div>
      </div>

      {!loading && (
        <>
          <div className="text-[13px] text-text mt-2">{sourceLine(row, title, year)}</div>
          <div className="text-[11px] text-muted mt-0.5">
            {[fetched ? `Fetched ${fetched}` : null, awards ? `Awards: ${awards}` : null].filter(Boolean).join(' · ')}
            {row?.unverified && (
              <span>
                {fetched || awards ? ' · ' : ''}Moods from this text always go to review. Link a Wikipedia page to
                replace it.
              </span>
            )}
          </div>
          {row?.error && <p className="text-[11px] text-danger mt-1 break-words">{row.error}</p>}
          {error && <p className="text-[11px] text-danger mt-1 break-words">{error}</p>}

          <div className="mt-2.5 flex items-center gap-3.5 flex-wrap">
            <button type="button" className={linkCls} onClick={() => setOverrideOpen((v) => !v)} disabled={busy !== null}>
              {overrideOpen ? 'Cancel' : 'Change page'}
            </button>
            <button
              type="button"
              className={linkCls}
              onClick={() => void run('refresh', () => api.enrichment.refresh(jellyfinId))}
              disabled={busy !== null}
            >
              {busy === 'refresh' ? 'Refreshing…' : 'Refresh'}
            </button>
            <span className="flex-1" />
            {plotWords > 0 && (
              <div className="flex items-center gap-2.5">
                <span className="text-[10px] uppercase tracking-widest text-muted">Show spoilers</span>
                <Toggle active={spoilersOpen} onChange={setSpoilersOpen} label="Show spoilers" />
              </div>
            )}
          </div>

          {overrideOpen && (
            <form
              className="mt-3 grid grid-cols-1 sm:grid-cols-[88px_1fr_auto] gap-3 sm:items-end"
              onSubmit={(e) => {
                e.preventDefault();
                const t = pageTitle.trim();
                if (!t) return;
                void run('override', () => api.enrichment.overridePage(jellyfinId, `${site}wiki`, t));
              }}
            >
              <div className="flex flex-col gap-1.5">
                <label htmlFor={`site-${jellyfinId}`} className="text-[10px] uppercase tracking-widest text-muted">
                  Site
                </label>
                <select
                  id={`site-${jellyfinId}`}
                  value={site}
                  onChange={(e) => setSite(e.target.value)}
                  className="bg-transparent border-0 border-b border-border focus:border-text outline-none text-text text-[14px] py-2 cursor-pointer"
                >
                  {(WIKI_LANGUAGES.includes(site) ? WIKI_LANGUAGES : [site, ...WIKI_LANGUAGES]).map((code) => (
                    <option key={code} value={code}>
                      {code}
                    </option>
                  ))}
                </select>
              </div>
              <div className="flex flex-col gap-1.5">
                <label htmlFor={`page-${jellyfinId}`} className="text-[10px] uppercase tracking-widest text-muted">
                  Page title
                </label>
                <input
                  id={`page-${jellyfinId}`}
                  value={pageTitle}
                  onChange={(e) => setPageTitle(e.target.value)}
                  placeholder="Heat (1995 film)"
                  className="bg-transparent border-0 border-b border-border focus:border-text outline-none text-text placeholder:text-muted text-[14px] py-2 transition-colors"
                />
              </div>
              <Button type="submit" variant="line" size="sm" disabled={busy !== null || !pageTitle.trim()}>
                {busy === 'override' ? 'Applying…' : 'Apply'}
              </Button>
            </form>
          )}

          {canGenerate && (
            <div className="mt-3 flex items-center gap-3 flex-wrap">
              <Button variant="line" size="sm" onClick={generateSynopsis} disabled={busy !== null}>
                {busy === 'synopsis' ? 'Writing…' : 'Generate synopsis'}
              </Button>
              <span className="text-[11px] text-text-dim">
                Strong model with web search, about $0.05 to $0.10. Marked unverified.
              </span>
            </div>
          )}

          {spoilersOpen && row?.plotText && (
            <div className="mt-3 border border-border bg-surface px-3 py-2.5 max-h-48 overflow-y-auto overscroll-contain">
              <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-text-dim">{row.plotText}</pre>
              {row.receptionText && (
                <>
                  <div className="text-[10px] uppercase tracking-widest text-muted mt-3 mb-1">Reception</div>
                  <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-text-dim">
                    {row.receptionText}
                  </pre>
                </>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}
