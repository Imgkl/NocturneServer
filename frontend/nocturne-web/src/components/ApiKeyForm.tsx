import { useState } from 'react';
import { Button } from '../ui/Button';
import { Input } from '../ui/Input';

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

  const effectivePlaceholder = isSet && !value ? '••••••••••••' : placeholder;

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
    <div className="space-y-3">
      <div className="flex items-end gap-2">
        <div className="flex-1">
          <Input
            label={label}
            type="password"
            placeholder={effectivePlaceholder}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') submit();
            }}
          />
        </div>
        <Button variant="primary" size="sm" onClick={submit} disabled={busy || !value.trim()}>
          {busy ? 'Saving…' : 'Save'}
        </Button>
      </div>
      {helpText && <p className="text-[11px] text-muted">{helpText}</p>}
    </div>
  );
}
