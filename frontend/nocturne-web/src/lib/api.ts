import type {
  AdminMovieApi,
  BackfillScope,
  BackfillStatusApi,
  CoverageStatus,
  DiscoveredServer,
  EnrichmentRow,
  EnrichmentSummary,
  EvalReport,
  GuideResponse,
  JellyfinConnectResult,
  JellyfinTestResult,
  JevTestResult,
  ModelSettings,
  ModelSettingsUpdate,
  MoodBuckets,
  OnboardingStatus,
  SettingsInfo,
  SyncStatus,
  TagSuggestionApi,
  TeachAccepted,
  TeachGroups,
  VerifyMode,
  VerifySample,
  VerifySaved,
  VerifyScope,
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

function del<T = unknown>(path: string): Promise<T> {
  return request<T>(path, { method: 'DELETE' });
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
    // The film's newest decision row of any status: what AI last decided and why.
    latestSuggestion: (jellyfinId: string) => getOrNull<TagSuggestionApi>(`/admin/movies/${enc(jellyfinId)}/suggestion`),
  },
  // The spot check: a seeded random sample of tagged films, judged mood by mood.
  verify: {
    sample: (n = 30, scope: VerifyScope = 'watched', mode: VerifyMode = 'tagged', seed?: string) =>
      get<VerifySample>(`/admin/verify/sample?n=${n}&scope=${scope}&mode=${mode}${seed ? `&seed=${enc(seed)}` : ''}`),
    save: (jellyfinId: string, wrong: string[], add: string[] = []) => post<VerifySaved>('/admin/verify', { jellyfinId, wrong, add }),
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
    saveJevKey: (key: string) => post('/settings/keys', { jev_api_key: key }),
    // One small classification with the stored key.
    testJev: () => post<JevTestResult>('/settings/jev-test'),
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
  // The guide AI reads on every film: the manual text and the learned rules.
  guide: {
    get: () => get<GuideResponse>('/settings/guide'),
    save: (manual: string) => put<GuideResponse>('/settings/guide', { manual }),
    reset: () => put<GuideResponse>('/settings/guide/reset'),
    removeLearned: (index: number) => del<GuideResponse>(`/settings/guide/learned/${index}`),
  },
  // The eval replays the policy over the owner's decisions; 404 before the first run.
  eval: {
    latest: () => getOrNull<EvalReport>('/admin/eval'),
    run: () => post<EvalReport>('/admin/eval'),
    acceptFloors: () => post<{ floors: Record<string, number> }>('/admin/eval/accept-floors'),
  },
  teach: {
    groups: () => get<TeachGroups>('/admin/teach'),
    answer: (jellyfinId: string, boundary: string, answer: string) =>
      post<{ ok: boolean; answer: string }>('/admin/teach/answer', { jellyfinId, boundary, answer }),
    // The strong model drafts up to three rules from the answers (about $0.05).
    previewRules: (boundary: string) => post<{ rules: string[] }>('/admin/teach/rules/preview', { boundary }),
    acceptRules: (boundary: string, rules: string[]) => post<TeachAccepted>('/admin/teach/rules/accept', { boundary, rules }),
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
    // The grader and the policy again over films with a stored AI answer; AI is not called.
    regrade: (scope: BackfillScope = 'all') => post<BackfillStatusApi>('/admin/auto-tag/regrade', { scope }),
    // The policy again over the stored answers: no AI call, no grader call. For a floor change.
    replay: (scope: BackfillScope = 'all') => post<BackfillStatusApi>('/admin/auto-tag/replay', { scope }),
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
