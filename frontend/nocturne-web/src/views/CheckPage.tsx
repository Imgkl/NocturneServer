import { useCallback, useEffect, useRef, useState } from 'react';
import { Check, RotateCw } from 'lucide-react';
import { api, posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import { pct } from '../lib/policy';
import { Button } from '../ui/Button';
import { Card } from '../ui/Card';
import { Empty } from '../ui/Empty';
import type { Movie, VerifyFilm, VerifyTally } from '../lib/types';

const SAMPLE = 30;

interface CheckPageProps {
  movieLookup: (jellyfinId: string) => Movie | undefined;
  onOpenMovie: (movie: Movie) => void;
  say: (text: string, tone?: 'ok' | 'error') => void;
  // A verdict landed: the caller refreshes the films and the Teach count.
  onVerified: () => void;
}

// The spot check: thirty random tagged films, each mood with its evidence. Tap a mood that is
// wrong, then Save; Looks right keeps them all. Every verdict becomes the owner's labels, which
// the Accuracy page and Teach read as ground truth. Keys: j k move, 1 to 5 toggle a mood, Enter saves.
export function CheckPage({ movieLookup, onOpenMovie, say, onVerified }: CheckPageProps) {
  const [films, setFilms] = useState<VerifyFilm[] | null>(null);
  const [remaining, setRemaining] = useState(0);
  const [tally, setTally] = useState<VerifyTally | null>(null);
  const [wrong, setWrong] = useState<Record<string, string[]>>({});
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState(0);
  const [busy, setBusy] = useState(false);
  const [seed, setSeed] = useState<string | undefined>(undefined);

  const load = useCallback(
    async (s?: string) => {
      try {
        const r = await api.verify.sample(SAMPLE, s);
        setFilms(r.films);
        setRemaining(r.remaining);
        setTally(r.tally);
        setWrong({});
        setFocus(0);
      } catch (e) {
        say(e instanceof Error ? e.message : 'Failed to load the sample', 'error');
      }
    },
    [say],
  );
  useEffect(() => {
    void load(seed);
  }, [load, seed]);

  const list = films ?? [];
  const cur = list[Math.min(focus, list.length - 1)];
  const toggle = (jellyfinId: string, slug: string) =>
    setWrong((w) => {
      const now = w[jellyfinId] ?? [];
      return { ...w, [jellyfinId]: now.includes(slug) ? now.filter((x) => x !== slug) : [...now, slug] };
    });

  const save = useCallback(
    async (film: VerifyFilm) => {
      if (busy) return;
      setBusy(true);
      try {
        const r = await api.verify.save(film.jellyfinId, wrong[film.jellyfinId] ?? []);
        setTally(r.tally);
        say(r.wrong.length ? `Kept ${r.kept.length}, dropped ${r.wrong.length}` : 'Looks right');
        setLeaving((l) => new Set(l).add(film.jellyfinId));
        window.setTimeout(() => {
          setLeaving((l) => {
            const n = new Set(l);
            n.delete(film.jellyfinId);
            return n;
          });
          setFilms((fs) => (fs ?? []).filter((f) => f.jellyfinId !== film.jellyfinId));
        }, 240);
        onVerified();
      } catch (e) {
        say(e instanceof Error ? e.message : 'Failed to save the verdict', 'error');
      } finally {
        setBusy(false);
      }
    },
    [busy, wrong, say, onVerified],
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
        const slug = cur.moods[Number(e.key) - 1]?.slug;
        if (slug) toggle(cur.jellyfinId, slug);
      } else if (e.key === 'Enter' && cur) {
        e.preventDefault();
        void save(cur);
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [list.length, cur, save]);
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (focus > 0) listRef.current?.querySelector<HTMLElement>(`[data-i="${focus}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [focus]);
  useEffect(() => {
    setFocus((f) => Math.max(0, Math.min(f, list.length - 1)));
  }, [list.length]);

  const precision = tally && tally.judged > 0 ? tally.right / tally.judged : null;
  const sub =
    films === null ? (
      'Loading…'
    ) : list.length ? (
      <>
        {list.length} random tagged films, every mood with its evidence. Tap a mood that is wrong, then Save; Looks right keeps them all. Each verdict becomes your label.
        {remaining > 0 && <span className="text-faint"> {remaining} more after these.</span>}
      </>
    ) : remaining > 0 ? (
      'All checked here. Press New 30 for the next batch.'
    ) : (
      'Every tagged film has a verdict.'
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

      <div className="mt-9 space-y-6 sm:mt-10">
        {films && list.length > 0 && (
          <p className="hidden items-center gap-3 text-[12px] text-faint md:flex">
            {[['j', 'k', 'move'], ['1', '5', 'mark a mood wrong'], ['Enter', 'save']].map((g) => (
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
            <Empty icon={<Check size={20} />} title={remaining > 0 ? 'Batch done' : 'Nothing left to check'} sub={remaining > 0 ? `${remaining} tagged films are still unjudged.` : 'Every film with a mood from AI has your verdict. New tags will show up here.'} action={remaining > 0 ? <Button variant="primary" onClick={() => setSeed(String(Date.now()))}>New 30</Button> : undefined} />
          </Card>
        )}
        <div ref={listRef} className="space-y-3">
          {list.map((film, i) => (
            <CheckCard
              key={film.jellyfinId}
              i={i}
              film={film}
              movie={movieLookup(film.jellyfinId)}
              wrong={wrong[film.jellyfinId] ?? []}
              focused={i === focus}
              leaving={leaving.has(film.jellyfinId)}
              busy={busy}
              onFocus={() => setFocus(i)}
              onToggle={(slug) => toggle(film.jellyfinId, slug)}
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
  movie?: Movie;
  wrong: string[];
  focused: boolean;
  leaving: boolean;
  busy: boolean;
  onFocus: () => void;
  onToggle: (slug: string) => void;
  onSave: () => void;
  onOpen: () => void;
}

// One film: poster, AI's one-line read, then every applied mood as a pill with its evidence.
function CheckCard({ i, film, movie, wrong, focused, leaving, busy, onFocus, onToggle, onSave, onOpen }: CheckCardProps) {
  const kept = film.moods.length - wrong.length;
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
          <ul className="mt-3 space-y-2">
            {film.moods.map((m, n) => {
              const off = wrong.includes(m.slug);
              return (
                <li key={m.slug} className="flex items-start gap-3">
                  <button
                    type="button"
                    onClick={() => onToggle(m.slug)}
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
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-[#f2f2f2] pt-4">
        <Button size="sm" variant="primary" disabled={busy} onClick={onSave}>
          {wrong.length === 0 ? <><Check size={13} strokeWidth={3} /> Looks right</> : `Save: keep ${kept}, drop ${wrong.length}`}
        </Button>
        {wrong.length > 0 && (
          <span className="text-[12.5px] text-mute">
            {wrong.length === film.moods.length ? 'Every mood comes off this film.' : 'The kept moods become your own tags.'}
          </span>
        )}
      </div>
    </div>
  );
}
