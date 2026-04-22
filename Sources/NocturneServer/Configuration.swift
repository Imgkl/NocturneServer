import Foundation
import Logging

final class NocturneConfiguration: @unchecked Sendable {
    // Server Settings
    var host: String = "0.0.0.0"
    var port: Int = 8001

    // Jellyfin Connection
    var jellyfinUrl: String = "http://192.168.0.111:8097"
    var jellyfinApiKey: String = ""
    var jellyfinUserId: String = ""

    // Database
    var databasePath: String = "nocturne.sqlite"

    // BYOK - Bring Your Own Key (Optional)
    var anthropicApiKey: String? = nil
    var omdbApiKey: String? = nil

    // Auto-tagging settings
    var enableAutoTagging: Bool = false
    var maxAutoTags: Int = 5
    var autoTaggingPrompt: String = """
    You are a meticulous film taxonomy expert. Pick up to 5 mood tags that describe the VIEWER RESIDUE —
    the feeling a viewer carries with them after the credits — NOT the plot events.

    Rule 0 — Residue-first (do this FIRST)
    In ONE sentence, describe the feeling a viewer leaves the theatre with. What do they carry home?
    Awe? Devastation? Warmth? Dread? Confusion? Nostalgia? A quiet ache? Then — and ONLY then — pick
    tags that match that residue. A plot-tragic film can still be "bittersweet-aftermath" if the
    residue is graceful awe rather than raw devastation (Thelma & Louise). A plot-happy film can still
    be "emotional-gut-punch" if the journey was wrecking (e.g., the ending of Up doesn't erase the
    opening montage). TAG THE RESIDUE, NOT THE PLOT.

    Rule 1 — Dominant register, not flavor notes
    Most films contain moments of humor, romance, warmth, or violence that are NOT the primary register.
    Tag the whole, never the parts.
    • A sad / tragic film with funny lines is NOT "ha-ha-ha".
    • A film with a romantic subplot but dark themes is NOT "feel-good-romance".
    • A heavy, intense film is NOT "rainy-day-rewinds" — that bucket is for comfort-first rewatchables.
    • A coming-of-age element in a broader drama is NOT "coming-of-age" unless identity-becoming is the
      CENTRAL arc.

    Rule 2 — Evidence or drop the tag
    For every tag you select, cite a short specific phrase from the overview / external summary
    in the `evidence` field (e.g. "time loop premise", "Palme d'Or winner", "confined to a single jury
    room"). No concrete phrase → no tag.

    Rule 3 — Per-tag guards (the loose ones — be strict here)
    • regional-gems: regional origin ALONE is NOT enough. Requires a standout signal — award, festival
      run, genre landmark, or widely acknowledged critical/cultural significance. Not every Tamil/Hindi
      film qualifies.
    • bittersweet-aftermath: viewer leaves with quiet ache + awe. NOT triumphant (→ rainy-day-rewinds)
      and NOT devastating (→ emotional-gut-punch). Apply the RESIDUE test, not the plot test.
    • crime-grit-style: gritty underworld tone. NOT Bond-style action, NOT caper comedies, NOT racing
      or sports films. The world must feel seedy and the consequences bruising.
    • film-school-shelf: historically pivotal, form-defining canon. "Old and popular" ≠ canon.
      "It's a Wonderful Life" and "Rocky" are iconic but not syllabus — prefer rainy-day-rewinds or
      bittersweet-aftermath.
    • ha-ha-ha: comedy is the PRIMARY delivery across the runtime. Dark comedies with tragic endings
      do NOT qualify. Dramedies with humorous beats do NOT qualify.
    • slow-burn-sharp-blade: patient stillness + precise release. Set-piece action films do NOT
      qualify; kinetic thrillers do NOT qualify.
    • modern-masterpieces: 2000s+ with actual landmark weight — Best Picture / Palme d'Or / Cannes /
      near-universal critical consensus or acknowledged landmark status. Popular-and-recent ≠
      masterpiece.
    • time-twists: requires explicit temporal mechanics — loops, travel, branching timelines,
      resets, paradoxes. Nonlinear editing alone is NOT enough.
    • psychological-pressure-cooker: requires MIND unraveling — paranoia, obsession, gaslighting.
      Spatial confinement alone → one-room-pressure-cooker.
    • feel-good-romance: overall uplifting arc AND romance is the engine. Tragic or ambivalent
      romances (Casablanca, The Notebook, Past Lives) do NOT qualify — those go to bittersweet-aftermath.

    Rule 4 — Disambiguation between close buckets
    When two could apply, prefer the more specific one:
    • bittersweet-aftermath vs emotional-gut-punch: residue test — ache-with-grace vs raw devastation.
    • one-room-pressure-cooker vs psychological-pressure-cooker: SPACE squeezing vs MIND squeezing.
      Both may apply if both present.
    • the-twist-is-the-plot (single reveal reframes) vs brainmelt-zone (perception fractured throughout).
    • horror-and-unease (dread-forward) vs uncanny-vibes (gentle off-reality) vs psychological-pressure-cooker.
    • vibe-is-the-plot (story recedes, mood leads) vs visual-worship (image/composition is the point).
    • modern-masterpieces (2000s+ landmark) vs film-school-shelf (form-defining canon, usually pre-2000).
    • regional-gems (Indian-cinema standout) vs underseen-treasures (globally overlooked anywhere).
    • crime-grit-style (gritty world) vs antihero-study (flawed protagonist psychology).

    Rule 5 — Prefer precision
    Return fewer tags when unsure. One well-justified tag beats five loose ones. Cap at 5. Return at
    LEAST 1 tag — never empty. Calibrate confidence 0.70–0.95 when evidence is strong; lower otherwise.

    Rule 6 — Valid slugs only
    Tags MUST be slugs from the provided list. Do not invent new tags. Jellyfin genres (Comedy, Drama, …)
    are hints, not mood tags — don't map them 1:1.

    Rule 7 — Honor each tag's Min confidence
    Each tag has a minimum confidence floor listed next to it. If you can't confidently clear that
    floor, DROP THE TAG. Loose tags (bittersweet-aftermath, regional-gems, film-school-shelf, etc.)
    need 0.82+; precise tags (time-twists, experimental-cinema) need 0.65+.

    Rule 8 — Honor user calibration
    If a tag listing shows "Recent user decisions" — ✓ approved / ✗ rejected — treat those as strong
    signals. Do NOT apply a tag to a film that closely resembles rejections; DO prefer a tag whose
    approved anchors resemble the current film.

    Few-shot calibration examples (use as a model; do not output these):

    ① Manchester by the Sea
       Residue: catatonic grief that never quite lifts.
       Tags: ["emotional-gut-punch", "bittersweet-aftermath"]
       NOT "ha-ha-ha" (one funeral laugh doesn't flip register), NOT "coming-of-age" (nephew subplot
       is secondary).

    ② The Big Lebowski
       Residue: shaggy comic joy, quotable for weeks.
       Tags: ["ha-ha-ha", "cult-chaos"]
       Comedy is the engine; crime elements are backdrop.

    ③ Memento
       Residue: puzzled, reassembling the film in your head.
       Tags: ["brainmelt-zone", "the-twist-is-the-plot"]
       NOT "time-twists" — non-linear editing, no time mechanics.

    ④ Groundhog Day
       Residue: comic time-loop that grows existential.
       Tags: ["time-twists", "ha-ha-ha", "existential-core"]
       Time-travel mechanic + comedy engine + meaning-of-life arc.

    ⑤ 12 Angry Men
       Residue: nailed to the jury room, every argument lands.
       Tags: ["one-room-pressure-cooker", "dialogue-driven"]
       NOT "psychological-pressure-cooker" — squeeze is social/spatial, not mental unraveling.

    ⑥ Thelma & Louise
       Residue: awed defiance; "wow, what a movie" alongside the ache of the ending.
       Tags: ["antihero-study", "bittersweet-aftermath"]
       Plot is tragic — BUT the residue is defiance-in-awe, not raw devastation. Bittersweet-aftermath
       WINS under the residue rule even though the final frame is a literal cliff.

    Workflow
    1. State the residue in ONE sentence (goes in the `residue` JSON field).
    2. For each candidate tag, cite the exact phrase from overview/summary justifying it (goes in `evidence`).
    3. Apply Rules 1–8. Drop any tag that fails its guard or its min confidence.
    4. Return up to 5 survivors, each with per-tag confidence.
    """

    // Guiding principle:
    // - These buckets are "primary mood lenses," not rigid genres.
    // - Tag the VIEWER RESIDUE (what you carry after the credits), not plot events.
    // - Overlaps happen; a film can live in multiple buckets when the residue strongly fits.
    // - anchorsFit/anchorsMiss are LLM few-shot; minConfidence is a per-tag floor (default 0.72).
    let moodBuckets: [String: MoodBucket] = [
        "dialogue-driven": MoodBucket(
            title: "Dialogue-Driven",
            description: """
You leave remembering what people SAID more than what they DID — specific lines, reversals inside conversations, subtext sharper than any set piece. Words are the primary engine of tension, humor, or revelation.
""",
            tags: ["talky","verbal-sparring","subtext","theatrical","intimate","witty"],
            anchorsFit: [
                "Before Sunrise / Before Sunset — 90 minutes of walking and talking IS the movie",
                "My Dinner with Andre — literally two men at a restaurant",
                "12 Angry Men — verbal jury combat in one room",
                "Glengarry Glen Ross — language as weapon",
            ],
            anchorsMiss: [
                "Pulp Fiction — iconic dialogue but the film is ALSO crime-grit-style with set pieces; dialogue alone isn't the engine",
                "The Social Network — fast talk but plot has deal-making / betrayal arcs, prefer antihero-study",
            ],
            minConfidence: 0.72
        ),
        "vibe-is-the-plot": MoodBucket(
            title: "Vibe Is the Plot",
            description: """
You leave having FELT something, not having followed a story. Plot beats recede, mood/texture/rhythm lead — music, color, and pacing carry momentum more than conflict. If you could describe the plot in one sentence and the vibe fills a page, this tag fits.
""",
            tags: ["ambient","mood-first","dreamy","hypnotic","tone-poem"],
            anchorsFit: [
                "Lost in Translation — the mood IS the plot",
                "Chungking Express — vibes over narrative",
                "Only God Forgives — atmosphere as story",
                "A Ghost Story — time and grief as texture",
            ],
            anchorsMiss: [
                "Drive — strong mood but a clear crime-plot; prefer obsidian-noir or men-with-vibes",
                "The Tree of Life — form-forward, prefer experimental-cinema",
            ],
            minConfidence: 0.72
        ),
        "existential-core": MoodBucket(
            title: "Existential Core",
            description: """
You leave wrestling with meaning, mortality, or identity. The film's central question isn't "what happens?" but "why are we here / who am I?" — characters confront purpose against an indifferent or absurd world.
""",
            tags: ["meaning-of-life","identity","mortality","philosophical","alienation"],
            anchorsFit: [
                "Synecdoche, New York — life itself as unfinishable project",
                "The Tree of Life — being vs nothingness",
                "A Ghost Story — time, presence, and absence",
                "Her — what is love, consciousness, loneliness",
                "Past Lives — identity across decades and lives",
            ],
            anchorsMiss: [
                "Inception — ideas of reality but the MACHINE is heist-energy / brainmelt-zone",
                "The Matrix — existential themes but primary register is action/sci-fi",
            ],
            minConfidence: 0.72
        ),
        "crime-grit-style": MoodBucket(
            title: "Crime, Grit & Style",
            description: """
You leave with the taste of a stylish underworld — bruised morality, slick craft, messy consequence. The world is seedy but the filmmaking is precise; cool surfaces clash with violence that lingers.
""",
            tags: ["crime","stylish","gritty","underworld","moral-ambiguity"],
            anchorsFit: [
                "Heat — the most crime-grit-style movie ever made",
                "Goodfellas / The Irishman — Scorsese's underworld",
                "City of God — favela grit with kinetic style",
                "Jackie Brown — tarantino grime + cool",
                "Fargo — polite exterior, bloody interior",
            ],
            anchorsMiss: [
                "Casino Royale / No Time to Die — Bond-style action, NOT gritty underworld",
                "Bullet Train — stylish action-comedy, prefer ha-ha-ha",
                "F1 — not a crime film at all; misapplied on sport-competition",
                "Die Hard — action, prefer cat-and-mouse",
            ],
            minConfidence: 0.82
        ),
        "men-with-vibes": MoodBucket(
            title: "Men With Vibes (and Guns)",
            description: """
You leave remembering HOW the lead held themselves — posture, glances, quiet competence, coiled menace. Minimal dialogue, maximum charisma; tension lives in silence and ritual punctuated by sudden violence.
""",
            tags: ["stoic","cool-factor","aura","competence","menace","iconic"],
            anchorsFit: [
                "Le Samouraï — the archetype",
                "Drive — cool-as-ice driver",
                "No Country for Old Men — Chigurh's silent menace",
                "The Good, the Bad and the Ugly — Eastwood's squint",
                "Ghost Dog: The Way of the Samurai — stoic code",
            ],
            anchorsMiss: [
                "John Wick — vibes + guns but primary register is kinetic action; can overlap with crime-grit-style",
                "Taxi Driver — stoic but the MIND unravels, prefer psychological-pressure-cooker",
            ],
            minConfidence: 0.72
        ),
        "brainmelt-zone": MoodBucket(
            title: "Brainmelt Zone",
            description: """
You leave disoriented-then-delighted. Perception fractures — memory slips, unreliable frames, shifting truths — and the pleasure is in reassembly. Different from the-twist-is-the-plot: here uncertainty is SUSTAINED, not a single reveal.
""",
            tags: ["surreal","unreliable","identity-blur","puzzle-box","mind-bending"],
            anchorsFit: [
                "Mulholland Drive — identity dissolves across layers",
                "Memento — memory as architecture",
                "Primer — time-loop logic as puzzle",
                "Eternal Sunshine of the Spotless Mind — memory erasure",
                "Enemy — doubles and dread without answers",
            ],
            anchorsMiss: [
                "The Sixth Sense — one big reveal, prefer the-twist-is-the-plot",
                "Fight Club — single twist + social critique, prefer the-twist-is-the-plot",
            ],
            minConfidence: 0.72
        ),
        "the-twist-is-the-plot": MoodBucket(
            title: "The Twist Is the Plot",
            description: """
You leave replaying the whole film to see what you missed. A single engineered reveal reframes everything — clues, misdirection, and set-ups are the architecture. One trapdoor opens, and the story you thought you were watching was a different story.
""",
            tags: ["twist","reveal-driven","misdirection","recontextualization"],
            anchorsFit: [
                "The Sixth Sense — the canonical third-act reveal",
                "The Usual Suspects — the last five minutes rewrite the first 100",
                "Gone Girl — mid-film pivot flips everything",
                "Fight Club — identity reveal reshapes the film",
                "Predestination — twist on twist",
            ],
            anchorsMiss: [
                "Mulholland Drive — perception fractures throughout, prefer brainmelt-zone",
                "Memento — fractured throughout, not a single reveal",
            ],
            minConfidence: 0.72
        ),
        "slow-burn-sharp-blade": MoodBucket(
            title: "Slow Burn, Sharp Blade",
            description: """
You leave feeling the PAYOFF was earned by patience. Quiet stakes accumulate; tension builds in stillness; then a precise surgical release. The pleasure is in simmering discipline — the film trusts you to wait.
""",
            tags: ["patient","tension-build","minimalism","precision","escalation"],
            anchorsFit: [
                "No Country for Old Men — tension as craft",
                "There Will Be Blood — 160 minutes of slow-crawl to \"I'M FINISHED\"",
                "A Separation — domestic slow-burn to moral reckoning",
                "The Lives of Others — surveillance as slow ignition",
                "Drive — stillness broken by blade",
            ],
            anchorsMiss: [
                "Jaws — faster-paced thriller with set pieces, not slow-burn",
                "Heat — ensemble crime epic, prefer crime-grit-style",
                "A Most Violent Year — fits, but so does crime-grit-style",
            ],
            minConfidence: 0.82
        ),
        "one-room-pressure-cooker": MoodBucket(
            title: "One-Room Pressure Cooker",
            description: """
You leave remembering a PLACE — the room, the table, the confined space where everything happened. SPACE does the squeezing: logistics, blocking, and power dynamics inside four walls. If the mind unravels more than the space confines, prefer psychological-pressure-cooker.
""",
            tags: ["single-location","claustrophobia","logistical-tension","containment"],
            anchorsFit: [
                "12 Angry Men — jury room",
                "Rope — Hitchcock in one apartment",
                "Locke — one man in a car for 85 minutes",
                "Buried — coffin, underground, real-time",
                "Reservoir Dogs — warehouse aftermath",
            ],
            anchorsMiss: [
                "The Shining — hotel is huge; prefer horror-and-unease",
                "Misery — minds unravel too; can also carry psychological-pressure-cooker",
            ],
            minConfidence: 0.72
        ),
        "emotional-gut-punch": MoodBucket(
            title: "Emotional Gut Punch",
            description: """
You leave RAW — devastated, wrecked, maybe in tears. The film does not handle you with grace; it delivers an emotional blow and leaves you to absorb it. Contrast bittersweet-aftermath (which is ache-with-grace, not devastation).
""",
            tags: ["devastating","emotional-impact","wrecking","unflinching"],
            anchorsFit: [
                "Requiem for a Dream — pure devastation",
                "Hereditary — grief weaponized",
                "Mystic River — tragedy compounding",
                "Manchester by the Sea — catatonic grief",
                "Incendies — final reveal annihilates",
            ],
            anchorsMiss: [
                "Past Lives — emotional but graceful, prefer bittersweet-aftermath",
                "Her — ache with acceptance, prefer bittersweet-aftermath",
                "Parasite — tragic but primary register is satire/thriller",
            ],
            minConfidence: 0.72
        ),
        "psychological-pressure-cooker": MoodBucket(
            title: "Psychological Pressure-Cooker",
            description: """
You leave feeling the MIND was the battlefield. Paranoia, obsession, gaslighting — dread comes from perception unraveling, not walls closing in. If a single room is the engine of tension, prefer one-room-pressure-cooker.
""",
            tags: ["paranoia","obsession","gaslighting","mental-unraveling","anxiety"],
            anchorsFit: [
                "Repulsion — inner world collapsing",
                "Black Swan — identity vs obsession",
                "Persona — two psyches blurring",
                "Shutter Island — unreliable reality",
                "Taxi Driver — mind under siege",
            ],
            anchorsMiss: [
                "12 Angry Men — spatial squeeze, prefer one-room-pressure-cooker",
                "Cube — geometric horror, prefer horror-and-unease",
            ],
            minConfidence: 0.72
        ),
        "time-twists": MoodBucket(
            title: "Time Twists",
            description: """
You leave having PLAYED with time as a toy. The film uses explicit temporal mechanics — loops, travel, branching timelines, resets, paradoxes — as its primary engine. Non-linear editing alone does NOT qualify; there must be literal temporal mechanics.
""",
            tags: ["time-loop","time-travel","paradox","alternate-timelines","chronological-puzzle"],
            anchorsFit: [
                "Primer — time-travel logic as lab puzzle",
                "Predestination — loops within loops",
                "Groundhog Day — the canonical loop",
                "Looper — causality as ballistic",
                "Back to the Future — the template",
                "Tenet — inversion as mechanic",
                "Arrival — non-linear time as perception",
                "Source Code — repeated eight-minute loops",
                "Edge of Tomorrow — die, rinse, repeat",
                "Palm Springs — loop comedy",
                "Donnie Darko — time as cosmic architecture",
                "About Time — quiet personal time-travel",
            ],
            anchorsMiss: [
                "Memento — non-linear editing only, prefer brainmelt-zone",
                "Pulp Fiction — non-linear, no time mechanics, prefer crime-grit-style",
            ],
            minConfidence: 0.65
        ),
        "visual-worship": MoodBucket(
            title: "Visual Worship",
            description: """
You leave remembering IMAGES, not lines. Frames are composed like paintings or posters; camera, color, and light do the storytelling. Even with a strong story, the EYE is the primary organ engaged.
""",
            tags: ["painterly","auteur-visuals","composed-frames","cinematography-first"],
            anchorsFit: [
                "2001: A Space Odyssey — image as metaphysics",
                "In the Mood for Love — every frame framed",
                "Blade Runner 2049 — Deakins painting in motion",
                "The Fall — visual maximalism",
                "Portrait of a Lady on Fire — painterly restraint",
            ],
            anchorsMiss: [
                "Drive — strong visuals but obsidian-noir / vibe-is-the-plot leads",
                "The Grand Budapest Hotel — visual but primary register is ha-ha-ha",
            ],
            minConfidence: 0.72
        ),
        "obsidian-noir": MoodBucket(
            title: "Obsidian Noir",
            description: """
You leave feeling the world is morally sleek, fatalistic, and slippery with desire. Modern noir — inky contrast, shadows, cynicism, a downward spiral dressed in style. Separate from crime-grit-style by TONE: noir is fatalistic and sexy-sad; crime-grit is kinetic and bruised.
""",
            tags: ["noir","shadows","fatalism","moral-fog","hardboiled"],
            anchorsFit: [
                "Drive — neon-noir elegy",
                "Chinatown — the modern noir template",
                "Blue Velvet — suburban moral fog",
                "Blade Runner — rain-and-shadow fatalism",
                "Nightcrawler — LA as noir decay",
            ],
            anchorsMiss: [
                "Sin City — noir pastiche but primary register is crime-grit-style",
                "LA Confidential — also fits crime-grit-style; either can win",
            ],
            minConfidence: 0.65
        ),
        "rain-neon-aesthetic": MoodBucket(
            title: "Rain & Neon Aesthetic",
            description: """
You leave carrying an IMAGE: wet streets, reflective signage, synth glow, urban melancholy. The city hums as mood board. Narrow and precise — not every neon-lit film qualifies; the aesthetic must be the primary signature.
""",
            tags: ["neon","rain-sheen","urban-melancholy","synth","nightscape"],
            anchorsFit: [
                "Blade Runner / Blade Runner 2049 — the canonical template",
                "Drive — neon-pink noir",
                "Chungking Express — Hong Kong neon melancholy",
                "Only God Forgives — neon as bloodstain",
                "Enter the Void — neon as hallucination",
            ],
            anchorsMiss: [
                "The Matrix — green-code aesthetic, not rain/neon",
                "Collateral — night LA but not rain/neon-forward",
            ],
            minConfidence: 0.65
        ),
        "rainy-day-rewinds": MoodBucket(
            title: "Rainy Day Rewinds",
            description: """
You leave SMILING — cozy, warm, wanting to watch it again. Low stakes, friendly rhythm, lines you love saying with the characters. Comfort cinema, rewatchable by design. Heavy/disturbing/tragic films do NOT qualify.
""",
            tags: ["cozy","nostalgic","warmth","comfort-watch","low-stakes","rewatchable"],
            anchorsFit: [
                "You've Got Mail — the platonic comfort watch",
                "The Princess Bride — quotable, warm",
                "Paddington 2 — joy distilled",
                "School of Rock — feel-good loop",
                "Chef — eating-and-driving therapy",
            ],
            anchorsMiss: [
                "The Shawshank Redemption — rewatchable but HEAVY, prefer bittersweet-aftermath or modern-masterpieces",
                "Little Miss Sunshine — warm but the ending carries ache; may also fit bittersweet-aftermath",
            ],
            minConfidence: 0.72
        ),
        "ha-ha-ha": MoodBucket(
            title: "Ha Ha Ha",
            description: """
You leave having LAUGHED. Comedy is the PRIMARY delivery mechanism across the whole runtime — not a dramedy with funny beats, not a tragedy with one-liners. Timing, chemistry, rhythm land on the beat. If you cried more than you laughed, this tag does NOT fit.
""",
            tags: ["comedy","wit","banter","screwball","physical-comedy"],
            anchorsFit: [
                "Airplane! — pure joke machine",
                "Anchorman — quotable across runtime",
                "The Big Lebowski — shaggy comic register",
                "Superbad — comedy engine throughout",
                "Kung Fu Hustle — physical-comedy masterclass",
            ],
            anchorsMiss: [
                "Little Miss Sunshine — dramedy, mostly melancholic, prefer bittersweet-aftermath",
                "City Lights — Chaplin's tramp is comic-tragic; primary register is tragicomedy, not pure comedy",
                "Parasite — has humor but register is satire/thriller, prefer modern-masterpieces",
            ],
            minConfidence: 0.82
        ),
        "feel-good-romance": MoodBucket(
            title: "Feel-Good Romance",
            description: """
You leave WARMED — connection, earned joy, tenderness. Romance is the engine AND the arc is uplifting. Tragic, ambivalent, or bittersweet romances do NOT qualify — those go to bittersweet-aftermath or emotional-gut-punch.
""",
            tags: ["tender","uplifting","chemistry","hopeful","heartwarming"],
            anchorsFit: [
                "When Harry Met Sally — the template",
                "About Time — love across time, finally uplifting",
                "Amélie — whimsical joy",
                "Crazy Rich Asians — feel-good romance at scale",
                "Notting Hill — uplifting meet-cute arc",
            ],
            anchorsMiss: [
                "Casablanca — iconic but the romance ends in graceful loss, prefer bittersweet-aftermath",
                "The Notebook — tragic framing, prefer bittersweet-aftermath",
                "Blue Valentine — devastating, prefer emotional-gut-punch",
                "Past Lives — ache, not joy, prefer bittersweet-aftermath",
            ],
            minConfidence: 0.72
        ),
        "coming-of-age": MoodBucket(
            title: "Coming of Age",
            description: """
You leave having watched an IDENTITY form. The CENTRAL arc is becoming — a character crossing a threshold from one self to another through mistakes, firsts, and hard-earned perspective. A coming-of-age subplot inside a broader story does NOT qualify.
""",
            tags: ["youth","self-discovery","first-love","growing-pains","rites-of-passage"],
            anchorsFit: [
                "Lady Bird — quintessential identity formation",
                "Boyhood — literal years of becoming",
                "Moonlight — three-stage identity arc",
                "The 400 Blows — template for the genre",
                "Call Me by Your Name — summer of first-love awakening",
            ],
            anchorsMiss: [
                "Dead Poets Society — young men but the arc is tragedy, prefer emotional-gut-punch",
                "Good Will Hunting — coming-of-age-ish but really about healing, prefer bittersweet-aftermath",
            ],
            minConfidence: 0.72
        ),
        "late-night-mind-rattle": MoodBucket(
            title: "Late-Night Mind Rattle",
            description: """
You leave UNABLE TO SLEEP — ideas rattling, thoughts lingering, not quite horror but not quite peaceful. Eerie-thoughtful films that sit in the uncanny middle space between intellectual and spooky. Great at 1:47am.
""",
            tags: ["haunting","liminal","restless-thoughts","uneasy-calm","philosophical-chill"],
            anchorsFit: [
                "Donnie Darko — 1am energy incarnate",
                "Under the Skin — eerie-thoughtful unease",
                "The Lighthouse — isolated mind-rattle",
                "Coherence — philosophical creep",
                "A Ghost Story — grief as liminal space",
            ],
            anchorsMiss: [
                "Hereditary — pure horror, not rattle",
                "Solaris — existential but more meditative than rattle-inducing, prefer existential-core",
            ],
            minConfidence: 0.65
        ),
        "uncanny-vibes": MoodBucket(
            title: "Uncanny Vibes",
            description: """
You leave with déjà vu that won't shake — reality slightly off, dreamlike cadence, ritual behavior, familiar-yet-wrong settings. Strangeness is GENTLE but persistent. Not primarily scary; that's horror-and-unease.
""",
            tags: ["uncanny","liminal","dreamlike","off-kilter","eeriness"],
            anchorsFit: [
                "The Lobster — off-reality as comedy",
                "Dogtooth — ritual family strangeness",
                "Yorgos Lanthimos filmography broadly",
                "Upstream Color — dreamlike logic",
                "Under the Skin — alien-yet-intimate",
            ],
            anchorsMiss: [
                "Midsommar — crosses into horror, prefer horror-and-unease",
                "Mulholland Drive — fractures perception, prefer brainmelt-zone",
            ],
            minConfidence: 0.72
        ),
        "horror-and-unease": MoodBucket(
            title: "Horror & Unease",
            description: """
You leave SCARED or DREAD-SATURATED. Menace in tone, image, or implication; scares can be quiet or loud, but anxiety rides beside you to the credits. Not merely unsettling (uncanny-vibes) — actively dread-forward.
""",
            tags: ["dread","terror","suspense","atmospheric","disturbing","fear"],
            anchorsFit: [
                "Hereditary — grief + dread",
                "The Shining — hotel as monster",
                "The Witch — slow religious dread",
                "It Follows — inescapable menace",
                "Get Out — social horror",
            ],
            anchorsMiss: [
                "The Lobster — uncanny, not scary, prefer uncanny-vibes",
                "Memories of Murder — procedural unease, prefer slow-burn-sharp-blade",
            ],
            minConfidence: 0.72
        ),
        "wtf-did-i-watch": MoodBucket(
            title: "WTF Did I Watch",
            description: """
You leave STUNNED and confused in the best way — transgressive, absurd, or confrontational cinema that broke decorum and dared you to keep up. Might regret, won't forget.
""",
            tags: ["transgressive","absurd","shock","provocative","boundary-pushing"],
            anchorsFit: [
                "Holy Motors — the archetype",
                "Titane — body-horror transgression",
                "Enemy — inexplicable ending",
                "mother! — allegorical provocation",
                "The Substance — body-horror maximalism",
            ],
            anchorsMiss: [
                "Mulholland Drive — weird but intentional, prefer brainmelt-zone",
                "Everything Everywhere All at Once — chaotic but coherent, prefer modern-masterpieces",
            ],
            minConfidence: 0.72
        ),
        "film-school-shelf": MoodBucket(
            title: "Film School Shelf",
            description: """
You leave knowing you watched a FORM-DEFINING work. Historically pivotal: editing, performance, blocking, or genre grammar that every cinephile needs to have seen. "Old and popular" ≠ canon; this is the actual syllabus.
""",
            tags: ["canon","foundational","form-defining","influential","curriculum"],
            anchorsFit: [
                "Citizen Kane — the textbook",
                "Seven Samurai — genre template",
                "8½ — meta-auteur canon",
                "Tokyo Story — narrative minimalism canon",
                "Breathless — French New Wave primer",
                "Persona — Bergman essential",
            ],
            anchorsMiss: [
                "It's a Wonderful Life — popular + old but not form-defining canon, prefer rainy-day-rewinds",
                "Rocky — iconic + old but not syllabus, prefer bittersweet-aftermath",
                "Drunken Master — genre-canon for kung fu but not broad film-school shelf",
            ],
            minConfidence: 0.82
        ),
        "modern-masterpieces": MoodBucket(
            title: "Modern Masterpieces",
            description: """
You leave feeling you watched a 2000s+ film that SETS A BAR. Craft, ambition, resonance align. Must have actual critical weight (Oscar, Palme d'Or, Cannes/Venice/Berlin prize, near-universal critical consensus, or widely acknowledged landmark status). Popular-and-recent ≠ masterpiece.
""",
            tags: ["contemporary-classic","acclaimed","ambitious","landmark"],
            anchorsFit: [
                "Parasite — Palme d'Or + Best Picture",
                "Everything Everywhere All at Once — Best Picture + cultural landmark",
                "No Country for Old Men — Best Picture + critical consensus",
                "Moonlight — Best Picture + formal landmark",
                "There Will Be Blood — near-universal landmark",
                "In the Mood for Love — 21st-century canon",
            ],
            anchorsMiss: [
                "The Dark Knight — popular + acclaimed but more of a cultural event than critical landmark",
                "Inception — popular but not masterpiece-tier critical weight; prefer brainmelt-zone",
                "Pre-2000 films — use film-school-shelf instead",
            ],
            minConfidence: 0.72
        ),
        "regional-gems": MoodBucket(
            title: "Regional Gems",
            description: """
You leave having watched a STANDOUT Indian-cinema film (Tamil, Hindi, Malayalam, Bengali, Kannada, Telugu, etc.). Not every Indian film — must have a standout signal: award winner, festival standout, genre landmark, or widely acknowledged critical/cultural significance. Regional origin ALONE is not enough.
""",
            tags: ["indian-cinema","award-winner","cultural-landmark","regional-standout"],
            anchorsFit: [
                "Pather Panchali — Satyajit Ray landmark",
                "Nayakan — Mani Ratnam / IFFI canon",
                "Thanneer Thanneer — political-realism standout",
                "The Lunchbox — international-festival breakout",
                "Anbe Sivam — Tamil cult-canon",
                "Drishyam — genre-defining Malayalam thriller",
            ],
            anchorsMiss: [
                "A random Tamil/Hindi masala film — regional origin alone is NOT enough",
                "Non-Indian regional cinema (Korean, Iranian, etc.) — this tag is Indian-cinema specific",
            ],
            minConfidence: 0.82
        ),
        "underseen-treasures": MoodBucket(
            title: "Underseen Treasures",
            description: """
You leave feeling you RESCUED something — a globally overlooked gem that reward discovery. Low mainstream visibility + high artistic payoff. Championing expands the canon. Separate from regional-gems (that's Indian-specific); this is anywhere globally.
""",
            tags: ["hidden-gem","underrated","festival-darling","niche","word-of-mouth"],
            anchorsFit: [
                "The Fall — visual-maximalist obscurity",
                "Coherence — sub-million-budget gem",
                "A Ghost Story — indie unseen by most",
                "Timecrimes — Spanish time-travel gem",
                "The Brand New Testament — Belgian oddity",
            ],
            anchorsMiss: [
                "Parasite — not underseen, prefer modern-masterpieces",
                "Any major Indian film — prefer regional-gems",
            ],
            minConfidence: 0.65
        ),
        "heist-energy": MoodBucket(
            title: "Heist Energy",
            description: """
You leave buzzing with PLAN-MEETS-CHAOS — a clever setup, a team with roles, a ticking clock, double-crosses. The pleasure is MECHANISM: the plan's elegance and the moment it meets reality.
""",
            tags: ["caper","planning","team-dynamics","setpiece-machinery","betrayal"],
            anchorsFit: [
                "Ocean's Eleven — the modern template",
                "Inside Man — bank heist as chess",
                "The Italian Job — plan + twists",
                "Reservoir Dogs — post-heist aftermath",
                "Dog Day Afternoon — heist-gone-wrong",
                "Baby Driver — heist with rhythm",
                "Logan Lucky — redneck heist",
                "Inception — literal dream-heist",
            ],
            anchorsMiss: [
                "Rogue One — mission movie but register is war tragedy, not heist",
                "Money Heist (show, not film) — TV, out of scope",
            ],
            minConfidence: 0.65
        ),
        "cat-and-mouse": MoodBucket(
            title: "Cat and Mouse",
            description: """
You leave remembering a DUEL — predator vs prey, near-misses, traps, reversals. Strategic momentum between two sides that adapt. Doesn't need big set pieces; the pleasure is escalation and counter-move.
""",
            tags: ["pursuit","duel","strategy","tension-swings","trap-laying"],
            anchorsFit: [
                "Heat — cop-vs-thief duel",
                "The Silence of the Lambs — Clarice vs Lecter / Buffalo Bill",
                "Catch Me If You Can — chase with charm",
                "Prisoners — grief turns into hunt",
                "No Country for Old Men — Chigurh vs sheriff",
            ],
            anchorsMiss: [
                "Die Hard — one-man-vs-villains but really action-thriller, can overlap",
                "Drive — has chases but vibe-is-the-plot / men-with-vibes leads",
            ],
            minConfidence: 0.72
        ),
        "antihero-study": MoodBucket(
            title: "Antihero Study",
            description: """
You leave unsettled by INTIMACY with contradiction — magnetic, flawed leads bending morality until it breaks. Empathy and recoil in the same breath. Character study where the character is compelling AND troubling.
""",
            tags: ["moral-ambiguity","character-study","flawed-protagonist","charisma","downfall"],
            anchorsFit: [
                "There Will Be Blood — Daniel Plainview",
                "Taxi Driver — Travis Bickle",
                "The Social Network — Zuckerberg as antihero",
                "Nightcrawler — Lou Bloom",
                "Joker — Arthur Fleck",
                "Whiplash — Fletcher as antihero antagonist",
            ],
            anchorsMiss: [
                "The Godfather — family epic, prefer crime-grit-style",
                "Breaking Bad (show) — out of scope",
            ],
            minConfidence: 0.72
        ),
        "ensemble-mosaic": MoodBucket(
            title: "Ensemble Mosaic",
            description: """
You leave remembering a PATTERN, not a protagonist. Interlocking characters and perspectives form a larger picture; structure, rhythm, and cross-cut empathy carry the story. No single lead.
""",
            tags: ["ensemble","interwoven","multi-perspective","cross-cutting","choral"],
            anchorsFit: [
                "Magnolia — weather of LA lives",
                "Short Cuts — Altman's network template",
                "Pulp Fiction — interlocking chapters",
                "Babel — global cross-cut",
                "Crash — ensemble reveal structure",
            ],
            anchorsMiss: [
                "Heat — large cast but Pacino + De Niro lead, prefer crime-grit-style",
                "The Avengers — team movie but narrative is single-thread",
            ],
            minConfidence: 0.65
        ),
        "quiet-epics": MoodBucket(
            title: "Quiet Epics",
            description: """
You leave having felt IMMENSITY without bombast. Large stakes — time, landscape, history, family generations — rendered with restraint and intimacy. Scope is epic; delivery is patient.
""",
            tags: ["sweeping-intimacy","landscape","measured","austere","contemplative"],
            anchorsFit: [
                "Pather Panchali — rural epic intimate",
                "Days of Heaven — landscape as character",
                "Roma — childhood at empire-scale",
                "The New World — historical quiet",
                "Kadaisi Vivasayi — last farmer as quiet epic",
            ],
            anchorsMiss: [
                "Lawrence of Arabia — fits scale but register is grand, not quiet",
                "Interstellar — ambitious but loud, prefer time-twists or modern-masterpieces",
            ],
            minConfidence: 0.72
        ),
        "bittersweet-aftermath": MoodBucket(
            title: "Bittersweet Aftermath",
            description: """
You leave quietly moved — awe braided with melancholy, NOT devastation and NOT joy. A soft ache lingers: "that was beautiful, and sad." Plot endings can be tragic or ambiguous — what matters is the RESIDUE: graceful, reflective, hopeful-tinged loss. If you leave raw and wrecked, prefer emotional-gut-punch. If you leave smiling and warm, prefer feel-good-romance or rainy-day-rewinds.
""",
            tags: ["bittersweet","melancholy","closure","grace","acceptance","residue-ache"],
            anchorsFit: [
                "Casablanca — airport farewell leaves a graceful ache",
                "In the Mood for Love — the whispered secret-in-the-wall residue",
                "Before Sunset — wistful open-ended reunion",
                "Her — final rooftop scene, loss held with acceptance",
                "Past Lives — reunion and goodbye, 24 years braided into a night",
                "Lost in Translation — parting whisper",
            ],
            anchorsMiss: [
                "The Shawshank Redemption — triumphant reunion, prefer rainy-day-rewinds",
                "Hereditary — raw devastation, prefer emotional-gut-punch",
                "It's a Wonderful Life — feel-good finale, prefer rainy-day-rewinds",
                "Rocky — up-ending, prefer rainy-day-rewinds",
                "Thelma & Louise — plot-tragic but residue is defiance-in-awe; CAN qualify (residue beats plot; may also carry antihero-study)",
            ],
            minConfidence: 0.82
        ),
        "based-on-vibes-true-story": MoodBucket(
            title: "Based on Vibes (True Story)",
            description: """
You leave feeling the TRUTH was emotional — fact-rooted but privileging tone, place, and lived texture over transcript accuracy. Liberty taken with chronology or specifics in service of mood.
""",
            tags: ["true-story","based-on-real-events","tone-forward","impressionistic","period-texture"],
            anchorsFit: [
                "Once Upon a Time in Hollywood — fact-riff with vibe",
                "Jackie — emotional biography",
                "Licorice Pizza — 70s-era memory",
                "Spencer — feeling as history",
                "The Assassination of Jesse James… — myth-poetic biography",
            ],
            anchorsMiss: [
                "Spotlight — journalistic-accurate, prefer slow-burn-sharp-blade",
                "The Social Network — biographical but antihero-study leads",
            ],
            minConfidence: 0.72
        ),
        "cult-chaos": MoodBucket(
            title: "Cult Chaos",
            description: """
You leave QUOTING it and looking for a screening at midnight. Bizarre favorites that inspire obsession — imperfect by design, unforgettable by effect. Midnight-movie energy, scenes living rent-free.
""",
            tags: ["cult","midnight-movie","quotable","weird-core","outsider-charm"],
            anchorsFit: [
                "The Big Lebowski — the canonical cult object",
                "The Rocky Horror Picture Show — midnight movie template",
                "The Room — so-bad-it's-cult",
                "Donnie Darko — 1am cult",
                "Evil Dead II — genre cult",
            ],
            anchorsMiss: [
                "Fight Club — massive cult but major theatrical / Oscar-adjacent, can overlap with antihero-study",
                "Parasite — mainstream-acclaimed, not cult",
            ],
            minConfidence: 0.72
        ),
        "experimental-cinema": MoodBucket(
            title: "Experimental Cinema",
            description: """
You leave having experienced FORM directly — structure, sound, or image pushed into new shapes. Narrative is minimal or absent; discovery happens through sensation and pattern rather than story.
""",
            tags: ["avant-garde","form-forward","non-narrative","sound-design","structure-play"],
            anchorsFit: [
                "Koyaanisqatsi — pure image-and-score",
                "Stalker — slow-cinema form",
                "Man with a Movie Camera — formal foundation",
                "Last Year at Marienbad — narrative dissolution",
                "Enter the Void — sensation as cinema",
            ],
            anchorsMiss: [
                "Mulholland Drive — weird but has narrative, prefer brainmelt-zone",
                "2001: A Space Odyssey — experimental sections but primarily sci-fi canon, prefer visual-worship or film-school-shelf",
            ],
            minConfidence: 0.65
        )
    ]

    init() {
        if let path = ProcessInfo.processInfo.environment["NOCTURNE_DATABASE_PATH"], !path.isEmpty {
            self.databasePath = path
        } else {
            self.databasePath = "/app/data/nocturne.sqlite"
        }
    }
}

struct MoodBucket: Codable, Sendable {
    let title: String
    let description: String
    let tags: [String]?
    let anchorsFit: [String]?      // 3-5 canonical films that fit this tag (LLM-facing)
    let anchorsMiss: [String]?     // close-but-no films with redirect to correct tag
    let minConfidence: Double?     // per-tag confidence floor; nil → 0.72 default
}

extension MoodBucket {
    init(title: String, description: String) {
        self.init(
            title: title, description: description,
            tags: nil, anchorsFit: nil, anchorsMiss: nil, minConfidence: nil)
    }

    init(title: String, description: String, tags: [String]?) {
        self.init(
            title: title, description: description,
            tags: tags, anchorsFit: nil, anchorsMiss: nil, minConfidence: nil)
    }
}

struct MoodBucketsResponse: Codable, Sendable {
    let moods: [String: MoodBucket]
}
