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

## Watched scope and the clean slate (same day, later)

The owner looked at the 725 "manual" tag rows and decided on a clean slate: 720 of them landed in one JSON import on 2026-04-23 (268 films, 202 without any suggestion row), so they were the old method's output, not curation. Every tag goes, and the first review baseline is the films the owner has watched: Jellyfin reports 209 of 680 as played. Shipped as `feat(tagger): watched scope`: sync stores `UserData.Played` on `movies.played`, Start auto-tag and Reprocess all take a scope (all, watched, unwatched) recorded on the run and shown in the banner, the review queue lists watched films first with a watched-only chip and a show-more control, and the auto-tag cap counts the admin's own tags.

Deployed as `v0.1.1` (the `v0.1.0` tag has no image: the Docker context lacked `Tests/` and the blanket markdown ignore dropped `Resources/guide.md`; both fixed in `build(docker)`). Linux build and tests passed on CI first. On the Pi: `docker compose pull && up -d` with sudo in `/opt/stacks/nocturneserver`, healthy on first boot, six migrations applied to the live database in two seconds (953 auto and 725 user label rows, 515 approvals marked auto, 7 approvals and 2 rejections user, 4 pending), `/version` reports v0.1.1, reader `claude-haiku-5-5`, budget $15.

## Live run on the Pi (same day, later)

Clean slate executed on v0.1.1: auto-tag on sync off, Clear local films, Sync (680 films, 209 watched), then the coverage run over all 680 from the web UI: 671 English plots, 1 other-language plot, 3 no plot, 2 unresolved, 3 errors, about 16 minutes at two Wikimedia requests a second. Two of the errors were a race in the awards label cache (three workers inserting the same `wikidata_labels` row), fixed by an upsert and tagged as `v0.1.3` together with the queue fix for pending rows of removed films (`v0.1.2`) and the api key no longer logged by the realtime listener. The Jellyfin realtime socket connected on first try; the three client routes the iOS app uses (`clients/tags/batch`, `clients/home`, `clients/omdb/ratings`, the last one now storing OMDb awards) answered on the Pi.

A hotspot drop paused the run for half an hour (the Mac fell off the LAN; the Pi was fine). Then, on v0.1.3: the three error rows refetched (674 English plots, zero errors), the reader check on two watched films passed (structured output parsed, the second call read 14,990 cached tokens for $0.00075), and the watched backfill ran over 209 films in 10 minutes for $0.13: 13 auto-applied, 196 to review, 2 films with no story source tagged on the blurb, 0 errors, 210 of 211 calls served from the prompt cache. The queue holds 197 films, watched first; 159 of the 209 watched films carry at least one applied mood (cat-and-mouse 25, ha-ha-ha 23, feel-good-romance 18 lead). Auto-tag on sync is back on. One warning seen: the reader once proposed an unknown slug (`body-horror-placeholder`), dropped as designed.

The next step is the owner's: review the 197 watched films in the queue, then Start auto-tag with scope unwatched.

## Web UI restyle (same day, evening)

The owner wants the admin UI in X-Cache Live's language. Spec: `docs/superpowers/specs/2026-10-21-web-ui-restyle-design.md`; mockup with real posters: https://claude.ai/artifact/AeMZUkQuTXFDJMka27Eo1M. Implemented on `gkl_web_ui_restyle` (cut from the tagger branch): Geist and the token set, pill primitives, one header with the search pill and the Sync menu, centred tabs, a mood band of poster collages, poster cards with pills, a Review page of rows with one-tap mood pills and keyboard moves, a film modal with the story source card and the reader's evidence, an accordion settings page, the onboarding wizard. Checked locally against the fake Jellyfin: library, settings, review, film modal. Not deployed: the owner's two picks (review page or tray, film modal or sheet) are open; A was built for both.

## Not verified yet (owner touchpoints)

1. **Reader live check (plan Task 9).** No Anthropic key on this Mac. On the Pi, with `models.reader = claude-haiku-5-5`: tag two films, then confirm in `api_calls` that the second call has `cache_read_input_tokens > 0` in `units_json` and that the response parsed (a `decisions` row with `reader_json` and outcome other than `error`).
2. **Live run (plan Task 17, steps 1 to 4).** Deploy the branch to the Pi, run coverage from Settings and record the five counts and the wall-clock time, open five films from the `no_plot` and `unresolved` worklists and try a page override, run a backfill on about 50 films, then set the budget below the month-to-date spend and confirm a `skipped` decision on a realtime or scheduled tag.

## Decisions and assumptions made during execution

- Mockup: the owner picked A for both Task 14 choices, so the coverage counts are the filter pills and the spoiler text sits behind a switch in the film panel.
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
| Films total / English plot / other language / model synopsis / no plot / unresolved / errors | 680 / 674 / 1 / 0 / 3 / 2 / 0 |
| Coverage wall-clock | about 16 min (3 workers, 2 req/s) |
| Reader cost per film (209-film run), cache hit rate | $0.00063 average, 210 of 211 calls cached |
| Budget pause: skipped decision id | not exercised yet (spend $0.14 of $15) |

## Taxonomy v2, the Wikipedia lead, the B/B restyle (same day, night)

Three things landed on `gkl_web_ui_restyle` after the watched-scope run, all uncommitted to `origin` and not deployed:

1. **Taxonomy v2** (`268a9b2`). The 212 reader outputs showed four failure modes: catch-all buckets (cat-and-mouse, crime-grit-style, antihero-study, bittersweet-aftermath proposed on a quarter of the films), canon buckets applied from memory instead of from the text (Star Wars and Rear Window as modern masterpieces, Rashomon as a regional gem), evidence that quoted a plot event without saying why it qualifies (the owner's example: "Imran, who fears heights, overcomes his phobia" made Zindagi Na Milegi Dobara a coming-of-age film), and floors between 0.65 and 0.82 with no defined meaning on the reader's compressed scale (median 0.70). Every bucket now carries "Qualifies when" conditions, text cues and anchors from this library; slugs and titles are unchanged for the iOS client. Floors: 0.85 canon and curation, 0.78 mechanics, 0.80 elsewhere. The guide gains hard gates from the lead, the evidence format, the confidence scale, the candidates versus alternates split, a thin-text rule and six examples from the failure modes. rainy-day-rewinds takes the triumphant rewatchables (Shawshank, Rocky, 3 Idiots) that had no home. The output schema describes every field the same way.
2. **The Wikipedia lead in the text block** (`62c5819`). The lead sentence carries the country, the language and the standing claims the canon buckets need. Column `lead_text`, text block version 2, shown in the story source panel. The next coverage run rebuilds every row (680 Wikipedia fetches, free) and changes every input hash.
3. **The restyle, B/B.** Review as a tray over the library, the film panel as a right-hand sheet, X-Cache's exact classes everywhere. Owner feedback the same evening: posters are just posters (no mood chips), the UI says AI and never "reader", Open in Jellyfin sits under the title. Checked locally against a copy of the Pi database (680 films, 201 pending rows, real posters) on desktop and at 375px.

Deploy order for v0.2.0 (needs the owner's go): tag, pull on the Pi, **run coverage first** (rebuilds the blocks with the lead), then re-run the watched scope under v2 (about $0.13 on Haiku; about $2 to $5 on Sonnet for the one-time baseline), then the owner reviews. Approvals already made survive as user labels. Under p-legacy the unwatched 470 will also land almost entirely in review; that is phase 1 by design.

Owner's question answered in chat: is this the right approach? The shape (checklists, a reader, the owner's review as ground truth, calibration examples per mood, eval-derived floors) is right for one person's library; no single prompt is. Two follow-ons proposed: a Sonnet pass for the one-time baseline, and a nearest-neighbour classifier over the owner's confirmed films for phase 2 instead of a second LLM pass.
