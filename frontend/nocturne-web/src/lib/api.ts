import type {
  AdminMovieApi,
  BackfillScope,
  BackfillStatusApi,
  CoverageStatus,
  DiscoveredServer,
  EnrichmentRow,
  EnrichmentSummary,
  JellyfinConnectResult,
  JellyfinTestResult,
  ModelSettings,
  ModelSettingsUpdate,
  MoodBuckets,
  OnboardingStatus,
  SettingsInfo,
  SyncStatus,
  TagSuggestionApi,
  WorklistFilter,
} from './types';

const API = '/api/v1';

// Non-2xx responses. `message` is the server's own message when the body is the usual
// `{ error, message }` JSON, else the raw body.
export class ApiError extends Error {
  status: number;

  constructor(status: number, body: string) {
    super(describe(body));
    this.name = 'ApiError';
    this.status = status;
  }
}

function describe(body: string): string {
  try {
    const j = JSON.parse(body) as { message?: unknown; error?: unknown };
    if (typeof j.message === 'string' && j.message) return j.message;
    if (typeof j.error === 'string' && j.error) return j.error;
  } catch {
    // not JSON
  }
  return body;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(API + path, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  });
  if (!res.ok) throw new ApiError(res.status, await res.text());
  return res.json() as Promise<T>;
}

function get<T>(path: string): Promise<T> {
  return request<T>(path, { method: 'GET' });
}

// A GET that resolves to null on 404, for per-film rows that may not exist yet.
async function getOrNull<T>(path: string): Promise<T | null> {
  try {
    return await get<T>(path);
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) return null;
    throw e;
  }
}

function post<T = unknown>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, {
    method: 'POST',
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function put<T = unknown>(path: string, body?: unknown): Promise<T> {
  return request<T>(path, {
    method: 'PUT',
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// Fire-and-forget; doesn't throw on non-2xx. For endpoints where the caller
// intentionally doesn't await (e.g. starting a sync + polling its status).
function postVoid(path: string): void {
  fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json' } }).catch(
    () => {},
  );
}

const enc = encodeURIComponent;

export const api = {
  moods: {
    list: () => get<{ moods: MoodBuckets }>('/moods'),
  },
  movies: {
    listAll: (limit = 10000, offset = 0) =>
      get<{ items: AdminMovieApi[]; totalCount: number }>(
        `/admin/movies?limit=${limit}&offset=${offset}`,
      ),
    updateTags: (jellyfinId: string, tagSlugs: string[], replaceAll: boolean) =>
      put(`/movies/${jellyfinId}/tags`, { tagSlugs, replaceAll }),
    autoTag: (jellyfinId: string) =>
      post<TagSuggestionApi>(`/movies/${jellyfinId}/auto-tag`, {}),
  },
  suggestions: {
    listPending: () =>
      get<{ items: TagSuggestionApi[] }>('/admin/suggestions?status=pending'),
    approve: (id: string, overrideTags?: string[]) =>
      post(`/admin/suggestions/${id}/approve`, overrideTags ? { tags: overrideTags } : undefined),
    reject: (id: string) => post(`/admin/suggestions/${id}/reject`),
  },
  settings: {
    info: () => get<SettingsInfo>('/settings/info'),
    saveAnthropicKey: (key: string) => post('/settings/keys', { anthropic_api_key: key }),
    saveOmdbKey: (key: string) => post('/settings/keys', { omdb_api_key: key }),
    setAutoTagging: (enabled: boolean) => post('/settings/keys', { enable_auto_tagging: enabled }),
    clearMovies: () => post('/settings/clear-movies'),
    saveJellyfin: (url: string, username: string, password: string) =>
      post<JellyfinConnectResult>('/settings/jellyfin', {
        jellyfin_url: url,
        jellyfin_username: username,
        jellyfin_password: password,
      }),
    models: () => get<ModelSettings>('/settings/models'),
    saveModels: (update: ModelSettingsUpdate) => post<ModelSettings>('/settings/models', update),
  },
  sync: {
    status: () => get<SyncStatus>('/sync/status'),
    trigger: () => postVoid('/sync/jellyfin'),
    testConnection: () => post<JellyfinTestResult>('/sync/test-connection'),
  },
  jellyfin: {
    discover: () => post<{ servers: DiscoveredServer[] }>('/jellyfin/discover'),
  },
  onboarding: {
    status: () => get<OnboardingStatus>('/onboarding/status'),
  },
  backfill: {
    start: (scope: BackfillScope = 'all') => post<BackfillStatusApi>('/admin/auto-tag/backfill', { scope }),
    reprocessAll: (scope: BackfillScope = 'all') =>
      post<BackfillStatusApi>('/admin/auto-tag/reprocess-all', { scope }),
    cancel: () => post<BackfillStatusApi>('/admin/auto-tag/cancel'),
    status: () => get<BackfillStatusApi>('/admin/auto-tag/backfill/status'),
  },
  // Story sources: Wikipedia plot, reception and awards per film, and the coverage run that
  // fills them for the whole library.
  enrichment: {
    coverageStart: () => post<CoverageStatus>('/admin/enrichment/coverage'),
    coverageStatus: () => get<CoverageStatus>('/admin/enrichment/coverage/status'),
    coverageCancel: () => post<CoverageStatus>('/admin/enrichment/coverage/cancel'),
    summary: () => get<EnrichmentSummary>('/admin/enrichment/summary'),
    worklist: (filter: WorklistFilter) =>
      get<{ items: EnrichmentRow[] }>(`/admin/enrichment/worklist?filter=${filter}`),
    get: (jellyfinId: string) => getOrNull<EnrichmentRow>(`/admin/enrichment/${enc(jellyfinId)}`),
    overridePage: (jellyfinId: string, site: string, title: string) =>
      put<EnrichmentRow>(`/admin/enrichment/${enc(jellyfinId)}/page`, {
        wiki_site: site,
        wiki_title: title,
      }),
    refresh: (jellyfinId: string) => post<EnrichmentRow>(`/admin/enrichment/${enc(jellyfinId)}/refresh`),
    synopsis: (jellyfinId: string) => post<EnrichmentRow>(`/admin/enrichment/${enc(jellyfinId)}/synopsis`),
  },
  link: {
    // Best-effort LAN-routable URL the mobile app can hit. Returns
    // `{ url: null }` when the host has no usable IPv4 LAN interface — the
    // caller should fall back to `window.location.origin`.
    lanAddress: () => get<{ url: string | null }>('/admin/lan-address'),
  },
  data: {
    export: () => get<Record<string, string[]>>('/data/export'),
    import: (map: Record<string, unknown>, replaceAll: boolean) =>
      post('/data/import', { map, replaceAll }),
  },
};

// Build a URL for the poster proxy. Returns image bytes (or 404 → img onError).
export function posterUrl(jellyfinId: string, size: 'thumb' | 'medium' | 'full' = 'medium'): string {
  return `${API}/movies/${encodeURIComponent(jellyfinId)}/poster?size=${size}`;
}

// Version endpoint lives outside the /api/v1 prefix.
export async function fetchVersion(): Promise<string | null> {
  try {
    const res = await fetch('/version', { headers: { 'Content-Type': 'application/json' } });
    if (!res.ok) return null;
    const j = (await res.json()) as { version?: string };
    return typeof j.version === 'string' ? j.version : null;
  } catch {
    return null;
  }
}
