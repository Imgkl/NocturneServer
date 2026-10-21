import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ListChecks, RotateCw, Sparkles, X } from 'lucide-react';
import { api, posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { moodTitle, pct } from '../lib/policy';
import { Button } from '../ui/Button';
import { Card } from '../ui/Card';
import { Dialog } from '../ui/Dialog';
import { Empty } from '../ui/Empty';
import { Spinner } from '../ui/Spinner';
import { inputCls } from '../ui/Input';
import type { MoodBuckets, Movie, TeachFilm, TeachGroup } from '../lib/types';

const MIN_ANSWERS = 3;
// Boundary chips shown at the top; the full list follows below.
const CHIP_LIMIT = 12;

interface TeachPageProps {
  moods: MoodBuckets;
  movieLookup: (jellyfinId: string) => Movie | undefined;
  onOpenMovie: (movie: Movie) => void;
  say: (text: string, tone?: 'ok' | 'error') => void;
  // The number of unanswered films changed (the tab shows it).
  onWaiting: (count: number) => void;
  // Accepted rules started a regrade run; the caller polls it.
  onRegradeStarted: () => void;
}

type Flat = { group: TeachGroup; film: TeachFilm };

// X-Cache's Teach page, for films: every film where you and AI disagree or the grader was unsure,
// grouped by the two moods in question, one tap each. Three answers on a boundary let the strong
// model write rules into the guide; accepting them regrades the films on that boundary.
export function TeachPage({ moods, movieLookup, onOpenMovie, say, onWaiting, onRegradeStarted }: TeachPageProps) {
  const [groups, setGroups] = useState<TeachGroup[] | null>(null);
  const [guideVersion, setGuideVersion] = useState<number | null>(null);
  const [focus, setFocus] = useState(0);
  const [busy, setBusy] = useState(false);
  const [draft, setDraft] = useState<{ group: TeachGroup; rules: string[] | null } | null>(null);

  const load = useCallback(async () => {
    try {
      const r = await api.teach.groups();
      // Most unanswered first; within a group the unanswered films come first.
      const sorted = [...r.groups]
        .map((g) => ({ ...g, films: [...g.films].sort((a, b) => Number(!!a.answer) - Number(!!b.answer)) }))
        .sort((a, b) => b.films.length - b.answered - (a.films.length - a.answered) || b.films.length - a.films.length);
      setGroups(sorted);
      setGuideVersion(r.guideVersion);
      onWaiting(sorted.reduce((n, g) => n + g.films.length - g.answered, 0));
    } catch (e) {
      say(e instanceof Error ? e.message : 'Failed to load the Teach list', 'error');
    }
  }, [onWaiting, say]);
  useEffect(() => {
    void load();
  }, [load]);

  const flat = useMemo<Flat[]>(() => (groups ?? []).flatMap((group) => group.films.map((film) => ({ group, film }))), [groups]);
  const waiting = flat.filter((f) => !f.film.answer).length;
  const cur = flat[Math.min(focus, flat.length - 1)];

  const answer = useCallback(
    async (t: Flat, value: string) => {
      if (busy) return;
      setBusy(true);
      try {
        await api.teach.answer(t.film.jellyfinId, t.group.boundary.key, value);
        setGroups((gs) =>
          (gs ?? []).map((g) => {
            if (g.boundary.key !== t.group.boundary.key) return g;
            const films = g.films.map((f) => (f.jellyfinId === t.film.jellyfinId ? { ...f, answer: value } : f));
            return { ...g, films, answered: films.filter((f) => !!f.answer).length };
          }),
        );
        say(value === 'neither' ? 'Neither' : moodTitle(moods, value));
        // Move on to the next film still waiting.
        const i = flat.findIndex((x) => x.film.jellyfinId === t.film.jellyfinId && x.group.boundary.key === t.group.boundary.key);
        const next = flat.findIndex((x, j) => j > i && !x.film.answer);
        if (next >= 0) setFocus(next);
      } catch (e) {
        say(e instanceof Error ? e.message : 'Failed to save the answer', 'error');
      } finally {
        setBusy(false);
      }
    },
    [busy, flat, moods, say],
  );

  useEffect(() => {
    onWaiting(waiting);
  }, [waiting, onWaiting]);

  // Keys: j/k move, 1 the left mood, 2 the right mood, 0 neither.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable || e.metaKey || e.ctrlKey || e.altKey || draft) return;
      if (e.key === 'j' || e.key === 'ArrowDown') {
        e.preventDefault();
        setFocus((i) => Math.min(flat.length - 1, i + 1));
      } else if (e.key === 'k' || e.key === 'ArrowUp') {
        e.preventDefault();
        setFocus((i) => Math.max(0, i - 1));
      } else if (e.key === '1' && cur) void answer(cur, cur.group.boundary.left);
      else if (e.key === '2' && cur) void answer(cur, cur.group.boundary.right);
      else if (e.key === '0' && cur) void answer(cur, 'neither');
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [flat.length, cur, answer, draft]);
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (focus > 0) listRef.current?.querySelector<HTMLElement>(`[data-i="${focus}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [focus]);
  useEffect(() => {
    setFocus((f) => Math.max(0, Math.min(f, flat.length - 1)));
  }, [flat.length]);

  async function openDraft(group: TeachGroup) {
    setDraft({ group, rules: null });
    try {
      const r = await api.teach.previewRules(group.boundary.key);
      setDraft((d) => (d && d.group.boundary.key === group.boundary.key ? { group, rules: r.rules } : d));
    } catch (e) {
      setDraft(null);
      say(e instanceof Error ? e.message : 'Could not write the rules', 'error');
    }
  }

  async function acceptDraft() {
    if (!draft?.rules) return;
    const rules = draft.rules.map((r) => r.trim()).filter(Boolean);
    if (rules.length === 0) return;
    setBusy(true);
    try {
      const r = await api.teach.acceptRules(draft.group.boundary.key, rules);
      setDraft(null);
      say(`Guide v${r.guideVersion}: ${r.rules} rule${r.rules === 1 ? '' : 's'} added${r.regradeStarted ? `, regrading ${r.regradeFilms} films` : ''}`);
      if (r.regradeStarted) onRegradeStarted();
      await load();
    } catch (e) {
      say(e instanceof Error ? e.message : 'Failed to add the rules', 'error');
    } finally {
      setBusy(false);
    }
  }

  const label = (g: TeachGroup) => `${g.leftTitle} or ${g.rightTitle}`;
  const sub =
    groups === null ? (
      'Loading…'
    ) : waiting ? (
      <>
        <b className="font-semibold text-ink">{waiting}</b> film{waiting === 1 ? '' : 's'} where you and AI disagree or AI was unsure, on {groups.length} boundar{groups.length === 1 ? 'y' : 'ies'}. Pick the mood you would look under. Three answers on a boundary let AI write a rule from them.
      </>
    ) : flat.length ? (
      <>All {flat.length} answered. Write rules below, then run the Accuracy page again.</>
    ) : (
      'Nothing to teach yet.'
    );

  return (
    <div className="mx-auto w-full max-w-[1080px] px-4 pb-28 pt-6 sm:px-8 sm:pt-10">
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
        <div className="min-w-0 max-w-[760px]">
          <h1 className="rise text-[30px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">Teach</h1>
          <p className="mt-3 text-[15px] leading-[1.55] text-mute">{sub}</p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {guideVersion != null && <span className="text-[12.5px] text-faint">Guide v{guideVersion}</span>}
          <Button variant="outline" size="sm" onClick={() => void load()} disabled={busy} title="Reload the list">
            <RotateCw size={14} /> Reload
          </Button>
        </div>
      </div>

      <div className="mt-9 space-y-6 sm:mt-10">
        {groups && groups.length > 0 && (
          // The busiest boundaries as chips (the groups are sorted by films waiting); the rest are below.
          <div className="flex flex-wrap items-center gap-2 rounded-[20px] bg-[#f7f7f7] px-5 py-4 text-[12.5px] text-mute sm:px-6">
            <span className="mr-1 font-semibold text-ink">Boundaries:</span>
            {groups.slice(0, CHIP_LIMIT).map((g) => (
              <a key={g.boundary.key} href={`#teach`} onClick={(e) => { e.preventDefault(); document.getElementById(`b-${g.boundary.key}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' }); }} className="inline-flex h-6 items-center gap-1 rounded-full bg-white px-2.5 shadow-[0_0_0_1px_rgba(0,0,0,.06)] hover:text-ink">
                {label(g)} <b className="font-semibold text-ink">{g.films.length - g.answered || <span className="text-good">✓</span>}</b>
              </a>
            ))}
            {groups.length > CHIP_LIMIT && <span className="text-faint">and {groups.length - CHIP_LIMIT} more below</span>}
          </div>
        )}
        {groups && waiting > 0 && (
          <p className="hidden items-center gap-3 text-[12px] text-faint md:flex">
            {[['j', 'k', 'move'], ['1', 'the left mood'], ['2', 'the right mood'], ['0', 'neither']].map((g) => (
              <span key={g.join()} className="inline-flex items-center gap-1">
                {g.slice(0, -1).map((x) => (
                  <kbd key={x} className="inline-grid h-5 min-w-5 place-items-center rounded-md bg-white px-1 font-sans text-[11px] font-medium text-mute shadow-[0_0_0_1px_rgba(0,0,0,.08)]">
                    {x}
                  </kbd>
                ))}
                {g[g.length - 1]}
              </span>
            ))}
          </p>
        )}
        {groups && groups.length === 0 && (
          <Card>
            <Empty icon={<ListChecks size={20} />} title="Nothing to teach" sub="When you add a mood AI did not pick, keep one it held back, or AI's two grader passes disagree, the film lands here with the two moods in question. Review a few films first." />
          </Card>
        )}

        <div ref={listRef} className="space-y-3">
          {groups?.map((g) => {
            const start = flat.findIndex((f) => f.group.boundary.key === g.boundary.key);
            const left = g.films.length - g.answered;
            return (
              <section key={g.boundary.key} id={`b-${g.boundary.key}`} className="scroll-mt-28 space-y-3">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-2 px-2 pt-3">
                  <div className="text-[12px] font-semibold uppercase tracking-wide text-faint">
                    {label(g)} · {left ? `${left} waiting` : 'all answered'}
                  </div>
                  <Button variant={g.answered >= MIN_ANSWERS && left === 0 ? 'primary' : 'outline'} size="sm" className="ml-auto" disabled={busy || g.answered < MIN_ANSWERS} reason={g.answered < MIN_ANSWERS ? `${g.answered} of ${MIN_ANSWERS} answers` : null} reasonInline={false} onClick={() => void openDraft(g)}>
                    <Sparkles size={13} /> Write rules
                  </Button>
                </div>
                {g.rules.length > 0 && (
                  <ul className="space-y-1 px-2 text-[12.5px] text-mute">
                    {g.rules.map((r, i) => (
                      <li key={i}>
                        <span className="text-faint">Rule · </span>
                        {r}
                      </li>
                    ))}
                  </ul>
                )}
                {g.films.map((film, j) => {
                  const i = start + j;
                  return <TeachCard key={film.jellyfinId} i={i} group={g} film={film} moods={moods} movie={movieLookup(film.jellyfinId)} focused={i === focus} busy={busy} onFocus={() => setFocus(i)} onAnswer={(v) => void answer({ group: g, film }, v)} onOpen={() => { const m = movieLookup(film.jellyfinId); if (m) onOpenMovie(m); }} />;
                })}
              </section>
            );
          })}
        </div>
      </div>

      <Dialog
        open={!!draft}
        onClose={() => setDraft(null)}
        title={draft ? `Rules for ${label(draft.group)}` : ''}
        sub={draft ? `Drafted by the strong model from your ${draft.group.answered} answers on this boundary. Edit or drop any. Accepting adds them to the guide and regrades the films on this boundary.` : ''}
        actions={
          <>
            <Button variant="ghost" onClick={() => setDraft(null)} disabled={busy}>
              Cancel
            </Button>
            <Button variant="primary" onClick={() => void acceptDraft()} disabled={busy || !draft?.rules || draft.rules.every((r) => !r.trim())}>
              {busy ? 'Adding…' : `Accept ${draft?.rules?.filter((r) => r.trim()).length ?? 0} rule${(draft?.rules?.filter((r) => r.trim()).length ?? 0) === 1 ? '' : 's'}`}
            </Button>
          </>
        }
      >
        {!draft?.rules ? (
          <div className="flex items-center gap-2 py-6 text-[13.5px] text-mute">
            <Spinner size={14} /> Writing rules…
          </div>
        ) : draft.rules.length === 0 ? (
          <p className="py-4 text-[13.5px] text-mute">The model found no rule worth adding from these answers. Answer a few more films first.</p>
        ) : (
          <ul className="space-y-2.5">
            {draft.rules.map((rule, i) => (
              <li key={i} className="flex items-start gap-2">
                <textarea value={rule} rows={2} onChange={(e) => setDraft((d) => (d && d.rules ? { ...d, rules: d.rules.map((x, j) => (j === i ? e.target.value : x)) } : d))} className={cn(inputCls, 'h-auto min-h-[56px] resize-y py-2 text-[13px] leading-[1.45]')} />
                <button type="button" aria-label="Drop this rule" onClick={() => setDraft((d) => (d && d.rules ? { ...d, rules: d.rules.filter((_, j) => j !== i) } : d))} className="mt-1 grid h-8 w-8 shrink-0 place-items-center rounded-full text-mute hover:bg-[#f3f3f3] hover:text-ink cursor-pointer">
                  <X size={15} />
                </button>
              </li>
            ))}
          </ul>
        )}
      </Dialog>
    </div>
  );
}

interface TeachCardProps {
  i: number;
  group: TeachGroup;
  film: TeachFilm;
  moods: MoodBuckets;
  movie?: Movie;
  focused: boolean;
  busy: boolean;
  onFocus: () => void;
  onAnswer: (value: string) => void;
  onOpen: () => void;
}

// One film: poster, title, AI's one-line read, who picked what, and the three answers.
function TeachCard({ i, group, film, moods, movie, focused, busy, onFocus, onAnswer, onOpen }: TeachCardProps) {
  const { left, right } = group.boundary;
  const answered = !!film.answer;
  const pickOf = (slug?: string) => (slug ? moodTitle(moods, slug) : null);
  const choice = (value: string, key: string, text: string) => {
    const on = film.answer === value;
    return (
      <Button size="sm" variant={on ? 'primary' : 'outline'} disabled={busy} onClick={() => onAnswer(value)} aria-pressed={on}>
        <kbd className={cn('mr-1 text-[10px]', on ? 'opacity-70' : 'opacity-50')}>{key}</kbd> {text}
      </Button>
    );
  };
  return (
    <div
      data-i={i}
      onPointerDown={onFocus}
      className={cn(
        'rounded-[24px] bg-white p-4 transition-shadow duration-200 sm:p-6',
        focused ? 'shadow-[0_0_0_1.5px_#111,0_16px_40px_-18px_rgba(0,0,0,.28)]' : 'shadow-[0_0_0_1px_rgba(0,0,0,.055),0_1px_2px_rgba(0,0,0,.03)]',
        answered && !focused && 'opacity-70',
      )}
    >
      <div className="flex gap-4">
        <button type="button" onClick={onOpen} className="shrink-0 cursor-pointer" aria-label={`Open ${film.title}`}>
          <img src={posterUrl(film.jellyfinId, 'thumb')} alt="" loading="lazy" className="h-20 w-20 rounded-2xl bg-[#f2f2f2] object-cover transition hover:opacity-90 sm:h-24 sm:w-24" />
        </button>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5 text-[13px]">
            <button type="button" onClick={onOpen} className="truncate font-semibold text-ink cursor-pointer">
              {film.title}
            </button>
            {movie?.year && <span className="shrink-0 tabular-nums text-faint">{movie.year}</span>}
            {movie?.played && <span className="shrink-0 text-faint">· Watched</span>}
            {answered && <span className="ml-auto hidden shrink-0 text-[11.5px] font-medium text-good sm:inline">answered</span>}
          </div>
          {film.residue && <p className="mt-1 line-clamp-3 text-[13.5px] leading-[1.45] text-[#3a3a3a]">{film.residue}</p>}
          <p className="mt-1.5 text-[12.5px] text-mute">
            {film.systemPick && (
              <>
                <span className="font-medium">AI:</span> {pickOf(film.systemPick)}
              </>
            )}
            {film.systemPick && film.adminPick && ' · '}
            {film.adminPick && (
              <>
                <span className="font-medium">You:</span> {pickOf(film.adminPick)}
              </>
            )}
            {(film.leftProbability != null || film.rightProbability != null) && (
              <>
                {(film.systemPick || film.adminPick) && ' · '}
                <span className="font-medium">{film.probabilitySource === 'reader' ? 'AI confidence:' : 'Jev:'}</span> {group.leftTitle} {pct(film.leftProbability)} · {group.rightTitle} {pct(film.rightProbability)}
              </>
            )}
          </p>
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-[#f2f2f2] pt-4">
        {choice(left, '1', group.leftTitle)}
        {choice(right, '2', group.rightTitle)}
        {choice('neither', '0', 'Neither')}
      </div>
    </div>
  );
}
