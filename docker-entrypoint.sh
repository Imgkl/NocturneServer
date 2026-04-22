#!/bin/sh
set -eu

# Fix ownership on bind-mounted volumes so the unprivileged rasa user can write.
# Idempotent: no-op if already correct. Silently ignored if the fs is read-only.
for d in /app/data /app/config /app/logs; do
  if [ -d "$d" ]; then
    chown -R rasa:rasa "$d" 2>/dev/null || true
  fi
done

exec gosu rasa:rasa "$@"
