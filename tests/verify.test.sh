#!/usr/bin/env bash
# Tests for scripts/verify.sh, with docker and curl replaced by fakes on PATH.
# Usage: tests/verify.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO/scripts/verify.sh"
. "$REPO/tests/lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin"
  export ENV_FILE="$SANDBOX/.env"
  printf 'COMPOSE_PROFILES=\n' > "$ENV_FILE"
  export FAKE_UNHEALTHY="" FAKE_MISSING="" FAKE_HOST_IP="203.0.113.10" FAKE_VPN_IP="198.51.100.20" FAKE_WIRE="exited 0" FAKE_SEED="exited 0" FAKE_COMPOSE_FAIL=0
  export FAKE_TOPOLOGY="$REPO/stacks/wire/wire/topology.py"
  export FAKE_DOCKER_LOG="$SANDBOX/docker.log"
  cat > "$SANDBOX/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  compose)
    [ "$FAKE_COMPOSE_FAIL" = 0 ] || exit 1
    profiles="$(sed -n 's/^COMPOSE_PROFILES=//p' "$ENV_FILE")"
    python3 -B "$FAKE_TOPOLOGY" services --profiles "$profiles" ;;
  inspect)
    name="${*: -1}"
    [ "$name" = "$FAKE_MISSING" ] && { echo "Error: No such object: $name" >&2; exit 1; }
    [ "$name" = wire ] && { echo "$FAKE_WIRE"; exit 0; }
    [ "$name" = wire-seed ] && { echo "$FAKE_SEED"; exit 0; }
    if [ "$name" = "$FAKE_UNHEALTHY" ]; then echo unhealthy; else echo healthy; fi ;;
  exec) echo "$FAKE_VPN_IP" ;;
esac
FAKE
  cat > "$SANDBOX/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$FAKE_HOST_IP"
FAKE
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"
}
teardown() { rm -rf "$SANDBOX"; }

run_verify() { OUTPUT="$("$VERIFY" 2>&1)"; STATUS=$?; }

test_passes_when_all_healthy_and_egress_is_the_vpn() {
  run_verify
  assert_status 0
  assert_output_contains "198.51.100.20"
}

test_fails_when_a_service_is_unhealthy() {
  FAKE_UNHEALTHY=sonarr run_verify
  assert_status 1
  assert_output_contains "sonarr"
}

test_fails_when_a_service_is_missing() {
  FAKE_MISSING=seerr run_verify
  assert_status 1
  assert_output_contains "seerr"
}

test_fails_when_the_wiring_failed() {
  FAKE_WIRE="exited 1" run_verify
  assert_status 1
  assert_output_contains "docker compose logs wire"
}

test_fails_while_the_wiring_is_still_running() {
  FAKE_WIRE="running 0" run_verify
  assert_status 1
  assert_output_contains "still connecting"
}

test_fails_when_the_wiring_never_ran() {
  FAKE_MISSING=wire run_verify
  assert_status 1
  assert_output_contains "wire never ran"
}

test_fails_when_qbittorrent_leaks_the_host_ip() {
  FAKE_VPN_IP="203.0.113.10" run_verify
  assert_status 1
  assert_output_contains "NOT"
}

test_fails_when_qbittorrent_has_no_internet() {
  FAKE_VPN_IP="" run_verify
  assert_status 1
}

test_fails_when_the_host_ip_is_unknown() {
  FAKE_HOST_IP="" run_verify
  assert_status 1
}

test_checks_vo_services_enabled_in_the_instance_env() {
  printf 'COMPOSE_PROFILES=backup, vo\n' > "$ENV_FILE"
  FAKE_UNHEALTHY=radarr-vo run_verify
  assert_status 1
  assert_output_contains "radarr-vo is unhealthy"
  assert_file_contains "$FAKE_DOCKER_LOG" "sonarr-vo"
}

test_does_not_check_vo_services_when_disabled() {
  FAKE_MISSING=radarr-vo run_verify
  assert_status 0
  assert_file_not_contains "$FAKE_DOCKER_LOG" "radarr-vo"
}

test_checks_the_seed_completed_successfully() {
  FAKE_SEED="exited 1" run_verify
  assert_status 1
  assert_output_contains "docker compose logs wire-seed"
}

test_compose_resolution_failure_stops_verification() {
  FAKE_COMPOSE_FAIL=1 run_verify
  assert_status 1
  assert_output_contains "cannot resolve"
  assert_file_not_contains "$FAKE_DOCKER_LOG" "inspect"
}

run_tests
