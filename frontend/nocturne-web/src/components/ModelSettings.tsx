import { useEffect, useState } from 'react';
import { Button } from '../ui/Button';
import { Field, inputCls } from '../ui/Input';
import { Select } from '../ui/Select';
import { Bar, Stat } from '../ui/Stat';
import { Toggle } from '../ui/Toggle';
import { GRADER_LABEL, POLICY_HINT, POLICY_LABEL } from '../lib/policy';
import type { ClassifierProvider, ModelSettings as ModelSettingsApi, ModelSettingsUpdate, PolicyVersion } from '../lib/types';

interface ModelSettingsProps {
  settings: ModelSettingsApi | null;
  onSave: (update: ModelSettingsUpdate) => Promise<void>;
}

// AI and strong model, the grader and the policy, the synopsis fallback, the monthly cap with the month's spend.
export function ModelSettings({ settings, onSave }: ModelSettingsProps) {
  const [reader, setReader] = useState('');
  const [strong, setStrong] = useState('');
  const [provider, setProvider] = useState<ClassifierProvider>('none');
  const [policy, setPolicy] = useState<PolicyVersion>('p1');
  const [jevModel, setJevModel] = useState('');
  const [budget, setBudget] = useState('');
  const [fallback, setFallback] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!settings) return;
    setReader(settings.reader_model);
    setStrong(settings.strong_model);
    setProvider(settings.classifier_provider);
    setPolicy(settings.policy_version);
    setJevModel(settings.classifier_model);
    setBudget(settings.monthly_budget_usd == null ? '' : String(settings.monthly_budget_usd));
    setFallback(settings.model_fallback);
  }, [settings]);

  if (!settings) return <p className="text-[13px] text-mute">Loading…</p>;
  const current = settings;

  const budgetNumber = budget.trim() === '' ? null : Number(budget);
  const budgetValid = budgetNumber === null || (Number.isFinite(budgetNumber) && budgetNumber >= 0);
  const budgetChanged = budgetNumber !== null && budgetNumber !== (current.monthly_budget_usd ?? null);
  const jevModelChanged = jevModel.trim() !== '' && jevModel.trim() !== current.classifier_model;
  const dirty =
    reader !== current.reader_model || strong !== current.strong_model || provider !== current.classifier_provider || policy !== current.policy_version || jevModelChanged || fallback !== current.model_fallback || budgetChanged;
  const cap = current.monthly_budget_usd ?? 0;
  const spent = current.budget_spent_usd;

  async function save() {
    const update: ModelSettingsUpdate = {};
    if (reader !== current.reader_model) update.reader_model = reader;
    if (strong !== current.strong_model) update.strong_model = strong;
    if (provider !== current.classifier_provider) update.classifier_provider = provider;
    if (policy !== current.policy_version) update.policy_version = policy;
    if (jevModelChanged) update.classifier_model = jevModel.trim();
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

  const withCurrent = (list: string[], v: string) => (v && !list.includes(v) ? [v, ...list] : list);

  return (
    <div className="space-y-5">
      <div className="grid grid-cols-1 gap-5 sm:grid-cols-2">
        <Field label="AI model" hint="Reads the story and lists every mood that fits. With the cached prefix: Haiku about $0.001 per film, Sonnet about $0.015.">
          <Select value={reader} onChange={setReader} label="AI model" block options={withCurrent(current.reader_models, reader).map((m) => [m, m])} />
        </Field>
        <Field label="Strong model" hint="Writes a spoiler synopsis with web search when no plot exists anywhere. About $0.05 to $0.10 per film.">
          <Select value={strong} onChange={setStrong} label="Strong model" block options={withCurrent(current.strong_models, strong).map((m) => [m, m])} />
        </Field>
      </div>

      <div className="grid grid-cols-1 gap-5 border-t border-line pt-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_150px]">
        <Field label="Grader" hint={provider === 'jev' ? (current.jev_key_set ? 'Jev grades every mood AI proposes, one question per mood. About $0.001 per film.' : 'Add the TypeSafe key under Connections, or the tagger falls back to AI alone.') : 'Nobody grades. AI\'s own confidence against the floors decides.'}>
          <Select<ClassifierProvider> value={provider} onChange={setProvider} label="Grader" block options={current.classifier_providers.map((p) => [p, GRADER_LABEL[p] ?? p])} />
        </Field>
        <Field label="Policy" hint={POLICY_HINT[policy] ?? ''}>
          <Select<PolicyVersion> value={policy} onChange={setPolicy} label="Policy" block options={current.policy_versions.map((v) => [v, `${POLICY_LABEL[v] ?? v} (${v})`])} />
        </Field>
        <Field label="Jev model" hint="TypeSafe model id.">
          <input id="jev-model" type="text" value={jevModel} onChange={(e) => setJevModel(e.target.value)} placeholder={current.classifier_model} spellCheck={false} className={inputCls} />
        </Field>
      </div>
      {provider === 'jev' && !current.jev_key_set && <p className="text-[12.5px] text-bad">The TypeSafe key is missing: films would be tagged by AI alone and marked unsure. Add it under Connections.</p>}

      <div className="flex items-start justify-between gap-4 border-t border-line pt-4">
        <div className="min-w-0">
          <div className="text-[14px] font-semibold text-ink">Write synopses automatically</div>
          <p className="mt-1 text-[13px] leading-snug text-mute">During coverage runs, films with no plot anywhere get a strong-model synopsis. It is marked unverified and its moods always go to review.</p>
        </div>
        <Toggle active={fallback} onChange={setFallback} label="Write synopses automatically" />
      </div>

      <div className="grid grid-cols-1 gap-5 border-t border-line pt-4 sm:grid-cols-[180px_minmax(0,1fr)] sm:items-end">
        <Field label="Monthly budget">
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[13.5px] text-faint">$</span>
            <input id="monthly-budget" type="number" min="0" step="1" inputMode="decimal" value={budget} onChange={(e) => setBudget(e.target.value)} className={`${inputCls} pl-6 tabular-nums`} />
          </div>
        </Field>
        <div>
          <Stat label="Spent this month" value={`$${spent.toFixed(2)}`} sub={cap > 0 ? `of $${cap}. Scheduled and real-time tagging pause at the cap; manual runs warn and continue.` : 'No cap set.'} tone={cap > 0 && spent >= cap ? 'bad' : undefined} />
          <Bar value={cap > 0 ? spent / cap : 0} className="mt-3" />
        </div>
      </div>

      <div className="flex items-center justify-end gap-3">
        {error && <span className="text-[12.5px] text-bad">{error}</span>}
        {saved && !error && <span className="text-[12.5px] font-medium text-good">Saved</span>}
        {!budgetValid && <span className="text-[12.5px] text-bad">Budget must be zero or more.</span>}
        <Button variant="primary" onClick={() => void save()} disabled={!dirty || !budgetValid || saving}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </div>
  );
}
