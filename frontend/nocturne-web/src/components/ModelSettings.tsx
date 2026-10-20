import { useEffect, useState } from 'react';
import { Button } from '../ui/Button';
import { Divider } from '../ui/Divider';
import { Toggle } from '../ui/Toggle';
import type { ModelSettings as ModelSettingsApi, ModelSettingsUpdate } from '../lib/types';

interface ModelSettingsProps {
  settings: ModelSettingsApi | null;
  onSave: (update: ModelSettingsUpdate) => Promise<void>;
}

const selectCls =
  'w-full bg-transparent border-0 border-b border-border focus:border-text outline-none text-text text-[14px] py-2 transition-colors cursor-pointer';

export function ModelSettings({ settings, onSave }: ModelSettingsProps) {
  const [reader, setReader] = useState('');
  const [strong, setStrong] = useState('');
  const [budget, setBudget] = useState('');
  const [fallback, setFallback] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!settings) return;
    setReader(settings.reader_model);
    setStrong(settings.strong_model);
    setBudget(settings.monthly_budget_usd == null ? '' : String(settings.monthly_budget_usd));
    setFallback(settings.model_fallback);
  }, [settings]);

  if (!settings) {
    return (
      <div className="border border-border p-5">
        <div className="text-[11px] uppercase tracking-widest text-muted">Models &amp; budget</div>
        <p className="text-[12px] text-muted mt-3">Loading…</p>
      </div>
    );
  }
  const current = settings;

  const budgetNumber = budget.trim() === '' ? null : Number(budget);
  const budgetValid = budgetNumber === null || (Number.isFinite(budgetNumber) && budgetNumber >= 0);
  const budgetChanged = budgetNumber !== null && budgetNumber !== (current.monthly_budget_usd ?? null);
  const dirty =
    reader !== current.reader_model ||
    strong !== current.strong_model ||
    fallback !== current.model_fallback ||
    budgetChanged;

  const cap = current.monthly_budget_usd ?? 0;
  const spent = current.budget_spent_usd;
  const spentPct = cap > 0 ? Math.min(100, (spent / cap) * 100) : 0;
  const overCap = cap > 0 && spent >= cap;

  async function save() {
    const update: ModelSettingsUpdate = {};
    if (reader !== current.reader_model) update.reader_model = reader;
    if (strong !== current.strong_model) update.strong_model = strong;
    if (fallback !== current.model_fallback) update.model_fallback = fallback;
    if (budgetChanged && budgetNumber !== null) update.monthly_budget_usd = budgetNumber;
    setSaving(true);
    setError(null);
    try {
      await onSave(update);
      setSaved(true);
      window.setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to save');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="border border-border p-5 space-y-5">
      <div className="text-[11px] uppercase tracking-widest text-muted">Models &amp; budget</div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-5">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="reader-model" className="text-[10px] uppercase tracking-widest text-muted">
            Reader model
          </label>
          <select id="reader-model" className={selectCls} value={reader} onChange={(e) => setReader(e.target.value)}>
            {withCurrent(current.reader_models, reader).map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
          <p className="text-[12px] text-text-dim leading-snug">
            Reads the story block and proposes moods. About $0.001 per film with the cached prefix.
          </p>
        </div>
        <div className="flex flex-col gap-1.5">
          <label htmlFor="strong-model" className="text-[10px] uppercase tracking-widest text-muted">
            Strong model
          </label>
          <select id="strong-model" className={selectCls} value={strong} onChange={(e) => setStrong(e.target.value)}>
            {withCurrent(current.strong_models, strong).map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
          <p className="text-[12px] text-text-dim leading-snug">
            Writes a spoiler synopsis with web search when no plot exists anywhere. About $0.05 to $0.10 per film.
          </p>
        </div>
      </div>

      <Divider />

      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0 flex-1">
          <div className="text-[14px] text-text">Write synopses automatically</div>
          <p className="text-[12px] text-text-dim mt-1 leading-snug">
            During coverage runs, films with no plot anywhere get a strong-model synopsis. It is marked unverified and
            its moods always go to review.
          </p>
        </div>
        <Toggle active={fallback} onChange={setFallback} label="Write synopses automatically" />
      </div>

      <Divider />

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-5 sm:items-end">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="monthly-budget" className="text-[10px] uppercase tracking-widest text-muted">
            Monthly budget
          </label>
          <div className="flex items-baseline gap-1.5">
            <span className="text-[14px] text-muted">$</span>
            <input
              id="monthly-budget"
              type="number"
              min="0"
              step="1"
              inputMode="decimal"
              value={budget}
              onChange={(e) => setBudget(e.target.value)}
              className="w-28 bg-transparent border-0 border-b border-border focus:border-text outline-none text-text text-[14px] py-2 tabular-nums transition-colors"
            />
          </div>
        </div>
        <div className="flex flex-col gap-2">
          <div className="h-[2px] bg-border overflow-hidden">
            <div className="h-full bg-text transition-all" style={{ width: `${spentPct}%` }} />
          </div>
          <p className="text-[12px] text-text-dim leading-snug">
            ${spent.toFixed(2)} spent this month{overCap ? ' · at the cap' : ''}. Scheduled and real-time tagging
            pause at the cap; manual runs warn and continue.
          </p>
        </div>
      </div>

      <div className="flex items-center justify-end gap-3">
        {error && <span className="text-[11px] text-danger">{error}</span>}
        {saved && !error && <span className="text-[10px] uppercase tracking-widest text-muted">Saved</span>}
        {!budgetValid && <span className="text-[11px] text-danger">Budget must be zero or more.</span>}
        <Button variant="primary" size="sm" onClick={save} disabled={!dirty || !budgetValid || saving}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </div>
  );
}

// Keep a value the admin set by hand (or an older default) selectable even when it is not in
// the server's list.
function withCurrent(list: string[], current: string): string[] {
  return current && !list.includes(current) ? [current, ...list] : list;
}
