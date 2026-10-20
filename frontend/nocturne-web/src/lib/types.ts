export type Tag = { id?: string; slug: string; title: string };

export type Movie = {
  jellyfinId: string;
  title: string;
  year?: number;
  posterUrl?: string;
  tags?: Tag[];
  needsReview?: boolean;
  // Jellyfin's per-user watched flag.
  played?: boolean;
};

export type AdminMovieApi = {
  jellyfinId: string;
  title: string;
  year?: number;
  posterUrl?: string;
  tags: string[];
  needsReview: boolean;
  played: boolean;
  lastPlayedDate?: string;
};

// Which films an auto-tag run covers.
export type BackfillScope = 'all' | 'watched' | 'unwatched';

// Where a film's story text came from. `model` is written by the strong model and is the only
// unverified kind; `none` means the tagger only had the Jellyfin blurb.
export type EnrichmentSource = 'wikipedia' | 'wikipedia_other_lang' | 'model' | 'none';

// One mood from a decision: what the review surfaces render per mood.
export type SuggestionItem = {
  slug: string;
  probability: number;
  evidence?: string;
  kind: 'add' | 'remove';
  // True when the tag is on the film right now; false when the policy held it back.
  applied: boolean;
  reason?: string;
};

export type TagSuggestionApi = {
  id: string;
  jellyfinId: string;
  suggestedTags: string[];
  confidence: number;
  reasoning?: string;
  status: string;
  kind: 'additive' | 'removal';
  removalTagSlug?: string;
  createdAt?: string;
  resolvedAt?: string;
  resolvedBy?: 'auto' | 'user';
  decisionId?: string;
  items?: SuggestionItem[];
  source?: EnrichmentSource;
};

export type BackfillStatusApi = {
  running: boolean;
  total: number;
  processed: number;
  startedAt?: string;
  cancelled?: boolean;
  scope?: BackfillScope;
};

export type EnrichmentBucket =
  | 'english_plot'
  | 'other_lang_plot'
  | 'model_synopsis'
  | 'no_plot'
  | 'unresolved'
  | 'error';

export type EnrichmentRow = {
  jellyfinId: string;
  imdbId?: string;
  tmdbId?: string;
  wikidataQid?: string;
  // Wikimedia site id: enwiki, tawiki, …
  wikiSite?: string;
  wikiTitle?: string;
  wikiTitleOverride?: string;
  source: EnrichmentSource;
  unverified: boolean;
  plotFound: boolean;
  // Only the per-film route returns the texts.
  plotText?: string;
  receptionText?: string;
  awardsJson?: string;
  omdbAwards?: string;
  inputHash?: string;
  enrichVersion: number;
  fetchedAt?: string;
  error?: string;
  bucket: EnrichmentBucket;
};

export type EnrichmentSummary = Partial<Record<EnrichmentBucket | 'total' | 'unverified', number>>;

export type WorklistFilter = 'no_plot' | 'unresolved' | 'other_lang' | 'unverified' | 'error';

export type CoverageStatus = {
  running: boolean;
  runId?: string;
  status?: string;
  total: number;
  processed: number;
  stats: Partial<Record<EnrichmentBucket, number>>;
  startedAt?: string;
  finishedAt?: string;
  cancelRequested: boolean;
  error?: string;
};

export type ModelSettings = {
  reader_model: string;
  strong_model: string;
  reader_models: string[];
  strong_models: string[];
  monthly_budget_usd?: number | null;
  budget_spent_usd: number;
  model_fallback: boolean;
  enrichment: EnrichmentSummary;
};

export type ModelSettingsUpdate = Partial<{
  reader_model: string;
  strong_model: string;
  monthly_budget_usd: number;
  model_fallback: boolean;
}>;

export type MoodBuckets = Record<string, { title: string; description: string }>;

export type SyncStatus = {
  isRunning: boolean;
  lastSyncAt?: string;
  lastSyncDuration?: number;
  moviesFound: number;
  moviesUpdated: number;
  moviesDeleted: number;
  errors: string[];
};

export type ImportProgress = {
  total: number;
  processed: number;
  success: number;
  fail: number;
  running: boolean;
};

export type SettingsInfo = {
  jellyfin_url: string;
  jellyfin_api_key_set: boolean;
  jellyfin_user_id: string;
  jellyfin_username?: string;
  anthropic_key_set: boolean;
  omdb_key_set: boolean;
  enable_auto_tagging: boolean;
};

export type JellyfinTestResult = {
  success: boolean;
  error?: string;
  userId?: string;
  serverName?: string;
  version?: string;
  localAddress?: string;
};

export type JellyfinConnectResult = {
  success: boolean;
  error?: string;
  serverName?: string;
  version?: string;
  localAddress?: string;
};

export type DiscoveredServer = {
  id: string;
  name: string;
  address: string;
  version?: string;
};

export type OnboardingStatus = {
  configured: boolean;
  has_jellyfin: boolean;
  has_anthropic_key: boolean;
  has_omdb_key: boolean;
};
