import { Button } from '../../ui/Button';

interface WelcomeStepProps {
  onStart: () => void;
}

export function WelcomeStep({ onStart }: WelcomeStepProps) {
  return (
    <div className="flex flex-col items-center text-center max-w-xl">
      <h1 className="font-serif italic text-6xl lg:text-7xl text-text mb-4">Nocturne</h1>
      <p className="text-[14px] text-text-dim mb-10">Your library, indexed by mood.</p>
      <Button variant="primary" onClick={onStart}>
        Get started
      </Button>
    </div>
  );
}
