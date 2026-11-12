#!/usr/bin/env bash
# Prepare the optional apps server; updates use the same host updater as the Instance.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/apps-server"
if [ "${1:-init}" != init ]; then
  echo 'Usage: scripts/apps-server.sh [init]' >&2
  exit 1
fi
python3 "$REPO/scripts/env_contract.py" validate --scope apps-server --file .env
docker compose config --quiet
APPDATA="$(python3 "$REPO/scripts/env_contract.py" get --scope apps-server --file .env --name APPDATA_ROOT)"
if [[ "$APPDATA" != /* ]] || [ "$APPDATA" = / ]; then
  echo 'APPDATA_ROOT must be an absolute directory other than /' >&2
  exit 1
fi
elevate=()
if [ "$EUID" != 0 ]; then elevate=(sudo); fi
"${elevate[@]}" install -d -m 750 "$APPDATA"
# Seerr runs as node (1000); do not recursively change existing App data.
"${elevate[@]}" install -d -m 750 -o 1000 -g 1000 "$APPDATA/seerr"
"${elevate[@]}" install -d -m 700 "$APPDATA/wud" "$APPDATA/security-monitor"
echo 'Apps server ready. Start with: cd apps-server && docker compose up -d --build'
