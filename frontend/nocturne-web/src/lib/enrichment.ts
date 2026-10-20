import type { EnrichmentRow, EnrichmentSource } from './types';

// Wikipedia language editions the server tries, in its own order (English first).
export const WIKI_LANGUAGES = ['en', 'ta', 'ml', 'hi', 'kn', 'te', 'bn'];

// `enwiki` → `en`.
export function siteCode(site?: string): string {
  if (!site) return 'en';
  return site.endsWith('wiki') ? site.slice(0, -4) : site;
}

// `enwiki` → `en.wikipedia`.
export function siteLabel(site?: string): string {
  return `${siteCode(site)}.wikipedia`;
}

export function isVerified(source?: EnrichmentSource): boolean {
  return source === 'wikipedia' || source === 'wikipedia_other_lang';
}

export function wordCount(text?: string): number {
  if (!text) return 0;
  return text.split(/\s+/).filter(Boolean).length;
}

export function timeAgo(iso?: string): string | null {
  if (!iso) return null;
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return null;
  const minutes = Math.round((Date.now() - then) / 60000);
  if (minutes < 2) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours === 1 ? '1 hour ago' : `${hours} hours ago`;
  const days = Math.round(hours / 24);
  if (days < 31) return days === 1 ? 'yesterday' : `${days} days ago`;
  return new Date(then).toLocaleDateString();
}

type Award = { name: string; kind: 'won' | 'nominated'; year?: number };

// One line for the awards: OMDb's own sentence when we have it, else counts from Wikidata.
export function awardsSummary(row: EnrichmentRow): string | null {
  if (row.omdbAwards) return row.omdbAwards;
  if (!row.awardsJson) return null;
  try {
    const awards = JSON.parse(row.awardsJson) as Award[];
    if (!Array.isArray(awards) || awards.length === 0) return null;
    const won = awards.filter((a) => a.kind === 'won').length;
    const nominated = awards.length - won;
    const parts: string[] = [];
    if (won > 0) parts.push(`${won} ${won === 1 ? 'win' : 'wins'}`);
    if (nominated > 0) parts.push(`${nominated} ${nominated === 1 ? 'nomination' : 'nominations'}`);
    return parts.join(', ');
  } catch {
    return null;
  }
}

// The page behind the story text, as "Heat (1995 film) · en.wikipedia".
export function pageLabel(row: EnrichmentRow): string | null {
  const title = row.wikiTitleOverride || row.wikiTitle;
  if (!title) return null;
  return `${title} · ${siteLabel(row.wikiSite)}`;
}

// What the admin reads on the source line, by state.
export function sourceLine(row: EnrichmentRow | null, title: string, year?: number): string {
  if (!row) return 'Not fetched yet. Refresh pulls the Wikipedia page, plot and awards.';
  if (row.source === 'model') return 'Written by the strong model with web search.';
  const page = pageLabel(row);
  if (isVerified(row.source)) return page ?? siteLabel(row.wikiSite);
  if (page) return `${page} · page has no plot section`;
  return `No Wikipedia page matched “${title}”${year ? ` (${year})` : ''} by IMDb id or title.`;
}

// Why a film sits in the coverage worklist, for the row's trailing text.
export function worklistReason(row: EnrichmentRow): string {
  if (row.error && !row.plotFound) return row.error;
  switch (row.bucket) {
    case 'no_plot':
      return `${siteLabel(row.wikiSite)} · no plot section`;
    case 'unresolved':
      return 'no page matched by IMDb id or title';
    case 'other_lang_plot':
      return `${siteLabel(row.wikiSite)} · plot in another language`;
    case 'model_synopsis':
      return 'written by the strong model';
    case 'error':
      return row.error ?? 'fetch failed';
    default:
      return siteLabel(row.wikiSite);
  }
}
