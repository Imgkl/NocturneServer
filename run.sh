# Make it executable
# chmod +x run.sh
# and run it with ./run.sh

#!/bin/sh
set -euo pipefail
cd frontend/nocturne-web && npm install && npm run build
cd ../../
mkdir -p data
swift build
DB_PATH="${NOCTURNE_DATABASE_PATH:-$PWD/data/nocturne.sqlite}"
exec env NOCTURNE_DATABASE_PATH="$DB_PATH" .build/debug/NocturneServer
