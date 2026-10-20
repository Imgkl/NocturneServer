# Tagger Rewrite, Phase 1: Ground truth and input

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Commits happen per task only when the owner has said go on execution; never push.

**Goal:** Give the tagger ground truth and a real input. After this phase every film has a canonical text block (full Wikipedia plot with spoilers, reception, awards) with a stored hash; every classification writes a decision row with raw answers and metered cost; human labels are distinguishable from auto-applied ones; the reader runs on a cheap, cached, settings-selectable model and reads the text block instead of a wrong Wikipedia extract; the self-critique pass, keyword post-filter and `fetchExternalSummary` are gone. No classifier yet (phase 2). The server keeps tagging the whole time.

**Architecture:** Four new areas inside the single `NocturneServer` executable target. **(1) `Providers/`**: one `OutboundClient` that every outbound HTTP call goes through, with retries, per-attempt `api_calls` metering, a price table and a monthly budget guard; `AnthropicClient` sits on it. **(2) `Enrichment/`**: Wikidata resolution from the IMDb id, Wikipedia extract fetch and section parsing, structured awards, OMDb awards, a deterministic `TextBlockBuilder`, an `EnrichmentService` that orchestrates them into `movie_enrichment`, and a coverage job. **(3) `Runs/`**: a `runs` table and `RunService` that replace the in-memory `BackfillStateActor` for progress, cancel and restart safety. **(4) `Tagger/`**: `ReaderService` (cache-friendly prompt, structured output, model picker), `PolicyEngine` with the phase 1 `p-legacy` version, `DecisionRecorder`, and the fallback synopsis writer. The old orchestration is replaced, not patched: `LLMService.swift`, `SuggestionService.swift` and `BackfillStateActor` are deleted whole, and their jobs move to `Tagger/TaggerPipeline` (one entry point: enrich, read, decide, record, apply), `Tagger/ReviewQueue` (approve, reject, regenerate, pending list) and `Runs/BackfillJob`. The per-tag refinement worker, its routes and its UI go with them (the owner approved scrapping structure that does not fit; the spec's phase 2 deletion moves here). The taxonomy and the manual guide leave `Configuration.swift` for `Resources/taxonomy.json` and `Resources/guide.md`, each with a version, which is the shape phase 4's Teach loop needs. `APIRoutes.swift` becomes a composition root over `Routes/*.swift` as each area is touched.

**Tech Stack:** Swift 6.0 tools (Docker builds on Swift 6.1, Ubuntu), Hummingbird 2, Fluent + FluentSQLiteDriver + HummingbirdFluent, AsyncHTTPClient, swift-crypto (SHA-256), swift-log, Swift Testing (`@Suite` / `@Test` / `#expect`) in a new `NocturneServerTests` target. Anthropic Messages API over raw HTTP (no official Swift SDK): `system` block with `cache_control`, `output_config.format` JSON schema, `output_config.effort: "low"`, web search tool `web_search_20260209` on the strong-model fallback only. Frontend: React + Vite in `frontend/nocturne-web` (both `pnpm-lock.yaml` and `package-lock.json` must stay in sync; no new dependencies expected).

**Spec:** `docs/superpowers/specs/2026-10-21-tagger-rewrite-design.md`, sections 1, 2, 5, 8, 9 and phase 1 of section 10. Read it before starting; this plan implements that scope and nothing from phases 2 to 4.

**Estimate:** 4 working days. Eighteen tasks (0 to 17); each ends with a passing `swift test` and a commit.

**Decisions this plan makes that the spec left open:** `p-legacy` floors come from `MoodBucket.minConfidence` until phase 2; the retro migration treats an approved suggestion resolved within 2 s of creation as auto; Rule 7 leaves the prompt but the reader still emits a confidence for the bridge policy; the 1.5 s backfill breather goes; the fallback synopsis uses `claude-opus-5-5`; films with no story source anywhere are tagged with today's semantics and marked on the decision, not routed to review (Task 11); enrichment fetches OMDb directly, best-effort, under a daily cap (Task 6); a 401 or 403 from any provider aborts the whole run (Tasks 8 and 15); UI work starts from a mockup the owner picks (Task 14).

---

## File Structure

### Server (`Sources/NocturneServer/`)

| File | Action | Responsibility |
|---|---|---|
| `Package.swift` | Modify | Add `NocturneServerTests` test target with fixture resources |
| `JellyfinTypes.swift` | Modify | `BaseItemDto` gains `providerIds`, `dateLastSaved` |
| `JellyfinService.swift` | Modify | Request `ProviderIds,DateLastSaved` in `fetchMovie` and `fetchAllMovies` |
| `ModelsV2.swift` | Create | Fluent models `MovieEnrichment`, `Decision`, `ApiCall`, `Run`, `WikidataLabel` |
| `Models.swift` | Modify | `MovieTag.labelSource`; `TagSuggestion.resolvedBy`, `decisionId`, `itemsJson`; `Movie.currentDecisionId`; `ReaderAnswer` value types |
| `MigrationsV2.swift` | Create | `CreateTaggerV2Tables`, `AddLabelSourceToMovieTags`, `AddResolvedByToTagSuggestions` (with retro rule), `AddCurrentDecisionToMovies` |
| `OmdbCacheStore.swift` | Modify | `awards` column, `set(imdbId:ratings:awards:)` |
| `NocturneServer.swift` | Modify | Register migrations, build `OutboundClient`, `RunService`, `EnrichmentService`, `ReaderService`; mark stale runs on boot |
| `Providers/HTTPTransport.swift` | Create | `HTTPTransport` protocol + `AsyncHTTPClientTransport` |
| `Providers/OutboundClient.swift` | Create | Retries, auth-failure classification, `api_calls` metering |
| `Providers/PriceTable.swift` | Create | Per-model prices with the date checked; `cost(for:units:)` |
| `Providers/BudgetGuard.swift` | Create | Month-to-date spend versus `budget.monthly_usd` |
| `Providers/RateLimiter.swift` | Create | Token-bucket actor (Wikimedia 2 req/s) |
| `Providers/AnthropicClient.swift` | Create | `messages(request:)` on `OutboundClient`; replaces `callAnthropicText` |
| `Enrichment/WikidataResolver.swift` | Create | IMDb id, TMDb id, title search to QID + sitelinks + award claims |
| `Enrichment/WikipediaClient.swift` | Create | `extracts` API fetch for a site and title |
| `Enrichment/SectionParser.swift` | Create | Split extract into sections; pick plot and reception with caps |
| `Enrichment/AwardsResolver.swift` | Create | Batched Wikidata label lookup with `wikidata_labels` cache; best-effort OMDb fetch under a daily cap |
| `Enrichment/TextBlockBuilder.swift` | Create | Deterministic block + SHA-256 `input_hash` |
| `Enrichment/EnrichmentService.swift` | Create | Orchestration, override handling, source flags, storage |
| `Enrichment/EnrichCoverageJob.swift` | Create | Library-wide resolve and fetch, no model calls, stats |
| `Runs/RunService.swift` | Create | Create, tick, cancel, finish, stale-on-boot; `BackfillStatus` adapter |
| `Tagger/ReaderPrompt.swift` | Create | Static system block (rules + buckets, no min-confidence lines) + user turn assembly |
| `Tagger/ReaderService.swift` | Create | Anthropic request with cache control + structured output; decode `ReaderAnswer` |
| `Tagger/PolicyEngine.swift` | Create | Pure function; phase 1 version `p-legacy` |
| `Tagger/DecisionRecorder.swift` | Create | Write `decisions` row, set `movies.current_decision_id`, build suggestion `items_json` |
| `Tagger/FallbackSynopsisService.swift` | Create | Strong model + web search writes plot and reception, flagged unverified |
| `Tagger/TaggerPipeline.swift` | Create | One entry point for realtime, manual and backfill tagging: enrich, read, decide, record, apply |
| `Tagger/ReviewQueue.swift` | Create | Pending list, approve, reject, regenerate; sets `resolved_by` and `label_source` |
| `Runs/BackfillJob.swift` | Create | Backfill and reprocess-all over `RunService`, calibration built once per run |
| `Taxonomy.swift` | Create | Loads `Resources/taxonomy.json` (`MoodBucket` dictionary + `taxonomyVersion`) and `Resources/guide.md` |
| `Resources/taxonomy.json`, `Resources/guide.md` | Create | The 36 buckets and the manual guide, moved out of `Configuration.swift` |
| `TagCalibration.swift` | Modify | Human-sourced labels only |
| `LLMService.swift` | Delete | Reader lives in `Tagger/ReaderService`; nothing else survives |
| `SuggestionService.swift` | Delete | Replaced by `TaggerPipeline`, `ReviewQueue`, `BackfillJob`; refinement worker gone |
| `Configuration.swift` | Modify | `moodBuckets` and `autoTaggingPrompt` removed (Task 16); `maxAutoTags`, keys and paths stay |
| `APIRoutes.swift` | Modify | Becomes the composition root; routes move to `Routes/EnrichmentRoutes.swift`, `Routes/TaggerRoutes.swift`, `Routes/SettingsRoutes.swift` as touched |
| `MovieService.swift` | Modify | `updateMovieTags` takes `labelSource` |
| `JellyfinRealtimeService.swift` | Modify | Calls `TaggerPipeline.tagInBackground` |

### Tests (`Tests/NocturneServerTests/`)

| File | Covers |
|---|---|
| `Support/TestDatabase.swift` | In-memory SQLite Fluent with all migrations |
| `Support/FakeTransport.swift` | Scripted HTTP responses for `OutboundClient` |
| `Fixtures/` | Saved Wikidata and Wikipedia JSON (Heat, Drive, Parasite, Nayakan, Kadaisi Vivasayi, a disambiguation page, a stub page), an OMDb response, an Anthropic structured-output response |
| `JellyfinDtoTests.swift` | Task 1 |
| `MigrationTests.swift` | Task 2 |
| `OutboundClientTests.swift`, `PriceTableTests.swift`, `BudgetGuardTests.swift` | Task 3 |
| `WikidataResolverTests.swift` | Task 4 |
| `SectionParserTests.swift`, `WikipediaClientTests.swift` | Task 5 |
| `AwardsResolverTests.swift`, `OmdbCacheStoreTests.swift` | Task 6 |
| `TextBlockBuilderTests.swift`, `EnrichmentServiceTests.swift` | Task 7 |
| `RunServiceTests.swift`, `EnrichCoverageJobTests.swift` | Task 8 |
| `ReaderPromptTests.swift`, `ReaderServiceTests.swift` | Task 9 |
| `TagCalibrationTests.swift` | Task 10 |
| `PolicyEngineTests.swift`, `DecisionRecorderTests.swift`, `SuggestionFlowTests.swift` | Task 11 |
| `HumanLabelTests.swift` | Task 12 |
| `FallbackSynopsisTests.swift` | Task 13 |
| `BackfillRunTests.swift` | Task 15 |

### Frontend (`frontend/nocturne-web/src/`)

| File | Action | Responsibility |
|---|---|---|
| `lib/api.ts`, `lib/types.ts` | Modify | Enrichment, coverage, models settings endpoints and types |
| `components/ModelSettings.tsx` | Create | Reader model, strong model, monthly budget, model fallback toggle |
| `components/EnrichmentCoverageCard.tsx` | Create | Run button, progress, counts, worklist |
| `components/MovieDetailPanel.tsx` | Modify | Enrichment section: page, source, override, refresh, show spoilers, generate synopsis |
| `components/AutoTagQueue.tsx` | Modify | `unverified source` badge; per-mood evidence from `items_json` |
| `components/TagRefineProgress.tsx` | Delete | Refinement worker is gone |
| `App.tsx` | Modify | Mount the two new components in Settings; remove the per-tag refine control |

### CI

| File | Action |
|---|---|
| `.github/workflows/test.yml` | Create: `swift build` + `swift test` in a `swift:6.1` container on every PR |

---

## Tasks

### Task 0: Test target and CI

**Files:**
- Modify: `Package.swift`
- Create: `Tests/NocturneServerTests/SmokeTests.swift`, `Tests/NocturneServerTests/Support/TestDatabase.swift`, `Tests/NocturneServerTests/Fixtures/.keep`
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Add the test target**

```swift
.testTarget(
    name: "NocturneServerTests",
    dependencies: ["NocturneServer"],
    resources: [.copy("Fixtures")]
)
```

`@testable import NocturneServer` works against an executable target on Swift 5.5+ toolchains, which covers 6.0 and 6.1. If `swift build` complains about `@main` in a testable executable, move `NocturneServer.swift`'s `@main` struct into `Sources/NocturneServerMain/main.swift` and make `NocturneServer` a library target; do that only if needed.

- [ ] **Step 2: In-memory database helper**

```swift
import FluentKit
import FluentSQLiteDriver
import HummingbirdFluent
import Logging
@testable import NocturneServer

func makeTestFluent() async throws -> Fluent {
    let fluent = Fluent(logger: Logger(label: "test"))
    fluent.databases.use(.sqlite(.memory), as: .sqlite)
    try await runMigrations(fluent: fluent, logger: Logger(label: "test"))
    return fluent
}
```

`runMigrations` already exists in `NocturneServer.swift`; make it `internal` if it is not.

- [ ] **Step 3: Smoke test**

```swift
import Testing
@testable import NocturneServer

@Suite struct SmokeTests {
    @Test func migrationsRunOnEmptyDatabase() async throws {
        let fluent = try await makeTestFluent()
        let count = try await Movie.query(on: fluent.db()).count()
        #expect(count == 0)
        try await fluent.shutdown()
    }
}
```

- [ ] **Step 4: CI workflow**

```yaml
name: test
on: [pull_request, push]
jobs:
  swift:
    runs-on: ubuntu-latest
    container: swift:6.1
    steps:
      - uses: actions/checkout@v4
      - run: swift build
      - run: swift test
```

- [ ] **Step 5: Run**

```bash
swift test 2>&1 | tail -5
```
Expected: 1 test passed.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Tests .github/workflows/test.yml
git commit -m "test: add NocturneServerTests target + CI test job

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 1: Jellyfin DTO carries `ProviderIds` and `DateLastSaved`

**Files:**
- Modify: `Sources/NocturneServer/JellyfinTypes.swift`, `Sources/NocturneServer/JellyfinService.swift`
- Create: `Tests/NocturneServerTests/JellyfinDtoTests.swift`

- [ ] **Step 1: Failing test**

Decode a fixture item with `"ProviderIds": {"Imdb": "tt0113277", "Tmdb": "949"}` and `"DateLastSaved": "2026-05-01T10:00:00.0000000Z"`; expect `providerIds?["Imdb"] == "tt0113277"` and `dateLastSaved != nil`.

- [ ] **Step 2: Implement**

Add to `BaseItemDto`: `let providerIds: [String: String]?` (`"ProviderIds"`) and `let dateLastSaved: String?` (`"DateLastSaved"`). Keep it a string; Jellyfin's 7-digit fractional seconds break `ISO8601DateFormatter`; compare as strings for change detection.

In `JellyfinService.fetchMovie` change `Fields=Overview,Genres,People` to `Fields=Overview,Genres,People,ProviderIds,DateLastSaved`. In `fetchAllMovies` change `"Fields": "Overview,Genres,ProviderIds"` to `"Overview,Genres,ProviderIds,DateLastSaved"`.

- [ ] **Step 3: Run, commit**

```bash
swift test --filter JellyfinDtoTests 2>&1 | tail -3
git add Sources/NocturneServer/JellyfinTypes.swift Sources/NocturneServer/JellyfinService.swift Tests
git commit -m "feat(jellyfin): decode ProviderIds and DateLastSaved

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Schema for enrichment, decisions, api_calls, runs, labels

**Files:**
- Create: `Sources/NocturneServer/ModelsV2.swift`, `Sources/NocturneServer/MigrationsV2.swift`
- Modify: `Sources/NocturneServer/Models.swift`, `Sources/NocturneServer/NocturneServer.swift`, `Sources/NocturneServer/OmdbCacheStore.swift`
- Create: `Tests/NocturneServerTests/MigrationTests.swift`

- [ ] **Step 1: Failing tests**

1. After migrations, tables `movie_enrichment`, `decisions`, `api_calls`, `runs`, `wikidata_labels` exist (insert and read one row each through the models).
2. Seed legacy rows before the migration (use the old models' field names via raw SQL): a `movie_tags` row with `added_by_auto_tag = 1` becomes `label_source = 'auto'`, one with `0` becomes `'user'`.
3. Seed three `tag_suggestions`: approved with `resolved_at == created_at` (auto), approved with `resolved_at = created_at + 90 s` (user), rejected (user). Expect `resolved_by` to be `auto`, `user`, `user`; a pending row stays `nil`.
4. `omdb_cache` gains `awards` after `ensureTable()` on a pre-existing table without it.

- [ ] **Step 2: Models**

`ModelsV2.swift`:

```swift
final class MovieEnrichment: Model, @unchecked Sendable {
    static let schema = "movie_enrichment"
    @ID(custom: "jellyfin_id", generatedBy: .user) var id: String?
    @OptionalField(key: "imdb_id") var imdbId: String?
    @OptionalField(key: "tmdb_id") var tmdbId: String?
    @OptionalField(key: "wikidata_qid") var wikidataQid: String?
    @OptionalField(key: "wiki_site") var wikiSite: String?
    @OptionalField(key: "wiki_title") var wikiTitle: String?
    @OptionalField(key: "wiki_title_override") var wikiTitleOverride: String?
    @OptionalField(key: "identity_json") var identityJson: String?
    @OptionalField(key: "overview_text") var overviewText: String?
    @OptionalField(key: "plot_text") var plotText: String?
    @OptionalField(key: "reception_text") var receptionText: String?
    @OptionalField(key: "awards_json") var awardsJson: String?
    @OptionalField(key: "omdb_awards") var omdbAwards: String?
    @OptionalField(key: "text_block") var textBlock: String?
    @OptionalField(key: "input_hash") var inputHash: String?
    @Field(key: "source") var source: String          // wikipedia | wikipedia_other_lang | model | none
    @Field(key: "unverified") var unverified: Bool
    @Field(key: "plot_found") var plotFound: Bool
    @Field(key: "enrich_version") var enrichVersion: Int
    @OptionalField(key: "jellyfin_last_saved") var jellyfinLastSaved: String?
    @OptionalField(key: "fetched_at") var fetchedAt: Date?
    @OptionalField(key: "error") var error: String?
}
```

`Decision` (schema `decisions`): `id` UUID, `jellyfinId`, `runId: UUID?`, `inputHash: String?`, `enrichVersion: Int`, `taxonomyVersion: Int`, `guideVersion: Int`, `policyVersion: String`, `classifierProvider: String?`, `readerJson: String?`, `classifierJson: String?`, `appliedJson: String`, `suggestedJson: String`, `unsure: Bool`, `outcome: String`, `reasonsJson: String`, `modelsJson: String`, `costUsd: Double`, `createdAt` timestamp.

`ApiCall` (schema `api_calls`): `id`, `runId: UUID?`, `decisionId: UUID?`, `provider`, `endpoint`, `model: String?`, `attempt: Int`, `httpStatus: Int?`, `durationMs: Int`, `unitsJson: String`, `costUsd: Double`, `createdAt`.

`Run` (schema `runs`): `id`, `kind`, `trigger`, `status` (`running`, `done`, `cancelled`, `error`), `paramsJson`, `statsJson`, `costJson`, `cancelRequested: Bool`, `total: Int`, `processed: Int`, `startedAt: Date?`, `finishedAt: Date?`, `heartbeatAt: Date?`.

`WikidataLabel` (schema `wikidata_labels`): `id` custom `qid`, `label`, `fetchedAt`.

In `Models.swift`: `MovieTag` gains `@Field(key: "label_source") var labelSource: String`; `TagSuggestion` gains `@OptionalField(key: "resolved_by") var resolvedBy: String?`, `@OptionalField(key: "decision_id") var decisionId: UUID?`, `@OptionalField(key: "items_json") var itemsJson: String?`; `Movie` gains `@OptionalField(key: "current_decision_id") var currentDecisionId: UUID?`.

- [ ] **Step 3: Migrations**

`CreateTaggerV2Tables`: Fluent `schema(...)` builders for the five tables (`movie_enrichment` keyed by `jellyfin_id` string, unique).

`AddLabelSourceToMovieTags`: raw `ALTER TABLE movie_tags ADD COLUMN label_source TEXT NOT NULL DEFAULT 'auto'` then `UPDATE movie_tags SET label_source = CASE WHEN added_by_auto_tag = 1 THEN 'auto' ELSE 'user' END`.

`AddResolvedByToTagSuggestions`: three `ALTER TABLE ... ADD COLUMN` statements (`resolved_by TEXT`, `decision_id TEXT`, `items_json TEXT`), then compute `resolved_by` in Swift, not SQL, so the stored date format does not matter:

```swift
let rows = try await TagSuggestion.query(on: database).all()
for row in rows {
    switch row.status {
    case "approved":
        if let c = row.createdAt, let r = row.resolvedAt, r.timeIntervalSince(c) < 2 { row.resolvedBy = "auto" }
        else { row.resolvedBy = "user" }
    case "rejected": row.resolvedBy = "user"
    default: row.resolvedBy = nil
    }
    try await row.save(on: database)
}
```

`AddCurrentDecisionToMovies`: `ALTER TABLE movies ADD COLUMN current_decision_id TEXT`.

Register all four in `runMigrations` after `AddKindToTagSuggestions`. SQLite `ALTER TABLE ADD COLUMN` is not idempotent; each `prepare` is guarded by a `PRAGMA table_info` check so a half-applied migration can be re-run.

`OmdbCacheStore.ensureTable()`: after `CREATE TABLE IF NOT EXISTS`, check `PRAGMA table_info(omdb_cache)` for `awards`; if missing, `ALTER TABLE omdb_cache ADD COLUMN awards TEXT`. Extend `OmdbCacheEntry` with `awards: String?` and `set(imdbId:ratings:awards:)`.

- [ ] **Step 4: Run, commit**

```bash
swift test --filter MigrationTests 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(db): enrichment, decisions, api_calls, runs tables + label_source and resolved_by

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Outbound client with metering, price table and budget guard

**Files:**
- Create: `Sources/NocturneServer/Providers/HTTPTransport.swift`, `OutboundClient.swift`, `PriceTable.swift`, `BudgetGuard.swift`, `RateLimiter.swift`, `AnthropicClient.swift`
- Modify: `Sources/NocturneServer/LLMService.swift` (shim `callAnthropicText` onto `AnthropicClient` so the old path keeps running until Task 11 deletes the file)
- Create: `Tests/NocturneServerTests/Support/FakeTransport.swift`, `OutboundClientTests.swift`, `PriceTableTests.swift`, `BudgetGuardTests.swift`

- [ ] **Step 1: Failing tests**

`OutboundClientTests`:
1. 429 then 200: two attempts, two `api_calls` rows, the second with `attempt == 2`, total sleep follows `Retry-After: 3`.
2. 529, 529, 200 without `Retry-After`: delays 1 s and 2 s (inject a `sleep` closure; assert the recorded delays).
3. 401: throws `OutboundError.authFailure`, no retry, one row with `http_status 401`.
4. Five 429s: throws `OutboundError.exhausted`, six rows.
5. Network error: one row with `http_status nil`, throws `OutboundError.transport`.
6. Bodies, headers and keys never appear in `units_json` or logs (assert the row's `units_json` equals the units the caller passed).

`PriceTableTests`: `claude-haiku-5-5` with 9,000 cache-read, 1,000 fresh input, 300 output tokens costs 0.009 × 0.01 + 0.001 × 0.10 + 0.0003 × 0.50 = $0.00034; unknown model returns 0 and logs once.

`BudgetGuardTests`: month-to-date sums only this month's rows; `allow(.scheduled)` is false at or over the cap, `allow(.manual)` is true with a warning flag.

- [ ] **Step 2: Transport protocol**

```swift
struct OutboundResponse: Sendable { let status: Int; let headers: [String: String]; let body: Data }

protocol HTTPTransport: Sendable {
    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> OutboundResponse
}

struct AsyncHTTPClientTransport: HTTPTransport { let client: HTTPClient /* wraps execute + body.collect(upTo:) */ }
```

- [ ] **Step 3: OutboundClient**

```swift
struct CallContext: Sendable { var runId: UUID?; var decisionId: UUID? }
struct CallUnits: Codable, Sendable { var inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, questions, images: Int? }

final class OutboundClient: Sendable {
    init(transport: HTTPTransport, fluent: Fluent, prices: PriceTable, logger: Logger,
         sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })

    func send(provider: String, endpoint: String, model: String?, request: HTTPClientRequest,
              timeout: TimeAmount, context: CallContext,
              units: @Sendable (OutboundResponse) -> CallUnits) async throws -> OutboundResponse
}
```

Rules: retry on 429, 529 and any 5xx with delays 1, 2, 4, 8 s plus up to 500 ms jitter, `Retry-After` wins when present, five retries maximum; 401 and 403 throw `authFailure` immediately; every attempt writes one `ApiCall` row with duration, status, `units_json` and `cost_usd = prices.cost(provider:model:units:)`. Never log request or response bodies or headers.

- [ ] **Step 4: PriceTable**

A static table keyed by provider and model with `inputPerM`, `outputPerM`, `cacheReadPerM`, `cacheWritePerM`, `perCall` and `checkedOn: "2026-10-21"`. Entries: `claude-haiku-5-5` 0.10 / 0.50 / 0.01 / 0.125; `claude-sonnet-5-5` 2 / 10 / 0.20 / 2.50; `claude-opus-5-5` 4 / 20 / 0.20 / 5; `claude-opus-4-7` 5 / 25 / 0.50 / 6.25; `wikimedia`, `wikidata`, `omdb` all 0. Anthropic web search: `perCall` left at 0 with a `TODO verify` comment and a log line; the fallback synopsis task records `questions: 1` per search so the price can be filled in later without losing data.

- [ ] **Step 5: BudgetGuard and RateLimiter**

`BudgetGuard(fluent:settings:)`: `monthToDateSpend()` sums `api_calls.cost_usd` where `created_at >= firstOfMonth` (computed in Swift, filtered with Fluent); `allow(_ kind: RunTrigger) async throws -> BudgetVerdict` returns `.ok`, `.paused(spent, cap)` for `.scheduled` and `.realtime`, `.warn(spent, cap)` for `.manual`.

`RateLimiter` actor: `init(perSecond: Double)`, `await limiter.acquire()`; token bucket with capacity equal to `perSecond`.

- [ ] **Step 6: AnthropicClient**

```swift
struct AnthropicClient: Sendable {
    let outbound: OutboundClient
    func messages(apiKey: String, body: Data, model: String, maxTokens: Int,
                  context: CallContext) async throws -> AnthropicMessageResponse
}
```

Headers as today (`x-api-key`, `anthropic-version: 2023-06-01`, `content-type`). `units` closure reads `usage.input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` from the response. `AnthropicMessageResponse` keeps `content`, `stop_reason`, `usage`. Turn `LLMService.callAnthropicText` into a three-line shim over `AnthropicClient.messages` so the existing enqueue path keeps compiling and gets metered from this task on; the whole file is deleted in Task 11.

- [ ] **Step 7: Wire in `NocturneServer.swift`**

Build `OutboundClient(transport: AsyncHTTPClientTransport(client: httpClient), fluent:, prices: .current, logger:)` once; pass it to `LLMService` and, in later tasks, to the enrichment and reader services.

- [ ] **Step 8: Run, commit**

```bash
swift test --filter 'OutboundClientTests|PriceTableTests|BudgetGuardTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(providers): outbound client with retries, api_calls metering, price table, budget guard

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Wikidata resolver

**Files:**
- Create: `Sources/NocturneServer/Enrichment/WikidataResolver.swift`
- Create: `Tests/NocturneServerTests/WikidataResolverTests.swift`, fixtures `Fixtures/wikidata/search-imdb-tt0113277.json`, `entity-Q42198.json`, `search-title-kadaisi.json`, `entity-Q60738204.json`

- [ ] **Step 1: Capture fixtures**

```bash
UA='NocturneServer-tests/0.1 (contact: <your email>)'
F=Tests/NocturneServerTests/Fixtures/wikidata; mkdir -p $F
curl -s -A "$UA" 'https://www.wikidata.org/w/api.php?action=query&list=search&srsearch=haswbstatement:P345=tt0113277&format=json' > $F/search-imdb-tt0113277.json
curl -s -A "$UA" 'https://www.wikidata.org/w/api.php?action=wbgetentities&ids=Q42198&props=sitelinks|claims&sitefilter=enwiki|tawiki|mlwiki|hiwiki|knwiki|tewiki|bnwiki&format=json' > $F/entity-Q42198.json
curl -s -A "$UA" 'https://www.wikidata.org/w/api.php?action=wbsearchentities&search=Kadaisi%20Vivasayi&language=en&type=item&limit=5&format=json' > $F/search-title-kadaisi.json
curl -s -A "$UA" 'https://www.wikidata.org/w/api.php?action=wbgetentities&ids=Q60738204&props=sitelinks|claims&sitefilter=enwiki|tawiki|mlwiki|hiwiki|knwiki|tewiki|bnwiki&format=json' > $F/entity-Q60738204.json
```

Strip nothing; the resolver must cope with the real shape.

- [ ] **Step 2: Failing tests**

1. IMDb `tt0113277` resolves to `Q42198`, `enwiki` title `Heat (1995 film)`, no other sitelinks, empty awards.
2. Title search "Kadaisi Vivasayi" with year 2022 picks `Q60738204` (the film, not the soundtrack `Q123703039`), `imdbId == "tt10300570"`, sitelinks include `tawiki`.
3. Entity `Q61448040` (Parasite, add its fixture) yields `P166` claims with `P585` years and `P1411` claims.
4. No hit returns `.unresolved(reason:)`, never throws.

- [ ] **Step 3: Implement**

```swift
struct WikidataResolution: Sendable {
    let qid: String
    let sitelinks: [String: String]       // "enwiki": "Heat (1995 film)"
    let imdbId: String?
    let tmdbId: String?
    let awardsWon: [AwardClaim]           // qid + year
    let awardsNominated: [AwardClaim]
}

struct WikidataResolver: Sendable {
    let outbound: OutboundClient; let limiter: RateLimiter; let userAgent: String
    func resolve(imdbId: String?, tmdbId: String?, title: String, year: Int?, context: CallContext) async throws -> WikidataResolution?
}
```

Order: `haswbstatement:P345=<imdb>`, then `P4947=<tmdb>`, then `wbsearchentities` by title filtered through `wbgetentities` claims: `P31` must contain a film class (`Q11424` film or its common subclasses: accept any `P31` whose label we do not need; use the `P577` year within one year of `year` as the discriminator, and require a `P345` or `P4947` claim to exist). Every call goes through `outbound.send(provider: "wikidata", ...)` after `limiter.acquire()`.

- [ ] **Step 4: Run, commit**

```bash
swift test --filter WikidataResolverTests 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(enrichment): Wikidata resolver by IMDb id, TMDb id and title

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Wikipedia extract fetch and section parsing

**Files:**
- Create: `Sources/NocturneServer/Enrichment/WikipediaClient.swift`, `SectionParser.swift`
- Create: `Tests/NocturneServerTests/SectionParserTests.swift`, `WikipediaClientTests.swift`, fixtures `Fixtures/wikipedia/heat-1995-film.json`, `drive-2011-film.json`, `parasite-2019-film.json`, `nayakan.json`, `kadaisi-vivasayi.json`, `drive-disambiguation.json`, `stub-no-plot.json`

- [ ] **Step 1: Capture fixtures**

```bash
UA='NocturneServer-tests/0.1 (contact: <your email>)'
F=Tests/NocturneServerTests/Fixtures/wikipedia; mkdir -p $F
for t in 'Heat (1995 film)' 'Drive (2011 film)' 'Parasite (2019 film)' 'Nayakan' 'Kadaisi Vivasayi' 'Drive'; do
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$t")
  out=$(echo "$t" | tr 'A-Z ()' 'a-z--' | tr -s '-' | sed 's/-$//')
  curl -s -A "$UA" "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exsectionformat=wiki&redirects=1&format=json&titles=$enc" > "$F/$out.json"
done
```

Rename `drive.json` to `drive-disambiguation.json`. For `stub-no-plot.json` take any short film article without a Plot section (search for one; a 1920s short usually works) or hand-edit a copy of `nayakan.json` with the Plot section removed.

- [ ] **Step 2: Failing tests**

`SectionParserTests`:
1. Heat: `plot` has 655 words (allow ±5 for whitespace), `reception` is non-empty and comes from `Reception`, `Accolades` and `Release` headings.
2. Disambiguation page: `plot == nil`, `isDisambiguation == true` (detect the phrase "may refer to" in the lead, or the `disambiguation` category when present in the extract).
3. Stub without a plot: `plot == nil`, `reception` may be nil, no throw.
4. Cap: a synthetic 4,000-word plot is cut to 2,500 words keeping the first 1,500 and the last 1,000, joined by one line reading `[...]`.
5. Heading matching is case-insensitive and tolerates `Plot summary`, `Synopsis`, `Story`, `Premise`, `Critical reception`, `Awards and nominations`, `Box office`.

`WikipediaClientTests` (FakeTransport): builds the right URL for `site = "tawiki"` (`https://ta.wikipedia.org/w/api.php`), passes the User-Agent, maps `missing` pages to `nil`, goes through the rate limiter.

- [ ] **Step 3: Implement**

```swift
struct ParsedArticle: Sendable { let lead: String; let sections: [(heading: String, body: String)]; let isDisambiguation: Bool }
enum SectionParser {
    static func parse(_ extract: String) -> ParsedArticle
    static func plot(from: ParsedArticle, capWords: Int = 2_500) -> String?
    static func reception(from: ParsedArticle, capWords: Int = 800) -> String?
}
```

Split on lines matching `^==+ *(.+?) *==+$`. Plot: first heading matching `(?i)^(plot|synopsis|story|premise)`. Reception: all headings matching `(?i)(reception|critical|accolades|awards|legacy|release|box office)`, in document order, capped at 800 words from the start.

- [ ] **Step 4: Run, commit**

```bash
swift test --filter 'SectionParserTests|WikipediaClientTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(enrichment): Wikipedia extract client + section parser

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Awards: Wikidata labels and OMDb `Awards`

**Files:**
- Create: `Sources/NocturneServer/Enrichment/AwardsResolver.swift`
- Modify: `Sources/NocturneServer/APIRoutes.swift` (`RawOmdbResponse` gains `Awards`), `Sources/NocturneServer/OmdbCacheStore.swift`
- Create: `Tests/NocturneServerTests/AwardsResolverTests.swift`, `OmdbCacheStoreTests.swift`, fixture `Fixtures/wikidata/labels-batch.json`, `Fixtures/omdb/heat.json`

- [ ] **Step 1: Failing tests**

1. 120 award QIDs produce three `wbgetentities` calls of at most 50 ids; labels land in `wikidata_labels`; a second resolve makes zero calls.
2. Output is `[Award(name:kind:year:)]` sorted won-first then by year descending, deterministic.
3. `RawOmdbResponse` decodes `Awards` when present and `nil` when absent; `OmdbCacheStore.set` stores it and `get` returns it.
4. `omdbAwards(imdbId:)` returns the cached value without a call when a row exists; with no row and a key configured it fetches once, stores ratings and awards together, and returns the awards; with no key it returns `nil`; after 900 OMDb calls today (count `api_calls` rows with `provider == "omdb"` since local midnight) it returns `nil` and logs the cap once per day.

- [ ] **Step 2: Implement**

`AwardsResolver(outbound:fluent:limiter:omdbCache:settings:)` with `labels(for qids: [String]) async throws -> [String: String]` (cache first, batched fetch for misses, `props=labels&languages=en`), `awards(from resolution: WikidataResolution) async throws -> [Award]`, and `omdbAwards(imdbId:context:) async -> String?`.

OMDb: the ratings route keeps working as today and now also stores `Awards` through `cache.set(imdbId:ratings:awards:)`. Enrichment does not wait for a client to open the film: on a cache miss with a key configured it calls OMDb itself through `OutboundClient` (`provider: "omdb"`), best-effort, never failing the enrichment, under a cap of 900 calls per local day because the free tier allows 1,000. A fresh 5,000-film library therefore fills in over about six days of coverage runs; the block writes `(none)` until then. Side effect worth having: the ratings cache fills for every film too, which is what the mobile repo's sub-project #3.5 needs.

- [ ] **Step 3: Run, commit**

```bash
swift test --filter 'AwardsResolverTests|OmdbCacheStoreTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(enrichment): structured awards from Wikidata + OMDb awards passthrough

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Text block builder and EnrichmentService

**Files:**
- Create: `Sources/NocturneServer/Enrichment/TextBlockBuilder.swift`, `EnrichmentService.swift`
- Create: `Tests/NocturneServerTests/TextBlockBuilderTests.swift`, `EnrichmentServiceTests.swift`, golden file `Fixtures/golden/heat-text-block.txt`

- [ ] **Step 1: Failing tests**

`TextBlockBuilderTests`:
1. Heat inputs produce exactly the golden file (write the golden file from the spec's example format on the first run, review it by eye, then lock it).
2. Missing sections render as `(none)`; the `Source` line shows `verified` or `unverified`.
3. `inputHash` is the SHA-256 hex of the UTF-8 block; the same inputs twice give the same hash; changing one cast name changes it.
4. The block never contains the strings `Min confidence` or `Recent user decisions` (it is input, not prompt).

`EnrichmentServiceTests` (fakes for Jellyfin, resolver, Wikipedia, awards, OMDb cache):
1. Happy path writes a `movie_enrichment` row with `source = wikipedia`, `plot_found = true`, `unverified = false`, `wiki_site = enwiki`.
2. No enwiki but `tawiki` present uses the Tamil page, `source = wikipedia_other_lang`.
3. Override set: resolver is not called, the override title is fetched.
4. Unchanged `DateLastSaved` and same `enrich_version`: no network calls, row untouched (`fetched_at` unchanged) unless `force`.
5. Resolver or fetch failure: row saved with `source = none`, `error` set, no throw.
6. Disambiguation page: treated as no plot (`plot_found = false`), `wiki_title` kept so the admin can see what matched.

- [ ] **Step 2: Implement**

```swift
struct TextBlockInput: Sendable {
    var title, originalTitle: String?; var year: Int?; var director: String?; var runtimeMinutes: Int?
    var genres: [String]; var cast: [String]; var overview: String?
    var plot: String?; var reception: String?; var awards: [Award]; var omdbAwards: String?
    var pageTitle: String?; var pageSite: String?; var fetchedOn: String; var unverified: Bool
}
enum TextBlockBuilder {
    static let version = 1
    static func build(_ input: TextBlockInput) -> (block: String, hash: String)
}
```

`EnrichmentService(fluent:jellyfin:resolver:wikipedia:awards:omdbCache:logger:)`:

```swift
func enrich(jellyfinId: String, item: BaseItemDto? = nil, force: Bool = false, context: CallContext) async throws -> MovieEnrichment
func override(jellyfinId: String, site: String, title: String) async throws -> MovieEnrichment   // sets override, then enrich(force: true)
func current(jellyfinId: String) async throws -> MovieEnrichment?
```

Callers that already hold the Jellyfin item (the enqueue flow) pass it in; the coverage job lets `enrich` fetch it. Order inside `enrich`: load existing row; fetch the Jellyfin item unless given; skip when not forced and `jellyfinLastSaved == item.dateLastSaved && enrichVersion == TextBlockBuilder.version && error == nil`; resolve (unless override); pick site (`enwiki` first, then the first of `tawiki, mlwiki, hiwiki, knwiki, tewiki, bnwiki`); fetch; parse; awards; OMDb awards from cache; build block; save. Identity fields come from the Jellyfin item every time (`identity_json` is a record of what was used, not a source).

- [ ] **Step 3: Run, commit**

```bash
swift test --filter 'TextBlockBuilderTests|EnrichmentServiceTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(enrichment): deterministic text block + EnrichmentService

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: RunService and the coverage job, with routes

**Files:**
- Create: `Sources/NocturneServer/Runs/RunService.swift`, `Sources/NocturneServer/Enrichment/EnrichCoverageJob.swift`
- Modify: `Sources/NocturneServer/APIRoutes.swift`, `Sources/NocturneServer/NocturneServer.swift`
- Create: `Tests/NocturneServerTests/RunServiceTests.swift`, `EnrichCoverageJobTests.swift`

- [ ] **Step 1: Failing tests**

`RunServiceTests`:
1. `start(kind: .enrichCoverage, trigger: .manual, total: 10)` creates a `running` row; a second `start` of any kind while one is running throws `RunError.busy` with the running run's id.
2. `tick(id, processed: 3, stats: ["english_plot": 2])` persists; `heartbeat_at` moves.
3. `requestCancel(id)` flips the flag; `isCancelled(id)` reads it; `finish(id, .cancelled)` sets `finished_at`.
4. `markStaleOnBoot()` turns a `running` row with `heartbeat_at` older than 10 minutes into `error` with a reason.
5. `backfillStatus()` maps the latest backfill run onto the existing `BackfillStatus` shape (`running`, `total`, `processed`, `startedAt`, `cancelled`).
6. `abort(id, reason: "auth")` finishes the run as `error` with the reason and makes `isCancelled(id)` true, so no worker claims another film.

`EnrichCoverageJobTests` (fake `EnrichmentService`): 20 films, concurrency 3, one cancel after 5: processed is at least 5 and at most 8, stats count `english_plot`, `other_lang_plot`, `no_plot`, `unresolved` correctly from the fake's returned rows, run finishes `cancelled`. A fake that throws `OutboundError.authFailure` on film 4 ends the run as `error` with reason `auth` and at most 6 films processed (the three in flight finish, nothing new is claimed); any other error marks only that film and the run continues.

- [ ] **Step 2: Implement**

`RunService` is an `actor` over `Run` rows. `EnrichCoverageJob.start(trigger:)`: `runService.start`, then a `TaskGroup` with width 3 over all `Movie.jellyfinId`s, each calling `enrichmentService.enrich(jellyfinId:force:false, context: .init(runId:))`, ticking every film, checking `isCancelled` before each claim, finishing with `done`, `cancelled` or `error`. No model calls. Error rule, shared by every worker in this codebase from now on: `OutboundError.authFailure` from any provider calls `runService.abort(id, reason: "auth")` and the loop stops claiming, because a bad key fails every film; any other error is recorded on that film only (`movie_enrichment.error`, or an `error` decision in Task 11) and the loop continues.

Routes, in a new `Routes/EnrichmentRoutes.swift` registered from `APIRoutes.addRoutes` (first step of splitting the 800-line file; later tasks move their areas the same way):
- `POST /admin/enrichment/coverage` starts the job (409 with the running id when busy).
- `GET /admin/enrichment/coverage/status` returns the latest coverage run: `{ running, total, processed, stats, startedAt, finishedAt, status }`.
- `POST /admin/enrichment/coverage/cancel`.
- `GET /admin/enrichment/worklist?filter=no_plot|unresolved|other_lang|unverified` returns `[{ jellyfinId, source, wikiSite, wikiTitle, plotFound, error }]`.
- `GET /admin/enrichment/:jellyfinId` returns the row including `textBlock` (admin only; this endpoint is never under `/clients`).
- `PUT /admin/enrichment/:jellyfinId/page` body `{ "wiki_site": "enwiki", "wiki_title": "Heat (1995 film)" }`.
- `POST /admin/enrichment/:jellyfinId/refresh` (force).

Boot: `await runService.markStaleOnBoot()` in `NocturneServer.main` after migrations.

- [ ] **Step 3: Run, commit**

```bash
swift test --filter 'RunServiceTests|EnrichCoverageJobTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(runs): persisted runs + enrichment coverage job and admin routes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Reader v2: cache-friendly prompt, structured output, model picker

**Files:**
- Create: `Sources/NocturneServer/Tagger/ReaderPrompt.swift`, `ReaderService.swift`
- Modify: `Sources/NocturneServer/Configuration.swift`, `Sources/NocturneServer/Models.swift` (`ReaderAnswer`)
- Create: `Tests/NocturneServerTests/ReaderPromptTests.swift`, `ReaderServiceTests.swift`, fixture `Fixtures/anthropic/reader-response.json`

- [ ] **Step 1: Failing tests**

`ReaderPromptTests`:
1. `systemBlock(buckets:rules:)` is byte-identical for two different films (nothing per-film inside it).
2. The system block contains no `Min confidence`, no `Recent user decisions`, and not the text of Rule 7.
3. `userTurn(learnedRules:calibration:textBlock:)` puts learned rules first, calibration second, the text block last, and ends with the task instruction and the JSON contract.
4. Calibration lines show at most 5 confirmed and 3 rejected titles per mood.

`ReaderServiceTests` (FakeTransport returning the fixture):
1. The request body has `system[0].cache_control.type == "ephemeral"`, `output_config.effort == "low"`, `output_config.format.type == "json_schema"`, `model == settings.readerModel`, `max_tokens == 4096`.
2. The response decodes into `ReaderAnswer { residue, candidates: [(slug, evidence, confidence)], alternates }`; unknown slugs are dropped with a log line; duplicates collapse.
3. `stop_reason == "max_tokens"` or `"refusal"` throws `ReaderError.incomplete` (the caller records an `error` decision).
4. `usage.cache_read_input_tokens` is surfaced on the result for the caller to log.

- [ ] **Step 2: Prompt**

`ReaderPrompt.systemBlock`: `Configuration.autoTaggingPrompt` with Rule 7 removed and the "Min confidence to apply" line removed from each bucket entry, followed by the bucket list (title, residue, keywords, fits, does-not-fit) sorted by slug. Edit `Configuration.autoTaggingPrompt` in place: delete Rule 7 and renumber Rule 8 to Rule 7; the per-bucket line is built in `ReaderPrompt`, so it simply is not emitted.

`ReaderPrompt.userTurn`:

```
## Learned from you
(none)

## Your recent decisions
bittersweet-aftermath: confirmed on Past Lives, Her; rejected on The Shawshank Redemption
...

## Film
<text block>

## Task
State the residue in one sentence, then list 1 to 5 moods with an exact evidence phrase from the Film text for each, a confidence in [0, 1], and up to 3 alternates. Never mention events after the first act in the residue sentence.
```

- [ ] **Step 3: Request**

```json
{
  "model": "claude-haiku-5-5",
  "max_tokens": 4096,
  "system": [{"type": "text", "text": "<system block>", "cache_control": {"type": "ephemeral"}}],
  "messages": [{"role": "user", "content": [{"type": "text", "text": "<user turn>"}]}],
  "output_config": {
    "effort": "low",
    "format": {"type": "json_schema", "schema": {
      "type": "object", "additionalProperties": false,
      "required": ["residue", "candidates", "alternates"],
      "properties": {
        "residue": {"type": "string"},
        "candidates": {"type": "array", "items": {"type": "object", "additionalProperties": false,
          "required": ["slug", "evidence", "confidence"],
          "properties": {"slug": {"type": "string"}, "evidence": {"type": "string"}, "confidence": {"type": "number"}}}},
        "alternates": {"type": "array", "items": {"type": "string"}}
      }}}
  }
}
```

Before committing, send this exact body once with the real key against `claude-haiku-5-5` (a `swift run` debug flag or a one-off `curl` with the body dumped from a test) and confirm two things: the response content is schema-valid JSON, and a second identical call reports `cache_read_input_tokens > 0`. Record both numbers in the commit message. If the `format` object shape is rejected, check the structured outputs page via the claude-api skill's `shared/live-sources.md` and adjust; do not guess a second shape.

- [ ] **Step 4: Service**

```swift
final class ReaderService: Sendable {
    init(anthropic: AnthropicClient, settings: SettingsStore, config: NocturneConfiguration, logger: Logger)
    func read(textBlock: String, learnedRules: String, calibration: [String: TagCalibration],
              apiKey: String, context: CallContext) async throws -> ReaderResult   // answer + cacheReadTokens + model
}
```

`models.reader` is read from `SettingsStore` on every call (cheap, one row) with fallback order: setting, `ANTHROPIC_MODEL` env, `"claude-haiku-5-5"`.

- [ ] **Step 5: Run, commit**

```bash
swift test --filter 'ReaderPromptTests|ReaderServiceTests' 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(tagger): reader v2 with cached system block, structured output, model setting

Live check: schema-valid JSON on claude-haiku-5-5; second call cache_read_input_tokens=<n>.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Calibration from human labels only

**Files:**
- Modify: `Sources/NocturneServer/TagCalibration.swift`
- Create: `Tests/NocturneServerTests/TagCalibrationTests.swift`

- [ ] **Step 1: Failing tests**

Seed: a suggestion auto-approved (`resolved_by = auto`) proposing `ha-ha-ha` on film A; a suggestion human-approved on film B with `ha-ha-ha`; a human rejection on film C with `ha-ha-ha`; a manual `movie_tags` row (`label_source = user`) with `cult-chaos` on film D. Expect `ha-ha-ha` positives `[B]`, negatives `[C]`, and `cult-chaos` positives `[D]`; film A appears nowhere.

- [ ] **Step 2: Implement**

Filter `TagSuggestion` by `resolvedBy == "user"` (both approved and rejected), and add `MovieTag` rows with `labelSource == "user"` as positives. Keep the title lookup through `fetchAllMovies`, but cache the id-to-title map for the duration of a run (pass it in from the worker; build once).

- [ ] **Step 3: Run, commit**

```bash
swift test --filter TagCalibrationTests 2>&1 | tail -3
git add Sources Tests
git commit -m "fix(tagger): calibration reads human labels only

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Policy `p-legacy`, decision recording, rewired enqueue, deletions

**Files:**
- Create: `Sources/NocturneServer/Tagger/PolicyEngine.swift`, `DecisionRecorder.swift`, `TaggerPipeline.swift`, `ReviewQueue.swift`
- Delete: `Sources/NocturneServer/LLMService.swift`, `Sources/NocturneServer/SuggestionService.swift`
- Modify: `Sources/NocturneServer/MovieService.swift`, `APIRoutes.swift` (routes move to `Routes/TaggerRoutes.swift`), `JellyfinRealtimeService.swift`, `NocturneServer.swift`, `Models.swift` (drop `TagRefinementStatus`, `TagRefinementResponse`)
- Create: `Tests/NocturneServerTests/PolicyEngineTests.swift`, `DecisionRecorderTests.swift`, `SuggestionFlowTests.swift`

- [ ] **Step 1: Failing tests**

`PolicyEngineTests` (`p-legacy`, pure):
1. Candidate with confidence at or above its bucket floor (`minConfidence`, default 0.72) is applied; below is suggested with reason `"reader 0.61 < 0.72"`.
2. Applied capped at `maxAutoTags` (5) by confidence.
3. `unverified == true` moves every applied mood to suggested, outcome `review`.
4. Empty candidates: outcome `none`, `unsure == true`.
5. Outcome `applied` only when nothing is suggested.

`DecisionRecorderTests`: a decision row is written with `policy_version == "p-legacy"`, `classifier_json == nil`, `reader_json` equal to the encoded answer, `models_json` naming the reader model, `cost_usd` equal to the sum of `api_calls` rows carrying its `decision_id`; `movies.current_decision_id` points at it; the `tag_suggestions` row has `decision_id`, `items_json` with one entry per mood (`kind: add`, probability = reader confidence, evidence), `resolved_by == "auto"` when auto-approved and `nil` when pending.

`SuggestionFlowTests` (fakes for enrichment, reader): `enqueue` runs enrich, read, policy, record, applies tags with `label_source = auto`, writes the suggestion row; a reader failure writes a decision with `outcome = error` and a zero-tag pending suggestion as today; a budget pause skips the call and records `outcome = skipped` with the reason; a film whose enrichment has `source = none` is still tagged with today's apply semantics (no forced review), and its decision's `models_json` carries `"enrichment_source": "none"` so the eval can separate those rows; only `source = model` sets `unverified` and forces review.

- [ ] **Step 2: PolicyEngine**

```swift
struct PolicyInput: Sendable { let candidates: [ReaderCandidate]; let floors: [String: Double]; let maxTags: Int; let unverified: Bool }
struct PolicyDecision: Sendable { let applied: [(slug: String, p: Double)]; let suggested: [(slug: String, p: Double, reason: String)]; let unsure: Bool; let outcome: String; let reasons: [String] }
enum PolicyEngine { static func decide(version: String, input: PolicyInput) -> PolicyDecision }
```

Only `"p-legacy"` is implemented in this phase; any other version throws a precondition. `floors` come from `config.moodBuckets[slug]?.minConfidence ?? 0.72` at the call site so phase 2 can swap in `policy.floors` without touching the engine.

- [ ] **Step 3: DecisionRecorder, TaggerPipeline, ReviewQueue**

`TaggerPipeline.tag(jellyfinId:trigger:replaceExistingPending:) async throws -> TagSuggestion` is the one entry point for the realtime hook, `POST /movies/:id/auto-tag` and the backfill job (`tagInBackground` wraps it fire-and-forget with logging, as `enqueueInBackground` does today). It does:

1. `budget.allow(trigger)`; on `.paused` write a `skipped` decision and return the existing or an empty pending suggestion.
2. `enrichment = try await enrichmentService.enrich(jellyfinId:, item:, context:)`. When `source == none` (no plot on any wiki and no model synopsis), the reader gets a block built from Jellyfin identity plus overview only, exactly the information today's tagger has. The policy input keeps `unverified = false` for these films, so they tag with today's semantics and the review queue is not flooded by the long tail on the first backfill; `models_json` records `enrichment_source` for every decision. `unverified = true` is reserved for `source == model`.
3. `reader = try await readerService.read(textBlock:learnedRules: "" , calibration:, apiKey:, context:)`.
4. `decision = PolicyEngine.decide(version: "p-legacy", input:)`.
5. `recorder.record(...)` writes the row, then `movieService.updateMovieTags(jellyfinId:, tagSlugs: applied, replaceAll: false, labelSource: .auto)`, then the suggestion row (`status` pending when anything is suggested or unsure, else approved with `resolvedBy = auto`), `reasoning = residue`.

`ReviewQueue` takes over `listPending`, `pendingJellyfinIds`, `approve`, `reject`, `regenerate` (which calls `TaggerPipeline.tag(replaceExistingPending: true)`) with the same route shapes as today, so `AutoTagQueue.tsx` keeps working.

Then delete `LLMService.swift` and `SuggestionService.swift` entirely: nothing in them survives (prompt assembly is `ReaderPrompt`, HTTP is `AnthropicClient`, the queue is `ReviewQueue`, the flow is `TaggerPipeline`, the keyword post-filter and `looksGeneric` have no replacement by design). The per-tag refinement worker goes with them: remove the `tags/:slug/refine`, `refine/status` and `refine/cancel` routes and the `TagRefinementStatus` / `TagRefinementResponse` types; its job (prune an over-applied tag across the library) is phase 4's targeted re-grade, and `reprocess-all` covers the gap until then. `BackfillStateActor` is deleted in Task 15 when `BackfillJob` lands; until then the backfill routes stay on the old actor, now calling `TaggerPipeline`. `MovieService.updateMovieTags` gains `labelSource: LabelSource` (`.auto`, `.user`, `.seed`) and keeps writing `addedByAutoTag = (labelSource == .auto)` for one release. New routes for this area live in `Routes/TaggerRoutes.swift`; `APIRoutes.swift` keeps only composition and the shared helpers.

- [ ] **Step 4: Run, commit**

```bash
swift test 2>&1 | tail -5
git add Sources Tests
git commit -m "feat(tagger): TaggerPipeline + ReviewQueue with p-legacy policy and decision records; delete LLMService, SuggestionService, refinement worker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Human actions set `label_source` and `resolved_by`

**Files:**
- Modify: `Sources/NocturneServer/Tagger/ReviewQueue.swift` (`approve`, `reject`), `Sources/NocturneServer/MovieService.swift` (`updateMovieTags` from the admin editor), `Sources/NocturneServer/Routes/TaggerRoutes.swift` (`movies.put(":id/tags")`)
- Create: `Tests/NocturneServerTests/HumanLabelTests.swift`

- [ ] **Step 1: Failing tests**

1. `approve(id)` sets `resolved_by = user` and flips every applied `movie_tags` row for that film from `auto` to `user`.
2. `approve(id, overrideTags:)` writes the override tags with `label_source = user` and keeps `resolved_by = user`.
3. `reject(id)` sets `resolved_by = user` and removes only `auto` tags the suggestion added, never `user` tags.
4. `PUT /movies/:id/tags` (admin editor) writes `label_source = user`.

- [ ] **Step 2: Implement, run, commit**

```bash
swift test --filter HumanLabelTests 2>&1 | tail -3
git add Sources Tests
git commit -m "feat(tagger): human approvals, rejections and edits mark label_source=user

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Fallback synopsis from the strong model

**Files:**
- Create: `Sources/NocturneServer/Tagger/FallbackSynopsisService.swift`
- Modify: `Sources/NocturneServer/Enrichment/EnrichmentService.swift`, `Sources/NocturneServer/APIRoutes.swift`
- Create: `Tests/NocturneServerTests/FallbackSynopsisTests.swift`, fixture `Fixtures/anthropic/synopsis-response.json`

- [ ] **Step 1: Failing tests**

1. Request uses `models.strong` (default `claude-opus-5-5`), declares `tools: [{"type": "web_search_20260209", "name": "web_search", "max_uses": 5}]`, and a structured output schema `{ plot, reception, sources: [uri] }`.
2. The response's final text block decodes; the result is stored with `source = model`, `unverified = true`, `plot_found = true`, `wiki_title = nil`, and `awards_json` untouched.
3. A refusal or `max_tokens` stop leaves the row as it was and records the error.
4. `enrich` never calls the fallback on its own unless `enrichment.model_fallback == "on"`; the admin route always can.

- [ ] **Step 2: Implement**

`FallbackSynopsisService(anthropic:settings:)` with `write(for identity: TextBlockInput, apiKey:, context:) async throws -> (plot: String, reception: String, sources: [String])`. Prompt: "Write the complete plot of this film including the ending, then one paragraph on its critical reception and awards. Use web search to confirm facts and list the sources." Budget check applies (`.manual` from the route, `.scheduled` from enrich).

Route: `POST /admin/enrichment/:jellyfinId/synopsis`.

`EnrichmentService.enrich`: when no plot was found on any wiki and the setting is on, call the fallback and store; the block's `Source` line reads `model-written · unverified`.

- [ ] **Step 3: Run, commit**

```bash
swift test --filter FallbackSynopsisTests 2>&1 | tail -3
git add Sources Tests
git commit -m "feat(enrichment): strong-model fallback synopsis with web search, flagged unverified

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Settings and web UI

**Files:**
- Modify: `Sources/NocturneServer/APIRoutes.swift` (`POST /settings/models`, extend `GET /settings/info`), `Sources/NocturneServer/NocturneServer.swift` (seed `models.reader` from `ANTHROPIC_MODEL` once)
- Modify: `frontend/nocturne-web/src/lib/api.ts`, `lib/types.ts`, `App.tsx`, `components/MovieDetailPanel.tsx`, `components/AutoTagQueue.tsx`
- Create: `frontend/nocturne-web/src/components/ModelSettings.tsx`, `components/EnrichmentCoverageCard.tsx`

- [ ] **Step 0: Mockup first, code after the owner picks**

House rule: no UI code before a visual. Produce one HTML mockup page (or inline images in chat) showing the three new surfaces in the existing web UI's style: the `ModelSettings` card next to `ApiKeyForm`, the `EnrichmentCoverageCard` using `BackfillProgress`'s bar and the Settings card chrome, and the "Story source" section inside `MovieDetailPanel` using `MoodChips`-style badges for `verified` / `unverified` / `no plot`. Two variants where a choice exists: coverage counts as a row of stat pills versus a short table, and the spoiler reveal as a toggle versus a collapsed block. Reuse existing components and SF-symbol-free icons already in the bundle; no new chrome, no new dependency. Get the pick, then do Steps 1 to 3.

- [ ] **Step 1: Server**

`POST /settings/models` body `{ reader_model?, strong_model?, monthly_budget_usd?, model_fallback? }` writes `models.reader`, `models.strong`, `budget.monthly_usd`, `enrichment.model_fallback`. `GET /settings/info` adds `reader_model`, `strong_model`, `monthly_budget_usd`, `budget_spent_usd` (month to date), `model_fallback`, `enrichment: { total, english_plot, other_lang_plot, no_plot, unresolved, unverified }`. Boot: if `models.reader` is unset and `ANTHROPIC_MODEL` is set, store it once and log that the env var is deprecated.

- [ ] **Step 2: Frontend**

`api.ts`: `settings.saveModels(...)`, `enrichment.coverageStart()`, `coverageStatus()`, `coverageCancel()`, `worklist(filter)`, `get(jellyfinId)`, `overridePage(jellyfinId, site, title)`, `refresh(jellyfinId)`, `synopsis(jellyfinId)`. `types.ts`: `EnrichmentRow`, `CoverageStatus`, `SettingsInfo` additions, `SuggestionItem { slug, probability, evidence, kind }`.

`ModelSettings.tsx`: two selects (reader: haiku 5.5, sonnet 5.5, opus 5.5; strong: opus 5.5, sonnet 5.5), a number input for the budget, a toggle for model fallback, month-to-date spend next to the budget. Save calls `settings.saveModels`.

`EnrichmentCoverageCard.tsx`: Run button (disabled while any run is active), progress bar polled every 2 s like `BackfillProgress`, the five counts, and a worklist list with filter chips that opens the movie in `MovieDetailPanel`.

`MovieDetailPanel.tsx`: new "Story source" section: page title and site, `verified` or `unverified` badge, `plot found` or `no plot`, an input to override the page (site select + title) with Apply, a Refresh button, a "Generate synopsis" button (strong model, confirm dialog with the cost note), and a "Show spoilers" toggle that reveals `plot_text` in a monospace block.

`AutoTagQueue.tsx`: show the `unverified source` badge when the film's enrichment is unverified; under each suggested mood show its evidence phrase from `items_json`.

Deletions: `components/TagRefineProgress.tsx`, the `tags.refine`, `tags.refineStatus` and `tags.refineCancel` functions in `api.ts`, the `TagRefineStatus` type, and the refine control in the focused-tag sticky header in `App.tsx`. The server routes went in Task 11.

- [ ] **Step 3: Build both, commit**

```bash
cd frontend/nocturne-web && pnpm install --frozen-lockfile && pnpm build && cd ../..
swift build 2>&1 | tail -3
git add Sources frontend/nocturne-web/src
git commit -m "feat(ui): model settings, enrichment coverage card, story source panel, evidence in queue; drop tag refine UI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

No dependency was added, so neither lockfile changes; if one does, run `npm install --package-lock-only` as well before committing.

---

### Task 15: Backfill and reprocess-all on `RunService`

**Files:**
- Create: `Sources/NocturneServer/Runs/BackfillJob.swift`
- Modify: `Sources/NocturneServer/Routes/TaggerRoutes.swift`, `Sources/NocturneServer/NocturneServer.swift`, `Sources/NocturneServer/Models.swift` (drop `BackfillStatus` only if the route shape changes; it does not)
- Delete: `BackfillStateActor`, `WorkerMode`, `SuggestionError` leftovers
- Create: `Tests/NocturneServerTests/BackfillRunTests.swift`

- [ ] **Step 1: Failing tests**

1. `BackfillJob.start(mode: .backfill, trigger: .manual)` creates a `runs` row of kind `backfill` whose candidate list is "no tags or pending review", as today; `GET /admin/auto-tag/backfill/status` returns the unchanged `BackfillStatus` shape derived from it.
2. `mode: .reprocessAll` detaches every tag first, supersedes pending suggestions, and runs over the whole library, as `startReprocessAll` does today.
3. Cancel flips the flag; the job stops within one film; a second start while running returns 409 with the running id.
4. Calibration is built once per run and passed to every `TaggerPipeline.tag` call.
5. An `OutboundError.authFailure` from Anthropic ends the run as `error` with reason `auth` within one film; a reader parse error marks that film's decision `error` and the run continues.
6. No in-memory worker state remains: after `BackfillStateActor` is deleted, a process restart mid-run leaves a `running` row that `markStaleOnBoot` turns into `error` with reason `stale`, and the status route reports it.

- [ ] **Step 2: Implement**

`BackfillJob(runService:pipeline:fluent:jellyfin:)` runs sequentially (concurrency 1 for the reader in this phase) with `RunService` for claim, tick, cancel and finish; the 1.5 s breather goes (the outbound client's retry and the provider's rate limits replace it). Delete `BackfillStateActor` and `WorkerMode`; the backfill routes (`auto-tag/backfill`, `backfill/status`, `reprocess-all`, `cancel`) keep their paths and payloads and now call `BackfillJob`.

- [ ] **Step 3: Run, commit**

```bash
swift test 2>&1 | tail -5
git add Sources Tests
git commit -m "refactor(tagger): BackfillJob on persisted runs; delete BackfillStateActor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Taxonomy and guide become resource files

**Files:**
- Create: `Sources/NocturneServer/Resources/taxonomy.json`, `Sources/NocturneServer/Resources/guide.md`, `Sources/NocturneServer/Taxonomy.swift`
- Modify: `Package.swift` (`resources: [.copy("Resources")]` on the executable target), `Configuration.swift`, `Migrations.swift` (`SeedMoodTags` and `UpdateRegionalGemsDescription` read from `Taxonomy`), `Tagger/ReaderPrompt.swift`, `Tagger/TaggerPipeline.swift`, `APIRoutes.swift` (`GET /moods` reads from `Taxonomy`)
- Create: `Tests/NocturneServerTests/TaxonomyTests.swift`

- [ ] **Step 1: Failing tests**

1. `Taxonomy.load()` returns 36 buckets whose slugs, titles, descriptions, keywords, `anchorsFit`, `anchorsMiss` and `minConfidence` equal the current `Configuration.moodBuckets` values (write the test against the Swift dictionary first, then generate the JSON from it, then delete the dictionary).
2. `Taxonomy.version` is an integer read from the file; `Guide.manual` equals the current `autoTaggingPrompt` text minus Rule 7 and the min-confidence lines.
3. A malformed resource fails at boot with a clear error, not at the first tag.
4. `ReaderPrompt.systemBlock` built from `Taxonomy` is byte-identical to the one built from the old dictionary (golden comparison captured in Task 9).

- [ ] **Step 2: Implement**

`taxonomy.json`: `{ "version": 1, "buckets": { "<slug>": { "title", "description", "keywords", "anchorsFit", "anchorsMiss", "minConfidence" } } }`. Generate it once with a throwaway script from the Swift dictionary (print JSON from a test, review the diff), commit the file, delete `moodBuckets` from `Configuration.swift`. `guide.md`: the manual guide text; `Guide.manual` is the seed for the `guide.manual` setting in phase 4 and is read directly until then.

`Taxonomy` is a `struct` loaded once in `NocturneServer.main` from `Bundle.module` and passed where `config.moodBuckets` was passed. `SeedMoodTags` keeps seeding the `tags` table from it. The spec's `taxonomy_version` on decisions reads `Taxonomy.version`.

- [ ] **Step 3: Run, commit**

```bash
swift test 2>&1 | tail -5
git add Package.swift Sources Tests
git commit -m "refactor(taxonomy): moods and guide move to resource files with versions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: Live run on the admin's library and close-out

**Files:**
- Create: `docs/sessions/2026-10-XX-tagger-phase-1.md`
- Modify: `README.md` (architecture section: reader + enrichment instead of "Claude suggestion queue"; remove "requires Claude API key" for enrichment), `docs/superpowers/specs/2026-10-21-tagger-rewrite-design.md` (status line: phase 1 shipped)

- [ ] **Step 1: Deploy to the Pi** (owner runs the tag and Docker build; this plan does not push or tag)

- [ ] **Step 2: Coverage dry run**

Start it from Settings. Record: total films, English plot, other-language plot, no plot, unresolved, wall-clock time, Wikimedia errors. Open five films from the `no_plot` and `unresolved` worklists and check whether a page override fixes them; note the pattern (remakes, transliterated titles, missing IMDb ids).

- [ ] **Step 3: Reader run on 50 films**

Run a backfill limited to 50 untagged films (temporary `limit` param on the route, removed after). Confirm in `api_calls`: every call after the first has `cache_read_input_tokens > 0`; cost per film under $0.002 on `claude-haiku-5-5`. Confirm in `decisions`: every film has a row with `reader_json`, `policy_version = p-legacy`, and the suggestion row's `items_json` carries evidence. Spot-check ten residue sentences for spoilers.

- [ ] **Step 4: Budget pause**

Set the monthly budget below the month-to-date spend, trigger a realtime enqueue (add a film in Jellyfin or call `POST /movies/:id/auto-tag`), confirm the `skipped` decision and the log line, restore the budget.

- [ ] **Step 5: Session log and docs**

Write the session log with the numbers from steps 2 to 4, what the long tail looked like, and anything that changed from this plan. Update the README architecture paragraph and the spec status line.

- [ ] **Step 6: Commit**

```bash
git add README.md docs
git commit -m "docs: tagger phase 1 session log + README architecture

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Summary

Phase 1 delivers the spec's section 1 (enrichment), section 5 (storage), section 8 (providers and operations) and the phase 1 line of section 10: every film gets a stored, hashed text block built from the full Wikipedia plot, reception and awards; every classification is a replayable decision row with metered cost; human labels are separable from auto labels in both `movie_tags` and `tag_suggestions`; the reader is cheap, cached and selectable; the self-critique pass, keyword filter and the wrong Wikipedia lookup are gone. Phase 2 adds the two classifier providers and the real policy on top of these rows without touching the enrichment or storage layers.

## Test plan

- `swift test` green after every task; CI runs it on every PR from Task 0 onward.
- Fixtures are real API responses captured once; the parsers are tested against them, not against hand-written approximations.
- One live Anthropic check in Task 9 (schema-valid structured output, cache hit on the second call) with the numbers in the commit message.
- Task 17 is the integration pass on the owner's library: coverage counts, 50-film reader run, budget pause.

## Self-review

- Spec coverage: section 1 (resolution, fetch, block, fallback, storage, coverage run) is Tasks 4 to 8 and 13; section 2 (reader) is Tasks 9, 10 and 16; section 5 (tables, label sources, settings keys) is Task 2 and 14; section 8 (wrapper, metering, budget, rate limits, settings UI, spoiler hygiene) is Tasks 3, 8 and 14; section 9 deletions all land in this phase (Tasks 11 and 15), one phase earlier than the spec wrote for the refinement worker, with the owner's approval to scrap structure.
- Nothing from phases 2 to 4 leaks in: no classifier, no `p0`/`p1`, no eval, no Teach, no `scores` field. The resource-file move (Task 16) is structure, not the taxonomy-editing UI the spec defers.
- Spoiler hygiene: the only route that returns `text_block` or `plot_text` is `/admin/enrichment/:jellyfinId`; the client group is untouched.
- Open risks carried into execution: the `@testable import` of an executable target (Task 0 has the fallback), the exact `output_config.format` wire shape (Task 9 verifies live before commit), and Wikimedia rate behaviour at concurrency 3 (Task 17 records errors).
