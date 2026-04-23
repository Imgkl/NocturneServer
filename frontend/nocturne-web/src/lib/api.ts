import type {
  AdminMovieApi,
  BackfillStatusApi,
  DiscoveredServer,
  JellyfinConnectResult,
  JellyfinTestResult,
  MoodBuckets,
  OnboardingStatus,
  SettingsInfo,
  SyncStatus,
  TagRefinementStatusApi,
  TagSuggestionApi,
} from './types';

const API = '/api/v1';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(API + path, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json() as Promise<T>;
}

function get<T>(path: string): Promise<T> {
  return request<T>(path, { method: 'GET' });
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
    start: () => post<BackfillStatusApi>('/admin/auto-tag/backfill'),
    reprocessAll: () => post<BackfillStatusApi>('/admin/auto-tag/reprocess-all'),
    cancel: () => post<BackfillStatusApi>('/admin/auto-tag/cancel'),
    status: () => get<BackfillStatusApi>('/admin/auto-tag/backfill/status'),
  },
  tags: {
    refine: (slug: string) =>
      post<TagRefinementStatusApi>(`/tags/${encodeURIComponent(slug)}/refine`),
    refineStatus: (slug: string) =>
      get<TagRefinementStatusApi>(`/tags/${encodeURIComponent(slug)}/refine/status`),
    refineCancel: (slug: string) =>
      post<TagRefinementStatusApi>(`/tags/${encodeURIComponent(slug)}/refine/cancel`),
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
