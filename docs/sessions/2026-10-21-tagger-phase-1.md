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

## v0.2.0 rollout (2026-10-21, 07:04 to 07:49)

Tag `v0.2.0` built in 7 minutes; `docker compose pull` on the Pi brought it up at 07:12 with the `lead_text` migration. Order: coverage first (680 films in 17 minutes, 674 English plots, 1 other language, 3 no plot, 2 unresolved, 0 errors; every block rebuilt at text block version 2 with the lead), then a one-film Sonnet pre-flight (Kushi: feel-good-romance 0.82, evidence in the quote-colon form, cache write 24,647 tokens), then the watched scope re-run on `claude-sonnet-5-5`, then the reader back to Haiku for arrivals. The Mac rebooted mid-run; the Pi carried on and a resume script finished the rollout.

| Watched re-run | v1 (Haiku, 2026-10-21 05:32) | v2 (Sonnet, 07:37) |
|---|---|---|
| Films | 209 | 209 |
| Applied / review / error | 13 / 196 / 0 | 70 / 139 / 0 |
| Candidates per film | about 3 | 1.63 (plus 2.95 alternates) |
| Candidate confidence p50 / p75 / p90 | 0.70 / 0.80 / 0.85 | 0.80 / 0.85 / 0.90 |
| antihero-study applied + suggested | 13 + 31 | 4 + 4 |
| cat-and-mouse applied + suggested | 25 + 26 | 7 + 17 |
| bittersweet-aftermath applied + suggested | 5 + 43 | 7 + 4 |
| regional-gems applied + suggested | 1 + 15 | 6 + 15 |
| film-school-shelf applied + suggested | 1 + 11 | 14 + 10 |
| Wall clock | 10 min | 12 min |
| Cost | $0.13 | $3.16 ($0.0151 per film; 5.15M cached tokens read, 0 non-200 calls) |

Pending rows after the run: 144 (v1 left 197). Watched films with at least one tag: 145 of 209. Month spend $3.37 of $15. Spot checks from the samples: Rosemary's Baby horror 0.90 plus film-school-shelf 0.88 on the National Film Registry sentence; Premam coming-of-age 0.84 plus regional-gems 0.80 (just under the 0.85 floor, so review); The Handmaiden modern-masterpieces 0.88 and visual-worship 0.82; Asuran regional-gems 0.90 on the National Film Award; Singam only cat-and-mouse 0.66 (review); The Dark Knight Rises only rainy-day-rewinds 0.66 (review). rainy-day-rewinds is the most suggested-below-floor mood (30): crowd-pleasers land at 0.66 to 0.72 and go to review, which is the conservative side.

A mid-run decision row reads `error` with reason `opened` until the pipeline completes it; it is the film in flight, not a failure.

Next: the owner reviews the 144 rows in the tray (watched first). Then Start auto-tag with scope unwatched (470 films, about $0.30 on Haiku, or about $7 on Sonnet).

## v0.2.1: alternates as maybe pills, and the one-tag problem (2026-10-21, morning)

The owner asked whether the tagger was tagging one mood per film. It was: half the watched films got a single candidate, 1.63 on average, because the v2 guide asked for moods the reader "would defend" and every few-shot carried one tag. v0.2.1 (`17d1ef1`, `aa58f68`) surfaced the reader's alternates in the tray as outline "maybe" pills (one tap adds them; never applied by the policy) and loosened the guide. The Sonnet re-run still produced 1.62 candidates per film, so the unwatched run was cancelled at 48 of 471 (month spend $7.34) rather than spend $7 on under-named answers.

Guide v2.2 fixed the cause rather than the symptom: candidates are every mood whose checklist holds at 0.60 or more (two to four is typical, the cap is five), alternates are the moods considered and set aside, twelve of the examples now carry several moods of different kinds, and the schema field descriptions and the task line say the same thing. Nothing was re-run under v2.2 before v0.3.0; the first full pass under it is the v0.3.0 rollout below.

The owner's verdict on the phased delivery: stop shipping phase 1 and phase 2, build the full thing. v0.3.0 is that.

## v0.3.0: the full system (2026-10-21, built in one pass)

Server, on `gkl_web_ui_restyle` (`1a9d8d9` grader and policy, `72fa484` eval, `8231e1e` teach, `6856462` web and review semantics):

- **Jev is the classifier of record.** `JevClient` sends one `noul` question per mood plus two primary passes over the 36 slugs and `none`, the second pass in a seeded shuffle, to TypeSafe's `POST /v1/systemone` (`jev-1.13.0`, $0.042 per million input tokens, metered in `api_calls` as `typesafe`). The answer is stored on the decision as `classifier_json`. Missing or failed classifier: the film degrades to `p-legacy` and is marked unsure; an auth failure aborts the run.
- **Policy versions.** `p1` (default): a mood is applied when AI named it and Jev's probability clears the mood's floor; AI's moods below the floor are suggested; a mood AI never named but Jev puts above the high line is suggested; the two primary passes disagreeing marks the film unsure. `p0` is Jev alone, `p-legacy` is AI's confidence against the floors (the old behaviour), `pr` applies nothing. Floors default to 0.70 (0.80 for the six strict moods), high to 0.85; all three live in settings and in the UI.
- **Regrade run.** Jev and the policy again over films with a stored AI answer, no Anthropic call. Its rows are `kind = regrade`: the new decision's adds, the moods it would drop as `remove` items, and the adds it put on the film marked so a reject can take them off. Approve drops the removals and promotes the rest; reject puts the film back as it was; an edited approval keeps the owner's own earlier tags (the old override replaced every tag on the film, including the owner's).
- **Eval.** The owner's decisions replayed through every policy over the stored answers, no model call: positives are user-labelled tags, negatives are moods proposed in a row the owner resolved and did not take. Per mood: precision, recall, the Wilson 95% lower bound and the Brier score of Jev's probability, on a floor grid from 0.50 to 0.90; the suggested floor is the lowest with Wilson lower at or above the target (0.85) and at least five applied films. One call writes the suggested floors into the policy.
- **Guide and Teach.** The guide is editable (`guide.manual`, the bundled text until edited) and carries learned rules (`guide.learned`) that both AI and Jev read; every change bumps `guide.version`. Teach groups the films where the owner and the system disagree, or the system was unsure, by the two moods in question (Rule 5 pairs first, else the top two by probability); one tap answers left, right or neither; after three answers the strong model drafts up to three rules, and accepting them regrades the films on that boundary.
- Tests: 160 across 28 suites.

Web UI, X-Cache's classes throughout: a Teach page (boundary chips, cards with poster, AI's one-line read, who picked what, Jev's two probabilities, keys j k 1 2 0, Write rules dialog with editable drafts), an Accuracy page (your decisions replayed, next steps, policies side by side, floors per mood with the suggested column and one button to use them), and Settings rows for the grader, the policy, the Jev model, the TypeSafe key with a test, Regrade, the floors table and the guide editor. The Review tray shows second-look rows with the moods AI would drop as strike-through pills. Checked locally against a copy of the Pi database with a watched-scope regrade run.

Known limits: the eval needs the owner's decisions (the Pi had no user-labelled tag and two rejections when v0.3.0 shipped, so the first report is empty until the tray is worked); leave-one-out evaluation with fresh model calls, an OpenAI Decisions provider and a `scores` field in the client payload were left out.

## v0.3.0 rollout (2026-10-21, 09:12 to 10:13)

Tag `v0.3.0` built in about 7 minutes; the Pi came up on it at 09:15 with the `teach_answers` migration. The Jev key was copied on the Pi from X-Cache's secrets into Nocturne's settings (never printed); the key test answered all 36 mood questions on `jev-1.13.0`. Grader set to Jev, policy `p1`, reader `claude-sonnet-5-5`. An 8-film pre-flight under guide v2.2 gave 2.75 candidates per film (2, 2, 2, 2, 3, 3, 4, 4), so the whole library was re-read.

| Full library, reprocess-all under v0.3.0 | Result |
|---|---|
| Films | 680 in 55 minutes, 0 errors, every decision `p1` |
| AI candidates per film | mean 3.19: 0 on 3 films, 1 on 9, 2 on 117, 3 on 298, 4 on 236, 5 on 17 (v2 on Sonnet: 1.63) |
| Applied per film at the shipped floors (0.70, 0.80 on six moods) | mean 1.16: none on 191 films, 1 on 256, 2 on 181, 3 on 39, 4 on 12, 5 on 1 |
| Films with at least one tag | 489 of 680 |
| Outcomes | applied 31, review 647, none 2; pending rows 652 (the owner's confirmation of the suggestions) |
| Jev's two primary passes | agree on 596 films, disagree on 84 (those are unsure) |
| Jev probability for the moods AI named | p25 0.38, p50 0.61, p75 0.81 over 2,165 moods |
| Uniform floor replay from the stored answers | 0.50: 2.02 applied per film; 0.60: 1.66; 0.70: 1.30; 0.80: 0.85 |
| Most applied moods | film-school-shelf 76, rainy-day-rewinds 66, horror-and-unease 58, modern-masterpieces 56, regional-gems 52, existential-core 41 |
| Cost | Anthropic $11.20 ($0.0165 per film, prefix cached at 25,589 tokens), TypeSafe $1.15 ($0.0017 per film); month spend $19.91 against the $15 cap |

The reader side of the owner's complaint is fixed: three or four moods named on most films, with evidence per mood. Spot checks read well on both sides of the floor. Jev holds back the moods AI named from memory (Anchorman as a modern masterpiece 0.06, 3 Idiots as existential 0.10, Whiplash visual-worship 0.07) and backs the ones the text supports (Heat: cat-and-mouse 0.92, crime-grit-style 0.89, film-school-shelf 0.82; Nayakan: regional-gems 0.96, crime-grit-style 0.95, antihero-study 0.77, based-on-vibes-true-story 0.74). It also finds moods AI did not name (Premam feel-good-romance 0.92, 3 Idiots coming-of-age 0.82, Nayakan film-school-shelf 0.81); only those above the 0.85 high line reach the tray.

What the shipped floors cost: the six strict moods at 0.80 held back Jev-backed moods at 0.70 to 0.79 (Drishyam slow-burn-sharp-blade 0.70, Kaithi crime-grit-style 0.75, Zindagi Na Milegi Dobara regional-gems 0.77), and those floors came from the reader-only era, where the reader's own confidence sat at 0.70 to 0.90. Jev's probabilities spread lower (median 0.61 for a mood AI named), so the same number means something else. Decision taken on the owner's "take the wheel": every floor set to 0.60 in settings (the code defaults are unchanged), then a regrade of the whole library (Jev only, about $1.15, no Anthropic call). The Accuracy page suggests floors per mood once the owner has worked the tray; the eval ran on the pre-review data and is empty by construction (7 films, 0 confirmed moods, 12 rejected).

The month is over its cap: manual runs warn and continue by design, scheduled and real-time tagging pause until the cap is raised or the month rolls over. Auto-tag on sync is on, so new films will wait.

Per-film enrichment lookups fetch the full Jellyfin catalog through the admin proxy on every film (680 fetches in this run); it is the pre-existing path and did not slow the run, but it is on the backlog.

### Floors at 0.60, the regrade, and v0.3.1 (10:15 to 10:35)

The Jev-only regrade of all 680 films took 13.5 minutes and $1.15. With every floor at 0.60 the library carries 1.68 tags per film (none on 99 films, 1 on 203, 2 on 233, 3 on 111, 4 on 32, 5 on 2); 581 of 680 films have at least one mood, up from 489 at the shipped floors. Outcomes: applied 76, review 602, none 2; the grader was unsure on 173 (its two passes disagreed, or nothing cleared the floor). Pending rows 607, almost all second looks with one mood to drop across the whole set. Most applied moods: film-school-shelf 98, rainy-day-rewinds 91, bittersweet-aftermath 83, modern-masterpieces 70, horror-and-unease 62, existential-core 58. The two canon buckets together sit on a quarter of the library; whether 0.60 is too generous for them is the first thing the Accuracy page will say once the owner has reviewed. Month spend after everything: $21.06 against the $15 cap.

v0.3.1 (`81db614`, tagged and on the Pi at 10:33): Teach lists the films the grader was unsure about plus the owner's disagreements, not every review row. Under p1 almost every film carries a suggestion below the floor, so the first version put 647 of 680 films on the page; it now shows 173 films on 105 boundaries.

What the owner does next, in order: work the Review tray with the Watched scope (209 films; Approve takes AI's applied set, pills add or drop a mood); answer Teach boundaries and press Write rules after three answers; run the Accuracy page and use the suggested floors; Regrade from Settings to re-apply the floors across the library (Jev only, about $1.15). Scheduled and real-time tagging stay paused until the cap is raised or November starts.

## v0.3.2: the tray holds decisions, the spot check, and a free replay (2026-10-21, 11:00 to 12:50)

The owner's reaction to the 604-row tray: it is basically all the movies, and they cannot start reviewing while they do not trust the tags. Breaking the 604 regrade rows down by what they needed: 430 needed nothing (the applied tags were on the film and the row only asked about moods below the floor), 99 had nothing applied, 74 had Jev's two passes disagreeing, 1 had a mood to drop. The rule was ported too literally from X-Cache's unsure mark.

Three changes, tagged `v0.3.2` (`4c25d7e`):

1. **A row waits for a human only when the film is unsure** (nothing applied, the grader's passes disagreed, or the story is unverified) or a regrade would drop a mood. A suggestion below the floor rides along on an auto-approved row, and the film sheet now shows every film's newest decision (`GET /admin/movies/:id/suggestion`), so "AI also considered" never disappears. On the local copy of the Pi database the tray went from 604 rows to 192.
2. **Spot check** (`#check`, `GET /admin/verify/sample`, `POST /admin/verify`): thirty random tagged films in a seeded order, every mood as a pill with its evidence and Jev's probability, one tap marks a mood wrong, Save or Looks right, keys j k 1 to 5 Enter. A verdict removes the wrong moods, makes the kept ones the owner's, supersedes the film's open row and writes a user-resolved `verify` row: positives and negatives for the Accuracy page, a disagreement for Teach, a running precision on the page. Ten minutes of this is the first real measure of whether the tags are right.
3. **Replay** (`POST /admin/auto-tag/replay`): the policy again over the stored AI and Jev answers, no call to anyone. The floors table offers "Apply to the library (free)" after a save, and the Accuracy page runs it after adopting suggested floors. Regrade stays for a changed guide or new rules, when Jev has to read again.

Answer to the owner's cost question, recorded here: story sources are stored and were free; AI's answer per film is stored and is only re-read for a new film, Reprocess, "AI again" on a film sheet, or Write rules on Teach; Jev recurs only on Regrade ($1.15 for the library) and on accepting a rule (that boundary's films); a floor change is now free; the Accuracy page is free.

Tests: 162 across 29 suites. The HumanLabel tests now build their pending row from a grader whose passes disagree, because applied tags with a suggestion no longer make one.

On the Pi (v0.3.2 at 12:25): film-school-shelf and modern-masterpieces back to 0.80, every other floor at 0.60, then a replay of the 680 films in 7 minutes at no cost. The tray went from 604 rows to 227: 99 films with nothing applied, 64 where Jev's passes disagreed, 64 where the raised canon floors would drop a tag (the weak calls such as Conclave, Dune and Devi stay on their films until the owner approves the drop; nothing is removed silently). Teach: 178 films on 107 boundaries. Spot check: 30 films up, 551 tagged films still unjudged. Tags per film unchanged at 1.68 until the drops are approved. Month spend unchanged at $21.06.

## v0.3.3: the spot check draws from watched films (2026-10-21, 13:00 to 13:40)

The owner could not do the first 30: most cards were films they had not seen (471 of 680 are unwatched). v0.3.3 (`feat(check)`) makes the watched films the default scope, with All as the other, and adds a second set for films with no mood at all. On the Pi the watched set holds 167 tagged films (306 moods) and 42 with no mood. A no-mood card shows what AI considered with its evidence and Jev's number; the owner picks from it, from any mood, or says nothing fits. Tagged cards show what AI considered too, so a held-back mood can be added with one tap. Moods AI considered that the owner did not take count as negatives, because they were on the card; precision on the page counts only the moods AI applied. Tests: 163 across 29 suites. Checked locally on a copy of the Pi database: both sets, keys, the save flow.
