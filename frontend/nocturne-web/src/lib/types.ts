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
  // `maybe` is a mood AI considered but would not defend; it is never applied by the policy.
  kind: 'add' | 'remove' | 'maybe';
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
  // `regrade` rows are the grader's second look at a tagged film: adds, plus `remove` items for
  // the moods it would drop. Approve takes the new decision; Reject puts the film back as it was.
  // `verify` rows are the owner's spot-check verdicts; they are never pending.
  kind: 'additive' | 'removal' | 'regrade' | 'verify';
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
  // What the latest run did: tag untagged films, re-tag them, or grade them again.
  kind?: 'backfill' | 'reprocess' | 'regrade';
  // A regrade that replayed the stored answers without calling the grader (a floor change).
  replay?: boolean;
};

// The spot check: a random sample of tagged films the owner judges mood by mood.
export type VerifyMood = {
  slug: string;
  title: string;
  // The grader's probability when one ran for the film, else AI's own confidence.
  probability?: number;
  evidence?: string;
};

export type VerifyFilm = {
  jellyfinId: string;
  title: string;
  year?: number;
  played: boolean;
  residue?: string;
  // The moods on the film from AI, to judge.
  moods: VerifyMood[];
  // Moods AI named that are not on the film, to add with one tap.
  candidates: VerifyMood[];
};

// Which films the sample draws from, and whether they carry a mood yet.
export type VerifyScope = 'watched' | 'all';
export type VerifyMode = 'tagged' | 'untagged';

export type VerifyTally = { films: number; judged: number; right: number; wrong: number };

export type VerifySample = {
  films: VerifyFilm[];
  remaining: number;
  // Unjudged films per scope and mode, keyed `watched.tagged`, `all.untagged` and so on.
  counts: Record<string, number>;
  tally: VerifyTally;
};

export type VerifySaved = { kept: string[]; wrong: string[]; added: string[]; tally: VerifyTally };

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
  leadText?: string;
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

// Who grades AI's proposals: nobody (AI's own confidence decides) or Jev, TypeSafe's classifier.
export type ClassifierProvider = 'none' | 'jev';

// Which policy turns the answers into tags. `p1`: AI proposes, the grader has to agree above the
// mood's floor. `p0`: the grader alone. `p-legacy`: AI's own confidence against the floors.
// `pr`: AI only, nothing applied (a dry run).
export type PolicyVersion = 'p1' | 'p0' | 'p-legacy' | 'pr';

export type ModelSettings = {
  reader_model: string;
  strong_model: string;
  reader_models: string[];
  strong_models: string[];
  monthly_budget_usd?: number | null;
  budget_spent_usd: number;
  model_fallback: boolean;
  enrichment: EnrichmentSummary;
  classifier_provider: ClassifierProvider;
  classifier_providers: ClassifierProvider[];
  classifier_model: string;
  jev_key_set: boolean;
  policy_version: PolicyVersion;
  policy_versions: PolicyVersion[];
  // Per mood: the grader probability a mood has to clear to be applied.
  floors: Record<string, number>;
  // Per mood: above this line a mood AI never named still becomes a suggestion.
  high: Record<string, number>;
  guide_version: number;
};

export type ModelSettingsUpdate = Partial<{
  reader_model: string;
  strong_model: string;
  monthly_budget_usd: number;
  model_fallback: boolean;
  classifier_provider: ClassifierProvider;
  classifier_model: string;
  policy_version: PolicyVersion;
  floors: Record<string, number>;
  high: Record<string, number>;
}>;

export type JevTestResult = {
  ok: boolean;
  model?: string;
  answered?: number;
  error?: string;
};

// The guide AI reads on every film: the manual text (the bundled one until edited) and the rules
// learned from the owner's Teach answers.
export type LearnedRule = {
  boundary: string;
  text: string;
  acceptedAt: string;
};

export type GuideResponse = {
  manual: string;
  bundled: boolean;
  learned: LearnedRule[];
  version: number;
};

// The eval: the policy replayed over the owner's own decisions, no model call.
export type EvalMetrics = {
  floor: number;
  applied: number;
  correct: number;
  wrong: number;
  precision?: number;
  wilsonLower?: number;
  recall?: number;
};

export type EvalMoodReport = {
  slug: string;
  title: string;
  positives: number;
  negatives: number;
  currentFloor: number;
  current: EvalMetrics;
  grid: EvalMetrics[];
  suggestedFloor?: number;
  brier?: number;
};

export type EvalOverall = {
  applied: number;
  correct: number;
  wrong: number;
  precision?: number;
  wilsonLower?: number;
  filmsWithApplied: number;
  films: number;
};

export type EvalReport = {
  generatedAt: string;
  policyVersion: PolicyVersion;
  targetPrecision: number;
  films: number;
  positives: number;
  negatives: number;
  moods: EvalMoodReport[];
  overall: EvalOverall;
  overallAtSuggested: EvalOverall;
  versions: Record<string, EvalOverall>;
};

// Teach: films where the owner and the system disagree, grouped by the two moods in question.
export type TeachBoundary = { key: string; left: string; right: string };

export type TeachFilm = {
  jellyfinId: string;
  title: string;
  residue?: string;
  leftProbability?: number;
  rightProbability?: number;
  systemPick?: string;
  adminPick?: string;
  // The owner's answer: the left slug, the right slug, or `neither`.
  answer?: string;
  // Who the probabilities come from: the grader, or AI's own confidence.
  probabilitySource?: 'classifier' | 'reader';
};

export type TeachGroup = {
  boundary: TeachBoundary;
  leftTitle: string;
  rightTitle: string;
  films: TeachFilm[];
  answered: number;
  rules: string[];
};

export type TeachGroups = { groups: TeachGroup[]; guideVersion: number };

export type TeachAccepted = {
  guideVersion: number;
  rules: number;
  regradeStarted: boolean;
  regradeFilms: number;
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
  jev_key_set: boolean;
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
