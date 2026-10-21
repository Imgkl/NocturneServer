import { useState } from 'react';
import { Check } from 'lucide-react';
import { Button } from '../ui/Button';
import { Field, inputCls } from '../ui/Input';

interface ApiKeyFormProps {
  label: string;
  placeholder: string;
  helpText?: string;
  isSet: boolean;
  onSave: (key: string) => Promise<void>;
}

export function ApiKeyForm({ label, placeholder, helpText, isSet, onSave }: ApiKeyFormProps) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    const v = value.trim();
    if (!v) return;
    setBusy(true);
    try {
      await onSave(v);
      setValue('');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Field
      label={
        <span className="inline-flex items-center gap-2">
          {label}
          {isSet && (
            <span className="inline-flex items-center gap-1 text-good">
              <Check size={12} strokeWidth={3} /> set
            </span>
          )}
        </span>
      }
      hint={helpText}
    >
      <div className="flex gap-2">
        <input
          type="password"
          autoComplete="off"
          placeholder={isSet && !value ? '•••••••••••• (paste a new key to replace)' : placeholder}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void submit();
          }}
          className={inputCls}
        />
        <Button variant="primary" size="md" onClick={() => void submit()} disabled={busy || !value.trim()}>
          {busy ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </Field>
  );
}
