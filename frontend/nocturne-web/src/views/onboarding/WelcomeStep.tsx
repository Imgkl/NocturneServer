import { Button } from '../../ui/Button';
import { Wordmark } from '../../components/Logo';

interface WelcomeStepProps {
  onStart: () => void;
}

export function WelcomeStep({ onStart }: WelcomeStepProps) {
  return (
    <div className="flex max-w-[440px] flex-col items-center text-center">
      <Wordmark className="text-[22px]" />
      <h1 className="mt-8 text-[34px] font-semibold leading-[1.05] tracking-[-0.035em] text-ink">Your library, sorted by mood.</h1>
      <p className="mt-3 text-[15px] leading-[1.55] text-mute">Connect Jellyfin, let the reader work through the stories, and keep the moods you agree with.</p>
      <Button variant="primary" size="lg" onClick={onStart} className="mt-8">
        Get started
      </Button>
    </div>
  );
}
