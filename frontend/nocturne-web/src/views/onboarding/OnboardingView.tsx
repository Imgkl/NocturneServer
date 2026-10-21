import { useState } from 'react';
import { cn } from '../../lib/cn';
import { WelcomeStep } from './WelcomeStep';
import { ConnectStep } from './ConnectStep';
import { DoneStep } from './DoneStep';

type Step = 'welcome' | 'connect' | 'done';

interface OnboardingViewProps {
  onFinished: () => void;
}

export function OnboardingView({ onFinished }: OnboardingViewProps) {
  const [step, setStep] = useState<Step>('welcome');

  return (
    <div className="relative flex min-h-screen items-center justify-center bg-white px-5 py-16">
      <StepPips step={step} />
      <div key={step} className="rise flex w-full justify-center">
        {step === 'welcome' && <WelcomeStep onStart={() => setStep('connect')} />}
        {step === 'connect' && <ConnectStep onConnected={() => setStep('done')} />}
        {step === 'done' && <DoneStep onOpenLibrary={onFinished} />}
      </div>
    </div>
  );
}

function StepPips({ step }: { step: Step }) {
  const order: Step[] = ['welcome', 'connect', 'done'];
  const active = order.indexOf(step);
  return (
    <div className="fixed left-1/2 top-8 flex -translate-x-1/2 gap-1.5" style={{ top: 'calc(32px + env(safe-area-inset-top, 0px))' }}>
      {order.map((s, i) => (
        <span key={s} className={cn('block h-1.5 rounded-full transition-all duration-300', i === active ? 'w-6 bg-ink' : 'w-1.5 bg-line-2')} aria-current={i === active ? 'step' : undefined} />
      ))}
    </div>
  );
}
