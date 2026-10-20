# 2026-10-21 · Tagger rewrite, phase 1

**tl;dr** The single-model auto-tagger (`LLMService` + `SuggestionService`, Opus 4.7, about 10K uncached tokens per film, no ground truth) is gone. In its place: a stored, hashed story text block per film built from the full Wikipedia plot, reception and awards (resolved from Jellyfin's IMDb id through Wikidata), a cheap cached reader on `claude-haiku-5-5` with structured output, a bridge policy, a replayable `decisions` row per classification with metered cost, human labels separable from auto labels, persisted runs, a budget guard, and a web UI for all of it. Branch `gkl_tagger_rewrite`, 21 commits, 121 tests in 24 suites. Spec: `docs/superpowers/specs/2026-10-21-tagger-rewrite-design.md`. Plan: `docs/superpowers/plans/2026-10-21-tagger-rewrite-phase-1.md`.

## What shipped

| Area | Where | Notes |
|---|---|---|
| Jellyfin DTO | `JellyfinTypes.swift`, `JellyfinService.swift` | `ProviderIds` and `DateLastSaved` requested and decoded. |
| Schema | `ModelsV2.swift`, `MigrationsV2.swift` | `movie_enrichment`, `decisions`, `api_calls`, `runs`, `wikidata_labels`; `movie_tags.label_source` (seed/auto/user), `tag_suggestions.resolved_by` + `decision_id` + `items_json`, `movies.current_decision_id`. Retro rule: an approved row resolved within 2 s of creation was the model. `SeedMissingMoodTags` adds the two slugs the old seed forgot. |
| Providers | `Providers/` | `OutboundClient` (retries 1, 2, 4, 8, 8 s with jitter, `Retry-After`, 401/403 abort), per-call metering, `PriceTable` (checked 2026-10-21), `BudgetGuard` (`budget.monthly_usd`, default $15; scheduled and realtime pause, manual warns), `RateLimiter` (2 req/s for Wikimedia), `AnthropicClient`, `OmdbClient`. |
| Enrichment | `Enrichment/` | `WikidataResolver` (P345 IMDb, P4947 TMDb, title search fallback, film-class and year cross-checks), `WikipediaClient` (`extracts`, wiki section format), `SectionParser` (plot cap 2,500 words head+tail, reception cap 800, seven languages), `AwardsResolver` (Wikidata P166/P1411 with cached labels, OMDb `Awards` under a 900/day cap), `TextBlockBuilder` (fixed headings, SHA-256 excluding the Source line, version 1), `EnrichmentService` (skip when unchanged, failures keep the last good block), `EnrichCoverageJob` (concurrency 3, buckets, worklist, summary). |
| Reader | `Tagger/ReaderPrompt.swift`, `ReaderService.swift` | Static system block (rules + buckets, no calibration) with `cache_control`, learned rules and recent human decisions in the user turn, `output_config` JSON schema, effort low, `models.reader` setting, unknown slugs and duplicates dropped. |
| Policy and decisions | `PolicyEngine.swift`, `DecisionRecorder.swift`, `TaggerPipeline.swift` | `p-legacy`: reader confidence against each bucket's `minConfidence`, cap 5, unverified source applies nothing. Every tag call opens a decision row first and completes it with reader JSON, applied and suggested lists, reasons, models and summed cost. |
| Review and runs | `ReviewQueue.swift`, `Runs/RunService.swift`, `Runs/BackfillJob.swift` | Approve promotes auto labels to user labels (or replaces with the admin's set); reject removes only auto labels. One run at a time, heartbeat, stale runs marked on boot, cost summed per provider. Backfill and reprocess-all run on persisted runs; the 1.5 s breather is gone. |
| Fallback synopsis | `Tagger/FallbackSynopsisService.swift` | Strong model (`models.strong`, default `claude-opus-5-5`) with web search writes plot and reception when no page exists; stored as `source = model`, `unverified = true`; moods from it always go to review. Flag `enrichment.model_fallback`. |
| Taxonomy | `Resources/taxonomy.json`, `Resources/guide.md`, `Taxonomy.swift` | 36 buckets with `version`, loaded at boot, fail loudly when malformed. The Docker image copies the resource bundle next to the binary. |
| Settings | `Routes/ModelSettingsRoutes.swift` | `GET/POST /api/v1/settings/models`: reader and strong model, budget, fallback flag, month-to-date spend, coverage summary. `ANTHROPIC_MODEL` is seeded into `models.reader` once and logged as deprecated. |
| Routes | `Routes/EnrichmentRoutes.swift`, `Routes/TaggerRoutes.swift` | Coverage run, worklist, per-film row (the only route that returns plot text, admin group only), page override, refresh, synopsis. Tagging routes keep their paths; suggestion responses gain `items` (per-mood probability and evidence) and `source`. |
| Web UI | `frontend/nocturne-web/src` | Models & budget card, Story sources card (run, progress, counts as filter pills, worklist that opens the film), Story source block in the film panel (badges, override, refresh, synopsis, collapsed spoilers), evidence and held-back proposals in the review queue and the auto-tag dialog, unverified-source badge. Tag refine UI deleted. |
| Deleted | | `LLMService.swift`, `SuggestionService.swift`, `BackfillStateActor`, the per-tag refinement worker and its routes and UI, the Swift mood dictionary and prompt string. |

## Verified on this Mac

- `swift test`: 121 tests, 24 suites, green. Fixtures are real Wikidata and Wikipedia captures (Heat, Drive, Parasite, Nayakan, Kadaisi Vivasayi, a disambiguation page, a stub, a Tamil page).
- Settings route smoke on a scratch database: seeding from `ANTHROPIC_MODEL`, update, validation (negative budget is a 400 with the route's message, which needed a middleware fix to surface).
- End to end against a fake Jellyfin (five films with real IMDb ids, one without): sync, coverage run from the web UI, worklist, film panel. The run resolved Heat, Drive, Parasite and Nayakan through Wikidata to their English pages, stored plots of 3,300 to 4,200 characters and reception text of about 4,800, pulled Wikidata awards for Drive, Parasite and Nayakan, left the id-less film as `unresolved`, and metered 15 calls (`wikidata` 11, `wikimedia` 4), all 200, in about 7 s. "Change page" with `en` + `Kadaisi Vivasayi` on the id-less film fetched a verified 492-word plot. The recipe is in the owner's memory notes (`local-e2e-harness`).
- Found while doing that and fixed in `JellyfinRealtimeService`: a refused websocket upgrade left a NIO promise unfulfilled, which is a fatal error in debug builds (release builds only leaked). The reconnect loop now fails the promise and backs off.

## Not verified yet (owner touchpoints)

1. **Reader live check (plan Task 9).** No Anthropic key on this Mac. On the Pi, with `models.reader = claude-haiku-5-5`: tag two films, then confirm in `api_calls` that the second call has `cache_read_input_tokens > 0` in `units_json` and that the response parsed (a `decisions` row with `reader_json` and outcome other than `error`).
2. **Live run (plan Task 17, steps 1 to 4).** Deploy the branch to the Pi, run coverage from Settings and record the five counts and the wall-clock time, open five films from the `no_plot` and `unresolved` worklists and try a page override, run a backfill on about 50 films, then set the budget below the month-to-date spend and confirm a `skipped` decision on a realtime or scheduled tag.
3. **Mockup pick.** The two A/B choices in the Task 14 mockup were implemented as A (counts are filter pills) and B (collapsed spoiler block). Both alternatives are a small swap in `EnrichmentCoverageCard.tsx` and `StorySource.tsx`.

## Decisions and assumptions made during execution

- The settings payload is a new `GET /settings/models` next to the legacy `GET /settings/info`, not an extension of it, so the old payload stays byte-stable for the wizard. The plan said "extend"; the shape of the data is the same.
- Suggestion responses carry `source` (read from the decision's `models_json`) so the review UI can badge unverified films without a second request per row. Not in the plan.
- In the review queue, moods the policy held back render as dashed "+ Mood · 61%" proposals; one tap adds them to the edited set. For unverified films nothing is applied, so all moods are proposals and Approve stays disabled until the admin picks.
- The auto-tag dialog fetches the film's enrichment row after the suggestion (best effort) to show the page behind the story text.
- The coverage card's "English plot" pill has no worklist (nothing to fix there); the "Model synopsis" pill lists `unverified` rows.
- `tsc --noEmit` reports one pre-existing unused function (`removeTag` in `App.tsx`). The build does not run `tsc`; left as is.
- The built `public/index.html` is committed as earlier UI commits did; `public/assets` stays ignored and the Docker build regenerates everything.

## Numbers to fill after the Pi run

| Step | Value |
|---|---|
| Films total / English plot / other language / model synopsis / no plot / unresolved / errors | |
| Coverage wall-clock | |
| Reader cost per film (50-film run), cache hit rate | |
| Budget pause: skipped decision id | |
