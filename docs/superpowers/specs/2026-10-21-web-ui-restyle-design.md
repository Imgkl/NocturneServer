# Spec: NocturneServer web UI restyle after X-Cache Live

> Status: **draft 2026-10-21**, direction approved by the owner ("follow that design structure"), mockup pending their pick on two choices. Replaces the Editorial Light look (EB Garamond, uppercase tracked labels, square corners, hairlines) in `frontend/nocturne-web`. Server routes do not change.

## Why

The owner runs X-Cache Live on the same Pi and likes how it looks and works. The Nocturne admin UI is the tool they will live in while reviewing 680 films, so it should feel like that app: white, soft, fast, one visual language from the header to the toasts. Editorial print DNA (serif italics, small caps, dotted underlines) reads as a magazine, and the owner has said before that movies are not magazines.

## Source of truth

X-Cache Live, `/opt/stacks/x-cache-live/web/src` on the Pi (owner's project, React + Tailwind 4 + Geist). The tokens, primitives and layouts below are lifted from `index.css`, `components/ui.tsx`, `components/Header.tsx`, `components/FolderBand.tsx`, `components/ToSort.tsx`, `components/DetailModal.tsx`, `components/Sync.tsx` and `pages/Settings.tsx`, checked against the live app on 2026-10-21. Where Nocturne has no analog, the closest X-Cache pattern is named.

## Tokens

```css
@theme {
  --font-sans: "Geist Variable", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --color-canvas: #f3f3f3;   /* chips, hover fills, inputs at rest; the page itself stays pure white */
  --color-canvas-2: #e9e9e9; /* chip hover */
  --color-surface: #ffffff;
  --color-ink: #111111;
  --color-ink-2: #2b2b2b;
  --color-mute: #6e6e6e;
  --color-faint: #a1a1a1;
  --color-line: #ededed;
  --color-line-2: #dcdcdc;
  --color-accent: #1f5eff;       /* links only */
  --color-accent-soft: #eaf0ff;
  --color-good: #0e8a4a;         /* verified source, success toasts: text */
  --color-new: #16b364;          /* the "New" dot */
  --color-bad: #c4320a;          /* danger buttons, error text */
  --shadow-card: 0 0 0 1px rgba(0,0,0,.055), 0 1px 2px rgba(0,0,0,.03), 0 12px 32px -20px rgba(0,0,0,.10);
  --shadow-pop:  0 0 0 1px rgba(0,0,0,.06), 0 24px 60px -16px rgba(0,0,0,.25);
  --shadow-modal: 0 40px 100px -24px rgba(0,0,0,.45);
  --ease-out-soft: cubic-bezier(.2,.75,.2,1);
}
```

Type: Geist only, `font-feature-settings: "ss01"`. Display 40px / -0.038em / 640 weight (30px on phones); card titles 17px semibold -0.02em; body 13.5 to 14px; captions 12 to 12.5px mute; numbers `tabular-nums`. No uppercase tracking anywhere. No serif.

Shape: pills (`rounded-full`) for buttons, chips, selects and toasts; `rounded-xl` inputs; `rounded-2xl` thumbnails and menus; `rounded-[24px]` cards, dialogs, sheets and the modal. Hairlines only as `divide-y` between list rows (#f0f0f0).

Motion: `rise` (page titles), `pop-in` (grid cards), `modal-in`, `sheet-in` (right sheet, bottom sheet on phones), `row-out` (a reviewed row slides away), `pop-menu`, a sliding tab underline (380ms, same ease), an indeterminate progress line under the header. `prefers-reduced-motion` kills all of it. No marching-ants button borders, no 3D letter flips.

Dependencies: `@fontsource-variable/geist` and `lucide-react` are added; `@fontsource/eb-garamond` and `framer-motion` are removed if nothing else uses them (both lockfiles updated).

## Primitives (`src/ui/`)

| Nocturne today | After | X-Cache source |
|---|---|---|
| `Button` variants primary / line / ghost / destructive, uppercase 10.5px | `Btn` kinds primary (ink pill), secondary (#f3f3f3 pill), ghost, outline (ring), danger (oxblood text + ring); sizes sm 32px, md 36px, lg 48px; a disabled button carries its reason as a title and small inline text | `ui.tsx` `Btn` |
| `Chip` uppercase 10px | pill chip, 13px medium, count in faint tabular numerals; active = ink on white | `Segmented`, folder chips |
| `Input` underline-only | `Field` label 12px semibold mute + `inputCls` (36px, #f3f3f3, rounded-xl, white on focus with a #dcdcdc ring) | `ui.tsx` |
| `Card` bordered | `Card` rounded-24 white with the ring shadow, optional title 17px + sub + right slot | `ui.tsx` `Card` |
| `Dialog` full-height sheet on phones, bordered box on desktop | `Dialog` rounded-24, black/40 blurred backdrop, bottom sheet on phones | `ui.tsx` `Dialog` |
| `Badge` (new this week) | pill badge 11px semibold: ink on white for "Review" and "Watched", green dot + "New", ink pill "unverified source" | `Pin.tsx` `NewBadge`, folder pill |
| `Toggle` square switch | round switch (ink track, white thumb) | Settings |
| `Divider` with label | removed; `divide-y` rows and card gaps | |
| `Spinner` | kept for buttons; progress elsewhere is the header line and `Bar` | `ui.tsx` `Bar` |
| none | `Stat` big number + label, `Segmented` control, `Select` pill, `Empty` state, `Toast` pill, `Page` layout, `Dot` | `ui.tsx` |

## Shell

One header on every page (sticky, white at 92% with backdrop blur, a 1px shadow once scrolled):

- Left: the Nocturne wordmark in Geist semibold with the "N" mark (same weight as X-Cache's logo lockup; no serif).
- Centre: search pill "Search films, moods" with a ⌘K keycap; opens a command palette over films and moods (replaces the inline search input).
- Right: **Sync** pill with a chevron menu (Sync library, Run coverage, Start auto-tag…, Reprocess…, Link Nocturne app, then the pages), and a **Review · N** pill that goes to the Review page. The sync label reads "Synced 2 h ago" when idle and the stage text while a run is on.
- Under the header: a thin indeterminate progress line while any run (sync, coverage, auto-tag) is active, and the page tabs centred: **Library · Review · Settings**. The underline slides between tabs.

The bordered banners (`BackfillProgress`, `CoverageProgress`, the fixed sync pill) go away; the header line plus a toast ("Auto-tagging 12 of 209 watched films") carry the state. Toasts are ink pills at the bottom; error toasts are white with an oxblood ring.

## Library

Replaces the current title block, floating chips and poster grid.

1. **Mood band** (X-Cache's folder band): a horizontal rail of collage tiles, one per mood plus "All". Each tile is a 3-poster collage (hero + two stacked) in a rounded-20 frame, name and count underneath, the selected tile ringed in ink. Arrows at the rail edges on desktop, edge masks. ⌘/shift-click combines moods. When the page scrolls, the band collapses into the chip row that X-Cache shows: round chips with a 20px cover thumbnail and the name.
2. **Heading**: "Everything" / the mood title at 40px, under it a one-line description and "680 films · 209 watched · 471 untagged" in mute.
3. **Chip row**: Watched, Unwatched, Untagged, Needs review, with counts; a sort pill (Newest, A to Z, Year, Runtime); a filter icon button. These replace the six-way sort menu and the Films/TV label.
4. **Grid**: posters at 2:3 in a responsive grid (not masonry: posters are uniform), rounded-2xl, soft shadow on hover, `pop-in` on mount. Floating pills top-left: the film's first mood (ink on white) and "Review" when pending; a green-dot "New" pill for films added since the last visit; a "Watched" pill bottom-left. Title and year under the poster in 13px, like the Dribbble-style byline.
5. Empty state: `Empty` with a film icon, "No films match", a sentence.

## Review

The review queue becomes a page (the tray pattern is the alternative, see Choices). Rows follow X-Cache's `TrayRow`:

- Left: the poster (80px tall, rounded-2xl). Right: title + year + "Watched" badge, the residue sentence in 13px, then "Why: " with the first reason.
- **Mood pills**: the reader's candidates in probability order, each pill "Mood 93%"; applied ones solid ink, held-back proposals grey; tapping toggles. "Other…" opens the mood picker (searchable, like `FolderPicker`). The evidence phrase for each pill shows on hover and in the expanded row.
- Right-aligned actions: **Approve** (ink) and Reject (outline). An approved or rejected row slides out (`row-out`).
- Top of the page: the count, a Watched-first segmented control (Watched · Unwatched · All), an "unverified source" explanation when any row carries it, and a "Retry errors" card when decisions failed, exactly as X-Cache does.
- Keyboard: ↑↓ move, A approve, R reject, 1 to 5 toggle the nth pill.

## Film panel

X-Cache's `DetailModal` layout, portalled, rounded-24, Esc to close, Previous/Next in the footer that walks the current grid or queue:

- Left stage: the poster on a near-black rounded stage (backdrop behind it when Jellyfin has one).
- Right column: "12 of 680" position, Share (copies the Jellyfin deep link) and **Open in Jellyfin** (ink pill); title 18px + year + runtime + genres in mute; the Jellyfin overview in 14px.
- **Moods**: the current tags as pills with ×, "+ Add" opening the picker; the five-tag cap shown as "3 of 5".
- **Story source** card: badge (verified / unverified source / no plot), "Heat (1995 film) · en.wikipedia", fetched time, awards line; actions as small outline pills: Change page, Refresh, Generate synopsis; **Show spoilers** as a round switch revealing the plot in a mono block, as picked earlier today.
- **Why these moods?** collapsible row: the decision's items with probabilities and evidence (the `EvidenceList` content).
- Footer: Previous / Next and the key hints.

## Settings

X-Cache's page: a left section nav (sticky on desktop) and accordion cards that open with a chevron; healthy sections start collapsed with a one-line summary, sections that need attention start open at the top.

| Section | Summary line examples | Contents |
|---|---|---|
| Connections | "Jellyfin · Anthropic · OMDb connected" / "Anthropic key missing" | the Jellyfin form, the two API key fields, Test buttons |
| Tagger | "haiku · $3.42 of $15 this month · auto-tag on sync" | reader and strong model selects, budget with the spend bar, synopsis fallback switch, auto-tag on sync switch, Start auto-tag with the scope segmented control, Reprocess |
| Story sources | "612 English · 23 no plot · 15 unresolved" | the coverage card: Run, the count pills as filters, the worklist |
| Link app | "QR ready" | the QR panel |
| Data | "680 films · last sync 2 h ago" | Sync now, import, export, clear local films (danger) |
| About | "v0.1.3" | version, links |

Each card uses `Card`, `Field`, `inputCls`, `Btn`, `Stat` where numbers lead.

## Onboarding

Same wizard steps, restyled: a centred 440px column, the wordmark, a 30px title, `Field` inputs, one ink primary pill per step, a thin step indicator. Discovery results as a list of outline pills.

## What goes away

Serif everything, uppercase tracked labels, square corners, the marching-ants hover, the floating glass chrome idea, dotted underline links, the bordered run banners, the fixed sync pill, the per-row bordered Rows in Settings.

## Choices for the owner

1. **Review surface**: A, a full page (above); B, X-Cache's right-hand tray that slides over the library (460px, bottom sheet on phones). A suits a 200-film session; B keeps the library in view.
2. **Film panel**: A, the centred modal with the poster stage (above); B, a right-hand sheet like the tray, poster on top, content below. A matches X-Cache's post modal; B is one pattern for both review and detail.

## Implementation plan (after the pick)

1. Tokens and fonts: `index.css` theme, Geist, lucide; delete the Garamond and framer-motion imports.
2. `src/ui/`: `Btn`, `Card`, `Chip`, `Field`+`inputCls`, `Segmented`, `Select`, `Dialog`, `Toast`, `Page`, `Stat`, `Empty`, `Bar`, `Badge`, `Toggle`, `Dot`. Old components are rewritten in place so imports keep working.
3. Shell: `Header` (wordmark, search pill, Sync menu, Review pill, progress line), `PageTabs`, hash routing for the three pages.
4. Library: `MoodBand` (collage tiles + collapsed chips), heading, chip row, `PosterCard` grid, `Empty`.
5. Review page with `ReviewRow`, the mood picker, keyboard handling.
6. Film panel: `FilmModal` with the story source card and the evidence row.
7. Settings page with sections; onboarding restyle.
8. Build, click through every surface on the Pi, then this spec's status line flips to shipped.

Routes stay as they are; `lib/api.ts` only gains what the command palette and the position footer need (nothing yet).

## Acceptance

Every screen uses only the tokens above; no serif, no uppercase tracking; Geist loads from the bundle; the three pages and the panel work at 400px; `prefers-reduced-motion` disables the animations; the review flow (approve, reject, edit, open film, next) works end to end on the Pi against real films.
