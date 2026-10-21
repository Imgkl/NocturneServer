import { useEffect, useMemo, useState } from 'react';
import { cn } from '../lib/cn';
import { Button } from '../ui/Button';
import type { MoodBuckets } from '../lib/types';

export const th = 'py-2.5 text-[11.5px] font-semibold uppercase tracking-[.06em] text-faint';
export const td = 'py-3 border-t border-[#f1f1f1]';

interface FloorsTableProps {
  moods: MoodBuckets;
  floors: Record<string, number>;
  high: Record<string, number>;
  onSave: (floors: Record<string, number>, high: Record<string, number>) => Promise<void>;
  // Re-apply the policy across the library from the stored answers (free, no grader call).
  onReplay: () => Promise<void>;
  replayDisabledReason?: string | null;
}

const cell = 'h-8 w-[76px] rounded-lg bg-canvas px-2 text-right text-[13px] tabular-nums text-ink outline-none ring-1 ring-inset ring-transparent transition focus:bg-white focus:ring-line-2';

// One row per mood: the grader probability it has to clear (floor), and the line above which a
// mood AI never named still becomes a suggestion (high). The Accuracy page suggests floors.
export function FloorsTable({ moods, floors, high, onSave, onReplay, replayDisabledReason }: FloorsTableProps) {
  const [f, setF] = useState<Record<string, string>>({});
  const [h, setH] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Floors were saved and not yet applied to the library.
  const [unapplied, setUnapplied] = useState(false);
  const reset = () => {
    setF(Object.fromEntries(Object.entries(floors).map(([k, v]) => [k, String(v)])));
    setH(Object.fromEntries(Object.entries(high).map(([k, v]) => [k, String(v)])));
  };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(reset, [floors, high]);

  const rows = useMemo(() => Object.keys(floors).sort((a, b) => (moods[a]?.title ?? a).localeCompare(moods[b]?.title ?? b)), [floors, moods]);
  const parse = (v: string) => {
    const n = Number(v);
    return v.trim() !== '' && Number.isFinite(n) && n >= 0 && n <= 1 ? n : null;
  };
  const changedFloors: Record<string, number> = {};
  const changedHigh: Record<string, number> = {};
  let invalid = false;
  for (const slug of rows) {
    const nf = parse(f[slug] ?? '');
    const nh = parse(h[slug] ?? '');
    if (nf === null || nh === null) invalid = true;
    else {
      if (nf !== floors[slug]) changedFloors[slug] = nf;
      if (nh !== high[slug]) changedHigh[slug] = nh;
    }
  }
  const dirty = Object.keys(changedFloors).length + Object.keys(changedHigh).length > 0;

  async function save() {
    setSaving(true);
    setError(null);
    try {
      // The route replaces each table it receives, so send the whole table when any row changed.
      await onSave(
        Object.keys(changedFloors).length ? Object.fromEntries(rows.map((s) => [s, changedFloors[s] ?? floors[s]])) : floors,
        Object.keys(changedHigh).length ? Object.fromEntries(rows.map((s) => [s, changedHigh[s] ?? high[s]])) : high,
      );
      setUnapplied(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to save');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div>
      <p className="text-[12.5px] text-faint">Floor: the grader probability a mood AI named has to reach to be applied. High: above this, a mood AI never named still goes to review as a suggestion. Values from 0 to 1; the Accuracy page suggests floors from your own decisions.</p>
      <div className="mt-3 max-h-[420px] overflow-y-auto">
        <table className="w-full text-[13.5px]">
          <thead className="sticky top-0 bg-white">
            <tr>
              <th className={cn(th, 'text-left')}>Mood</th>
              <th className={cn(th, 'w-[96px] text-right')}>Floor</th>
              <th className={cn(th, 'w-[96px] text-right')}>High</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((slug) => (
              <tr key={slug}>
                <td className={cn(td, 'pr-3 text-ink')}>{moods[slug]?.title ?? slug}</td>
                <td className={cn(td, 'text-right')}>
                  <input type="number" min="0" max="1" step="0.05" inputMode="decimal" aria-label={`${moods[slug]?.title ?? slug} floor`} value={f[slug] ?? ''} onChange={(e) => setF((x) => ({ ...x, [slug]: e.target.value }))} className={cn(cell, parse(f[slug] ?? '') === null && 'ring-[#f0d6cc] bg-[#fff6f2]')} />
                </td>
                <td className={cn(td, 'text-right')}>
                  <input type="number" min="0" max="1" step="0.05" inputMode="decimal" aria-label={`${moods[slug]?.title ?? slug} high`} value={h[slug] ?? ''} onChange={(e) => setH((x) => ({ ...x, [slug]: e.target.value }))} className={cn(cell, parse(h[slug] ?? '') === null && 'ring-[#f0d6cc] bg-[#fff6f2]')} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-end gap-3">
        {error && <span className="text-[12.5px] text-bad">{error}</span>}
        {invalid && <span className="text-[12.5px] text-bad">Every value must be between 0 and 1.</span>}
        {unapplied && !dirty && (
          <Button
            variant="outline"
            size="sm"
            disabled={!!replayDisabledReason}
            reason={replayDisabledReason ?? null}
            reasonInline={false}
            onClick={async () => {
              await onReplay();
              setUnapplied(false);
            }}
          >
            Apply to the library (free)
          </Button>
        )}
        {dirty && (
          <Button variant="ghost" size="sm" onClick={reset}>
            Reset
          </Button>
        )}
        <Button variant="primary" size="sm" onClick={() => void save()} disabled={!dirty || invalid || saving}>
          {saving ? 'Saving…' : 'Save floors'}
        </Button>
      </div>
    </div>
  );
}
