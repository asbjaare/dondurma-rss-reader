#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f "$root/.tools/env.sh" ]]; then
  echo 'Run bash scripts/setup-dev.sh first.' >&2
  exit 1
fi
source "$root/.tools/env.sh"
if [[ -f "$root/.tools/signing.env" ]]; then
  source "$root/.tools/signing.env"
fi
cd "$root"
exec "$root/.tools/flutter/bin/flutter" "$@"
