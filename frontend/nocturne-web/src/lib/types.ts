export type Tag = { id?: string; slug: string; title: string };

export type Movie = {
  jellyfinId: string;
  title: string;
  year?: number;
  posterUrl?: string;
  tags?: Tag[];
  needsReview?: boolean;
};

export type AdminMovieApi = {
  jellyfinId: string;
  title: string;
  year?: number;
  posterUrl?: string;
  tags: string[];
  needsReview: boolean;
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
};

export type BackfillStatusApi = {
  running: boolean;
  total: number;
  processed: number;
  startedAt?: string;
  cancelled?: boolean;
};

export type TagRefinementStatusApi = {
  running: boolean;
  tagSlug?: string;
  total: number;
  processed: number;
  removed: number;
  addSuggestions: number;
  removeSuggestions: number;
  startedAt?: string;
  cancelled?: boolean;
};

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
