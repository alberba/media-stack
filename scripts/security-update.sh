#!/usr/bin/env bash
# Host entry point: installation, verified security updates and crash recovery.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$REPO/stacks/monitoring/security-monitor/updater.py" "${@:-run}"
