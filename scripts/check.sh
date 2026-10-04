#!/usr/bin/env bash
# Shared validation entry point for contributors, CI and release validation.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
MODE="${1:-fast}"
case "$MODE" in
  fast|ci|integration|release) ;;
  *) echo 'Usage: scripts/check.sh [fast|ci|integration|release]' >&2; exit 1 ;;
esac
if [ "$MODE" != fast ] && [ "$(uname -s)" != Linux ]; then
  echo 'Full checks require Linux/GNU utilities. See docs/agents/testing.md.' >&2
  exit 1
fi
if [ "$MODE" = integration ]; then
  exec bash tests/wire-integration.test.sh
fi

scripts=(scripts/*.sh scripts/lib/*.sh tests/*.sh stacks/*/*.sh .githooks/pre-commit)
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${scripts[@]}"
else
  docker run --rm -v "$REPO:/repo:ro" -w /repo koalaman/shellcheck:v0.10.0 "${scripts[@]}"
fi
python3 scripts/env_contract.py check
[ "$MODE" != fast ] || exit 0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 scripts/env_contract.py fixture > "$WORK/instance.env"
python3 scripts/env_contract.py fixture --scope worker > "$WORK/worker.env"
# Use Template fixtures even when this checkout also hosts a running Instance.
while IFS= read -r key; do unset "$key"; done < <(python3 -c \
  'import json; print("\n".join(json.load(open("env/catalog.json"))))')
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE
compose() { docker compose --project-directory "$REPO" --env-file "$WORK/instance.env" -f compose.yaml "$@"; }
compose config --quiet
while IFS= read -r profile; do
  [ -z "$profile" ] || compose --profile "$profile" config --quiet
done < <(compose config --profiles)
compose --profile '*' config --quiet
compose -f compose.gpu.yaml --profile '*' config --quiet
compose -f compose.gpu.yaml -f compose.syncplay.yaml config --quiet
docker compose --project-directory "$REPO/worker" --env-file "$WORK/worker.env" config --quiet
python3 scripts/env_contract.py validate --scope worker --file "$WORK/worker.env"
for test in tests/*.test.sh; do
  if [ "$MODE" = ci ] && [ "$test" = tests/wire-integration.test.sh ]; then continue; fi
  echo "Running $test"
  if [ "$test" = tests/init.test.sh ] && [ "$EUID" != 0 ]; then
    sudo bash "$test"
  else
    bash "$test"
  fi
done
compose --profile '*' build
