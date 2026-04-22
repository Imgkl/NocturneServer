#!/bin/sh
set -eu

# Fix ownership on bind-mounted volumes so the unprivileged nocturne user can write.
# Idempotent: no-op if already correct. Silently ignored if the fs is read-only.
for d in /app/data /app/config /app/logs; do
  if [ -d "$d" ]; then
    chown -R nocturne:nocturne "$d" 2>/dev/null || true
  fi
done

exec gosu nocturne:nocturne "$@"
