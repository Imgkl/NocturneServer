import { useCallback, useEffect, useRef, useState } from 'react';
import { Check, ChevronDown, Plus, RotateCw } from 'lucide-react';
import { api, posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { pct } from '../lib/policy';
import { Button } from '../ui/Button';
import { Card } from '../ui/Card';
import { Empty } from '../ui/Empty';
import { Segmented } from '../ui/Segmented';
import { MoodPicker } from '../components/MoodPicker';
import type { MoodBuckets, Movie, VerifyFilm, VerifyMode, VerifyScope, VerifyTally } from '../lib/types';

const SAMPLE = 30;
const MAX_TAGS = 5;

interface CheckPageProps {
  moods: MoodBuckets;
  covers?: Record<string, string | undefined>;
  movieLookup: (jellyfinId: string) => Movie | undefined;
  onOpenMovie: (movie: Movie) => void;
  say: (text: string, tone?: 'ok' | 'error') => void;
  // A verdict landed: the caller refreshes the films and the Teach count.
  onVerified: () => void;
}

type Marks = { wrong: string[]; add: string[] };

// The spot check: thirty random films you have seen (or any film), each mood with its evidence.
// Tagged films: tap a mood that is wrong, add one AI considered, then Save; Looks right keeps them
// all. Films with no mood: pick from what AI considered, or any mood, or say nothing fits. Every
// verdict becomes the owner's labels. Keys: j k move, 1 to 5 toggle a mood, Enter saves.
export function CheckPage({ moods, covers, movieLookup, onOpenMovie, say, onVerified }: CheckPageProps) {
  const [scope, setScope] = useState<VerifyScope>('watched');
  const [mode, setMode] = useState<VerifyMode>('tagged');
  const [films, setFilms] = useState<VerifyFilm[] | null>(null);
  const [remaining, setRemaining] = useState(0);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [tally, setTally] = useState<VerifyTally | null>(null);
  const [marks, setMarks] = useState<Record<string, Marks>>({});
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState(0);
  const [busy, setBusy] = useState(false);
  const [seed, setSeed] = useState<string | undefined>(undefined);

  const load = useCallback(
    async (sc: VerifyScope, md: VerifyMode, s?: string) => {
      try {
        const r = await api.verify.sample(SAMPLE, sc, md, s);
        setFilms(r.films);
        setRemaining(r.remaining);
        setCounts(r.counts);
        setTally(r.tally);
        setMarks({});
        setFocus(0);
      } catch (e) {
        say(e instanceof Error ? e.message : 'Failed to load the sample', 'error');
      }
    },
    [say],
  );
  useEffect(() => {
    setFilms(null);
    void load(scope, mode, seed);
  }, [load, scope, mode, seed]);

  const list = films ?? [];
  const cur = list[Math.min(focus, list.length - 1)];
  const marksOf = (id: string): Marks => marks[id] ?? { wrong: [], add: [] };
  const toggleWrong = (id: string, slug: string) =>
    setMarks((m) => {
      const now = marksOf(id);
      return { ...m, [id]: { ...now, wrong: now.wrong.includes(slug) ? now.wrong.filter((x) => x !== slug) : [...now.wrong, slug] } };
    });
  const toggleAdd = (id: string, slug: string, limit: number) =>
    setMarks((m) => {
      const now = marksOf(id);
      if (now.add.includes(slug)) return { ...m, [id]: { ...now, add: now.add.filter((x) => x !== slug) } };
      return now.add.length >= limit ? m : { ...m, [id]: { ...now, add: [...now.add, slug] } };
    });

  const save = useCallback(
    async (film: VerifyFilm) => {
      if (busy) return;
      setBusy(true);
      try {
        const mk = marks[film.jellyfinId] ?? { wrong: [], add: [] };
        const r = await api.verify.save(film.jellyfinId, mk.wrong, mk.add);
        setTally(r.tally);
        const parts = [r.wrong.length ? `dropped ${r.wrong.length}` : '', r.added.length ? `added ${r.added.length}` : ''].filter(Boolean);
        say(parts.length ? `Kept ${r.kept.length}, ${parts.join(', ')}` : film.moods.length ? 'Looks right' : 'Nothing fits, noted');
        setLeaving((l) => new Set(l).add(film.jellyfinId));
        window.setTimeout(() => {
          setLeaving((l) => {
            const n = new Set(l);
            n.delete(film.jellyfinId);
            return n;
          });
          setFilms((fs) => (fs ?? []).filter((f) => f.jellyfinId !== film.jellyfinId));
        }, 240);
        setRemaining((n) => n);
        setCounts((c) => ({ ...c, [`${scope}.${mode}`]: Math.max(0, (c[`${scope}.${mode}`] ?? 1) - 1) }));
        onVerified();
      } catch (e) {
        say(e instanceof Error ? e.message : 'Failed to save the verdict', 'error');
      } finally {
        setBusy(false);
      }
    },
    [busy, marks, say, onVerified, scope, mode],
  );

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement;
      if (el?.tagName === 'INPUT' || el?.tagName === 'TEXTAREA' || el?.isContentEditable || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === 'j' || e.key === 'ArrowDown') {
        e.preventDefault();
        setFocus((i) => Math.min(list.length - 1, i + 1));
      } else if (e.key === 'k' || e.key === 'ArrowUp') {
        e.preventDefault();
        setFocus((i) => Math.max(0, i - 1));
      } else if (/^[1-5]$/.test(e.key) && cur) {
        const n = Number(e.key) - 1;
        if (cur.moods.length) {
          const slug = cur.moods[n]?.slug;
          if (slug) toggleWrong(cur.jellyfinId, slug);
        } else {
          const slug = cur.candidates[n]?.slug;
          if (slug) toggleAdd(cur.jellyfinId, slug, MAX_TAGS);
        }
      } else if (e.key === 'Enter' && cur) {
        e.preventDefault();
        void save(cur);
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [list.length, cur, save]);
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (focus > 0) listRef.current?.querySelector<HTMLElement>(`[data-i="${focus}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [focus]);
  useEffect(() => {
    setFocus((f) => Math.max(0, Math.min(f, list.length - 1)));
  }, [list.length]);

  const precision = tally && tally.judged > 0 ? tally.right / tally.judged : null;
  const count = (sc: VerifyScope, md: VerifyMode) => counts[`${sc}.${md}`];
  const sub =
    films === null ? (
      'Loading…'
    ) : list.length ? (
      mode === 'tagged' ? (
        <>
          {list.length} random {scope === 'watched' ? 'films you have seen' : 'films'}, every mood with its evidence. Tap a mood that is wrong, add one AI considered if it fits, then Save; Looks right keeps them all.
          {remaining > 0 && <span className="text-faint"> {remaining} more after these.</span>}
        </>
      ) : (
        <>
          {list.length} {scope === 'watched' ? 'films you have seen' : 'films'} with no mood yet. Pick from what AI considered, or any other mood, or say nothing fits.
          {remaining > 0 && <span className="text-faint"> {remaining} more after these.</span>}
        </>
      )
    ) : remaining > 0 ? (
      'All judged here. Press New 30 for the next batch.'
    ) : (
      'Nothing left in this set.'
    );

  return (
    <div className="mx-auto w-full max-w-[1080px] px-4 pb-28 pt-6 sm:px-8 sm:pt-10">
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
        <div className="min-w-0 max-w-[760px]">
          <h1 className="rise text-[30px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">Spot check</h1>
          <p className="mt-3 text-[15px] leading-[1.55] text-mute">{sub}</p>
        </div>
        <div className="flex shrink-0 items-center gap-3">
          {tally && tally.judged > 0 && (
            <span className="text-[13px] tabular-nums text-mute">
              <b className="font-semibold text-ink">{pct(precision)} right</b> over {tally.judged} mood{tally.judged === 1 ? '' : 's'} on {tally.films} film{tally.films === 1 ? '' : 's'}
            </span>
          )}
          <Button variant="outline" size="sm" disabled={busy || films === null} onClick={() => setSeed(String(Date.now()))} title="Another random batch">
            <RotateCw size={14} /> New 30
          </Button>
        </div>
      </div>

      <div className="mt-7 flex flex-wrap items-center gap-3">
        <Segmented<VerifyScope>
          value={scope}
          onChange={setScope}
          label="Films"
          options={[
            { value: 'watched', label: 'Watched', count: count('watched', mode) },
            { value: 'all', label: 'All', count: count('all', mode) },
          ]}
        />
        <Segmented<VerifyMode>
          value={mode}
          onChange={setMode}
          label="Mode"
          options={[
            { value: 'tagged', label: 'With moods', count: count(scope, 'tagged') },
            { value: 'untagged', label: 'No mood yet', count: count(scope, 'untagged') },
          ]}
        />
      </div>

      <div className="mt-6 space-y-6">
        {films && list.length > 0 && (
          <p className="hidden items-center gap-3 text-[12px] text-faint md:flex">
            {[['j', 'k', 'move'], ['1', '5', mode === 'tagged' ? 'mark a mood wrong' : 'pick a mood'], ['Enter', 'save']].map((g) => (
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
        {films && list.length === 0 && (
          <Card>
            <Empty
              icon={<Check size={20} />}
              title={remaining > 0 ? 'Batch done' : 'Nothing left here'}
              sub={remaining > 0 ? `${remaining} films in this set are still unjudged.` : mode === 'tagged' ? 'Every film in this set has your verdict. Try the other set, or All films.' : 'Every film here has a mood or a verdict.'}
              action={remaining > 0 ? <Button variant="primary" onClick={() => setSeed(String(Date.now()))}>New 30</Button> : undefined}
            />
          </Card>
        )}
        <div ref={listRef} className="space-y-3">
          {list.map((film, i) => (
            <CheckCard
              key={film.jellyfinId}
              i={i}
              film={film}
              moods={moods}
              covers={covers}
              movie={movieLookup(film.jellyfinId)}
              marks={marksOf(film.jellyfinId)}
              focused={i === focus}
              leaving={leaving.has(film.jellyfinId)}
              busy={busy}
              onFocus={() => setFocus(i)}
              onWrong={(slug) => toggleWrong(film.jellyfinId, slug)}
              onAdd={(slug) => toggleAdd(film.jellyfinId, slug, MAX_TAGS - (film.moods.length - marksOf(film.jellyfinId).wrong.length))}
              onSave={() => void save(film)}
              onOpen={() => {
                const m = movieLookup(film.jellyfinId);
                if (m) onOpenMovie(m);
              }}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

interface CheckCardProps {
  i: number;
  film: VerifyFilm;
  moods: MoodBuckets;
  covers?: Record<string, string | undefined>;
  movie?: Movie;
  marks: Marks;
  focused: boolean;
  leaving: boolean;
  busy: boolean;
  onFocus: () => void;
  onWrong: (slug: string) => void;
  onAdd: (slug: string) => void;
  onSave: () => void;
  onOpen: () => void;
}

// One film: poster, AI's one-line read, every applied mood as a pill with its evidence, then what
// AI considered as outline pills to add, and Other mood for anything else.
function CheckCard({ i, film, moods, covers, movie, marks, focused, leaving, busy, onFocus, onWrong, onAdd, onSave, onOpen }: CheckCardProps) {
  const [pick, setPick] = useState(false);
  const kept = film.moods.length - marks.wrong.length;
  const untagged = film.moods.length === 0;
  const extra = marks.add.filter((slug) => !film.candidates.some((c) => c.slug === slug));
  const title = (slug: string) => moods[slug]?.title || slug;
  const full = kept + marks.add.length >= MAX_TAGS;
  const label = untagged
    ? marks.add.length
      ? `Save ${marks.add.length} mood${marks.add.length === 1 ? '' : 's'}`
      : 'Nothing fits'
    : marks.wrong.length || marks.add.length
      ? `Save: keep ${kept}${marks.add.length ? `, add ${marks.add.length}` : ''}${marks.wrong.length ? `, drop ${marks.wrong.length}` : ''}`
      : 'Looks right';
  return (
    <div
      data-i={i}
      onPointerDown={onFocus}
      className={cn(
        'rounded-[24px] bg-white p-4 transition-shadow duration-200 sm:p-6',
        focused ? 'shadow-[0_0_0_1.5px_#111,0_16px_40px_-18px_rgba(0,0,0,.28)]' : 'shadow-[0_0_0_1px_rgba(0,0,0,.055),0_1px_2px_rgba(0,0,0,.03)]',
        leaving && 'row-out',
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
            {film.year && <span className="shrink-0 tabular-nums text-faint">{film.year}</span>}
            {(movie?.played ?? film.played) && <span className="shrink-0 text-faint">· Watched</span>}
          </div>
          {film.residue && <p className="mt-1 line-clamp-2 text-[13.5px] leading-[1.45] text-[#3a3a3a]">{film.residue}</p>}
          {film.moods.length > 0 && (
            <ul className="mt-3 space-y-2">
              {film.moods.map((m, n) => {
                const off = marks.wrong.includes(m.slug);
                return (
                  <li key={m.slug} className="flex items-start gap-3">
                    <button
                      type="button"
                      onClick={() => onWrong(m.slug)}
                      aria-pressed={off}
                      title={off ? 'Marked wrong. Tap to keep it.' : 'Tap if this mood is wrong'}
                      className={cn(
                        'inline-flex h-8 shrink-0 items-center gap-1.5 rounded-full px-3 text-[13px] font-medium transition cursor-pointer',
                        off ? 'text-mute line-through decoration-[#c4320a]/70 ring-1 ring-inset ring-[#f0d6cc] bg-[#fff6f2]' : 'bg-ink text-white hover:bg-black',
                      )}
                    >
                      <kbd className={cn('text-[10px]', off ? 'opacity-60' : 'opacity-50')}>{n + 1}</kbd>
                      {m.title}
                      {m.probability != null && <span className={cn('tabular-nums', off ? 'text-faint' : 'text-white/55')}>{Math.round(m.probability * 100)}%</span>}
                    </button>
                    <span className={cn('min-w-0 pt-1.5 text-[12.5px] leading-[1.45]', off ? 'text-faint line-through' : 'text-mute')}>{m.evidence ?? 'no evidence line'}</span>
                  </li>
                );
              })}
            </ul>
          )}
          {(film.candidates.length > 0 || untagged) && (
            <div className="mt-3">
              <div className="mb-1.5 text-[12px] font-semibold text-mute">{untagged ? (film.candidates.length ? 'AI considered' : 'AI named nothing for this film') : 'AI also considered'}</div>
              <ul className="space-y-1.5">
                {film.candidates.map((c, n) => {
                  const on = marks.add.includes(c.slug);
                  return (
                    <li key={c.slug} className="flex items-start gap-3">
                      <button
                        type="button"
                        onClick={() => onAdd(c.slug)}
                        aria-pressed={on}
                        disabled={!on && full}
                        title={on ? 'Added. Tap to take it back.' : 'Tap to add this mood'}
                        className={cn(
                          'inline-flex h-8 shrink-0 items-center gap-1 rounded-full px-3 text-[13px] font-medium transition cursor-pointer disabled:opacity-40',
                          on ? 'bg-ink text-white hover:bg-black' : 'text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7]',
                        )}
                      >
                        {untagged && <kbd className={cn('text-[10px]', on ? 'opacity-70' : 'opacity-50')}>{n + 1}</kbd>}
                        {!on && <Plus size={13} strokeWidth={2.4} className="-ml-0.5 text-faint" />}
                        {c.title}
                        {c.probability != null && <span className={cn('tabular-nums', on ? 'text-white/55' : 'text-faint')}>{Math.round(c.probability * 100)}%</span>}
                      </button>
                      <span className="min-w-0 pt-1.5 text-[12.5px] leading-[1.45] text-faint">{c.evidence ?? ''}</span>
                    </li>
                  );
                })}
              </ul>
            </div>
          )}
          <div className="mt-2.5 flex flex-wrap items-center gap-1.5">
            {extra.map((slug) => (
              <button key={slug} type="button" onClick={() => onAdd(slug)} aria-pressed className="inline-flex h-8 items-center gap-1.5 rounded-full bg-ink px-3 text-[13px] font-medium text-white hover:bg-black cursor-pointer">
                {title(slug)}
              </button>
            ))}
            <div className="relative">
              <button
                type="button"
                onClick={() => setPick((v) => !v)}
                disabled={full}
                className="inline-flex h-8 items-center gap-1 rounded-full px-3 text-[13px] font-medium text-ink ring-1 ring-inset ring-[#e6e6e6] hover:bg-[#f7f7f7] disabled:opacity-40 cursor-pointer"
              >
                Other mood… <ChevronDown size={13} />
              </button>
              {pick && (
                <MoodPicker
                  moods={moods}
                  exclude={[...film.moods.map((m) => m.slug), ...marks.add]}
                  covers={covers}
                  onPick={(slug) => {
                    setPick(false);
                    onAdd(slug);
                  }}
                  onClose={() => setPick(false)}
                />
              )}
            </div>
          </div>
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-[#f2f2f2] pt-4">
        <Button size="sm" variant={untagged && !marks.add.length ? 'outline' : 'primary'} disabled={busy} onClick={onSave}>
          {!untagged && !marks.wrong.length && !marks.add.length ? <><Check size={13} strokeWidth={3} /> Looks right</> : label}
        </Button>
        <span className="text-[12.5px] text-mute">
          {untagged
            ? marks.add.length
              ? 'They become your own tags.'
              : 'Nothing fits records that what AI considered was wrong.'
            : marks.wrong.length === film.moods.length && film.moods.length > 0 && !marks.add.length
              ? 'Every mood comes off this film.'
              : marks.wrong.length || marks.add.length
                ? 'The kept and added moods become your own tags.'
                : ''}
        </span>
      </div>
    </div>
  );
}
