import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { cn } from '../lib/cn';
import { moodTitle } from '../lib/policy';
import { Button } from '../ui/Button';
import { inputCls } from '../ui/Input';
import type { GuideResponse, MoodBuckets } from '../lib/types';

interface GuideEditorProps {
  moods: MoodBuckets;
  say: (text: string, tone?: 'ok' | 'error') => void;
  // The guide version changed (an edit, a reset, a rule removed).
  onVersion?: (version: number) => void;
}

// The guide AI reads on every film: the manual text (the bundled one until edited) and the rules
// learned from the owner's Teach answers, which both AI and the grader get appended.
export function GuideEditor({ moods, say, onVersion }: GuideEditorProps) {
  const [guide, setGuide] = useState<GuideResponse | null>(null);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);

  const apply = (g: GuideResponse) => {
    setGuide(g);
    setText(g.manual);
    onVersion?.(g.version);
  };
  useEffect(() => {
    api.guide
      .get()
      .then((g) => {
        setGuide(g);
        setText(g.manual);
      })
      .catch((e: unknown) => say(e instanceof Error ? e.message : 'Failed to load the guide', 'error'));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (!guide) return <div className="skel h-24" />;
  const edited = text !== guide.manual;

  async function run(label: string, work: () => Promise<GuideResponse>) {
    setBusy(true);
    try {
      apply(await work());
      say(label);
    } catch (e) {
      say(e instanceof Error ? e.message : 'Failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  const boundaryLabel = (key: string) => key.split('|').map((s) => moodTitle(moods, s)).join(' or ');

  return (
    <div className="space-y-4">
      <p className="text-[12.5px] text-faint">
        AI reads this on every film; the grader reads it too. {guide.bundled ? 'This is the bundled guide.' : 'Edited from the bundled guide.'} Guide v{guide.version}. The learned rules below are appended automatically.
      </p>
      <textarea value={text} onChange={(e) => setText(e.target.value)} rows={16} spellCheck={false} className={cn(inputCls, 'h-auto min-h-[240px] w-full resize-y py-2 font-mono text-[12.5px] leading-[1.5]')} />
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="primary" size="sm" disabled={!edited || busy || !text.trim()} onClick={() => void run('Guide saved', () => api.guide.save(text))}>
          Save guide
        </Button>
        {edited && (
          <Button variant="ghost" size="sm" disabled={busy} onClick={() => setText(guide.manual)}>
            Discard edits
          </Button>
        )}
        {!guide.bundled && (
          <Button variant="outline" size="sm" disabled={busy} onClick={() => void run('Back to the bundled guide', () => api.guide.reset())}>
            Reset to bundled
          </Button>
        )}
      </div>
      <div>
        <div className="mb-2 text-[12px] font-semibold text-mute">Learned from you · {guide.learned.length}</div>
        {guide.learned.length === 0 ? (
          <p className="text-[12.5px] text-faint">Nothing yet. Answer the Teach list, then press Write rules there.</p>
        ) : (
          <ul className="space-y-1.5">
            {guide.learned.map((r, i) => (
              <li key={`${r.boundary}-${i}`} className="flex items-start gap-2 text-[13px] text-[#3a3a3a]">
                <span className="min-w-0 flex-1">
                  <span className="text-faint">{boundaryLabel(r.boundary)} · </span>
                  {r.text}
                </span>
                <button type="button" disabled={busy} onClick={() => void run('Rule removed', () => api.guide.removeLearned(i))} className="shrink-0 text-[12px] text-faint underline decoration-[#dcdcdc] underline-offset-4 hover:text-ink cursor-pointer">
                  delete
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
