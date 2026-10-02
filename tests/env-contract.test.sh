#!/usr/bin/env bash
# Public contract checks for Instance settings, Worker settings and Wiring inputs.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  python3 "$REPO/scripts/env_contract.py" fixture > "$SANDBOX/.env"
  python3 "$REPO/scripts/env_contract.py" fixture --scope worker > "$SANDBOX/worker.env"
}
teardown() { rm -rf "$SANDBOX"; }

test_worker_requires_its_server_address() {
  sed -i 's/^TDARR_SERVER_IP=.*/TDARR_SERVER_IP=/' "$SANDBOX/worker.env"
  OUTPUT="$(python3 "$REPO/scripts/env_contract.py" validate --scope worker --file "$SANDBOX/worker.env" 2>&1)"; STATUS=$?
  assert_status 1
  assert_output_contains "TDARR_SERVER_IP"
}

test_unknown_and_duplicate_instance_settings_warn_without_blocking() {
  printf 'TZ=Europe/Brussels\nOPERATOR_EXTENSION=enabled\n' >> "$SANDBOX/.env"
  OUTPUT="$(python3 "$REPO/scripts/env_contract.py" validate --file "$SANDBOX/.env" 2>&1)"; STATUS=$?
  assert_status 0
  assert_output_contains "warning: TZ occurs"
  assert_output_contains "warning: OPERATOR_EXTENSION"
}

test_assistant_reports_indirect_shell_override_of_an_extension() {
  # shellcheck disable=SC2016 # Write literal Compose interpolation to the fixture.
  sed -i 's|^APPDATA_ROOT=.*|APPDATA_ROOT=${CUSTOM_ROOT}/app|' "$SANDBOX/.env"
  sed -i '1iCUSTOM_ROOT=/file' "$SANDBOX/.env"
  export CUSTOM_ROOT=/shell
  [ "$(python3 "$REPO/scripts/env_contract.py" get --file "$SANDBOX/.env" --name APPDATA_ROOT)" = /file/app ] \
    || fail "the assistant did not read the file value"
  OUTPUT="$(python3 "$REPO/scripts/env_contract.py" overrides --file "$SANDBOX/.env" 2>&1)"; STATUS=$?
  assert_status 0
  assert_output_contains "CUSTOM_ROOT: shell overrides"
  assert_output_contains "APPDATA_ROOT: shell interpolation changes"
}

test_assistant_reports_shell_only_interpolation() {
  # shellcheck disable=SC2016 # Write literal Compose interpolation to the fixture.
  sed -i 's|^APPDATA_ROOT=.*|APPDATA_ROOT=${CUSTOM_ROOT:-/file}/app|' "$SANDBOX/.env"
  export CUSTOM_ROOT=/shell
  [ "$(python3 "$REPO/scripts/env_contract.py" get --file "$SANDBOX/.env" --name APPDATA_ROOT)" = /file/app ] \
    || fail "the assistant read an exported fallback as a file value"
  OUTPUT="$(python3 "$REPO/scripts/env_contract.py" overrides --file "$SANDBOX/.env" 2>&1)"; STATUS=$?
  assert_status 0
  assert_output_contains "APPDATA_ROOT: shell interpolation changes"
}

test_wiring_receives_only_cataloged_inputs() {
  local model
  model="$(docker compose --project-directory "$REPO" --env-file "$SANDBOX/.env" config --format json)" || fail "Compose config failed"
  MODEL="$model" python3 - <<'PY' || fail "Wiring environment differs from the contract"
import json, os
services = json.loads(os.environ["MODEL"])["services"]
for service in ("wire", "wire-seed"):
    env = services[service]["environment"]
    assert env["RADARR_API_KEY"] == "dummy"
    assert "RESTIC_PASSWORD" not in env
PY
}

test_generated_contract_files_are_current() {
  OUTPUT="$(python3 "$REPO/scripts/env_contract.py" check 2>&1)"; STATUS=$?
  assert_status 0
}

run_tests
