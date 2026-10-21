import { useEffect, useState } from 'react';
import { ArrowRight, Check, FolderTree, Gauge, ListChecks, SlidersHorizontal } from 'lucide-react';
import type { ReactNode } from 'react';
import { api } from '../lib/api';
import { cn } from '../lib/cn';
import { POLICY_ORDER, pct, policyLabel } from '../lib/policy';
import { timeAgo } from '../lib/enrichment';
import { Button } from '../ui/Button';
import { Card } from '../ui/Card';
import { Empty } from '../ui/Empty';
import { Stat } from '../ui/Stat';
import { td, th } from '../components/FloorsTable';
import type { EvalMoodReport, EvalOverall, EvalReport } from '../lib/types';

interface EvalPageProps {
  say: (text: string, tone?: 'ok' | 'error') => void;
  // Films waiting on the Teach page and rules learned so far, for the next steps.
  teachWaiting: number;
  learnedRules: number;
  // The floors changed: the caller refetches the model settings.
  onFloorsAccepted: () => Promise<void>;
}

// X-Cache's accuracy page, for moods: the owner's own decisions replayed through the policy with
// no AI call, the policies side by side, and a floor per mood that keeps the applied moods right.
export function EvalPage({ say, teachWaiting, learnedRules, onFloorsAccepted }: EvalPageProps) {
  const [report, setReport] = useState<EvalReport | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api.eval
      .latest()
      .then(setReport)
      .catch((e: unknown) => {
        setReport(null);
        say(e instanceof Error ? e.message : 'Failed to load the report', 'error');
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function run() {
    setBusy(true);
    try {
      const r = await api.eval.run();
      setReport(r);
      say(r.films === 0 ? 'No decisions to replay yet' : `Replayed ${r.films} films`);
    } catch (e) {
      say(e instanceof Error ? e.message : 'The eval failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  const r = report;
  const changes = r ? r.moods.filter((m) => m.suggestedFloor != null && m.suggestedFloor !== m.currentFloor) : [];
  const applied = !!r && changes.length === 0 && r.moods.some((m) => m.suggestedFloor != null);

  async function accept() {
    setBusy(true);
    try {
      await api.eval.acceptFloors();
      await onFloorsAccepted();
      setReport(await api.eval.run());
      say(`${changes.length} floor${changes.length === 1 ? '' : 's'} updated`);
    } catch (e) {
      say(e instanceof Error ? e.message : 'Failed to apply the floors', 'error');
    } finally {
      setBusy(false);
    }
  }

  const sub =
    r === undefined ? 'Loading…' : r === null ? (
      'No report yet. The eval replays your decisions through the policy, with no AI call.'
    ) : (
      <>
        {r.films} film{r.films === 1 ? '' : 's'} you judged, replayed through policy {r.policyVersion}: <b className="font-semibold text-ink">{r.positives} confirmed moods</b> and <b className="font-semibold text-ink">{r.negatives} rejected</b>.{' '}
        <span className="text-faint">{timeAgo(r.generatedAt) ?? r.generatedAt}</span>
      </>
    );

  return (
    <div className="mx-auto w-full max-w-[1080px] px-4 pb-28 pt-6 sm:px-8 sm:pt-10">
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
        <div className="min-w-0 max-w-[760px]">
          <h1 className="rise text-[30px] font-semibold leading-[1.04] tracking-[-0.038em] text-ink sm:text-[40px]">Accuracy</h1>
          <p className="mt-3 text-[15px] leading-[1.55] text-mute">{sub}</p>
        </div>
        {r !== undefined && (
          <Button variant={r ? 'outline' : 'primary'} onClick={() => void run()} disabled={busy}>
            {busy ? 'Replaying…' : r ? 'Run again' : 'Run the eval'}
          </Button>
        )}
      </div>

      <div className="mt-9 space-y-6 sm:mt-10">
        {r === null && (
          <Card>
            <Empty
              icon={<Gauge size={20} />}
              title="No accuracy report yet"
              sub="Approve and reject a few films in Review first. The eval then replays those decisions through the policy and shows, mood by mood, which floor keeps the applied moods right. It costs nothing."
              action={
                <Button variant="primary" onClick={() => void run()} disabled={busy}>
                  Run the eval
                </Button>
              }
            />
          </Card>
        )}

        {r && (
          <>
            <Card title="Your decisions, replayed" sub="Only moods you judged count: a mood you never approved or rejected on a film cannot be right or wrong.">
              <div className="grid grid-cols-2 gap-x-6 gap-y-7 lg:grid-cols-4 lg:divide-x lg:divide-[#f0f0f0] [&>*]:lg:pl-7 [&>*:first-child]:lg:pl-0">
                <Stat label="Moods applied" value={r.overall.applied} sub={`${r.overall.correct} right, ${r.overall.wrong} wrong`} />
                <Stat label="Right" value={pct(r.overall.precision)} tone={r.overall.precision != null && r.overall.precision >= r.targetPrecision ? 'good' : undefined} sub={`Wilson 95% low ${pct(r.overall.wilsonLower)} · target ${pct(r.targetPrecision)}`} />
                <Stat label="Films with a mood" value={r.overall.filmsWithApplied} sub={`of ${r.overall.films} you judged`} />
                <Stat label="Floors to change" value={changes.length} tone={changes.length === 0 ? 'good' : undefined} sub={changes.length ? 'suggested from your decisions' : 'every suggested floor is in use'} />
              </div>
              <div className="mt-6 flex flex-wrap items-baseline gap-x-6 gap-y-1 border-t border-[#f2f2f2] pt-4 text-[13px] text-mute">
                <span>
                  <b className="font-semibold text-ink">With the suggested floors:</b> {r.overallAtSuggested.applied} applied, {pct(r.overallAtSuggested.precision)} right, {r.overallAtSuggested.filmsWithApplied} films with a mood.
                </span>
              </div>
            </Card>

            <Card flush title="Next steps" sub="Each one teaches AI more of your taste. Run the eval again after.">
              <ol className="border-t border-[#f0f0f0]">
                <Step n={1} icon={<ListChecks size={16} />} href="#teach" title={teachWaiting ? `Teach: ${teachWaiting} film${teachWaiting === 1 ? '' : 's'} waiting` : 'Teach: nothing waiting'} sub={teachWaiting ? 'Pick between the two moods in question, one tap each.' : 'Films where you and AI disagree land there as you review.'} done={teachWaiting === 0} />
                <Step n={2} icon={<FolderTree size={16} />} href="#teach" title={learnedRules ? `${learnedRules} rule${learnedRules === 1 ? '' : 's'} learned from you` : 'No rules learned yet'} sub={learnedRules ? 'Edit or delete them under Settings, Tagger, Guide.' : 'After three answers on a boundary, press Write rules on the Teach page.'} done={learnedRules > 0} />
                <li className="flex flex-wrap items-center gap-x-4 gap-y-3 border-t border-[#f3f3f3] px-5 py-4 sm:px-7">
                  <StepNum n={3} done={applied} />
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 text-[14.5px] font-semibold tracking-[-0.01em] text-ink">
                      <SlidersHorizontal size={15} className="text-mute" />
                      {applied ? 'The suggested floors are in use' : changes.length ? `Use the ${changes.length} suggested floor${changes.length === 1 ? '' : 's'}` : 'No floor to suggest yet'}
                    </div>
                    <p className="mt-0.5 text-[13px] leading-[1.45] text-mute">{changes.length ? `The lowest floor per mood whose applied moods are at least ${pct(r.targetPrecision)} right, with five or more films behind it.` : 'A floor needs five or more judged films behind it before it counts.'}</p>
                  </div>
                  <Button variant={applied ? 'secondary' : 'primary'} size="sm" disabled={busy || changes.length === 0} onClick={() => void accept()}>
                    {applied ? 'In use' : 'Use them'}
                  </Button>
                </li>
              </ol>
            </Card>

            <Card title="Policies side by side" sub="Every policy at the current floors, over the same decisions. The one in use is marked.">
              <table className="w-full text-[13.5px]">
                <thead>
                  <tr>
                    <th className={cn(th, 'text-left')}>Policy</th>
                    <th className={cn(th, 'w-[80px] text-right')}>Applied</th>
                    <th className={cn(th, 'w-[80px] text-right')}>Right</th>
                    <th className={cn(th, 'w-[96px] text-right')}>Precision</th>
                    <th className={cn(th, 'w-[110px] text-right')}>Wilson low</th>
                  </tr>
                </thead>
                <tbody className="tabular-nums">
                  {POLICY_ORDER.filter((v) => r.versions[v]).map((v) => {
                    const o: EvalOverall = r.versions[v];
                    const inUse = v === r.policyVersion;
                    return (
                      <tr key={v}>
                        <td className={cn(td, 'text-ink')}>
                          {policyLabel(v)} <span className="text-faint">({v})</span>
                          {inUse && <span className="ml-2 inline-flex h-[20px] items-center rounded-full bg-ink px-2 text-[11px] font-semibold text-white">in use</span>}
                        </td>
                        <td className={cn(td, 'text-right text-ink')}>{o.applied}</td>
                        <td className={cn(td, 'text-right text-ink')}>{o.correct}</td>
                        <td className={cn(td, 'text-right text-ink')}>{pct(o.precision, 1)}</td>
                        <td className={cn(td, 'text-right text-mute')}>{pct(o.wilsonLower, 1)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </Card>

            <Card flush title="Floors per mood" sub={`Current floor against the suggested one. A suggestion is the lowest floor on the 0.50 to 0.90 grid that keeps the applied moods at least ${pct(r.targetPrecision)} right with five or more films behind it. Brier: how well the grader's probability matched your call, lower is better.`}>
              <div className="overflow-x-auto px-5 pb-5 sm:px-7">
                <table className="w-full min-w-[760px] text-[13.5px]">
                  <thead>
                    <tr>
                      <th className={cn(th, 'text-left')}>Mood</th>
                      <th className={cn(th, 'w-[90px] text-right')}>Judged</th>
                      <th className={cn(th, 'w-[72px] text-right')}>Floor</th>
                      <th className={cn(th, 'w-[72px] text-right')}>Applied</th>
                      <th className={cn(th, 'w-[64px] text-right')}>Right</th>
                      <th className={cn(th, 'w-[96px] text-right')}>Wilson low</th>
                      <th className={cn(th, 'w-[72px] text-right')}>Recall</th>
                      <th className={cn(th, 'w-[64px] text-right')}>Brier</th>
                      <th className={cn(th, 'w-[110px] rounded-t-xl bg-[#f7f7f7] pr-3 text-right')}>Suggested</th>
                    </tr>
                  </thead>
                  <tbody className="tabular-nums">
                    {sortMoods(r.moods).map((m, i, a) => {
                      const judged = m.positives + m.negatives;
                      const differs = m.suggestedFloor != null && m.suggestedFloor !== m.currentFloor;
                      return (
                        <tr key={m.slug} className={judged === 0 ? 'text-faint' : ''}>
                          <td className={cn(td, 'pr-3', judged ? 'text-ink' : 'text-faint')}>{m.title}</td>
                          <td className={cn(td, 'text-right text-mute')}>
                            {judged ? (
                              <>
                                <span className="text-good">{m.positives}</span> <span className="text-faint">/</span> <span className="text-bad">{m.negatives}</span>
                              </>
                            ) : (
                              '-'
                            )}
                          </td>
                          <td className={cn(td, 'text-right text-ink')}>{m.currentFloor.toFixed(2)}</td>
                          <td className={cn(td, 'text-right')}>{judged ? m.current.applied : '-'}</td>
                          <td className={cn(td, 'text-right')}>{judged ? m.current.correct : '-'}</td>
                          <td className={cn(td, 'text-right text-mute')}>{pct(m.current.wilsonLower, 1)}</td>
                          <td className={cn(td, 'text-right text-mute')}>{pct(m.current.recall)}</td>
                          <td className={cn(td, 'text-right text-mute')}>{m.brier == null ? '-' : m.brier.toFixed(2)}</td>
                          <td className={cn(td, 'bg-[#f7f7f7] pr-3 text-right', differs ? 'font-semibold text-ink' : 'text-mute', i === a.length - 1 && 'rounded-b-xl')}>
                            {m.suggestedFloor == null ? '-' : m.suggestedFloor.toFixed(2)}
                            {differs && <span className="ml-1 text-[11px] text-[#0e8a4a]">●</span>}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              <div className="flex flex-wrap items-center gap-3 border-t border-[#f2f2f2] px-5 py-4 sm:px-7">
                <Button variant="primary" size="sm" disabled={busy || changes.length === 0} reason={changes.length === 0 ? (applied ? 'The suggested floors are in use' : 'No floor has enough decisions behind it yet') : null} onClick={() => void accept()}>
                  {applied ? 'Suggested floors in use' : 'Use the suggested floors'}
                </Button>
                <span className="text-[12.5px] text-faint">Floors can also be set by hand under Settings, Tagger, Floors per mood.</span>
              </div>
            </Card>
          </>
        )}
      </div>
    </div>
  );
}

// Moods with judgments first, most judged on top; the rest alphabetical.
function sortMoods(moods: EvalMoodReport[]): EvalMoodReport[] {
  return [...moods].sort((a, b) => {
    const ja = a.positives + a.negatives;
    const jb = b.positives + b.negatives;
    if ((ja > 0) !== (jb > 0)) return ja > 0 ? -1 : 1;
    if (ja !== jb) return jb - ja;
    return a.title.localeCompare(b.title);
  });
}

function StepNum({ n, done }: { n: number; done?: boolean }) {
  return <span className={cn('grid h-7 w-7 shrink-0 place-items-center rounded-full text-[12.5px] font-semibold tabular-nums', done ? 'bg-ink text-white' : 'bg-[#f3f3f3] text-mute')}>{done ? <Check size={13} strokeWidth={3} /> : n}</span>;
}

function Step({ n, icon, href, title, sub, done }: { n: number; icon: ReactNode; href: string; title: string; sub: string; done?: boolean }) {
  return (
    <li className="border-t border-[#f3f3f3] first:border-t-0">
      <a href={href} className="group flex items-center gap-4 px-5 py-4 transition hover:bg-[#fafafa] sm:px-7">
        <StepNum n={n} done={done} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 text-[14.5px] font-semibold tracking-[-0.01em] text-ink">
            <span className="text-mute">{icon}</span>
            {title}
          </div>
          <p className="mt-0.5 text-[13px] leading-[1.45] text-mute">{sub}</p>
        </div>
        <span className="inline-flex shrink-0 items-center gap-1 text-[13px] font-medium text-ink">
          <span className="hidden sm:inline">Open</span> <ArrowRight size={14} className="transition group-hover:translate-x-0.5" />
        </span>
      </a>
    </li>
  );
}
