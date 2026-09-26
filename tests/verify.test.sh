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
  export FAKE_UNHEALTHY="" FAKE_MISSING="" FAKE_HOST_IP="203.0.113.10" FAKE_VPN_IP="198.51.100.20"
  cat > "$SANDBOX/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  inspect)
    name="${*: -1}"
    [ "$name" = "$FAKE_MISSING" ] && { echo "Error: No such object: $name" >&2; exit 1; }
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

run_tests
