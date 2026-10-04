#!/usr/bin/env bash
# Verify Seerr can write to the same fixture used by the real-app integration test.
# shellcheck disable=SC1091
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/wire-integration.test.sh"
setup() {
  WORK="$(mktemp -d)"; mkdir "$WORK/appdata"
  ENVFILE="$WORK/env"
  printf 'SEERR_API_KEY=%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > "$ENVFILE"
  unset KEEP
}
teardown() {
  if [ -d "$WORK" ]; then
    docker run --rm --network none --user root --entrypoint sh \
      -v "$WORK:/fixture" "$(image seerr)" -c 'rm -rf /fixture/appdata'
    rm -f "$ENVFILE"
    rmdir "$WORK"
  fi
  if [ -n "${DIAGNOSTIC_REPORT:-}" ]; then rm -rf "$DIAGNOSTIC_REPORT"; fi
}
test_seerr_image_can_write_to_its_fixture() {
  prepare_seerr || fail 'Seerr fixture preparation failed'
  OUTPUT="$(docker run --rm --network none --entrypoint node \
    -v "$WORK/appdata/seerr:/app/config" "$(image seerr)" \
    -e 'const fs = require("fs"); fs.writeFileSync("/app/config/probe", "ok"); process.stdout.write(fs.readFileSync("/app/config/probe", "utf8"))' 2>&1)"; STATUS=$?
  assert_status 0
  # The private directory belongs to node, not the non-root CI runner.
  [ "$OUTPUT" = ok ] || fail "Seerr did not read back its fixture file: $OUTPUT"
}
test_failure_saves_redacted_logs_before_removing_containers() {
  local secret
  secret="$(cut -d= -f2 "$ENVFILE")"
  docker run -d --name "$P-probe" --network none --env-file "$ENVFILE" --entrypoint node \
    "$(image seerr)" -e 'console.log("fixture failure " + process.env.SEERR_API_KEY)' >/dev/null
  docker wait "$P-probe" >/dev/null
  OUTPUT="$( (trap cleanup EXIT; exit 37) 2>&1)"; STATUS=$?
  assert_status 37
  assert_output_contains 'fixture failure <REDACTED>'
  assert_output_not_contains "$secret"
  DIAGNOSTIC_REPORT="$(sed -n 's/^Wiring failed; redacted container diagnostics: //p' <<< "$OUTPUT")"
  assert_dir "$DIAGNOSTIC_REPORT"
  [ -z "$(docker ps -aq --filter "name=^$P-")" ] || fail 'scratch containers were left behind'
  grep -qF 'fixture failure <REDACTED>' "$DIAGNOSTIC_REPORT"/*.log || fail 'failure log was lost during cleanup'
}
run_tests
