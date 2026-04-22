import { useState } from 'react';
import { AnimatePresence, motion } from 'framer-motion';
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
    <div className="min-h-screen bg-bg text-text font-sans flex items-center justify-center px-5 py-10 relative">
      <StepPips step={step} />
      <AnimatePresence mode="wait">
        <motion.div
          key={step}
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8 }}
          transition={{ duration: 0.25 }}
          className="flex justify-center"
        >
          {step === 'welcome' && <WelcomeStep onStart={() => setStep('connect')} />}
          {step === 'connect' && <ConnectStep onConnected={() => setStep('done')} />}
          {step === 'done' && <DoneStep onOpenLibrary={onFinished} />}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

function StepPips({ step }: { step: Step }) {
  const order: Step[] = ['welcome', 'connect', 'done'];
  const active = order.indexOf(step);
  return (
    <div className="fixed top-8 left-1/2 -translate-x-1/2 flex gap-2">
      {order.map((s, i) => (
        <span
          key={s}
          className={`block w-6 h-px ${i === active ? 'bg-text' : 'bg-border'}`}
          aria-current={i === active ? 'step' : undefined}
        />
      ))}
    </div>
  );
}
